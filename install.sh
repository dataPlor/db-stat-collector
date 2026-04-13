#!/usr/bin/env bash
set -uo pipefail

fail() { echo "  Error: $1" >&2; exit 1; }

# db-stat-collector install script
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/benjaminsanborn/db-stat-collector/main/install.sh | sudo bash
#
# With flags (note the `-- ` to pass through to the script):
#   curl -fsSL https://raw.githubusercontent.com/benjaminsanborn/db-stat-collector/main/install.sh | sudo bash -s -- --database orders
#
# Flags:
#   --database NAME    Database to monitor (default: postgres)
#   --dsn DSN          Full libpq/postgres:// DSN; overrides --database
#   --namespace NS     CloudWatch namespace (default: PostgreSQL)
#   --interval DUR     Collection interval (default: 2s)
#   --cluster NAME     Optional ClusterName dimension
#   --user USER        Unix user to run service as (default: postgres)
#   --repo-url URL     Git remote to clone (default: github.com/benjaminsanborn/db-stat-collector)
#   --repo-ref REF     Branch/tag/sha (default: main)
#   --go-version VER   Go to install if missing (default: 1.23.4)

BINARY_NAME="db-stat-collector"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/db-stat-collector"
SERVICE_FILE="/etc/systemd/system/db-stat-collector.service"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

PG_DATABASE="postgres"
PG_DSN=""
CW_NAMESPACE="PostgreSQL"
COLLECT_INTERVAL="2s"
CLUSTER=""
SERVICE_USER="postgres"
REPO_URL="https://github.com/benjaminsanborn/db-stat-collector.git"
REPO_REF="main"
GO_VERSION="1.23.4"

while [[ $# -gt 0 ]]; do
  case $1 in
    --database)   PG_DATABASE="$2";      shift 2 ;;
    --dsn)        PG_DSN="$2";           shift 2 ;;
    --namespace)  CW_NAMESPACE="$2";     shift 2 ;;
    --interval)   COLLECT_INTERVAL="$2"; shift 2 ;;
    --cluster)    CLUSTER="$2";          shift 2 ;;
    --user)       SERVICE_USER="$2";     shift 2 ;;
    --repo-url)   REPO_URL="$2";         shift 2 ;;
    --repo-ref)   REPO_REF="$2";         shift 2 ;;
    --go-version) GO_VERSION="$2";       shift 2 ;;
    *) echo "Unknown argument: $1" >&2; shift ;;
  esac
done

if [[ -z "$PG_DSN" ]]; then
  PG_DSN="dbname=${PG_DATABASE} sslmode=disable"
fi

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------

echo ""
echo "  ╔══════════════════════════════════════╗"
echo "  ║    db-stat-collector installer       ║"
echo "  ╚══════════════════════════════════════╝"
echo ""

[[ $EUID -eq 0 ]] || fail "install.sh must be run as root (sudo)"
id -u "$SERVICE_USER" >/dev/null 2>&1 || fail "Service user '$SERVICE_USER' does not exist"

# ---------------------------------------------------------------------------
# [1/5] Detect OS / arch
# ---------------------------------------------------------------------------

OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)        ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) fail "Unsupported architecture: $ARCH" ;;
esac
[[ "$OS" == "linux" ]] || fail "Only linux is supported (detected: $OS)"

echo "  [1/5] Detected $OS/$ARCH"

# ---------------------------------------------------------------------------
# [2/5] Install dependencies (apt packages + Go)
# ---------------------------------------------------------------------------

need=()
command -v git >/dev/null 2>&1 || need+=(git)
command -v curl >/dev/null 2>&1 || need+=(curl)
dpkg -s ca-certificates >/dev/null 2>&1 || need+=(ca-certificates)

