#!/usr/bin/env bash
#
# Idempotent installer for db-stat-collector.
#
# Can be run two ways:
#   1. From a local checkout:   sudo ./install.sh
#   2. Via curl one-liner:      curl -fsSL https://raw.githubusercontent.com/benjaminsanborn/db-stat-collector/main/install.sh | sudo bash
#
# When piped from curl the script auto-clones the repo to a temp dir and
# builds from there. When run from a checkout (go.mod next to the script)
# it builds in place. Either way: installs /usr/local/bin/db-stat-collector,
# writes the systemd unit, enables on boot, and restarts the service.
#
# Overrides (env vars):
#   PG_DATABASE         Database to connect to (default: postgres)
#   PG_DSN              Full libpq key=value or postgres:// URL; overrides PG_DATABASE
#   CW_NAMESPACE        CloudWatch namespace (default: PostgreSQL)
#   COLLECT_INTERVAL    Go duration string (default: 2s)
#   CLUSTER             Optional ClusterName dimension value
#   SERVICE_USER        Unix user to run as (default: postgres)
#   REPO_URL            Git remote to clone when no local source (default: https://github.com/benjaminsanborn/db-stat-collector.git)
#   REPO_REF            Branch/tag/sha to check out (default: main)
#   GO_VERSION          Go version to auto-install if missing (default: 1.23.4)

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
REPO_URL="${REPO_URL:-https://github.com/benjaminsanborn/db-stat-collector.git}"
REPO_REF="${REPO_REF:-main}"
GO_VERSION="${GO_VERSION:-1.23.4}"

if [[ $EUID -ne 0 ]]; then
    echo "install.sh must be run as root (sudo)." >&2
    exit 1
fi

ensure_apt_deps() {
    local need=()
    command -v git >/dev/null 2>&1 || need+=(git)
    command -v curl >/dev/null 2>&1 || need+=(curl)
    # ca-certificates has no binary — check the package directly.
    dpkg -s ca-certificates >/dev/null 2>&1 || need+=(ca-certificates)
    if [[ ${#need[@]} -eq 0 ]]; then
        return 0
    fi
    if ! command -v apt-get >/dev/null 2>&1; then
        echo "apt-get not found; install ${need[*]} manually and rerun." >&2
        exit 1
    fi
    echo "==> Installing apt packages: ${need[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${need[@]}"
}

ensure_go() {
    # Prefer a Go already on PATH, otherwise a prior tarball install.
    if ! command -v go >/dev/null 2>&1 && [[ -x /usr/local/go/bin/go ]]; then
        export PATH="/usr/local/go/bin:${PATH}"
    fi
    if command -v go >/dev/null 2>&1; then
        return 0
    fi

    local arch
    arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
    case "${arch}" in
        amd64|x86_64)  arch=amd64 ;;
        arm64|aarch64) arch=arm64 ;;
        *) echo "unsupported architecture: ${arch}" >&2; exit 1 ;;
    esac

    local tarball="go${GO_VERSION}.linux-${arch}.tar.gz"
    local url="https://go.dev/dl/${tarball}"
    local tmp
    tmp="$(mktemp -d)"
    echo "==> Installing Go ${GO_VERSION} (${arch}) from ${url}"
    curl -fsSL "${url}"        -o "${tmp}/${tarball}"
    curl -fsSL "${url}.sha256" -o "${tmp}/${tarball}.sha256"
    (cd "${tmp}" && echo "$(cat "${tarball}.sha256")  ${tarball}" | sha256sum -c -)
    rm -rf /usr/local/go
    tar -C /usr/local -xzf "${tmp}/${tarball}"
    rm -rf "${tmp}"
    export PATH="/usr/local/go/bin:${PATH}"

    if [[ ! -f /etc/profile.d/golang.sh ]]; then
        printf 'export PATH=$PATH:/usr/local/go/bin\n' > /etc/profile.d/golang.sh
        chmod 0644 /etc/profile.d/golang.sh
    fi
}

ensure_apt_deps
ensure_go

if ! id -u "${SERVICE_USER}" >/dev/null 2>&1; then
    echo "Service user '${SERVICE_USER}' does not exist." >&2
    exit 1
fi

# Resolve source directory: prefer a local checkout sitting next to this
# script, fall back to cloning the repo into a temp dir when piped from curl.
SCRIPT_PATH="${BASH_SOURCE[0]:-}"
SCRIPT_DIR=""
if [[ -n "${SCRIPT_PATH}" && -f "${SCRIPT_PATH}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd)"
fi

CLEANUP_SRC=""
cleanup() {
    [[ -n "${tmp_unit:-}" ]] && rm -f "${tmp_unit}"
    [[ -n "${CLEANUP_SRC}" ]] && rm -rf "${CLEANUP_SRC}"
}
trap cleanup EXIT

if [[ -n "${SCRIPT_DIR}" && -f "${SCRIPT_DIR}/go.mod" ]]; then
    SRC_DIR="${SCRIPT_DIR}"
    echo "==> Building from local checkout at ${SRC_DIR}"
else
    if ! command -v git >/dev/null 2>&1; then
        echo "git is required to fetch sources (install git or run from a checkout)." >&2
        exit 1
    fi
    SRC_DIR="$(mktemp -d -t db-stat-collector.XXXXXX)"
    CLEANUP_SRC="${SRC_DIR}"
    echo "==> Cloning ${REPO_URL} (${REPO_REF}) into ${SRC_DIR}"
    git clone --depth 1 --branch "${REPO_REF}" "${REPO_URL}" "${SRC_DIR}" >/dev/null
fi

BUILD_OUT="${SRC_DIR}/bin/${SERVICE_NAME}"

echo "==> Building ${SERVICE_NAME}"
mkdir -p "${SRC_DIR}/bin"
(
    cd "${SRC_DIR}"
    CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' \
        -o "${BUILD_OUT}" ./cmd/${SERVICE_NAME}
)

echo "==> Installing binary to ${BINARY_PATH}"
install -m 0755 "${BUILD_OUT}" "${BINARY_PATH}"

echo "==> Writing systemd unit to ${UNIT_PATH}"
tmp_unit="$(mktemp)"

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
