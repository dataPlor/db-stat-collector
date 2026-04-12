#!/usr/bin/env bash
#
# Idempotent installer for db-stat-collector.
#
# Builds the Go binary from the current working tree, installs it to
# /usr/local/bin, writes a systemd unit, enables it on boot, and restarts
# the service. Safe to re-run after pulling updates.
#
# Overrides (env vars):
#   PG_DATABASE         Database to connect to (default: postgres)
#   PG_DSN              Full libpq key=value or postgres:// URL; overrides PG_DATABASE
#   CW_NAMESPACE        CloudWatch namespace (default: PostgreSQL)
#   COLLECT_INTERVAL    Go duration string (default: 2s)
#   CLUSTER             Optional ClusterName dimension value
#   SERVICE_USER        Unix user to run as (default: postgres)

set -euo pipefail

SERVICE_NAME="db-stat-collector"
INSTALL_DIR="/usr/local/bin"
BINARY_PATH="${INSTALL_DIR}/${SERVICE_NAME}"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"

SERVICE_USER="${SERVICE_USER:-postgres}"
PG_DATABASE="${PG_DATABASE:-postgres}"
PG_DSN="${PG_DSN:-dbname=${PG_DATABASE} sslmode=disable}"
CW_NAMESPACE="${CW_NAMESPACE:-PostgreSQL}"
COLLECT_INTERVAL="${COLLECT_INTERVAL:-2s}"
CLUSTER="${CLUSTER:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_OUT="${SCRIPT_DIR}/bin/${SERVICE_NAME}"

if [[ $EUID -ne 0 ]]; then
    echo "install.sh must be run as root (sudo)." >&2
    exit 1
fi

if ! command -v go >/dev/null 2>&1; then
    echo "Go toolchain not found. Install Go 1.22+ (e.g. 'dnf install -y golang') and rerun." >&2
    exit 1
fi

if ! id -u "${SERVICE_USER}" >/dev/null 2>&1; then
    echo "Service user '${SERVICE_USER}' does not exist." >&2
    exit 1
fi

echo "==> Building ${SERVICE_NAME}"
mkdir -p "${SCRIPT_DIR}/bin"
(
    cd "${SCRIPT_DIR}"
    CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' \
        -o "${BUILD_OUT}" ./cmd/${SERVICE_NAME}
)

echo "==> Installing binary to ${BINARY_PATH}"
install -m 0755 "${BUILD_OUT}" "${BINARY_PATH}"

echo "==> Writing systemd unit to ${UNIT_PATH}"
tmp_unit="$(mktemp)"
trap 'rm -f "${tmp_unit}"' EXIT

{
    cat <<EOF
[Unit]
Description=PostgreSQL statistics collector (db-stat-collector)
Documentation=https://github.com/
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
ExecStart=${BINARY_PATH}
Restart=always
RestartSec=5

Environment=PG_DSN=${PG_DSN}
Environment=CW_NAMESPACE=${CW_NAMESPACE}
Environment=COLLECT_INTERVAL=${COLLECT_INTERVAL}
EOF

    if [[ -n "${CLUSTER}" ]]; then
        echo "Environment=CLUSTER=${CLUSTER}"
    fi

    cat <<'EOF'

# Hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictNamespaces=true
LockPersonality=true
MemoryDenyWriteExecute=true
RestrictRealtime=true
RestrictSUIDSGID=true

[Install]
WantedBy=multi-user.target
EOF
} > "${tmp_unit}"

install -m 0644 "${tmp_unit}" "${UNIT_PATH}"

echo "==> Reloading systemd"
systemctl daemon-reload

echo "==> Enabling ${SERVICE_NAME} on boot"
systemctl enable "${SERVICE_NAME}.service" >/dev/null

echo "==> Restarting ${SERVICE_NAME}"
systemctl restart "${SERVICE_NAME}.service"

sleep 1
systemctl --no-pager --full status "${SERVICE_NAME}.service" || true
echo "==> Done"
