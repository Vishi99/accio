use std::env;
use std::error::Error;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use datafusion::arrow::array::{Array, Int64Array, StringArray, UInt64Array};
use datafusion::arrow::datatypes::{DataType, Field, Schema};
use datafusion::arrow::record_batch::RecordBatch;
use datafusion::execution::options::CsvReadOptions;
use datafusion::prelude::{SessionConfig, SessionContext};
use datafusion_postgres::auth::AuthManager;
use datafusion_postgres::datafusion_pg_catalog::setup_pg_catalog;
use datafusion_postgres::{ServerOptions, serve};
use env_logger::Env;
use log::info;

const ALL_TPCH_TABLES: &[&str] = &[
    "region", "nation", "supplier", "customer", "part", "partsupp", "orders", "lineitem",
];
const ALL_JOB_TABLES: &[&str] = &[
    "aka_name",
    "aka_title",
    "cast_info",
    "char_name",
    "comp_cast_type",
    "company_name",
    "company_type",
    "complete_cast",
    "info_type",
    "keyword",
    "kind_type",
    "link_type",
    "movie_companies",
    "movie_info",
    "movie_info_idx",
    "movie_keyword",
    "movie_link",
    "name",
    "person_info",
    "role_type",
    "title",
];

const TABLE_STATS_TABLE: &str = "accio_table_stats";
const COLUMN_STATS_TABLE: &str = "accio_column_stats";

fn field(name: &str, data_type: DataType) -> Field {
    Field::new(name, data_type, true)
}

fn decimal() -> DataType {
    DataType::Decimal128(15, 2)
}

fn tpch_schema(table: &str) -> Result<Schema, Box<dyn Error>> {
    let fields = match table {
        "region" => vec![
            field("r_regionkey", DataType::Int32),
            field("r_name", DataType::Utf8),
            field("r_comment", DataType::Utf8),
            field("_accio_trailing", DataType::Utf8),
        ],
        "nation" => vec![
            field("n_nationkey", DataType::Int32),
            field("n_name", DataType::Utf8),
            field("n_regionkey", DataType::Int32),
            field("n_comment", DataType::Utf8),
            field("_accio_trailing", DataType::Utf8),
        ],
        "supplier" => vec![
            field("s_suppkey", DataType::Int64),
            field("s_name", DataType::Utf8),
            field("s_address", DataType::Utf8),
            field("s_nationkey", DataType::Int32),
            field("s_phone", DataType::Utf8),
            field("s_acctbal", decimal()),
            field("s_comment", DataType::Utf8),
            field("_accio_trailing", DataType::Utf8),
        ],
        "customer" => vec![
            field("c_custkey", DataType::Int64),
            field("c_name", DataType::Utf8),
            field("c_address", DataType::Utf8),
            field("c_nationkey", DataType::Int32),
            field("c_phone", DataType::Utf8),
            field("c_acctbal", decimal()),
            field("c_mktsegment", DataType::Utf8),
            field("c_comment", DataType::Utf8),
            field("_accio_trailing", DataType::Utf8),
        ],
        "part" => vec![
            field("p_partkey", DataType::Int64),
            field("p_name", DataType::Utf8),
            field("p_mfgr", DataType::Utf8),
            field("p_brand", DataType::Utf8),
            field("p_type", DataType::Utf8),
            field("p_size", DataType::Int32),
            field("p_container", DataType::Utf8),
            field("p_retailprice", decimal()),
            field("p_comment", DataType::Utf8),
            field("_accio_trailing", DataType::Utf8),
        ],
        "partsupp" => vec![
            field("ps_partkey", DataType::Int64),
            field("ps_suppkey", DataType::Int64),
            field("ps_availqty", DataType::Int32),
            field("ps_supplycost", decimal()),
            field("ps_comment", DataType::Utf8),
            field("_accio_trailing", DataType::Utf8),
        ],
        "orders" => vec![
            field("o_orderkey", DataType::Int64),
            field("o_custkey", DataType::Int64),
            field("o_orderstatus", DataType::Utf8),
            field("o_totalprice", decimal()),
            field("o_orderdate", DataType::Date32),
            field("o_orderpriority", DataType::Utf8),
            field("o_clerk", DataType::Utf8),
            field("o_shippriority", DataType::Int32),
            field("o_comment", DataType::Utf8),
            field("_accio_trailing", DataType::Utf8),
        ],
        "lineitem" => vec![
            field("l_orderkey", DataType::Int64),
            field("l_partkey", DataType::Int64),
            field("l_suppkey", DataType::Int64),
            field("l_linenumber", DataType::Int32),
            field("l_quantity", decimal()),
            field("l_extendedprice", decimal()),
            field("l_discount", decimal()),
            field("l_tax", decimal()),
            field("l_returnflag", DataType::Utf8),
            field("l_linestatus", DataType::Utf8),
            field("l_shipdate", DataType::Date32),
            field("l_commitdate", DataType::Date32),
            field("l_receiptdate", DataType::Date32),
            field("l_shipinstruct", DataType::Utf8),
            field("l_shipmode", DataType::Utf8),
            field("l_comment", DataType::Utf8),
            field("_accio_trailing", DataType::Utf8),
        ],
        _ => return Err(format!("unknown TPC-H table: {table}").into()),
    };
    Ok(Schema::new(fields))
}

