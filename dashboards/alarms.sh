#!/usr/bin/env bash
#
# Create/update CloudWatch alarms for one db-stat-collector cluster.
#
# Usage:
#   dashboards/alarms.sh <cluster-name> [region]
#
# Optional env:
#   SNS_TOPIC_ARN   override the default Slack topic
#                   (arn:aws:sns:us-east-1:930917098718:dataplor-slack-dar)
#                   on both ALARM and OK transitions.
#
# Each alarm is named "<cluster>-<short-name>". Re-running the script
# updates existing alarms in-place (CloudWatch put-metric-alarm is upsert).

set -euo pipefail

CLUSTER="${1:-}"
REGION="${2:-${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}}"

if [[ -z "$CLUSTER" ]]; then
    echo "Usage: $0 <cluster-name> [region]" >&2
    exit 1
fi

SNS_TOPIC_ARN="${SNS_TOPIC_ARN:-arn:aws:sns:us-east-1:930917098718:dataplor-slack-dar}"
ACTIONS=(--alarm-actions "$SNS_TOPIC_ARN" --ok-actions "$SNS_TOPIC_ARN")

NAME_PREFIX="$(printf '%s' "$CLUSTER" | tr -c 'A-Za-z0-9-_' '-')"
NS="PostgreSQL"

echo "==> Setting up alarms for cluster='${CLUSTER}' region=${REGION}"

# put_alarm <suffix> <description> <comparison-op> <threshold> <metric-json>
put_alarm() {
    local suffix="$1" desc="$2" op="$3" threshold="$4" metrics_json="$5"
    local name="${NAME_PREFIX}-${suffix}"
    echo "    - ${name}"
    aws cloudwatch put-metric-alarm \
        --region "$REGION" \
        --alarm-name "$name" \
        --alarm-description "$desc" \
        --comparison-operator "$op" \
        --evaluation-periods 3 \
        --datapoints-to-alarm 3 \
        --threshold "$threshold" \
        --treat-missing-data notBreaching \
        --metrics "$metrics_json" \
        "${ACTIONS[@]}"
}

# Single-metric helper: aggregate a search expression (max/avg/sum) across all
# instances in the cluster, returning one time series for the alarm to compare.
search_alarm() {
    local suffix="$1" desc="$2" op="$3" threshold="$4"
    local metric_name="$5" agg="$6" stat="$7" period="$8" missing="${9:-notBreaching}"

    local metrics
    metrics=$(cat <<JSON
[
  {
    "Id": "agg",
    "Expression": "${agg}(SEARCH('Namespace=\"${NS}\" MetricName=\"${metric_name}\" ClusterName=\"${CLUSTER}\"', '${stat}', ${period}))",
    "Label": "${metric_name}",
    "ReturnData": true
  }
]
JSON
)
    local name="${NAME_PREFIX}-${suffix}"
    echo "    - ${name}"
    aws cloudwatch put-metric-alarm \
        --region "$REGION" \
        --alarm-name "$name" \
        --alarm-description "$desc" \
        --comparison-operator "$op" \
        --evaluation-periods 3 \
        --datapoints-to-alarm 3 \
        --threshold "$threshold" \
        --treat-missing-data "$missing" \
        --metrics "$metrics" \
        "${ACTIONS[@]}"
}

# 1. Connections > 5000 (any instance)
search_alarm connections-high \
    "Total Postgres connections exceeded 5000" \
    GreaterThanThreshold 5000 \
    "Connections.Total" MAX Average 60

# 2. CPU > 80% (any instance)
search_alarm cpu-high \
    "CPU used > 80%" \
    GreaterThanThreshold 80 \
    "System.CPU.UsedPercent" MAX Average 60

# 3. TPS (commits + rollbacks) < 5 across the cluster
TPS_METRICS=$(cat <<JSON
[
  {
    "Id": "tps",
    "Expression": "SUM(SEARCH('Namespace=\"${NS}\" MetricName=\"Commits\" ClusterName=\"${CLUSTER}\"', 'Average', 60)) + SUM(SEARCH('Namespace=\"${NS}\" MetricName=\"Rollbacks\" ClusterName=\"${CLUSTER}\"', 'Average', 60))",
    "Label": "TPS",
    "ReturnData": true
  }
]
JSON
)
put_alarm tps-low \
    "Cluster transactions/sec dropped below 5" \
    LessThanThreshold 5 "$TPS_METRICS"

# 4. Cache hit ratio < 80%
search_alarm cache-hit-low \
    "Cache hit ratio dropped below 80%" \
    LessThanThreshold 80 \
    "CacheHitRatio" AVG Average 60

# 5. Deadlocks > 5/sec across the cluster
search_alarm deadlocks-high \
    "Deadlocks exceeded 5/sec" \
    GreaterThanThreshold 5 \
    "Deadlocks" SUM Average 60

# 6. Longest non-vacuum non-replication query > 24h (86400s)
search_alarm long-query \
    "A non-vacuum non-replication query has been running for over 24 hours" \
    GreaterThanThreshold 86400 \
    "LongestQuerySeconds" MAX Maximum 60

echo "==> Done"
echo "    https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#alarmsV2:?search=${NAME_PREFIX}-"
