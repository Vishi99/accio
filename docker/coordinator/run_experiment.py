#!/usr/bin/env python3
"""Wait for the TPC-H sources, generate Accio config, and run DuckDB."""

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
DEFAULT_SOURCES = ("db1", "db2", "db3", "db4")
DEFAULT_PLACEMENTS = {
    "v0": {
        "db1": {"region", "nation", "supplier", "customer", "orders", "lineitem"},
        "db2": {"part", "partsupp"},
        "db3": set(),
        "db4": set(),
    },
    "v1": {
        "db1": {"region", "nation", "supplier", "customer", "part", "partsupp"},
        "db2": {"orders", "lineitem"},
        "db3": set(),
        "db4": set(),
    },
    "v2": {
        "db1": {"part", "partsupp", "orders", "lineitem"},
        "db2": {"region", "nation", "supplier", "customer"},
        "db3": set(),
        "db4": set(),
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


def first_env(*names: str, default: str | None = None) -> str:
    for name in names:
        value = os.environ.get(name, "").strip()
        if value:
            return value
    if default is not None and default.strip():
        return default.strip()
    raise SystemExit(
        f"[accio-coordinator] set one of these environment variables: {', '.join(names)}"
    )


def configured_sources() -> tuple[str, ...]:
    sources = tuple(os.environ.get("ACCIO_SOURCES", " ".join(DEFAULT_SOURCES)).split())
    if not sources:
        raise SystemExit("[accio-coordinator] ACCIO_SOURCES must contain at least one source")
    if len(set(sources)) != len(sources):
        raise SystemExit("[accio-coordinator] ACCIO_SOURCES contains duplicates")
    invalid = [source for source in sources if not re.fullmatch(r"[a-z][a-z0-9_]*", source)]
    if "coordinator" in sources:
        invalid.append("coordinator (reserved)")
    if invalid:
        raise SystemExit(
            "[accio-coordinator] source names must be lowercase identifiers; "
            f"invalid: {invalid}"
        )
    return sources


def configured_tables(placement: str, sources: tuple[str, ...]) -> dict[str, set[str]]:
    if placement not in DEFAULT_PLACEMENTS:
        raise SystemExit("[accio-coordinator] TPCH_PLACEMENT must be v0, v1, or v2")

    coordinator_tables = set(os.environ.get("TPCH_TABLES_COORDINATOR", "").split())
    result: dict[str, set[str]] = {"coordinator": coordinator_tables}
    for source in sources:
        override = os.environ.get(f"TPCH_TABLES_{source.upper()}", "").split()
        result[source] = (
            set(override)
            if override
            else DEFAULT_PLACEMENTS[placement].get(source, set()) - coordinator_tables
        )

    all_assigned = set().union(*result.values())
    overlap = {
        table
        for table in ALL_TABLES
        if sum(table in assigned_tables for assigned_tables in result.values()) > 1
    }
    unknown = all_assigned - ALL_TABLES
    missing = ALL_TABLES - all_assigned
    if overlap or unknown or missing:
        raise SystemExit(
            "[accio-coordinator] invalid table distribution: "
            f"overlap={sorted(overlap)}, unknown={sorted(unknown)}, missing={sorted(missing)}"
        )
    return result


def source_config(source: str) -> dict[str, object]:
    prefix = source.upper()
    source_type = env(f"{prefix}_TYPE", "POSTGRES").upper()
    cost_params = {
        "join": float(env("COST_JOIN", "2.0")),
        "agg": float(env("COST_AGG", "2.0")),
        "sort": float(env("COST_SORT", "2.0")),
        "trans": float(env("COST_TRANSFER", "10.0")),
    }
    if source_type == "POSTGRES":
        host = env(f"{prefix}_HOST", f"postgres{source[-1]}")
        port = int(env(f"{prefix}_PORT", "5432"))
        database = first_env(
            f"{prefix}_DATABASE",
            "POSTGRES_DB",
            default=f"tpch{env('TPCH_SCALE', '1')}",
        )
        return {
            "type": "POSTGRES",
            "driver": "org.postgresql.Driver",
            "url": os.environ.get(
                f"{prefix}_JDBC_URL",
                f"jdbc:postgresql://{host}:{port}/{database}",
            ),
            "username": first_env(f"{prefix}_USERNAME", "POSTGRES_USER", default="postgres"),
            "password": first_env(f"{prefix}_PASSWORD", "POSTGRES_PASSWORD"),
            "costParams": cost_params,
            "cardEstType": "postgres",
            "partitionType": "postgres",
            "partition": {"max_parallelism": int(env("PG_MAX_PARALLELISM", "8"))},
            "dialect": "postgres",
            "disableOps": [],
        }
    if source_type in {"DUCKDB", "QUACK"}:
        host = env(f"{prefix}_HOST", f"duckdb{source[-1]}")
        port = int(env(f"{prefix}_PORT", "9494"))
        token = first_env(f"{prefix}_TOKEN", "QUACK_TOKEN")
        return {
            "type": "QUACK",
            "driver": "com.gizmodata.quack.jdbc.sql.QuackDriver",
            "url": os.environ.get(
                f"{prefix}_JDBC_URL",
                f"jdbc:quack://{host}:{port}",
            ),
            "username": "",
            "password": token,
            "costParams": cost_params,
            "cardEstType": "duckdb",
            "dialect": "postgres",
            "quackDisableSsl": env(f"{prefix}_DISABLE_SSL", "true").lower()
            in {"1", "true", "yes"},
            "disableOps": [],
        }
    if source_type == "DATAFUSION":
        host = env(f"{prefix}_HOST", f"datafusion{source[-1]}")
        port = int(env(f"{prefix}_PORT", "5432"))
        database = env(f"{prefix}_DATABASE", "postgres")
        return {
            # DuckDB executes remote fragments through its PostgreSQL connector.
            # accioSourceType preserves the real engine identity for readiness.
            "type": "POSTGRES",
            "accioSourceType": "DATAFUSION",
            "driver": "org.postgresql.Driver",
            "url": os.environ.get(
                f"{prefix}_JDBC_URL",
                f"jdbc:postgresql://{host}:{port}/{database}",
            ),
            "username": env(f"{prefix}_USERNAME", "postgres"),
            # The development PGWire server accepts any credentials. A
            # non-empty placeholder keeps PostgreSQL URI parsers happy.
            "password": os.environ.get(f"{prefix}_PASSWORD", "unused"),
            "costParams": cost_params,
            # DataFusion does not expose meaningful PostgreSQL reltuples/
            # pg_stats or CTID. Unknown values select Accio's generic paths.
            "cardEstType": "default",
            "partitionType": "default",
            "dialect": "datafusion",
            "disableOps": [],
        }
    raise SystemExit(
        f"[accio-coordinator] unsupported {prefix}_TYPE={source_type}; "
        "use POSTGRES, DUCKDB, QUACK, or DATAFUSION"
    )


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


def postgres_source_state(
    config: dict[str, object],
) -> tuple[bool, tuple[object, ...] | None, set[str]]:
    with psycopg2.connect(**connection_kwargs(config)) as connection:
        with connection.cursor() as cursor:
            cursor.execute("SELECT to_regclass('public.accio_dataset_metadata')")
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
    return metadata_table is not None, metadata, actual_tables


def quack_query(
    connection: duckdb.DuckDBPyConnection,
    config: dict[str, object],
    query: str,
) -> list[tuple[object, ...]]:
    uri = str(config["url"]).removeprefix("jdbc:")
    disable_ssl = "true" if config.get("quackDisableSsl", True) else "false"
    uri_sql = uri.replace("'", "''")
    query_sql = query.replace("'", "''")
    token_sql = str(config["password"]).replace("'", "''")
    return connection.execute(
        "SELECT * FROM quack_query("
        f"'{uri_sql}', '{query_sql}', token = '{token_sql}', "
        f"disable_ssl = {disable_ssl})"
    ).fetchall()


def quack_source_state(
    config: dict[str, object],
) -> tuple[bool, tuple[object, ...] | None, set[str]]:
    with duckdb.connect(":memory:") as connection:
        connection.execute("LOAD quack")
        metadata_table = bool(
            quack_query(
                connection,
                config,
                """
                SELECT 1 FROM information_schema.tables
                WHERE table_schema = 'main'
                  AND table_name = 'accio_dataset_metadata'
                LIMIT 1
                """,
            )
        )
        metadata = None
        if metadata_table:
            rows = quack_query(
                connection,
                config,
                """
                SELECT placement, source_id, table_list, scale
                FROM accio_dataset_metadata
                ORDER BY loaded_at DESC
                LIMIT 1
                """,
            )
            metadata = rows[0] if rows else None
        actual_tables = {
            str(row[0])
            for row in quack_query(
                connection,
                config,
                """
                SELECT table_name FROM information_schema.tables
                WHERE table_schema = 'main'
                  AND table_name <> 'accio_dataset_metadata'
                """,
            )
        }
    return metadata_table, metadata, actual_tables


def datafusion_source_state(
    config: dict[str, object], expected_tables: set[str]
) -> tuple[bool, tuple[object, ...] | None, set[str]]:
    """Probe assigned tables without relying on PostgreSQL system catalogs."""
    with psycopg2.connect(**connection_kwargs(config)) as connection:
        with connection.cursor() as cursor:
            for table in sorted(expected_tables):
                if table not in ALL_TABLES:
                    raise ValueError(f"invalid TPC-H table name: {table}")
                cursor.execute(f'SELECT * FROM "{table}" LIMIT 0')
    return False, None, set(expected_tables)


def source_state(
    config: dict[str, object], expected_tables: set[str]
) -> tuple[bool, tuple[object, ...] | None, set[str]]:
    if str(config.get("accioSourceType", "")).upper() == "DATAFUSION":
        return datafusion_source_state(config, expected_tables)
    if str(config["type"]).upper() == "QUACK":
        return quack_source_state(config)
    return postgres_source_state(config)


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
    metadata_empty_since: float | None = None
    last_error = "not attempted"
    print(
        f"[accio-coordinator] waiting for {source} to load "
        f"{sorted(expected_tables)} (timeout: {timeout}s)",
        flush=True,
    )
    while time.monotonic() < deadline:
        try:
            metadata_table, metadata, actual_tables = source_state(config, expected_tables)
        except Exception as error:  # readiness failures are retried until the deadline
            error_text = str(error)
            sqlstate = getattr(error, "pgcode", None) or getattr(
                getattr(error, "diag", None), "sqlstate", None
            )
            actual_source_type = str(
                config.get("accioSourceType", config["type"])
            ).upper()
            database_absent = sqlstate == "3D000" or re.search(
                r'database "[^"]+" does not exist', error_text, re.IGNORECASE
            )
            if actual_source_type == "POSTGRES" and database_absent:
                raise SystemExit(
                    f"[accio-coordinator] configured database is absent on {source}; "
                    "reset the PostgreSQL volume after changing TPCH_SCALE"
                ) from error
            last_error = error_text
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

        if str(config.get("accioSourceType", "")).upper() == "DATAFUSION":
            print(
                f"[accio-coordinator] {source} is ready with "
                f"{sorted(actual_tables)}",
                flush=True,
            )
            return

        if metadata is None:
            now = time.monotonic()
            if metadata_table:
                if metadata_empty_since is None:
                    metadata_empty_since = now
                elif now - metadata_empty_since >= 15:
                    raise SystemExit(
                        f"[accio-coordinator] {source} has an empty "
                        "accio_dataset_metadata table; source initialization "
                        "was interrupted or failed. Inspect the source logs, then "
                        "reset its data volume"
                    )
                last_error = "accio_dataset_metadata exists but is empty"
            else:
                metadata_empty_since = None
                last_error = "accio_dataset_metadata has not been created yet"
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
                f"expected {placement}/{source}/sf{scale}; reset the source data volume"
            )
        if actual_tables != expected_tables:
            raise SystemExit(
                f"[accio-coordinator] stale table placement in {source}: "
                f"got {sorted(actual_tables)}, expected {sorted(expected_tables)}; "
                "reset the source data volume"
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
            with input_file.open("rb") as input_stream:
                first_row = input_stream.readline().rstrip(b"\r\n")
            if not first_row:
                raise SystemExit(f"[accio-coordinator] coordinator data file is empty: {input_file}")
            has_trailing_delimiter = first_row.endswith(b"|")
            csv_columns = (
                columns + [("_accio_trailing", "VARCHAR")]
                if has_trailing_delimiter
                else columns
            )
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
                    auto_detect = false,
                    columns = {{{columns_sql}}}
                )
                """
            )


def prepare_workload(
    source_dir: Path,
    output_dir: Path,
    tables: dict[str, set[str]],
    sources: tuple[str, ...],
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
    source_pattern = "|".join(re.escape(source) for source in sources)
    query_files = sorted(source_dir.glob("q*.sql"))
    if not query_files:
        raise SystemExit(f"[accio-coordinator] no q*.sql files found in {source_dir}")
    for query_file in query_files:
        sql = query_file.read_text()
        for table, owner in owners.items():
            target = table if owner == "coordinator" else f"{owner}.{table}"
            sql = re.sub(
                rf"\b(?:{source_pattern})\.{table}\b",
                target,
                sql,
                flags=re.IGNORECASE,
            )
        (output_dir / query_file.name).write_text(sql)
    return output_dir


def main() -> None:
    placement = env("TPCH_PLACEMENT", "v1")
    scale = env("TPCH_SCALE", "1")
    sources = configured_sources()
    tables = configured_tables(placement, sources)
    configs = {source: source_config(source) for source in sources}
    timeout = int(env("STARTUP_TIMEOUT_SECONDS", "7200"))

    for source in sources:
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
        sources,
    )

    query = os.environ.get("ACCIO_QUERY", "").strip()
    if query and not (workload / f"{query}.sql").is_file():
        raise SystemExit(f"[accio-coordinator] query does not exist: {workload / f'{query}.sql'}")

    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    run_name = f"tpch-sf{scale}-{placement}-{query or 'all'}-{timestamp}"
    work_dir = Path("/tmp/accio-runs") / run_name
    database_path = work_dir / "run.duckdb"
    log_path = results_dir / f"{run_name}.log"
    shutil.rmtree(work_dir, ignore_errors=True)
    work_dir.mkdir(parents=True)
    try:
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
        command.extend(sources)

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
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