fn int(name: &str) -> Field {
    field(name, DataType::Int32)
}

fn text(name: &str) -> Field {
    field(name, DataType::Utf8)
}

fn job_schema(table: &str) -> Result<Schema, Box<dyn Error>> {
    let fields = match table {
        "aka_name" => vec![
            int("id"),
            int("person_id"),
            text("name"),
            text("imdb_index"),
            text("name_pcode_cf"),
            text("name_pcode_nf"),
            text("surname_pcode"),
            text("md5sum"),
        ],
        "aka_title" => vec![
            int("id"),
            int("movie_id"),
            text("title"),
            text("imdb_index"),
            int("kind_id"),
            int("production_year"),
            text("phonetic_code"),
            int("episode_of_id"),
            int("season_nr"),
            int("episode_nr"),
            text("note"),
            text("md5sum"),
        ],
        "cast_info" => vec![
            int("id"),
            int("person_id"),
            int("movie_id"),
            int("person_role_id"),
            text("note"),
            int("nr_order"),
            int("role_id"),
        ],
        "char_name" => vec![
            int("id"),
            text("name"),
            text("imdb_index"),
            int("imdb_id"),
            text("name_pcode_nf"),
            text("surname_pcode"),
            text("md5sum"),
        ],
        "comp_cast_type" => vec![int("id"), text("kind")],
        "company_name" => vec![
            int("id"),
            text("name"),
            text("country_code"),
            int("imdb_id"),
            text("name_pcode_nf"),
            text("name_pcode_sf"),
            text("md5sum"),
        ],
        "company_type" => vec![int("id"), text("kind")],
        "complete_cast" => vec![
            int("id"),
            int("movie_id"),
            int("subject_id"),
            int("status_id"),
        ],
        "info_type" => vec![int("id"), text("info")],
        "keyword" => vec![int("id"), text("keyword"), text("phonetic_code")],
        "kind_type" => vec![int("id"), text("kind")],
        "link_type" => vec![int("id"), text("link")],
        "movie_companies" => vec![
            int("id"),
            int("movie_id"),
            int("company_id"),
            int("company_type_id"),
            text("note"),
        ],
        "movie_info" | "movie_info_idx" => vec![
            int("id"),
            int("movie_id"),
            int("info_type_id"),
            text("info"),
            text("note"),
        ],
        "movie_keyword" => vec![int("id"), int("movie_id"), int("keyword_id")],
        "movie_link" => vec![
            int("id"),
            int("movie_id"),
            int("linked_movie_id"),
            int("link_type_id"),
        ],
        "name" => vec![
            int("id"),
            text("name"),
            text("imdb_index"),
            int("imdb_id"),
            text("gender"),
            text("name_pcode_cf"),
            text("name_pcode_nf"),
            text("surname_pcode"),
            text("md5sum"),
        ],
        "person_info" => vec![
            int("id"),
            int("person_id"),
            int("info_type_id"),
            text("info"),
            text("note"),
        ],
        "role_type" => vec![int("id"), text("role")],
        "title" => vec![
            int("id"),
            text("title"),
            text("imdb_index"),
            int("kind_id"),
            int("production_year"),
            int("imdb_id"),
            text("phonetic_code"),
            int("episode_of_id"),
            int("season_nr"),
            int("episode_nr"),
            text("series_years"),
            text("md5sum"),
        ],
        _ => return Err(format!("unknown JOB table: {table}").into()),
    };
    Ok(Schema::new(fields))
}

