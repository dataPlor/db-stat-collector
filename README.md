# db-stat-collector

A small Go worker that runs on a PostgreSQL EC2 instance, samples Postgres and host statistics every 60 seconds, and publishes them to CloudWatch as high-resolution custom metrics.

- Connects to Postgres over the local unix socket as the `postgres` user (peer auth, no password).
- Uses the EC2 instance profile for AWS credentials — no secrets on disk.
- Runs as a hardened systemd service.

## Install

On an Ubuntu EC2 instance (root, in one line):

```bash
curl -fsSL https://raw.githubusercontent.com/dataplor/db-stat-collector/main/install.sh | sudo bash
```

The installer bootstraps everything it needs: installs `git`/`curl`/`ca-certificates` via apt, fetches Go from `dl.google.com` (with sha256 verification) if missing, clones the repo, builds the binary, writes `/etc/db-stat-collector/config.env`, and enables a systemd unit that starts on boot.

### Flags

Pass flags after `-- ` to tune the install:

```bash
curl -fsSL https://raw.githubusercontent.com/datplor/db-stat-collector/main/install.sh \
  | sudo bash -s -- --database orders --cluster orders-primary
```

| Flag            | Default                                            | Description                                    |
| --------------- | -------------------------------------------------- | ---------------------------------------------- |
| `--database`    | `postgres`                                         | Database to connect to                         |
| `--dsn`         | built from `--database`                            | Full libpq/`postgres://` DSN (overrides above) |
| `--namespace`   | `PostgreSQL`                                       | CloudWatch namespace                           |
| `--interval`    | `60s`                                              | Collection interval (Go duration)              |
| `--cluster`     | *unset*                                            | Optional `ClusterName` dimension               |
| `--user`        | `postgres`                                         | Unix user the service runs as                  |
| `--repo-url`    | `https://github.com/dataplor/db-stat-collector.git` | Git remote to clone                 |
| `--repo-ref`    | `main`                                             | Branch / tag / sha                             |
| `--go-version`  | `1.23.4`                                           | Go version to install if missing               |

The installer is idempotent — re-running it rebuilds, overwrites the binary and unit file, and restarts the service.

### IAM requirements

