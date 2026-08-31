# Docker experiments: DuckDB coordinator + two PostgreSQL sources

This deployment runs one Accio/DuckDB coordinator and exactly two PostgreSQL
data sources. It supports both:

- Docker Compose on one machine, for development and smoke tests.
- Docker Swarm on three machines, with each service pinned to a labeled node.

The PostgreSQL containers load their assigned TPC-H `.tbl` files only when
their data volumes are first created. The coordinator waits for both loads,
checks that the physical table distribution matches the configuration, loads
any coordinator-assigned tables into DuckDB, writes the Accio source configs,
and runs the selected `tpch2_v*` workload.

## Files

| File | Purpose |
| --- | --- |
| `docker-compose.multinode.yml` | Three-service Compose/Swarm topology |
| `docker/experiment.env.example` | All experiment, TPC-H, resource, and cost settings |
| `docker/coordinator/Dockerfile` | Accio, DuckDB, custom PostgreSQL scanner, and rewriter image |
| `docker/postgres/Dockerfile` | PostgreSQL image with TPC-H loader and optional `netem` support |
| `generate_tpch_data.sh` | Clone, build, and run TPC-H dbgen |
| `run_multinode_experiments.sh` | Build/deploy/log/status/rerun wrapper |
| `run_docker_experiments.sh` | Existing imperative single-host runner |

## Architecture

```text
                         overlay/bridge network
  coordinator node                                  source nodes
  +--------------------+          +---------------------------------------+
  | Accio + DuckDB     |--------->| postgres1 (Accio schema name: db1)   |
  | optional local     |          | assigned subset of TPC-H tables      |
  | TPC-H tables,      |          +---------------------------------------+
  | local execution    |--------->| postgres2 (Accio schema name: db2)   |
  +--------------------+          | assigned subset of TPC-H tables      |
                                  +---------------------------------------+
```

DuckDB is embedded in the coordinator process; it is not a network database
service. PostgreSQL ports are not published to the host. Communication stays
on the deployment network under the service names `postgres1` and `postgres2`.

## Prerequisites

- Docker Engine with the Compose v2 plugin.
- A homogeneous CPU architecture across Swarm nodes, unless multi-platform
  images are built separately.
- TPC-H `dbgen` output containing these files:
  `region.tbl`, `nation.tbl`, `supplier.tbl`, `customer.tbl`, `part.tbl`,
  `partsupp.tbl`, `orders.tbl`, and `lineitem.tbl`.
- Enough free disk for two PostgreSQL volumes, the images, and coordinator
  results. The coordinator image is slow to build the first time because it
  compiles the custom DuckDB/PostgreSQL scanner and the Java rewriter.

The scanner build uses Ninja and four parallel compile jobs by default. Set
`POSTGRESSCANNER_BUILD_JOBS` in `docker/experiment.env` to the number of jobs
your Docker VM can comfortably support. More jobs usually shorten the first
build; if the build is killed or reports an out-of-memory error, reduce it to
`2` or `1`. Once a build succeeds, Docker caches that layer, so later builds do
not recompile the scanner unless its Dockerfile, repository, ref, or build-job
setting changes.

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

## Local three-container quick start

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
TPCH_DATA_DIR_COORDINATOR=/absolute/path/to/tpch-dbgen-output
```

Each path must name the directory that directly contains the `.tbl` files. For
the default generator invocation this is
`/absolute/path/to/accio/.accio-docker/tpch-data/sf1`, not its parent
`.../tpch-data`. In Compose mode, the wrapper verifies every table required by
the configured distribution before building, deploying, or deleting volumes.
The generator also grants directory traversal and file-read permissions so the
non-root `postgres` user can consume the bind-mounted files, even when the host
uses a restrictive umask.

Then validate, build, deploy, and follow the experiment:

```bash
./run_multinode_experiments.sh config
./run_multinode_experiments.sh build
./run_multinode_experiments.sh deploy
./run_multinode_experiments.sh logs
```

To discard both PostgreSQL databases and perform a guaranteed fresh Compose
load, use:

```bash
./run_multinode_experiments.sh fresh
```

`fresh` permanently removes the two PostgreSQL data volumes resolved from the
running containers, verifies their removal, and redeploys. It retains the
coordinator results volume and the source `.tbl` files. It is intentionally not
available in Swarm mode because those volumes reside on separate nodes.

The coordinator is intentionally a one-shot container and shows as `Exited (0)`
after success. PostgreSQL remains running. Run the same experiment again without
reloading data with:

```bash
./run_multinode_experiments.sh rerun
```

Inspect or stop the deployment with:

```bash
./run_multinode_experiments.sh status
./run_multinode_experiments.sh down
```

`down` retains all named volumes. To copy result files locally, find the stopped
coordinator container and use `docker cp`:

```bash
set -a; source docker/experiment.env; set +a
container_id=$(docker compose --env-file docker/experiment.env \
  -f docker-compose.multinode.yml --project-name "$STACK_NAME" \
  ps -aq coordinator)