fn join_key_columns(dataset: &str, table: &str) -> &'static [&'static str] {
    if dataset == "job" {
        match table {
            "aka_name" => &["person_id"],
            "aka_title" => &["movie_id", "kind_id", "episode_of_id"],
            "cast_info" => &["person_id", "movie_id", "person_role_id", "role_id"],
            "char_name" => &[],
            "comp_cast_type" => &[],
            "company_name" => &[],
            "company_type" => &[],
            "complete_cast" => &["movie_id", "subject_id", "status_id"],
            "info_type" => &[],
            "keyword" => &[],
            "kind_type" => &[],
            "link_type" => &[],
            "movie_companies" => &["movie_id", "company_id", "company_type_id"],
            "movie_info" | "movie_info_idx" => &["movie_id", "info_type_id"],
            "movie_keyword" => &["movie_id", "keyword_id"],
            "movie_link" => &["movie_id", "linked_movie_id", "link_type_id"],
            "name" => &[],
            "person_info" => &["person_id", "info_type_id"],
            "role_type" => &[],
            "title" => &["kind_id", "episode_of_id"],
            _ => &[],
        }
    } else {
        match table {
            "region" => &[],
            "nation" => &["n_regionkey"],
            "supplier" => &["s_nationkey"],
            "customer" => &["c_nationkey"],
            "part" => &[],
            "partsupp" => &["ps_partkey", "ps_suppkey"],
            "orders" => &["o_custkey"],
            "lineitem" => &["l_orderkey", "l_partkey", "l_suppkey"],
            _ => &[],
        }
    }
}

fn primary_key_column(dataset: &str, table: &str) -> Option<&'static str> {
    if dataset == "job" {
        return Some("id");
    }
    match table {
        "region" => Some("r_regionkey"),
        "nation" => Some("n_nationkey"),
        "supplier" => Some("s_suppkey"),
        "customer" => Some("c_custkey"),
        "part" => Some("p_partkey"),
        "orders" => Some("o_orderkey"),
        _ => None,
    }
}

fn count_value(batch: &RecordBatch, column: usize) -> Result<i64, Box<dyn Error>> {
    let array = batch.column(column);
    if let Some(values) = array.as_any().downcast_ref::<Int64Array>() {
        return Ok(values.value(0));
    }
    if let Some(values) = array.as_any().downcast_ref::<UInt64Array>() {
        return i64::try_from(values.value(0)).map_err(Into::into);
    }
    Err(format!(
        "unexpected aggregate type for column {column}: {}",
        array.data_type()
    )
    .into())
}

