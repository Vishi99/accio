# Docker experiments: DuckDB coordinator + mixed data sources

The default deployment runs one Accio/DuckDB coordinator, two PostgreSQL
sources, one DuckDB source served through Quack, and one DataFusion source
served through PGWire. It supports both:

- Docker Compose on one machine, for development and smoke tests.
- Docker Swarm on five machines, with each service pinned to a labeled node.

PostgreSQL and DuckDB load their assigned TPC-H `.tbl` files when their data
volumes are first created. DataFusion registers its assigned files directly
through DataFusion's CSV API on every container start and does not copy them. The coordinator waits
for all sources, validates their assigned tables, writes the Accio source
configs, and runs the selected `tpch2_v*` workload.

## Files

| File | Purpose |
| --- | --- |
| `docker-compose.multinode.yml` | Five-service Compose/Swarm topology |
| `docker/experiment.env.example` | All experiment, TPC-H, resource, and cost settings |
| `docker/coordinator/Dockerfile` | Accio, DuckDB, custom PostgreSQL scanner, and rewriter image |
| `docker/coordinator/Dockerfile.mixed` | Modern DuckDB coordinator with PostgreSQL and Quack extensions |
| `docker/postgres/Dockerfile` | PostgreSQL image with TPC-H loader and optional `netem` support |
| `docker/duckdb/Dockerfile` | DuckDB source served over Quack |
| `docker/datafusion/Dockerfile` | DataFusion source served by `datafusion-postgres` PGWire |
| `generate_tpch_data.sh` | Clone, build, and run TPC-H dbgen |
| `run_multinode_experiments.sh` | Build/deploy/log/status/rerun wrapper |
| `run_docker_experiments.sh` | Existing imperative single-host runner |

## Architecture

```text
                         overlay/bridge network
  coordinator node                                  source nodes
  +--------------------+          +---------------------------------------+
  | Accio + DuckDB     |--------->| postgres1 (Accio schema name: db1)   |
  | query planning and |          | assigned subset of TPC-H tables      |
  | local execution    |          +---------------------------------------+
  |                    |--------->| postgres2 (Accio schema name: db2)   |
  |                    |          | assigned subset of TPC-H tables      |
  |                    |          +---------------------------------------+
  |                    |--------->| duckdb3 (Accio schema name: db3)     |
  |                    |          | assigned subset of TPC-H tables      |
  |                    |          +---------------------------------------+
  |                    |--------->| datafusion4 (Accio schema name: db4) |
  +--------------------+          | external TPC-H tables over PGWire    |
                                  +---------------------------------------+
```

DuckDB is embedded in the coordinator process. `duckdb3` is a separate DuckDB
process reached over Quack. `datafusion4` runs DataFusion behind a PostgreSQL
wire-compatible endpoint. Source ports are not published to the host;
communication stays on the deployment network.

## Prerequisites

- Docker Engine with the Compose v2 plugin.
- A homogeneous CPU architecture across Swarm nodes, unless multi-platform
  images are built separately.
- TPC-H `dbgen` output containing these files:
  `region.tbl`, `nation.tbl`, `supplier.tbl`, `customer.tbl`, `part.tbl`,
  `partsupp.tbl`, `orders.tbl`, and `lineitem.tbl`.
- Enough free disk for two PostgreSQL volumes, one DuckDB volume, the images,
  the mounted dbgen files, and coordinator results. DataFusion reads those
  files in place and has no data volume.

The legacy PostgreSQL-only coordinator scanner build uses Ninja and four
parallel compile jobs by default. Set
`POSTGRESSCANNER_BUILD_JOBS` in `docker/experiment.env` to the number of jobs
your Docker VM can comfortably support. More jobs usually shorten the first
build; if the build is killed or reports an out-of-memory error, reduce it to
`2` or `1`. Once a build succeeds, Docker caches that layer, so later builds do
not recompile the scanner unless its Dockerfile, repository, ref, or build-job
setting changes.

