#!/usr/bin/env python3
"""Serve a mounted DuckDB database through the Quack protocol."""

import os
import signal
import subprocess
import threading
from pathlib import Path

import duckdb

from dataset_catalog import DATASET_COLUMNS, job_csv_files

def sql_string(value: str) -> str:
    return value.replace("'", "''")


def configured_tables(source: str) -> list[str]:
    prefix = source.upper()
    return os.environ.get(
        f"ACCIO_TABLES_{prefix}", os.environ.get(f"TPCH_TABLES_{prefix}", "")
    ).split()


def initialize_dataset(connection: duckdb.DuckDBPyConnection, source: str) -> None:
    dataset = os.environ.get("ACCIO_DATASET", "tpch").lower()
    if dataset not in DATASET_COLUMNS:
        raise SystemExit(f"[duckdb-source] unsupported ACCIO_DATASET={dataset}")
    columns_by_table = DATASET_COLUMNS[dataset]
    placement = os.environ.get(
        "ACCIO_DATASET_VARIANT", os.environ.get("TPCH_PLACEMENT", "custom")
    )
    signature = (
        os.environ.get("TPCH_SCALE", "1")
        if dataset == "tpch"
        else os.environ.get("ACCIO_DATASET_VERSION", "job")
    )
    tables = configured_tables(source)
    unknown = set(tables) - columns_by_table.keys()
    if unknown:
        raise SystemExit(f"[duckdb-source] unknown {dataset} tables: {sorted(unknown)}")

    metadata_exists = connection.execute(
        """
        SELECT count(*) FROM information_schema.tables
        WHERE table_schema = 'main' AND table_name = 'accio_dataset_metadata'
        """
    ).fetchone()[0]
    if metadata_exists:
        print("[duckdb-source] reusing initialized database", flush=True)
        return

    data_dir = Path(
        os.environ.get(
            "ACCIO_DATA_MOUNT", os.environ.get("TPCH_DATA_MOUNT", "/benchmark-data")
        )
    )
    for table in tables:
        columns = columns_by_table[table]
        print(f"[duckdb-source] loading {table}", flush=True)
        if dataset == "job":
            input_files = job_csv_files(data_dir, table)
            if not input_files:
                raise SystemExit(f"[duckdb-source] missing JOB CSV data for {table}")
            ddl = ", ".join(f'"{name}" {kind}' for name, kind in columns)
            file_list = ", ".join(f"'{sql_string(str(path))}'" for path in input_files)
            connection.execute(f'CREATE TABLE "{table}" ({ddl})')
            connection.execute(
                f"""
                INSERT INTO "{table}"
                SELECT * FROM read_csv(
                    [{file_list}], header = false, all_varchar = true,
                    delim = ',', quote = '"', escape = '\\', nullstr = ''
                )
                """
            )
        else:
            input_file = data_dir / f"{table}.tbl"
            if not input_file.is_file():
                raise SystemExit(f"[duckdb-source] missing {input_file}")
            with input_file.open("rb") as stream:
                first_row = stream.readline().rstrip(b"\r\n")
            if not first_row:
                raise SystemExit(f"[duckdb-source] empty input file: {input_file}")
            csv_columns = columns + ([('_accio_trailing', 'VARCHAR')] if first_row.endswith(b'|') else [])
            columns_sql = ", ".join(f"'{name}': '{kind}'" for name, kind in csv_columns)
            select_sql = ", ".join(f'"{name}"' for name, _ in columns)
            connection.execute(
                f"""
                CREATE OR REPLACE TABLE "{table}" AS
                SELECT {select_sql}
                FROM read_csv(
                    '{sql_string(str(input_file))}',
                    delim = '|', header = false, auto_detect = false,
                    columns = {{{columns_sql}}}
                )
                """
            )

    connection.execute("ANALYZE")
    connection.execute(
        """
        CREATE TABLE accio_dataset_metadata (
            placement VARCHAR, source_id VARCHAR, table_list VARCHAR,
            scale VARCHAR, loaded_at TIMESTAMPTZ DEFAULT current_timestamp
        )
        """
    )
    connection.execute(
        "INSERT INTO accio_dataset_metadata VALUES (?, ?, ?, ?, current_timestamp)",
        [placement, source, " ".join(tables), signature],
    )
    connection.execute("CHECKPOINT")


database = os.environ.get("DUCKDB_DATABASE", "/data/source.duckdb")
source_id = os.environ.get("ACCIO_SOURCE_ID", os.environ.get("TPCH_SOURCE_ID", "")).strip()
token = os.environ.get(f"{source_id.upper()}_TOKEN", "") or os.environ.get("QUACK_TOKEN", "")
if len(token) < 4:
    raise SystemExit("[duckdb-source] set a Quack token of at least four characters")
threads = int(os.environ.get("DUCKDB_THREADS", "4"))
memory = os.environ.get("DUCKDB_MEMORY", "8GB")
bandwidth = os.environ.get("BANDWIDTH", "none")
if bandwidth != "none":
    subprocess.run(
        ["tc", "qdisc", "replace", "dev", "eth0", "root", "netem", "rate", bandwidth],
        check=True,
    )

connection = duckdb.connect(database)
connection.execute(f"SET threads = {threads}")
connection.execute(f"SET memory_limit = '{sql_string(memory)}'")
if source_id:
    initialize_dataset(connection, source_id)
connection.execute("LOAD quack")
connection.execute(
    "CALL quack_serve('quack:0.0.0.0:9494', "
    f"token => '{sql_string(token)}', allow_other_hostname => true)"
)
print(f"[duckdb-source] serving {database} on port 9494", flush=True)

stopped = threading.Event()


def stop(_signum, _frame):
    stopped.set()


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
stopped.wait()

connection.execute("CALL quack_stop('quack:0.0.0.0:9494')")
connection.close()
