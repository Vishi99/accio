import os


def _sql_string(value):
    return str(value).replace("'", "''")


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
            return (
                f"SELECT * FROM postgres_query('{_sql_string(db)}', "
                f"'{_sql_string(sql)}')"
            )
    escaped_sql = sql.replace('"', '""')
    return f"SELECT * FROM postgres_query('{db}', \"{escaped_sql}\", {card})"


def registerTmpView(conn, db, sql, alias, card, accio=None):
    remote_query = _remote_query(db, sql, card, accio)
    conn.sql(f"CREATE OR REPLACE TEMP VIEW {alias} AS ({remote_query})")


def run_duckdb(plan, conn, accio=None):
    for v in plan.temp_views:
        registerTmpView(conn, v.db, v.sql, v.alias, v.card, accio)
    return conn.sql(plan.local.sql)


def clean_duckdb(plan, conn):
    for v in plan.temp_views:
        conn.sql(f"DROP VIEW IF EXISTS {v.alias}")