The first DataFusion image build compiles the small source server and its pinned
`datafusion-postgres` dependencies and can take several minutes. Docker caches
that build unless its manifest, lockfile, source, or Dockerfile changes.

Generate SF1 with the included script:

```bash
./generate_tpch_data.sh
```

The script clones `gregrahn/tpch-kit` under `.accio-docker/tpch-kit`, builds
`dbgen` locally, generates all eight `.tbl` files under
`.accio-docker/tpch-data/sf1`, verifies them, and prints the exact
`TPCH_SCALE` and `TPCH_DATA_DIR_*` values for the experiment env file. It needs
`git`, `make`, and a C compiler.

Useful examples:

```bash
# Default SF1 under .accio-docker/tpch-data/sf1
./generate_tpch_data.sh

# SF10 in a specific output directory
./generate_tpch_data.sh 10 /data/tpch/sf10
```

The first positional argument is the scale and the optional second argument is
the output directory. Existing `.tbl` files are overwritten by dbgen. The
selected scale must match `TPCH_SCALE` in the experiment env file.

## Local five-container quick start

Generate the data, then create the active config and use the absolute paths
printed by the generator:

```bash
./generate_tpch_data.sh 1
cp docker/experiment.env.example docker/experiment.env
$EDITOR docker/experiment.env
```

Keep these values for local Compose:

```dotenv
DEPLOY_MODE=compose
NETWORK_DRIVER=bridge
TPCH_DATA_DIR_DB1=/absolute/path/to/tpch-dbgen-output
TPCH_DATA_DIR_DB2=/absolute/path/to/tpch-dbgen-output
TPCH_DATA_DIR_DB3=/absolute/path/to/tpch-dbgen-output
TPCH_DATA_DIR_DB4=/absolute/path/to/tpch-dbgen-output
TPCH_DATA_DIR_COORDINATOR=/absolute/path/to/tpch-dbgen-output
ACCIO_RESULTS_DIR=/absolute/path/to/accio-results
ACCIO_EXPLAIN=true
```

Each path must name the directory that directly contains the `.tbl` files. For
the default generator invocation this is
`/absolute/path/to/accio/.accio-docker/tpch-data/sf1`, not its parent
`.../tpch-data`. In Compose mode, the wrapper verifies every table required by
the configured distribution before building, deploying, or deleting volumes.
The generator also grants directory traversal and file-read permissions so the
non-root `postgres` user can consume the bind-mounted files, even when the host
uses a restrictive umask.

Create the results directory before validating or deploying:

```bash
mkdir -p /absolute/path/to/accio-results
```

Each run writes one timestamped `.log` directly into this host directory. The
log contains runtimes and, when `ACCIO_EXPLAIN=true`, the Accio and DuckDB plans.
The run's DuckDB database is created under the container's `/tmp` and deleted
on completion or benchmark failure.

Then validate, build, deploy, and follow the experiment:

```bash
./run_multinode_experiments.sh config
./run_multinode_experiments.sh build
./run_multinode_experiments.sh deploy
./run_multinode_experiments.sh logs
```

To discard all source databases and perform a guaranteed fresh Compose
load, use:

```bash
./run_multinode_experiments.sh fresh
```

`fresh` permanently removes the two PostgreSQL volumes and the DuckDB volume
resolved from the running containers, verifies their removal, and redeploys.
DataFusion is restarted and re-registers the mounted files; it has no volume to
delete. `fresh` does not modify `ACCIO_RESULTS_DIR` or the source `.tbl` files.
It is intentionally unavailable in Swarm mode because persistent volumes are
node-local.

The coordinator is intentionally a one-shot container and shows as `Exited (0)`
after success. The sources remain running. Run the same experiment again
without reloading persistent source data with:

```bash
./run_multinode_experiments.sh rerun
```

Inspect or stop the deployment with:

```bash
./run_multinode_experiments.sh status
./run_multinode_experiments.sh down
```

`down` retains the source volumes and the host result logs. Read the latest
logs directly without `docker cp`:

```bash
ls -lt /absolute/path/to/accio-results
less /absolute/path/to/accio-results/tpch-sf1-v1-all-TIMESTAMP.log
```

## Five-host Docker Swarm setup

The expected roles are one manager/coordinator host and four source hosts. A
manager may also be a worker, but each label should identify the intended
machine. On the manager:

```bash
docker swarm init --advertise-addr MANAGER_IP
docker swarm join-token worker
```

Run the printed `docker swarm join ...` command on all source hosts. Back on
the manager, obtain the node names and assign the five placement labels:

```bash
docker node ls
docker node update --label-add accio.role=coordinator COORDINATOR_NODE
docker node update --label-add accio.role=postgres1 POSTGRES1_NODE
docker node update --label-add accio.role=postgres2 POSTGRES2_NODE
docker node update --label-add accio.role=duckdb3 DUCKDB3_NODE
docker node update --label-add accio.role=datafusion4 DATAFUSION4_NODE
```

Put the matching TPC-H files on each node that owns tables. All five bind
directories must exist even when the coordinator owns no tables. The paths may
differ; the env file supplies one bind path per node:

```dotenv
DEPLOY_MODE=swarm
TPCH_DATA_DIR_DB1=/data/tpch/sf1
TPCH_DATA_DIR_DB2=/mnt/benchmarks/tpch/sf1
TPCH_DATA_DIR_DB3=/data/tpch/sf1
TPCH_DATA_DIR_DB4=/data/tpch/sf1
TPCH_DATA_DIR_COORDINATOR=/data/tpch/sf1
ACCIO_RESULTS_DIR=/data/accio-results
```

Create `ACCIO_RESULTS_DIR` on the node labeled `accio.role=coordinator` before
deploying the stack.

Swarm nodes pull images rather than using the Compose `build` section. Set all
image names to a registry reachable by every node:

```dotenv
ACCIO_COORDINATOR_IMAGE=registry.example.edu/accio/coordinator:latest
ACCIO_POSTGRES_IMAGE=registry.example.edu/accio/postgres:latest
ACCIO_DUCKDB_IMAGE=registry.example.edu/accio/duckdb:latest
ACCIO_DATAFUSION_IMAGE=registry.example.edu/accio/datafusion:latest
```

Log in to that registry if necessary, then build, push, and deploy from the
manager:

```bash
./run_multinode_experiments.sh config
./run_multinode_experiments.sh build
./run_multinode_experiments.sh deploy
./run_multinode_experiments.sh logs
```

`docker stack deploy` may report that it ignores the Compose-only `build`,
`restart`, and `depends_on` keys. This is expected: images were pushed by the
build command, Swarm restart policies are under `deploy`, and the coordinator
has its own database/dataset readiness loop.

Use these commands for operations:

```bash
./run_multinode_experiments.sh status
./run_multinode_experiments.sh rerun
./run_multinode_experiments.sh down
```

Coordinator logs can always be read from the manager with `docker service
logs`. Timestamped result logs are written directly to `ACCIO_RESULTS_DIR` on
the node labeled `accio.role=coordinator`; SSH to that node to read them:

```bash
ls -lt /data/accio-results
```

## Experiment configuration

`docker/experiment.env` is the only file normally edited. Use a different file
without copying by prefixing any wrapper command with
`ACCIO_ENV_FILE=/absolute/path/to/config.env`.

### Source registry

The coordinator source count and connection types come from the env file:

```dotenv
ACCIO_SOURCES="db1 db2 db3 db4"
DB1_TYPE=POSTGRES
DB1_HOST=postgres1
DB1_PORT=5432
DB2_TYPE=POSTGRES
DB2_HOST=postgres2
DB2_PORT=5432
DB3_TYPE=DUCKDB
DB3_HOST=duckdb3
DB3_PORT=9494
DB3_TOKEN=replace-with-a-long-random-token
DB3_DISABLE_SSL=true
DB4_TYPE=DATAFUSION
DB4_HOST=datafusion4
DB4_PORT=5432
DB4_DATABASE=postgres
DB4_USERNAME=postgres
DB4_PASSWORD=unused
```