async fn register_statistics(
    context: &SessionContext,
    dataset: &str,
    tables: &[String],
) -> Result<(), Box<dyn Error>> {
    let mut table_names = Vec::with_capacity(tables.len());
    let mut row_counts = Vec::with_capacity(tables.len());
    let mut column_tables = Vec::new();
    let mut column_names = Vec::new();
    let mut distinct_counts = Vec::new();

    for table in tables {
        let columns = join_key_columns(dataset, table);
        let mut projections = vec!["COUNT(*) AS row_count".to_owned()];
        projections.extend(
            columns
                .iter()
                .enumerate()
                .map(|(index, column)| format!("APPROX_DISTINCT(\"{column}\") AS ndv_{index}")),
        );
        let sql = format!("SELECT {} FROM \"{table}\"", projections.join(", "));
        info!("collecting statistics for {table}");
        let batches = context.sql(&sql).await?.collect().await?;
        let batch = batches
            .first()
            .ok_or_else(|| format!("statistics query returned no rows for {table}"))?;
        let row_count = count_value(batch, 0)?;
        table_names.push(table.clone());
        row_counts.push(row_count);

        let primary_key = primary_key_column(dataset, table);
        if let Some(column) = primary_key {
            column_tables.push(table.clone());
            column_names.push(column.to_owned());
            distinct_counts.push(row_count);
        }
        for (index, column) in columns.iter().enumerate() {
            let distinct_count = count_value(batch, index + 1)?;
            column_tables.push(table.clone());
            column_names.push((*column).to_owned());
            distinct_counts.push(distinct_count);
        }
        info!(
            "statistics ready for {table}: rows={row_count}, join_columns={}",
            columns.len() + usize::from(primary_key.is_some())
        );
    }

    let table_batch = RecordBatch::try_from_iter(vec![
        (
            "table_name",
            Arc::new(StringArray::from(table_names)) as Arc<dyn Array>,
        ),
        (
            "row_count",
            Arc::new(Int64Array::from(row_counts)) as Arc<dyn Array>,
        ),
    ])?;
    context.register_batch(TABLE_STATS_TABLE, table_batch)?;

    let column_batch = RecordBatch::try_from_iter(vec![
        (
            "table_name",
            Arc::new(StringArray::from(column_tables)) as Arc<dyn Array>,
        ),
        (
            "column_name",
            Arc::new(StringArray::from(column_names)) as Arc<dyn Array>,
        ),
        (
            "distinct_count",
            Arc::new(Int64Array::from(distinct_counts)) as Arc<dyn Array>,
        ),
    ])?;
    context.register_batch(COLUMN_STATS_TABLE, column_batch)?;
    Ok(())
}

fn assigned_tables(source_id: &str, dataset: &str) -> Result<Vec<String>, Box<dyn Error>> {
    let prefix = source_id.to_ascii_uppercase();
    let variable = format!("ACCIO_TABLES_{prefix}");
    let legacy_variable = format!("TPCH_TABLES_{prefix}");
    let tables =
        env::var(&variable).unwrap_or_else(|_| env::var(&legacy_variable).unwrap_or_default());
    let known_tables = if dataset == "job" {
        ALL_JOB_TABLES
    } else {
        ALL_TPCH_TABLES
    };
    tables
        .split_whitespace()
        .map(|table| {
            if known_tables.contains(&table) {
                Ok(table.to_owned())
            } else {
                Err(format!("invalid table '{table}' in {variable}").into())
            }
        })
        .collect()
}