docker cp "${container_id}:/experiment/results/." ./accio-results
```

## Three-host Docker Swarm setup

The expected roles are one manager/coordinator host and two source hosts. A
manager may also be a worker, but each label should identify the intended
machine. On the manager:

```bash
docker swarm init --advertise-addr MANAGER_IP
docker swarm join-token worker
```

Run the printed `docker swarm join ...` command on both source hosts. Back on
the manager, obtain the node names and assign the three placement labels:

```bash
docker node ls
docker node update --label-add accio.role=coordinator COORDINATOR_NODE
docker node update --label-add accio.role=postgres1 POSTGRES1_NODE
docker node update --label-add accio.role=postgres2 POSTGRES2_NODE
```

Put the matching TPC-H files on each node that owns tables. All three bind
directories must exist even when the coordinator owns no tables. The paths may
differ; the env file supplies one bind path per node:

```dotenv
DEPLOY_MODE=swarm
TPCH_DATA_DIR_DB1=/data/tpch/sf1
TPCH_DATA_DIR_DB2=/mnt/benchmarks/tpch/sf1
TPCH_DATA_DIR_COORDINATOR=/data/tpch/sf1
```

Swarm nodes pull images rather than using the Compose `build` section. Set both
image names to a registry reachable by every node:

```dotenv
ACCIO_COORDINATOR_IMAGE=registry.example.edu/accio/coordinator:latest
ACCIO_POSTGRES_IMAGE=registry.example.edu/accio/postgres:latest
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
logs`. Result files are in the `${STACK_NAME}_coordinator-results` local volume
on the node labeled `accio.role=coordinator`. To copy them, SSH to that node,
find the completed task container, and use `docker cp`:

```bash
set -a; source docker/experiment.env; set +a
task_id=$(docker ps -aq \
  --filter "label=com.docker.swarm.service.name=${STACK_NAME}_coordinator" | head -n1)