Supported source types are `POSTGRES`, `DUCKDB`/`QUACK`, and `DATAFUSION`.
DataFusion uses PGWire for transport but Accio's DataFusion dialect for pushed
SQL. It deliberately uses Accio's generic cardinality estimator and no
PostgreSQL CTID partitioner. When an engine-specific domain statistic is not
available, the generic estimator uses Accio's existing 100-row heuristic; it
does not issue an additional data scan during planning. Per-source
`DBn_USERNAME`, `DBn_PASSWORD`, `DBn_DATABASE`, and `DBn_JDBC_URL` override the
shared defaults. To add another already-deployed supported source,
append its name to `ACCIO_SOURCES`, add its `DBn_*` settings,
`TPCH_TABLES_DBn`, and `TPCH_DATA_DIR_DBn`; no coordinator code change is
required. If the Docker service name does not follow `postgresN`, `duckdbN`, or
`datafusionN`, set `DBn_SERVICE`.

For example, after a `duckdb4` service exists on the deployment network and
receives the same env file, adding it to Accio requires only:

```dotenv
ACCIO_SOURCES="db1 db2 db3 db4"
DB4_TYPE=DUCKDB
DB4_HOST=duckdb4
DB4_PORT=9494
DB4_TOKEN=replace-with-a-long-random-token
DB4_DISABLE_SSL=true
TPCH_TABLES_DB4="supplier"
TPCH_DATA_DIR_DB4=/absolute/path/to/tpch-dbgen-output
```

Move `supplier` out of its old `TPCH_TABLES_DBn` list so every table remains
assigned exactly once. The source service must set `TPCH_SOURCE_ID=db4`; the
provided loaders resolve `TPCH_TABLES_DB4` dynamically.

For the provided DB4 service, the source process registers each assigned TPC-H
file directly with DataFusion using an explicit pipe-delimited schema, then
starts the PGWire endpoint. The final dbgen delimiter is represented by an
unused `_accio_trailing` column, so the source files are used without rewriting
or copying. Check the registered source directly with:

```bash
set -a; source docker/experiment.env; set +a
ACCIO_ENV_FILE=docker/experiment.env docker compose \
  --env-file docker/experiment.env -f docker-compose.multinode.yml \
  --project-name "$STACK_NAME" exec datafusion4 \
  psql -h 127.0.0.1 -U postgres -d postgres -c 'SELECT count(*) FROM orders;'
```

Replace `orders` if DB4 owns another table. The generated Accio JSON uses the
PostgreSQL connector only as the execution transport; `dialect=datafusion`
controls pushed SQL, while generic cardinality and partition implementations
avoid PostgreSQL-only catalog and CTID assumptions.

### TPC-H scale and distribution

`TPCH_SCALE` supports `1`, `10`, and `50`. The example distribution setting is
`TPCH_PLACEMENT=v2` in `docker/experiment.env`. `TPCH_PLACEMENT` selects both
the default physical table distribution and the corresponding
`workload/tpch2_<placement>` SQL directory:

| Placement | `db1` / PostgreSQL | `db2` / PostgreSQL | `db3` / DuckDB | `db4` / DataFusion | coordinator / DuckDB |
| --- | --- | --- | --- | --- | --- |
| `v0` | region, nation, supplier, customer, orders, lineitem | part, partsupp | none | none | none |
| `v1` | region, nation, supplier, customer, part, partsupp | orders, lineitem | none | none | none |
| `v2` defaults | part, partsupp, orders, lineitem | region, nation, supplier, customer | none | none | none |

For a completely explicit distribution, set every source list. Every TPC-H
table must occur exactly once across the source and coordinator lists:

```dotenv
TPCH_TABLES_DB1="region nation supplier customer part partsupp"
TPCH_TABLES_DB2="orders lineitem"
TPCH_TABLES_DB3=
TPCH_TABLES_DB4=
TPCH_TABLES_COORDINATOR=
```

