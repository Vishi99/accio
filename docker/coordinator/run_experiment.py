#!/usr/bin/env python3
"""Wait for the two TPC-H sources, generate Accio config, and run DuckDB."""

from __future__ import annotations

import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import psycopg2
import duckdb


ALL_TABLES = {
    "region",
    "nation",
    "supplier",
    "customer",
    "part",
    "partsupp",
    "orders",
    "lineitem",
}
DEFAULT_PLACEMENTS = {
    "v0": {
        "db1": {"region", "nation", "supplier", "customer", "orders", "lineitem"},
        "db2": {"part", "partsupp"},
    },
    "v1": {
        "db1": {"region", "nation", "supplier", "customer", "part", "partsupp"},
        "db2": {"orders", "lineitem"},
    },
    "v2": {
        "db1": {"part", "partsupp", "orders", "lineitem"},
        "db2": {"region", "nation", "supplier", "customer"},
    },
}
TPCH_COLUMNS = {
    "region": [("r_regionkey", "INTEGER"), ("r_name", "VARCHAR"), ("r_comment", "VARCHAR")],
    "nation": [("n_nationkey", "INTEGER"), ("n_name", "VARCHAR"), ("n_regionkey", "INTEGER"), ("n_comment", "VARCHAR")],
    "supplier": [("s_suppkey", "BIGINT"), ("s_name", "VARCHAR"), ("s_address", "VARCHAR"), ("s_nationkey", "INTEGER"), ("s_phone", "VARCHAR"), ("s_acctbal", "DECIMAL(15,2)"), ("s_comment", "VARCHAR")],
    "customer": [("c_custkey", "BIGINT"), ("c_name", "VARCHAR"), ("c_address", "VARCHAR"), ("c_nationkey", "INTEGER"), ("c_phone", "VARCHAR"), ("c_acctbal", "DECIMAL(15,2)"), ("c_mktsegment", "VARCHAR"), ("c_comment", "VARCHAR")],
    "part": [("p_partkey", "BIGINT"), ("p_name", "VARCHAR"), ("p_mfgr", "VARCHAR"), ("p_brand", "VARCHAR"), ("p_type", "VARCHAR"), ("p_size", "INTEGER"), ("p_container", "VARCHAR"), ("p_retailprice", "DECIMAL(15,2)"), ("p_comment", "VARCHAR")],
    "partsupp": [("ps_partkey", "BIGINT"), ("ps_suppkey", "BIGINT"), ("ps_availqty", "INTEGER"), ("ps_supplycost", "DECIMAL(15,2)"), ("ps_comment", "VARCHAR")],
    "orders": [("o_orderkey", "BIGINT"), ("o_custkey", "BIGINT"), ("o_orderstatus", "VARCHAR"), ("o_totalprice", "DECIMAL(15,2)"), ("o_orderdate", "DATE"), ("o_orderpriority", "VARCHAR"), ("o_clerk", "VARCHAR"), ("o_shippriority", "INTEGER"), ("o_comment", "VARCHAR")],
    "lineitem": [("l_orderkey", "BIGINT"), ("l_partkey", "BIGINT"), ("l_suppkey", "BIGINT"), ("l_linenumber", "INTEGER"), ("l_quantity", "DECIMAL(15,2)"), ("l_extendedprice", "DECIMAL(15,2)"), ("l_discount", "DECIMAL(15,2)"), ("l_tax", "DECIMAL(15,2)"), ("l_returnflag", "VARCHAR"), ("l_linestatus", "VARCHAR"), ("l_shipdate", "DATE"), ("l_commitdate", "DATE"), ("l_receiptdate", "DATE"), ("l_shipinstruct", "VARCHAR"), ("l_shipmode", "VARCHAR"), ("l_comment", "VARCHAR")],
}


def env(name: str, default: str | None = None) -> str:
    value = os.environ.get(name, default)
    if value is None or not value.strip():
        raise SystemExit(f"[accio-coordinator] required environment variable {name} is not set")
    return value.strip()