docker cp "${task_id}:/experiment/results/." ./accio-results
```

## Experiment configuration

`docker/experiment.env` is the only file normally edited. Use a different file
without copying by prefixing any wrapper command with
`ACCIO_ENV_FILE=/absolute/path/to/config.env`.

### TPC-H scale and distribution

`TPCH_SCALE` supports `1`, `10`, and `50`. The default distribution setting is
`TPCH_PLACEMENT=v1` in `docker/experiment.env`. `TPCH_PLACEMENT` selects both
the default physical table distribution and the corresponding
`workload/tpch2_<placement>` SQL directory:

| Placement | `db1` / `postgres1` | `db2` / `postgres2` | coordinator / DuckDB |
| --- | --- | --- | --- |
| `v0` | region, nation, supplier, customer, orders, lineitem | part, partsupp | none |
| `v1` (default) | region, nation, supplier, customer, part, partsupp | orders, lineitem | none |
| `v2` | part, partsupp, orders, lineitem | region, nation, supplier, customer | none |

To move tables from the selected default placement into the coordinator, set
`TPCH_TABLES_COORDINATOR` and leave the two PostgreSQL overrides empty:

```dotenv
TPCH_PLACEMENT=v1
TPCH_TABLES_DB1=
TPCH_TABLES_DB2=
TPCH_TABLES_COORDINATOR="region nation"
```

This example produces `db1={supplier, customer, part, partsupp}`,
`db2={orders, lineitem}`, and `coordinator={region, nation}`. The coordinator
loads `region.tbl` and `nation.tbl` from `TPCH_DATA_DIR_COORDINATOR` into the
run's DuckDB database. It also rewrites the checked-in workload so local tables
are unqualified (`region`) while remote tables retain `db1.` or `db2.`.

For a completely explicit three-way distribution, set all three lists. Every
TPC-H table must occur exactly once across them:

```dotenv
TPCH_TABLES_DB1="supplier customer"
TPCH_TABLES_DB2="orders lineitem"
TPCH_TABLES_COORDINATOR="region nation part partsupp"
```

Quote non-empty lists because the env file is also loaded as shell syntax.
`WORKLOAD_DIR` can select another workload directory inside the coordinator
image; its existing `db1.`/`db2.` table qualifiers are normalized to the
configured ownership before execution.

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
- `STARTUP_TIMEOUT_SECONDS`: maximum wait per PostgreSQL source, including load.

### PostgreSQL and network

- `PG_SHARED_BUFFERS`, `PG_SHM_SIZE`, `PG_MAX_CONNECTIONS`, and worker settings
  control each PostgreSQL instance.
- `PG_MAX_PARALLELISM` controls Accio's PostgreSQL query partitioner.
- `DB_STATS_TARGET` is used while collecting optimizer statistics after load.
- `BANDWIDTH=none` uses the real network. A value such as `1gbit` installs a
  per-source `netem` egress limit. Two sources can therefore provide twice that
  bandwidth in aggregate. The containers receive only `NET_ADMIN`, required
  for this optional traffic control.
- `COST_JOIN`, `COST_AGG`, `COST_SORT`, and `COST_TRANSFER` populate each Accio
  data-source JSON config.

The example password is only suitable for an isolated experiment network.
Change it for shared machines. The password is present in container environment
and generated Accio config, so this setup is not a production secret-management
pattern.

## Changing scale or table placement

PostgreSQL's official initialization hooks run only for an empty data directory.
Consequently, changing `TPCH_SCALE`, `TPCH_PLACEMENT`, any of the three table
lists, or the dbgen files requires deleting both PostgreSQL volumes before
redeploying.
The coordinator checks stored metadata and fails instead of silently running a
workload against stale placement.

For local Compose, after confirming the stack name and that the data can be
regenerated:

```bash
set -a; source docker/experiment.env; set +a
./run_multinode_experiments.sh down
docker volume rm "${STACK_NAME}_postgres1-data" "${STACK_NAME}_postgres2-data"
./run_multinode_experiments.sh deploy
```

For Swarm, remove the stack and then run the corresponding `docker volume rm`
for `${STACK_NAME}_postgres1-data` on the postgres1 node and
`${STACK_NAME}_postgres2-data` on the postgres2 node. Swarm local volumes are
node-local and are deliberately not deleted by the wrapper.

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
coordinator. Follow PostgreSQL loading logs with:

```bash
# Local Compose
docker compose --env-file docker/experiment.env \
  -f docker-compose.multinode.yml logs -f postgres1 postgres2

# Swarm
docker service logs -f "${STACK_NAME}_postgres1"
docker service logs -f "${STACK_NAME}_postgres2"
```

Multinode result logs and DuckDB database files live in the
`coordinator-results` volume; use the `docker cp` commands in the local or
Swarm sections above to copy them out.

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
- The coordinator reports metadata or table mismatch: the PostgreSQL volume was
  initialized with another placement; follow the volume reset procedure.
- `Remote branch parallel_query not found`: use
  `POSTGRESSCANNER_REF=prallel_query`. The fork currently publishes the branch
  with that spelling; the example env file already contains the corrected ref.
- A Swarm service remains at `0/1`: run `docker service ps --no-trunc SERVICE`.
  A rejected task commonly means a missing node label, missing bind path, image
  pull failure, or insufficient memory.
- `tc ... Operation not permitted`: retain `cap_add: NET_ADMIN` when shaping is
  needed. If the platform forbids that capability, set `BANDWIDTH=none` and
  remove the `cap_add` block from the Compose file.
- A long coordinator wait is normal while large `.tbl` files load. Follow both
  source logs with `docker compose logs -f postgres1 postgres2` locally or
  `docker service logs -f ${STACK_NAME}_postgres1` in Swarm.