The example env overrides the v2 defaults to use all four sources:

```dotenv
TPCH_PLACEMENT=v2
TPCH_TABLES_DB1="part partsupp"
TPCH_TABLES_DB2="region nation supplier customer"
TPCH_TABLES_DB3="lineitem"
TPCH_TABLES_DB4="orders"
TPCH_TABLES_COORDINATOR=
```

Quote non-empty lists because the env file is also loaded as shell syntax.
`WORKLOAD_DIR` can select another workload directory inside the coordinator
image; its existing source qualifiers are normalized to the
configured ownership before execution. The normalizer continues to recognize
the checked-in `db1` through `db4` qualifiers even when one of those sources is
not listed in `ACCIO_SOURCES`.

The loader accepts `TPCH_TABLES_COORDINATOR`, but the current Accio `benefit`
and `pushdown` rewriters do not correctly plan coordinator-resident base tables.
Keep that setting empty for executable benchmark runs. DuckDB still acts as the
coordinator and executes the resulting federated plan.

### Accio and DuckDB

- `ACCIO_QUERY`: query basename such as `q05`; empty runs every `q*.sql`.
- `WORKLOAD_DIR`: directory inside the image; empty selects the checked-in
  `workload/tpch2_${TPCH_PLACEMENT}` directory.
- `ACCIO_RUNS`: executions per query.
- `ACCIO_STRATEGY`: rewrite strategy, normally `benefit`.
- `ACCIO_CORES`: DuckDB threads and coordinator CPU limit.
- `ACCIO_MEMORY`: DuckDB memory limit.
- `COORDINATOR_MEMORY_LIMIT`: container limit; leave headroom above DuckDB for
  Python and the Accio rewriter JVM.
- `ACCIO_EXPLAIN`: set to `true` to print Accio and DuckDB plans.
- `ACCIO_RESULTS_DIR`: absolute host path receiving timestamped `.log` files.
  No DuckDB database files are persisted there.
- `STARTUP_TIMEOUT_SECONDS`: maximum wait per source, including initial load.

### Data sources and network

- `PG_SHARED_BUFFERS`, `PG_SHM_SIZE`, `PG_MAX_CONNECTIONS`, and worker settings
  control each PostgreSQL instance.
- `PG_MAX_PARALLELISM` controls Accio's PostgreSQL query partitioner.
- `DB_STATS_TARGET` is used while collecting optimizer statistics after load.
- `BANDWIDTH=none` uses the real network. A value such as `1gbit` installs a
  separate `netem` egress limit on each source. The containers receive only
  `NET_ADMIN`, required for this optional traffic control.
- `COST_JOIN`, `COST_AGG`, `COST_SORT`, and `COST_TRANSFER` populate each Accio
  data-source JSON config.

The example password is only suitable for an isolated experiment network.
Change it for shared machines. The password is present in container environment
and generated Accio config, so this setup is not a production secret-management
pattern. The provided DataFusion PGWire server is likewise unencrypted and
unauthenticated; it is reachable only on the private deployment network and is
intended for experiments, not production exposure.

## Changing scale or table placement

PostgreSQL and DuckDB initialization runs only for an empty data volume.
Consequently, changing `TPCH_SCALE`, `TPCH_PLACEMENT`, their table lists, or the
dbgen files requires deleting the two PostgreSQL volumes and the DuckDB volume
before redeploying. DataFusion is stateless and registers the current DB4 list
and mounted files whenever its container starts. The coordinator checks stored
metadata for persistent sources and fails instead of silently running against
stale placement.

For local Compose, after confirming the stack name and that the data can be
regenerated:

```bash
set -a; source docker/experiment.env; set +a
./run_multinode_experiments.sh down
docker volume rm "${STACK_NAME}_postgres1-data" "${STACK_NAME}_postgres2-data" \
  "${STACK_NAME}_duckdb3-data"
./run_multinode_experiments.sh deploy
```