async fn register_table(
    context: &SessionContext,
    dataset: &str,
    table: &str,
    data_dir: &Path,
) -> Result<(), Box<dyn Error>> {
    if dataset == "job" {
        let roots = [data_dir.to_path_buf(), data_dir.join("csv")];
        let path = roots
            .iter()
            .map(|root| root.join(format!("{table}.csv")))
            .find(|path| path.is_file())
            .or_else(|| {
                roots
                    .iter()
                    .map(|root| root.join(table))
                    .find(|path| path.is_dir())
            })
            .ok_or_else(|| {
                format!(
                    "missing JOB CSV data for {table} under {}",
                    data_dir.display()
                )
            })?;
        let schema = job_schema(table)?;
        let options = CsvReadOptions::new()
            .schema(&schema)
            .has_header(false)
            .delimiter(b',')
            .quote(b'"')
            .escape(b'\\')
            .null_regex(Some("^$".to_owned()))
            .file_extension(".csv");
        let path_text = path
            .to_str()
            .ok_or_else(|| format!("non-UTF-8 input path: {}", path.display()))?;
        info!("registering table {table} from {}", path.display());
        context.register_csv(table, path_text, options).await?;
    } else {
        let path = data_dir.join(format!("{table}.tbl"));
        if !path.is_file() {
            return Err(format!("missing {}", path.display()).into());
        }
        let schema = tpch_schema(table)?;
        let options = CsvReadOptions::new()
            .schema(&schema)
            .has_header(false)
            .delimiter(b'|')
            .truncated_rows(true)
            .file_extension(".tbl");
        let path_text = path
            .to_str()
            .ok_or_else(|| format!("non-UTF-8 input path: {}", path.display()))?;
        info!("registering table {table} from {}", path.display());
        context.register_csv(table, path_text, options).await?;
    }
    Ok(())
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    env_logger::Builder::from_env(
        Env::default().default_filter_or("accio_datafusion_source=info,datafusion_postgres=info"),
    )
    .init();

    let dataset = env::var("ACCIO_DATASET")
        .unwrap_or_else(|_| "tpch".into())
        .to_ascii_lowercase();
    if dataset != "tpch" && dataset != "job" {
        return Err(format!("ACCIO_DATASET must be tpch or job: {dataset}").into());
    }
    let source_id = env::var("ACCIO_SOURCE_ID")
        .or_else(|_| env::var("TPCH_SOURCE_ID"))
        .map_err(|_| "ACCIO_SOURCE_ID is required for the DataFusion source")?;
    let mut source_chars = source_id.chars();
    let valid_source_id = source_chars.next().is_some_and(|c| c.is_ascii_lowercase())
        && source_chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_');
    if !valid_source_id {
        return Err(format!("ACCIO_SOURCE_ID must be a lowercase identifier: {source_id}").into());
    }

    let data_dir = PathBuf::from(
        env::var("ACCIO_DATA_MOUNT")
            .or_else(|_| env::var("TPCH_DATA_MOUNT"))
            .unwrap_or_else(|_| "/benchmark-data".into()),
    );
    let tables = assigned_tables(&source_id, &dataset)?;
    let context =
        SessionContext::new_with_config(SessionConfig::new().with_information_schema(true));

    for table in &tables {
        register_table(&context, &dataset, table, &data_dir).await?;
    }
    register_statistics(&context, &dataset, &tables).await?;

    setup_pg_catalog(&context, "datafusion", Arc::new(AuthManager::new()))?;

    info!(
        "ready on port 5432 with tables: {}",
        if tables.is_empty() {
            "<none>".into()
        } else {
            tables.join(" ")
        }
    );
    let options = ServerOptions::new()
        .with_host("0.0.0.0".to_owned())
        .with_port(5432);
    serve(Arc::new(context), &options).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use datafusion::arrow::array::Int32Array;

    #[tokio::test]
    async fn registers_row_counts_and_join_key_distinct_counts() {
        let context = SessionContext::new();
        let input = RecordBatch::try_from_iter(vec![
            (
                "id",
                Arc::new(Int32Array::from(vec![1, 2, 3])) as Arc<dyn Array>,
            ),
            (
                "movie_id",
                Arc::new(Int32Array::from(vec![10, 10, 11])) as Arc<dyn Array>,
            ),
            (
                "linked_movie_id",
                Arc::new(Int32Array::from(vec![20, 21, 20])) as Arc<dyn Array>,
            ),
            (
                "link_type_id",
                Arc::new(Int32Array::from(vec![1, 1, 2])) as Arc<dyn Array>,
            ),
        ])
        .unwrap();
        context.register_batch("movie_link", input).unwrap();

        register_statistics(&context, "job", &["movie_link".to_owned()])
            .await
            .unwrap();

        let table_batches = context
            .sql("SELECT row_count FROM accio_table_stats WHERE table_name = 'movie_link'")
            .await
            .unwrap()
            .collect()
            .await
            .unwrap();
        assert_eq!(count_value(&table_batches[0], 0).unwrap(), 3);

        let column_batches = context
            .sql(
                "SELECT distinct_count FROM accio_column_stats \
                 WHERE table_name = 'movie_link' AND column_name = 'movie_id'",
            )
            .await
            .unwrap()
            .collect()
            .await
            .unwrap();
        assert_eq!(count_value(&column_batches[0], 0).unwrap(), 2);

        let id_batches = context
            .sql(
                "SELECT distinct_count FROM accio_column_stats \
                 WHERE table_name = 'movie_link' AND column_name = 'id'",
            )
            .await
            .unwrap()
            .collect()
            .await
            .unwrap();
        assert_eq!(count_value(&id_batches[0], 0).unwrap(), 3);
    }
}