def configured_tables(placement: str) -> dict[str, set[str]]:
    if placement not in DEFAULT_PLACEMENTS:
        raise SystemExit("[accio-coordinator] TPCH_PLACEMENT must be v0, v1, or v2")

    coordinator_tables = set(os.environ.get("TPCH_TABLES_COORDINATOR", "").split())
    result: dict[str, set[str]] = {"coordinator": coordinator_tables}
    for source in ("db1", "db2"):
        override = os.environ.get(f"TPCH_TABLES_{source.upper()}", "").split()
        result[source] = (
            set(override)
            if override
            else DEFAULT_PLACEMENTS[placement][source] - coordinator_tables
        )

    all_assigned = result["db1"] | result["db2"] | result["coordinator"]
    overlap = (
        (result["db1"] & result["db2"])
        | (result["db1"] & result["coordinator"])
        | (result["db2"] & result["coordinator"])
    )
    unknown = all_assigned - ALL_TABLES
    missing = ALL_TABLES - all_assigned
    if overlap or unknown or missing:
        raise SystemExit(
            "[accio-coordinator] invalid table distribution: "
            f"overlap={sorted(overlap)}, unknown={sorted(unknown)}, missing={sorted(missing)}"
        )
    return result


def source_config(source: str) -> dict[str, object]:
    host = env(f"{source.upper()}_HOST", f"postgres{source[-1]}")
    port = int(env(f"{source.upper()}_PORT", "5432"))
    user = env("POSTGRES_USER", "postgres")
    password = env("POSTGRES_PASSWORD")
    database = env("POSTGRES_DB", f"tpch{env('TPCH_SCALE', '1')}")
    max_parallelism = int(env("PG_MAX_PARALLELISM", "8"))

    return {
        "type": "POSTGRES",
        "driver": "org.postgresql.Driver",
        "url": f"jdbc:postgresql://{host}:{port}/{database}",
        "username": user,
        "password": password,
        "costParams": {
            "join": float(env("COST_JOIN", "2.0")),
            "agg": float(env("COST_AGG", "2.0")),
            "sort": float(env("COST_SORT", "2.0")),
            "trans": float(env("COST_TRANSFER", "10.0")),
        },
        "cardEstType": "postgres",
        "partitionType": "postgres",
        "partition": {"max_parallelism": max_parallelism},
        "dialect": "postgres",
        "disableOps": [],
    }


def connection_kwargs(config: dict[str, object]) -> dict[str, object]:
    jdbc_url = str(config["url"])
    address = jdbc_url.removeprefix("jdbc:postgresql://")
    host_port, database = address.split("/", maxsplit=1)
    host, port = host_port.rsplit(":", maxsplit=1)
    return {
        "host": host,
        "port": int(port),
        "dbname": database,
        "user": config["username"],
        "password": config["password"],
        "connect_timeout": 5,
    }