if [[ ${#need[@]} -gt 0 ]]; then
  command -v apt-get >/dev/null 2>&1 || fail "apt-get not found; install ${need[*]} manually"
  DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null || fail "apt-get update failed"
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${need[@]}" >/dev/null || fail "apt-get install failed"
fi

if ! command -v go &>/dev/null && [[ -x /usr/local/go/bin/go ]]; then
  export PATH="/usr/local/go/bin:$PATH"
fi

if ! command -v go &>/dev/null; then
  GO_TARBALL="go${GO_VERSION}.${OS}-${ARCH}.tar.gz"
  # dl.google.com serves both the tarball and its .sha256 as raw files;
  # go.dev/dl/X.sha256 redirects to an HTML page, which breaks checksum verification.
  GO_URL="https://dl.google.com/go/${GO_TARBALL}"
  TMP_DIR=$(mktemp -d)
  curl -fsSL "$GO_URL" -o "$TMP_DIR/$GO_TARBALL" || fail "Failed to download Go from $GO_URL"
  expected=$(curl -fsSL "${GO_URL}.sha256" | tr -d '[:space:]')
  actual=$(sha256sum "$TMP_DIR/$GO_TARBALL" | awk '{print $1}')
  [[ -n "$expected" && "$expected" == "$actual" ]] || fail "Go tarball checksum mismatch (expected=$expected actual=$actual)"
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "$TMP_DIR/$GO_TARBALL" || fail "Failed to extract Go"
  rm -rf "$TMP_DIR"
  export PATH="/usr/local/go/bin:$PATH"
  if [[ ! -f /etc/profile.d/golang.sh ]]; then
    printf 'export PATH=$PATH:/usr/local/go/bin\n' > /etc/profile.d/golang.sh
    chmod 0644 /etc/profile.d/golang.sh
  fi
fi
command -v go &>/dev/null || fail "Go installation failed — 'go' not found in PATH"
echo "  [2/5] Dependencies ready ($(go version | awk '{print $3}'))"

# ---------------------------------------------------------------------------
# [3/5] Fetch source and build
# ---------------------------------------------------------------------------

BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT

# When run from a local checkout (go.mod next to this script) build in place,
# otherwise clone the repo into the temp build dir.
SCRIPT_PATH="${BASH_SOURCE[0]:-}"
SCRIPT_DIR=""
if [[ -n "$SCRIPT_PATH" && -f "$SCRIPT_PATH" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
fi

if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/go.mod" ]]; then
  SRC_DIR="$SCRIPT_DIR"
  echo "  [3/5] Building from local checkout: $SRC_DIR"
else
  SRC_DIR="$BUILD_DIR/src"
  echo "  [3/5] Cloning $REPO_URL ($REPO_REF)"
  git clone --quiet --depth 1 --branch "$REPO_REF" "$REPO_URL" "$SRC_DIR" || fail "git clone failed"
fi

(cd "$SRC_DIR" && CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' \
    -o "$BUILD_DIR/$BINARY_NAME" ./cmd/"$BINARY_NAME") || fail "go build failed"

# ---------------------------------------------------------------------------
# [4/5] Install binary and config
# ---------------------------------------------------------------------------

echo "  [4/5] Installing to $INSTALL_DIR/$BINARY_NAME"
install -m 0755 "$BUILD_DIR/$BINARY_NAME" "$INSTALL_DIR/$BINARY_NAME" || fail "Failed to install binary"

mkdir -p "$CONFIG_DIR"
chmod 0755 "$CONFIG_DIR"

CONFIG_FILE="$CONFIG_DIR/config.env"
cat > "$CONFIG_FILE" <<EOF
PG_DSN=$PG_DSN
CW_NAMESPACE=$CW_NAMESPACE
COLLECT_INTERVAL=$COLLECT_INTERVAL
CLUSTER=$CLUSTER
EOF
chown root:"$SERVICE_USER" "$CONFIG_FILE"
chmod 0640 "$CONFIG_FILE"

# ---------------------------------------------------------------------------
# [5/5] Systemd unit
# ---------------------------------------------------------------------------

command -v systemctl >/dev/null 2>&1 || fail "systemctl not found"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=PostgreSQL statistics collector (db-stat-collector)
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
EnvironmentFile=$CONFIG_FILE
ExecStart=$INSTALL_DIR/$BINARY_NAME
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=db-stat-collector

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

systemctl daemon-reload
systemctl enable "$BINARY_NAME" >/dev/null 2>&1
systemctl restart "$BINARY_NAME"

echo "  [5/5] systemd service enabled and started"
echo ""
echo "  Done! db-stat-collector is running."
echo ""
echo "  Useful commands:"
echo "    sudo systemctl status db-stat-collector"
echo "    sudo journalctl -u db-stat-collector -f"
echo "    sudo systemctl restart db-stat-collector"
echo ""
echo "  Config:   $CONFIG_FILE"
echo "  Database: $PG_DSN"
echo ""