The instance profile needs `cloudwatch:PutMetricData`. A minimal policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "cloudwatch:PutMetricData",
    "Resource": "*",
    "Condition": {
      "StringEquals": { "cloudwatch:namespace": "PostgreSQL" }
    }
  }]
}
```

If the instance lives in a private subnet, you'll need either a NAT gateway or a **CloudWatch interface VPC endpoint** (`com.amazonaws.<region>.monitoring`) with a security group that allows inbound `443/tcp` from the instance.

## Operating

```bash
sudo systemctl status db-stat-collector
sudo journalctl -u db-stat-collector -f
sudo systemctl restart db-stat-collector
```

Config lives at `/etc/db-stat-collector/config.env` — edit and restart to change settings without re-installing.

## Metrics

All metrics are published to the `PostgreSQL` namespace (override with `--namespace`) at 1-second storage resolution. Every datum carries `InstanceId` (from IMDS) and optionally `ClusterName` as dimensions.

### Postgres — connections & activity

| Metric                              | Unit       | Source                                                         |
| ----------------------------------- | ---------- | -------------------------------------------------------------- |
| `Connections.Active`                | Count      | `pg_stat_activity`, `state = 'active'`                         |
| `Connections.Idle`                  | Count      | `pg_stat_activity`, `state = 'idle'`                           |
| `Connections.IdleInTransaction`     | Count      | `state in ('idle in transaction', 'idle in transaction (aborted)')` |
| `Connections.Total`                 | Count      | row count in `pg_stat_activity`                                |
| `Connections.WaitingOnLock`         | Count      | `wait_event_type = 'Lock'`                                     |
| `LongestQuerySeconds`               | Seconds    | `max(now() - query_start)` across active **client** backends, excluding autovacuum and manual `VACUUM` |
| `LongestUserTransactionSeconds`     | Seconds    | `max(now() - xact_start)` across client backends, excluding autovacuum and manual `VACUUM` |
| `LongestVacuumSeconds`              | Seconds    | `max(now() - query_start)` across autovacuum workers + manual `VACUUM` |

### Postgres — throughput & cache

| Metric            | Unit    | Source                                                       |
| ----------------- | ------- | ------------------------------------------------------------ |
| `Commits`         | Count/s | rate of `pg_stat_database.xact_commit` across all databases  |
| `Rollbacks`       | Count/s | rate of `pg_stat_database.xact_rollback`                     |
| `Deadlocks`       | Count/s | rate of `pg_stat_database.deadlocks`                         |
| `CacheHitRatio`   | Percent | `blks_hit / (blks_hit + blks_read)` over the tick interval   |

Rates are computed as deltas between consecutive snapshots, so counter resets (`pg_stat_reset`) produce a single zero tick rather than a spike.

### Active queries

| Metric                  | Unit  | Dimensions | Source                                                                |
| ----------------------- | ----- | ---------- | --------------------------------------------------------------------- |
| `ActiveQueries.Count`   | Count | `+ Query`  | active client backends grouped by leading SQL command (`SELECT`, `INSERT`, `UPDATE`, `DELETE`, `VACUUM`, `COPY`, `BEGIN`, …, else `OTHER`); leading SQL comments are stripped before the keyword is extracted |

Stacked in the dashboard. Cardinality is capped at ~15 series regardless of workload — you get a live view of "what kinds of things is Postgres doing right now" without per-statement CloudWatch cost. For per-statement drill-down, use `pg_stat_statements` directly instead.

### Wait events

| Metric              | Unit  | Dimensions                                                | Source                                                            |
| ------------------- | ----- | --------------------------------------------------------- | ----------------------------------------------------------------- |
| `WaitEvents.Count`  | Count | `+ WaitEvent` (= `<wait_event_type>:<wait_event>` or `CPU`) | all active backends (client + autovacuum + walsender) grouped by `wait_event_type \|\| ':' \|\| wait_event`; NULL bucketed as `CPU` |

Stacked in the dashboard. The total across all `WaitEvent` buckets equals the active-query count, so you can see at a glance whether active queries are running on CPU, waiting on locks, doing IO, etc.

### Tablespaces

| Metric                          | Unit    | Dimensions           | Source                                                          |
| ------------------------------- | ------- | -------------------- | --------------------------------------------------------------- |
| `Tablespace.SizeBytes`          | Bytes   | `+ Tablespace`       | `pg_tablespace_size(oid)` per row of `pg_tablespace`            |
| `Tablespace.DiskUsedPercent`    | Percent | `+ Tablespace`       | `statfs(location)` → `(blocks - bavail) / blocks * 100`         |
| `Tablespace.DiskAvailBytes`     | Bytes   | `+ Tablespace`       | `statfs(location).Bavail * Bsize`                               |

`pg_default` and `pg_global` resolve to the `data_directory` setting (so their `statfs` reflects the main data volume); user-defined tablespaces use their own `CREATE TABLESPACE` path.

### Host (read from `/proc`)

| Metric                       | Unit    | Source                                                   |
| ---------------------------- | ------- | -------------------------------------------------------- |
| `System.CPU.UsedPercent`     | Percent | `1 - idleΔ/totalΔ` from `/proc/stat` cpu line            |
| `System.LoadAverage.1m`      | None    | field 1 of `/proc/loadavg`                               |
| `System.LoadAverage.5m`      | None    | field 2 of `/proc/loadavg`                               |
| `System.LoadAverage.15m`     | None    | field 3 of `/proc/loadavg`                               |
| `System.Memory.UsedPercent`  | Percent | `100 * (1 - MemAvailable/MemTotal)` from `/proc/meminfo` |

## Dashboards and alarms

```bash
./dashboards/deploy.sh <cluster>   # creates/updates the CloudWatch dashboard named after <cluster>
./dashboards/alarms.sh  <cluster>  # creates/updates per-instance alarms for <cluster>
```

Both scripts take an optional region as a 2nd arg (default `us-east-1`). Alarms notify `arn:aws:sns:us-east-1:930917098718:ptu-alerts` on ALARM and OK transitions. `alarms.sh` discovers `InstanceId`s via `list-metrics` at run-time, so re-run it after scaling the cluster in/out.

## Repo layout

```
cmd/db-stat-collector/main.go     wiring: flags, IMDS lookup, ticker loop
internal/collector/collector.go   pgx queries + /proc readers + statfs → Snapshot
internal/publisher/publisher.go   Snapshot → CloudWatch MetricDatum, tracks prev for rates
install.sh                        ubuntu installer + systemd unit
dashboards/db-stat-collector.json dashboard template (cluster/region baked in at deploy)
dashboards/deploy.sh              dashboard upsert script
dashboards/alarms.sh              per-instance alarm upsert script
```