def wait_for_source(
    source: str,
    config: dict[str, object],
    expected_tables: set[str],
    placement: str,
    scale: str,
    timeout: int,
) -> None:
    started = time.monotonic()
    deadline = started + timeout
    next_progress_report = started + 30
    last_error = "not attempted"
    print(
        f"[accio-coordinator] waiting for {source} to load "
        f"{sorted(expected_tables)} (timeout: {timeout}s)",
        flush=True,
    )
    while time.monotonic() < deadline:
        try:
            with psycopg2.connect(**connection_kwargs(config)) as connection:
                with connection.cursor() as cursor:
                    cursor.execute(
                        "SELECT to_regclass('public.accio_dataset_metadata')"
                    )
                    metadata_table = cursor.fetchone()[0]
                    metadata = None
                    if metadata_table is not None:
                        cursor.execute(
                            """
                            SELECT placement, source_id, table_list, scale
                            FROM accio_dataset_metadata
                            ORDER BY loaded_at DESC
                            LIMIT 1
                            """
                        )
                        metadata = cursor.fetchone()
                    cursor.execute(
                        """
                        SELECT table_name
                        FROM information_schema.tables
                        WHERE table_schema = 'public'
                          AND table_name <> 'accio_dataset_metadata'
                        """
                    )
                    actual_tables = {row[0] for row in cursor.fetchall()}
        except Exception as error:  # readiness failures are retried until the deadline
            if getattr(error, "pgcode", None) == "3D000":
                raise SystemExit(
                    f"[accio-coordinator] configured database is absent on {source}; "
                    "reset the PostgreSQL volume after changing TPCH_SCALE"
                ) from error
            last_error = str(error)
            now = time.monotonic()
            if now >= next_progress_report:
                detail = " ".join(last_error.splitlines())
                print(
                    f"[accio-coordinator] still waiting for {source} "
                    f"after {int(now - started)}s: {detail}",
                    flush=True,
                )
                next_progress_report = now + 30
            time.sleep(5)
            continue

        if metadata is None:
            last_error = "accio_dataset_metadata is empty"
            now = time.monotonic()
            if now >= next_progress_report:
                print(
                    f"[accio-coordinator] still waiting for {source} "
                    f"after {int(now - started)}s: {last_error}",
                    flush=True,
                )
                next_progress_report = now + 30
            time.sleep(5)
            continue
        actual_placement, actual_source, _, actual_scale = metadata
        if (actual_placement, actual_source, actual_scale) != (placement, source, scale):
            raise SystemExit(
                "[accio-coordinator] stale dataset metadata in "
                f"{source}: got {actual_placement}/{actual_source}/sf{actual_scale}, "
                f"expected {placement}/{source}/sf{scale}; reset the PostgreSQL volume"
            )
        if actual_tables != expected_tables:
            raise SystemExit(
                f"[accio-coordinator] stale table placement in {source}: "
                f"got {sorted(actual_tables)}, expected {sorted(expected_tables)}; "
                "reset the PostgreSQL volume"
            )
        print(f"[accio-coordinator] {source} is ready with {sorted(actual_tables)}", flush=True)
        return

    raise SystemExit(
        f"[accio-coordinator] timed out after {timeout}s waiting for {source}: {last_error}"
    )


def write_configs(
    config_dir: Path,
    configs: dict[str, dict[str, object]],
    coordinator_tables: set[str],
) -> None:
    config_dir.mkdir(parents=True, exist_ok=True)
    for source, config in configs.items():
        (config_dir / f"{source}.json").write_text(json.dumps(config, indent=2) + "\n")
    local_schema = {
        table: [column for column, _ in TPCH_COLUMNS[table]]
        for table in sorted(coordinator_tables)
    }
    local = {"type": "MANUAL", "dialect": "postgres", "schema": local_schema}
    (config_dir / "local.json").write_text(json.dumps(local, indent=2) + "\n")


def load_coordinator_tables(
    database_path: Path,
    coordinator_tables: set[str],
    data_dir: Path,
) -> None:
    if not coordinator_tables:
        return
    if not data_dir.is_dir():
        raise SystemExit(
            f"[accio-coordinator] coordinator TPC-H data directory does not exist: {data_dir}"
        )

    with duckdb.connect(str(database_path)) as connection:
        for table in sorted(coordinator_tables):
            input_file = data_dir / f"{table}.tbl"
            if not input_file.is_file():
                raise SystemExit(f"[accio-coordinator] missing coordinator data file: {input_file}")
            print(f"[accio-coordinator] loading local DuckDB table {table}", flush=True)
            columns = TPCH_COLUMNS[table]
            csv_columns = columns + [("_accio_trailing", "VARCHAR")]
            columns_sql = ", ".join(
                f"'{name}': '{data_type}'" for name, data_type in csv_columns
            )
            select_sql = ", ".join(f'"{name}"' for name, _ in columns)
            file_sql = str(input_file).replace("'", "''")
            connection.execute(
                f"""
                CREATE OR REPLACE TABLE "{table}" AS
                SELECT {select_sql}
                FROM read_csv(
                    '{file_sql}',
                    delim = '|',
                    header = false,
                    columns = {{{columns_sql}}}
                )
                """
            )


