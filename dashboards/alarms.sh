#!/usr/bin/env bash
#
# Create/update CloudWatch alarms for one db-stat-collector cluster.
#
# Usage:
#   dashboards/alarms.sh <cluster-name> [region]
#
# Notifications are hardcoded to the ptu-alerts SNS topic on both ALARM and
# OK transitions. Each alarm is named "<cluster>-<instance>-<suffix>", so a
# 3-instance cluster ends up with 15 alarms (5 per instance). Re-running
# this script upserts existing alarms; it does NOT delete alarms for
# instances that have gone away.
#
# Discovery happens at script run-time via list-metrics, so re-run this
# after scaling the cluster.

set -euo pipefail

CLUSTER="${1:-}"
REGION="${2:-${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}}"

if [[ -z "$CLUSTER" ]]; then
    echo "Usage: $0 <cluster-name> [region]" >&2
    exit 1
fi

SNS_TOPIC_ARN="arn:aws:sns:us-east-1:930917098718:ptu-alerts"
ACTIONS=(--alarm-actions "$SNS_TOPIC_ARN" --ok-actions "$SNS_TOPIC_ARN")

CLUSTER_PREFIX="$(printf '%s' "$CLUSTER" | tr -c 'A-Za-z0-9-_' '-')"
NS="PostgreSQL"

echo "==> Discovering InstanceIds reporting under cluster='${CLUSTER}'"
INSTANCE_IDS=()
while IFS= read -r iid; do
    [[ -n "$iid" ]] && INSTANCE_IDS+=("$iid")
done < <(aws cloudwatch list-metrics \
    --region "$REGION" \
    --namespace "$NS" \
    --metric-name "Connections.Total" \
    --dimensions Name=ClusterName,Value="$CLUSTER" \
    --query 'Metrics[].Dimensions[?Name==`InstanceId`].Value' \
    --output text 2>/dev/null | tr '\t' '\n' | sort -u)

if [[ ${#INSTANCE_IDS[@]} -eq 0 ]]; then
    echo "  No InstanceIds found. Run install.sh on at least one instance first," >&2
    echo "  wait ~30s for metrics to appear, then rerun this script." >&2
    exit 1
fi

echo "  Found ${#INSTANCE_IDS[@]}: ${INSTANCE_IDS[*]}"

# put_simple <iid> <suffix> <description> <metric-name> <stat> <op> <threshold>
put_simple() {
    local iid="$1" suffix="$2" desc="$3" metric="$4" stat="$5" op="$6" threshold="$7"
    local name="${CLUSTER_PREFIX}-${iid}-${suffix}"
    echo "    - ${name}"
    aws cloudwatch put-metric-alarm \
        --region "$REGION" \
        --alarm-name "$name" \
        --alarm-description "${desc} (${iid})" \
        --namespace "$NS" \
        --metric-name "$metric" \
        --dimensions Name=ClusterName,Value="$CLUSTER" Name=InstanceId,Value="$iid" \
        --statistic "$stat" \
        --period 60 \
        --evaluation-periods 3 \
        --datapoints-to-alarm 3 \
        --threshold "$threshold" \
        --comparison-operator "$op" \
        --treat-missing-data notBreaching \
        "${ACTIONS[@]}"
}

echo "==> Putting alarms"
for iid in "${INSTANCE_IDS[@]}"; do
    put_simple "$iid" connections-high \
        "Total Postgres connections exceeded 5000" \
        "Connections.Total" Average GreaterThanThreshold 5000

    put_simple "$iid" cpu-high \
        "CPU used > 80%" \
        "System.CPU.UsedPercent" Average GreaterThanThreshold 80

    put_simple "$iid" cache-hit-low \
        "Cache hit ratio dropped below 80%" \
        "CacheHitRatio" Average LessThanThreshold 80

    put_simple "$iid" deadlocks-high \
        "Deadlocks exceeded 5/sec" \
        "Deadlocks" Average GreaterThanThreshold 5

    put_simple "$iid" long-query \
        "A non-vacuum non-replication query has been running for over 24 hours" \
        "LongestQuerySeconds" Maximum GreaterThanThreshold 86400
done

echo "==> Done"
echo "    https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#alarmsV2:?search=${CLUSTER_PREFIX}-"
