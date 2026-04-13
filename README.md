# db-stat-collector

A small Go worker that runs on a PostgreSQL EC2 instance, samples Postgres and host statistics every 2 seconds, and publishes them to CloudWatch as high-resolution custom metrics.

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
| `--interval`    | `2s`                                               | Collection interval (Go duration)              |
| `--cluster`     | *unset*                                            | Optional `ClusterName` dimension               |
| `--user`        | `postgres`                                         | Unix user the service runs as                  |
| `--repo-url`    | `https://github.com/benjaminsanborn/db-stat-collector.git` | Git remote to clone                 |
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

### Postgres

| Metric                              | Unit       | Source                                                         |
| ----------------------------------- | ---------- | -------------------------------------------------------------- |
| `Connections.Active`                | Count      | `pg_stat_activity`, `state = 'active'`                         |
| `Connections.Idle`                  | Count      | `pg_stat_activity`, `state = 'idle'`                           |
| `Connections.IdleInTransaction`     | Count      | `state in ('idle in transaction', 'idle in transaction (aborted)')` |
| `Connections.Total`                 | Count      | row count in `pg_stat_activity`                                |
| `Connections.WaitingOnLock`         | Count      | `wait_event_type = 'Lock'`                                     |
| `LongestQuerySeconds`               | Seconds    | `max(now() - query_start)` across active backends              |
| `LongestTransactionSeconds`         | Seconds    | `max(now() - xact_start)` across all backends                  |
| `Commits`                           | Count/s    | rate of `pg_stat_database.xact_commit` across all databases    |
| `Rollbacks`                         | Count/s    | rate of `pg_stat_database.xact_rollback`                       |
| `Deadlocks`                         | Count/s    | rate of `pg_stat_database.deadlocks`                           |
| `CacheHitRatio`                     | Percent    | `blks_hit / (blks_hit + blks_read)` over the tick interval    |

Rates are computed as deltas between consecutive snapshots, so counter resets (`pg_stat_reset`) produce a single zero tick rather than a spike.

### Host (read from `/proc`)

| Metric                       | Unit    | Source                                           |
| ---------------------------- | ------- | ------------------------------------------------ |
| `System.CPU.UsedPercent`     | Percent | `1 - idleΔ/totalΔ` from `/proc/stat` cpu line    |
| `System.LoadAverage.1m`      | None    | field 1 of `/proc/loadavg`                       |
| `System.LoadAverage.5m`      | None    | field 2 of `/proc/loadavg`                       |
| `System.LoadAverage.15m`     | None    | field 3 of `/proc/loadavg`                       |
| `System.Memory.UsedPercent`  | Percent | `100 * (1 - MemAvailable/MemTotal)` from `/proc/meminfo` |

## Repo layout

```
cmd/db-stat-collector/main.go     wiring: flags, IMDS lookup, ticker loop
internal/collector/collector.go   pgx queries + /proc readers → Snapshot
internal/publisher/publisher.go   Snapshot → CloudWatch MetricDatum, tracks prev for rates
install.sh                        ubuntu installer + systemd unit
```