def prepare_workload(
    source_dir: Path,
    output_dir: Path,
    tables: dict[str, set[str]],
) -> Path:
    if not source_dir.is_dir():
        raise SystemExit(f"[accio-coordinator] workload directory does not exist: {source_dir}")
    shutil.rmtree(output_dir, ignore_errors=True)
    output_dir.mkdir(parents=True)

    owners = {
        table: owner
        for owner, assigned_tables in tables.items()
        for table in assigned_tables
    }
    query_files = sorted(source_dir.glob("q*.sql"))
    if not query_files:
        raise SystemExit(f"[accio-coordinator] no q*.sql files found in {source_dir}")
    for query_file in query_files:
        sql = query_file.read_text()
        for table, owner in owners.items():
            target = table if owner == "coordinator" else f"{owner}.{table}"
            sql = re.sub(
                rf"\bdb[12]\.{table}\b",
                target,
                sql,
                flags=re.IGNORECASE,
            )
        (output_dir / query_file.name).write_text(sql)
    return output_dir


def main() -> None:
    placement = env("TPCH_PLACEMENT", "v1")
    scale = env("TPCH_SCALE", "1")
    tables = configured_tables(placement)
    configs = {source: source_config(source) for source in ("db1", "db2")}
    timeout = int(env("STARTUP_TIMEOUT_SECONDS", "7200"))

    for source in ("db1", "db2"):
        wait_for_source(source, configs[source], tables[source], placement, scale, timeout)

    config_dir = Path(env("ACCIO_CONFIG_DIR", "/experiment/config"))
    results_dir = Path(env("RESULTS_DIR", "/experiment/results"))
    results_dir.mkdir(parents=True, exist_ok=True)
    write_configs(config_dir, configs, tables["coordinator"])

    workload_value = os.environ.get("WORKLOAD_DIR", "").strip()
    source_workload = Path(workload_value or f"/opt/accio/workload/tpch2_{placement}")
    workload = prepare_workload(
        source_workload,
        Path("/experiment/workload"),
        tables,
    )

    query = os.environ.get("ACCIO_QUERY", "").strip()
    if query and not (workload / f"{query}.sql").is_file():
        raise SystemExit(f"[accio-coordinator] query does not exist: {workload / f'{query}.sql'}")

    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    run_name = f"tpch-sf{scale}-{placement}-{query or 'all'}-{timestamp}"
    database_path = results_dir / f"{run_name}.duckdb"
    load_coordinator_tables(
        database_path,
        tables["coordinator"],
        Path(env("TPCH_DATA_MOUNT", "/tpch-data")),
    )
    command = [
        sys.executable,
        "/opt/accio/benchmark/bench_duckdb.py",
        "accio",
        "--config",
        str(config_dir),
        "--workload",
        str(workload),
        "--strategy",
        env("ACCIO_STRATEGY", "benefit"),
        "--runs",
        env("ACCIO_RUNS", "1"),
        "--cores",
        env("ACCIO_CORES", "4"),
        "--memory",
        env("ACCIO_MEMORY", "8GB"),
        "--dbfile",
        str(database_path),
    ]
    if query:
        command.extend(["--query", query])
    if os.environ.get("ACCIO_EXPLAIN", "false").lower() in {"1", "true", "yes"}:
        command.append("--explain")
    command.extend(["db1", "db2"])

    log_path = results_dir / f"{run_name}.log"
    print(f"[accio-coordinator] running: {shlex.join(command)}", flush=True)
    print(f"[accio-coordinator] result log: {log_path}", flush=True)
    with log_path.open("w", encoding="utf-8") as log_file:
        process = subprocess.Popen(
            command,
            cwd="/opt/accio",
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        assert process.stdout is not None
        for line in process.stdout:
            sys.stdout.write(line)
            sys.stdout.flush()
            log_file.write(line)
            log_file.flush()
        return_code = process.wait()

    if return_code:
        raise SystemExit(return_code)
    print(f"[accio-coordinator] experiment completed successfully: {run_name}", flush=True)


if __name__ == "__main__":
    main()