For Swarm, remove the stack and then run the corresponding `docker volume rm`
for `${STACK_NAME}_postgres1-data` on the postgres1 node and
`${STACK_NAME}_postgres2-data` on the postgres2 node, and
`${STACK_NAME}_duckdb3-data` on the duckdb3 node. Swarm local volumes are
node-local and are deliberately not deleted by the wrapper. Restarting the
DataFusion service is sufficient for DB4 because it owns no data volume.

## Existing single-host runner

The original `run_docker_experiments.sh` remains available and now builds the
same two Dockerfiles. It is useful when table loading and placement switching
should be driven interactively from one host:

```bash
TPCH_DATA_DIR=/data/tpch-sf1 ./run_docker_experiments.sh experiment v1 q05
TPCH_DATA_DIR=/data/tpch-sf1 ACCIO_RUNS=3 \
  ./run_docker_experiments.sh all q05
```

Use the Compose/Swarm wrapper for actual multi-host placement. Use the existing
runner when all three containers live on one Docker daemon and repeated `v0`,
`v1`, `v2` physical reloads are desired. Coordinator-resident input tables are
currently supported by `run_multinode_experiments.sh`, not by this legacy
runner.

The legacy runner streams benchmark output to the terminal and also saves it
on the host under `.accio-docker/accio-expt-sf<SCALE>/results/` (or under the
custom `STATE_DIR`). For example:

```bash
ls -lh .accio-docker/accio-expt-sf1/results/
tail -f .accio-docker/accio-expt-sf1/results/*.log
```

For the multinode runner, `./run_multinode_experiments.sh logs` follows the
coordinator. Follow source loading logs with:

```bash
# Local Compose
docker compose --env-file docker/experiment.env \
  -f docker-compose.multinode.yml logs -f postgres1 postgres2 duckdb3 datafusion4

# Swarm
docker service logs -f "${STACK_NAME}_postgres1"
docker service logs -f "${STACK_NAME}_postgres2"
docker service logs -f "${STACK_NAME}_duckdb3"
docker service logs -f "${STACK_NAME}_datafusion4"
```

Result logs are available directly under `ACCIO_RESULTS_DIR`; transient DuckDB
database files are deleted and do not need to be collected.

## Troubleshooting

- During a fresh load, an older coordinator image may cause PostgreSQL to log
  `relation "accio_dataset_metadata" does not exist`. This is a harmless
  readiness check while the loader is still working. Rebuild the coordinator
  image to use the quiet readiness probe and periodic progress messages.
- `Extension ... v0.0.1 ... does not match ... v0.0.0` means the coordinator
  image predates the pinned Python-version fix. Rebuild it. The image build now
  loads the scanner once as a smoke test and fails immediately on a mismatch.
- A source repeatedly fails with `Missing ...tbl`: verify the bind path on that
  source node and confirm all tables assigned to it exist there.
- The coordinator reports metadata or table mismatch: a persistent source
  volume was initialized with another placement; follow the reset procedure.
- DataFusion reports a table-registration or CSV error: inspect `datafusion4`
  logs and verify the assigned `.tbl` file is readable. The loader includes the
  dbgen trailing empty field as an unused `_accio_trailing` column.
- `Remote branch parallel_query not found`: use
  `POSTGRESSCANNER_REF=prallel_query`. The fork currently publishes the branch
  with that spelling; the example env file already contains the corrected ref.
- A Swarm service remains at `0/1`: run `docker service ps --no-trunc SERVICE`.
  A rejected task commonly means a missing node label, missing bind path, image
  pull failure, or insufficient memory.
- `tc ... Operation not permitted`: retain `cap_add: NET_ADMIN` when shaping is
  needed. If the platform forbids that capability, set `BANDWIDTH=none` and
  remove the `cap_add` block from the Compose file.
- A long coordinator wait is normal while large `.tbl` files load. Follow the
  source logs with
  `docker compose logs -f postgres1 postgres2 duckdb3 datafusion4` locally or
  `docker service logs -f ${STACK_NAME}_postgres1` in Swarm.
