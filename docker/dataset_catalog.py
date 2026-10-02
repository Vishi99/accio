"""Schemas and file discovery shared by the Docker experiment helpers."""

from __future__ import annotations

from pathlib import Path


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

JOB_COLUMNS = {
    "aka_name": [("id", "INTEGER"), ("person_id", "INTEGER"), ("name", "VARCHAR"), ("imdb_index", "VARCHAR"), ("name_pcode_cf", "VARCHAR"), ("name_pcode_nf", "VARCHAR"), ("surname_pcode", "VARCHAR"), ("md5sum", "VARCHAR")],
    "aka_title": [("id", "INTEGER"), ("movie_id", "INTEGER"), ("title", "VARCHAR"), ("imdb_index", "VARCHAR"), ("kind_id", "INTEGER"), ("production_year", "INTEGER"), ("phonetic_code", "VARCHAR"), ("episode_of_id", "INTEGER"), ("season_nr", "INTEGER"), ("episode_nr", "INTEGER"), ("note", "VARCHAR"), ("md5sum", "VARCHAR")],
    "cast_info": [("id", "INTEGER"), ("person_id", "INTEGER"), ("movie_id", "INTEGER"), ("person_role_id", "INTEGER"), ("note", "VARCHAR"), ("nr_order", "INTEGER"), ("role_id", "INTEGER")],
    "char_name": [("id", "INTEGER"), ("name", "VARCHAR"), ("imdb_index", "VARCHAR"), ("imdb_id", "INTEGER"), ("name_pcode_nf", "VARCHAR"), ("surname_pcode", "VARCHAR"), ("md5sum", "VARCHAR")],
    "comp_cast_type": [("id", "INTEGER"), ("kind", "VARCHAR")],
    "company_name": [("id", "INTEGER"), ("name", "VARCHAR"), ("country_code", "VARCHAR"), ("imdb_id", "INTEGER"), ("name_pcode_nf", "VARCHAR"), ("name_pcode_sf", "VARCHAR"), ("md5sum", "VARCHAR")],
    "company_type": [("id", "INTEGER"), ("kind", "VARCHAR")],
    "complete_cast": [("id", "INTEGER"), ("movie_id", "INTEGER"), ("subject_id", "INTEGER"), ("status_id", "INTEGER")],
    "info_type": [("id", "INTEGER"), ("info", "VARCHAR")],
    "keyword": [("id", "INTEGER"), ("keyword", "VARCHAR"), ("phonetic_code", "VARCHAR")],
    "kind_type": [("id", "INTEGER"), ("kind", "VARCHAR")],
    "link_type": [("id", "INTEGER"), ("link", "VARCHAR")],
    "movie_companies": [("id", "INTEGER"), ("movie_id", "INTEGER"), ("company_id", "INTEGER"), ("company_type_id", "INTEGER"), ("note", "VARCHAR")],
    "movie_info": [("id", "INTEGER"), ("movie_id", "INTEGER"), ("info_type_id", "INTEGER"), ("info", "VARCHAR"), ("note", "VARCHAR")],
    "movie_info_idx": [("id", "INTEGER"), ("movie_id", "INTEGER"), ("info_type_id", "INTEGER"), ("info", "VARCHAR"), ("note", "VARCHAR")],
    "movie_keyword": [("id", "INTEGER"), ("movie_id", "INTEGER"), ("keyword_id", "INTEGER")],
    "movie_link": [("id", "INTEGER"), ("movie_id", "INTEGER"), ("linked_movie_id", "INTEGER"), ("link_type_id", "INTEGER")],
    "name": [("id", "INTEGER"), ("name", "VARCHAR"), ("imdb_index", "VARCHAR"), ("imdb_id", "INTEGER"), ("gender", "VARCHAR"), ("name_pcode_cf", "VARCHAR"), ("name_pcode_nf", "VARCHAR"), ("surname_pcode", "VARCHAR"), ("md5sum", "VARCHAR")],
    "person_info": [("id", "INTEGER"), ("person_id", "INTEGER"), ("info_type_id", "INTEGER"), ("info", "VARCHAR"), ("note", "VARCHAR")],
    "role_type": [("id", "INTEGER"), ("role", "VARCHAR")],
    "title": [("id", "INTEGER"), ("title", "VARCHAR"), ("imdb_index", "VARCHAR"), ("kind_id", "INTEGER"), ("production_year", "INTEGER"), ("imdb_id", "INTEGER"), ("phonetic_code", "VARCHAR"), ("episode_of_id", "INTEGER"), ("season_nr", "INTEGER"), ("episode_nr", "INTEGER"), ("series_years", "VARCHAR"), ("md5sum", "VARCHAR")],
}

DATASET_COLUMNS = {"tpch": TPCH_COLUMNS, "job": JOB_COLUMNS}

JOB_PLACEMENTS = {
    "v0": {
        "db1": {"aka_name", "cast_info", "char_name", "comp_cast_type", "complete_cast", "info_type", "link_type", "movie_info", "movie_info_idx", "movie_link", "name", "person_info", "role_type", "title"},
        "db2": {"aka_title", "company_name", "company_type", "keyword", "kind_type", "movie_companies", "movie_keyword"},
    },
    "v1": {
        "db1": {"aka_name", "aka_title", "comp_cast_type", "company_name", "company_type", "complete_cast", "keyword", "kind_type", "link_type", "movie_companies", "movie_info", "movie_info_idx", "movie_keyword", "movie_link", "title"},
        "db2": {"cast_info", "char_name", "info_type", "name", "person_info", "role_type"},
    },
    "v2": {
        "db1": {"comp_cast_type", "complete_cast", "link_type", "movie_info", "movie_info_idx", "movie_link", "title"},
        "db2": {"aka_name", "aka_title", "cast_info", "char_name", "company_name", "company_type", "info_type", "keyword", "kind_type", "movie_companies", "movie_keyword", "name", "person_info", "role_type"},
    },
}


def job_csv_files(data_dir: Path, table: str) -> list[Path]:
    """Return a JOB table's single CSV or its sorted CSV chunks."""
    for root in (data_dir, data_dir / "csv"):
        single = root / f"{table}.csv"
        if single.is_file():
            return [single]
        chunks = root / table
        if chunks.is_dir():
            files = sorted(chunks.glob("*.csv"))
            if files:
                return files
    return []
