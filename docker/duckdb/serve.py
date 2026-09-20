#!/usr/bin/env python3
"""Serve a mounted DuckDB database through the Quack protocol."""

import os
import signal
import subprocess
import threading
from pathlib import Path

import duckdb


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


def sql_string(value: str) -> str:
    return value.replace("'", "''")


def initialize_tpch(connection: duckdb.DuckDBPyConnection, source: str) -> None:
    placement = os.environ.get("TPCH_PLACEMENT", "custom")
    scale = os.environ.get("TPCH_SCALE", "1")
    tables = os.environ.get(f"TPCH_TABLES_{source.upper()}", "").split()
    unknown = set(tables) - TPCH_COLUMNS.keys()
    if unknown:
        raise SystemExit(f"[duckdb-source] unknown TPC-H tables: {sorted(unknown)}")

    metadata_exists = connection.execute(
        """
        SELECT count(*) FROM information_schema.tables
        WHERE table_schema = 'main' AND table_name = 'accio_dataset_metadata'
        """
    ).fetchone()[0]
    if metadata_exists:
        print("[duckdb-source] reusing initialized database", flush=True)
        return

    data_dir = Path(os.environ.get("TPCH_DATA_MOUNT", "/tpch-data"))
    for table in tables:
        input_file = data_dir / f"{table}.tbl"
        if not input_file.is_file():
            raise SystemExit(f"[duckdb-source] missing {input_file}")
        with input_file.open("rb") as stream:
            first_row = stream.readline().rstrip(b"\r\n")
        if not first_row:
            raise SystemExit(f"[duckdb-source] empty input file: {input_file}")
        columns = TPCH_COLUMNS[table]
        csv_columns = columns + ([('_accio_trailing', 'VARCHAR')] if first_row.endswith(b'|') else [])
        columns_sql = ", ".join(f"'{name}': '{kind}'" for name, kind in csv_columns)
        select_sql = ", ".join(f'"{name}"' for name, _ in columns)
        print(f"[duckdb-source] loading {table}", flush=True)
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
        [placement, source, " ".join(tables), scale],
    )
    connection.execute("CHECKPOINT")


database = os.environ.get("DUCKDB_DATABASE", "/data/source.duckdb")
source_id = os.environ.get("TPCH_SOURCE_ID", "").strip()
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
    initialize_tpch(connection, source_id)
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
