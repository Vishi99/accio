import os


def _sql_string(value):
    return str(value).replace("'", "''")


def _postgres_queries(db, sql):
    statements = [statement.strip() for statement in sql.split(";") if statement.strip()]
    return " UNION ALL ".join(
        f"SELECT * FROM postgres_query('{_sql_string(db)}', "
        f"'{_sql_string(statement)}')"
        for statement in statements
    )


def _identifier(value):
    return '"' + str(value).replace('"', '""') + '"'


def _pg_arrow_type(column, pyarrow):
    type_code = column.type_code
    if type_code == 16:
        return pyarrow.bool_()
    if type_code == 21:
        return pyarrow.int16()
    if type_code == 23:
        return pyarrow.int32()
    if type_code == 20:
        return pyarrow.int64()
    if type_code == 700:
        return pyarrow.float32()
    if type_code == 701:
        return pyarrow.float64()
    if type_code == 1082:
        return pyarrow.date32()
    if type_code == 1114:
        return pyarrow.timestamp("us")
    if type_code == 1184:
        return pyarrow.timestamp("us", tz="UTC")
    if type_code == 1700:
        precision = column.precision or 38
        scale = column.scale or 0
        return pyarrow.decimal128(min(precision, 38), scale)
    return pyarrow.string()


def _arrow_batch(rows, description, pyarrow):
    arrays = []
    for index, column in enumerate(description):
        values = [row[index] for row in rows]
        if values:
            arrays.append(pyarrow.array(values))
        else:
            arrays.append(pyarrow.array([], type=_pg_arrow_type(column, pyarrow)))
    return pyarrow.Table.from_arrays(arrays, names=[column.name for column in description])


def _register_datafusion_view(conn, source, sql, alias):
    import psycopg2
    import pyarrow

    batch_rows = int(os.environ.get("DATAFUSION_FETCH_BATCH_ROWS", "100000"))
    if batch_rows < 1:
        raise ValueError("DATAFUSION_FETCH_BATCH_ROWS must be at least 1")

    materialized = f"__accio_datafusion_{alias}"
    staging = f"{materialized}_batch"
    quoted_materialized = _identifier(materialized)
    quoted_staging = _identifier(staging)
    quoted_alias = _identifier(alias)
    first_batch = True

    with psycopg2.connect(source["url"]) as remote_connection:
        with remote_connection.cursor() as cursor:
            cursor.execute(sql.rstrip().rstrip(";"))
            while True:
                rows = cursor.fetchmany(batch_rows)
                if not rows and not first_batch:
                    break
                batch = _arrow_batch(rows, cursor.description, pyarrow)
                conn.register(staging, batch)
                try:
                    if first_batch:
                        conn.sql(
                            f"CREATE OR REPLACE TEMP TABLE {quoted_materialized} "
                            f"AS SELECT * FROM {quoted_staging}"
                        )
                    else:
                        conn.sql(
                            f"INSERT INTO {quoted_materialized} "
                            f"SELECT * FROM {quoted_staging}"
                        )
                finally:
                    conn.unregister(staging)
                first_batch = False
                if not rows:
                    break

    conn.sql(
        f"CREATE OR REPLACE TEMP VIEW {quoted_alias} "
        f"AS SELECT * FROM {quoted_materialized}"
    )


def _remote_query(db, sql, card, accio=None):
    if accio is not None:
        source = accio.dbs[db]
        config = source["config"]
        if config["type"].upper() == "QUACK":
            quack_uri = str(config["url"]).removeprefix("jdbc:")
            disable_ssl = "true" if config.get("quackDisableSsl", True) else "false"
            return (
                "SELECT * FROM quack_query("
                f"'{_sql_string(quack_uri)}', "
                f"'{_sql_string(sql)}', "
                f"token = '{_sql_string(config.get('password', ''))}', "
                f"disable_ssl = {disable_ssl})"
            )
        if config["type"].upper() == "POSTGRES" and not os.environ.get(
            "DUCK_PG_EXTENSION", ""
        ).strip():
            # Accio's PostgreSQL partitioner returns a semicolon-separated list
            # of disjoint CTID queries. DuckDB's postgres_query accepts only one
            # prepared statement, so expose the partitions as a UNION ALL.
            return _postgres_queries(db, sql)
    escaped_sql = sql.replace('"', '""')
    return f"SELECT * FROM postgres_query('{db}', \"{escaped_sql}\", {card})"


def registerTmpView(conn, db, sql, alias, card, accio=None):
    if accio is not None:
        source = accio.dbs[db]
        if str(source["config"].get("accioSourceType", "")).upper() == "DATAFUSION":
            _register_datafusion_view(conn, source, sql, alias)
            return
    remote_query = _remote_query(db, sql, card, accio)
    conn.sql(f"CREATE OR REPLACE TEMP VIEW {alias} AS ({remote_query})")


def run_duckdb(plan, conn, accio=None):
    for v in plan.temp_views:
        registerTmpView(conn, v.db, v.sql, v.alias, v.card, accio)
    return conn.sql(plan.local.sql)


def clean_duckdb(plan, conn):
    for v in plan.temp_views:
        conn.sql(f"DROP VIEW IF EXISTS {v.alias}")
        conn.sql(f"DROP TABLE IF EXISTS {_identifier(f'__accio_datafusion_{v.alias}')}")
