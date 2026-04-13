#!/usr/bin/env bash
#
# Create or update a CloudWatch dashboard for one db-stat-collector cluster.
# The dashboard is named after the cluster, and every widget is hard-bound
# to that ClusterName (no variable dropdown).
#
# Usage:
#   dashboards/deploy.sh <cluster-name> [region]
#
# Examples:
#   dashboards/deploy.sh dataplor-api-staging
#   dashboards/deploy.sh dataplor-api-staging us-east-1

set -euo pipefail

CLUSTER="${1:-}"
REGION="${2:-${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}}"

if [[ -z "$CLUSTER" ]]; then
    echo "Usage: $0 <cluster-name> [region]" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/db-stat-collector.json"

[[ -f "$TEMPLATE" ]] || { echo "Template not found: $TEMPLATE" >&2; exit 1; }

# CloudWatch dashboard names allow [A-Za-z0-9-_]. Sanitize anything else.
DASHBOARD_NAME="$(printf '%s' "$CLUSTER" | tr -c 'A-Za-z0-9-_' '-')"

echo "==> Deploying dashboard '${DASHBOARD_NAME}' for cluster='${CLUSTER}' region=${REGION}"

body="$(sed \
    -e "s|REGION_PLACEHOLDER|${REGION}|g" \
    -e "s|CLUSTER_PLACEHOLDER|${CLUSTER}|g" \
    "$TEMPLATE")"

aws cloudwatch put-dashboard \
    --region "$REGION" \
    --dashboard-name "$DASHBOARD_NAME" \
    --dashboard-body "$body"

echo "==> Done"
echo "    https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#dashboards:name=${DASHBOARD_NAME}"
