#!/usr/bin/env bash
# Grafana + Prometheus one-click installer for Ubuntu 24.04 LTS
# Installs native systemd services (no Docker), configures Prometheus as a Grafana data source,
# and preserves existing Grafana credentials/configuration on re-runs.
#
# Run:
#   chmod +x install-grafana-prometheus-ubuntu24.sh
#   sudo ./install-grafana-prometheus-ubuntu24.sh
#
# Optional environment variables:
#   GRAFANA_PORT=4000 PROMETHEUS_PORT=9090 BIND_ADDRESS=127.0.0.1
#   GRAFANA_ADMIN_USER=admin GRAFANA_ADMIN_PASSWORD='choose-a-strong-password'
#
set -Eeuo pipefail
umask 027

GRAFANA_PORT="${GRAFANA_PORT:-4000}"
PROMETHEUS_PORT="${PROMETHEUS_PORT:-9090}"
BIND_ADDRESS="${BIND_ADDRESS:-0.0.0.0}"
GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-}"

PROM_VERSION="${PROM_VERSION:-latest}"
NODE_EXPORTER_VERSION="${NODE_EXPORTER_VERSION:-latest}"
PROM_USER="prometheus"
PROM_GROUP="prometheus"
PROM_DIR="/etc/prometheus"
PROM_DATA="/var/lib/prometheus"
PROM_BIN="/usr/local/bin"
NODE_USER="node_exporter"
NODE_GROUP="node_exporter"

log() { printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
need_root() { [[ "${EUID}" -eq 0 ]] || die "Run with sudo: sudo $0"; }

need_root
[[ -r /etc/os-release ]] || die "Cannot detect operating system."
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]] || \
  die "This script is intended for Ubuntu 24.04 LTS. Detected: ${PRETTY_NAME:-unknown}."
command -v apt-get >/dev/null 2>&1 || die "apt-get was not found."
[[ "$GRAFANA_PORT" =~ ^[0-9]+$ && "$GRAFANA_PORT" -ge 1 && "$GRAFANA_PORT" -le 65535 ]] || die "Invalid GRAFANA_PORT."
[[ "$PROMETHEUS_PORT" =~ ^[0-9]+$ && "$PROMETHEUS_PORT" -ge 1 && "$PROMETHEUS_PORT" -le 65535 ]] || die "Invalid PROMETHEUS_PORT."
[[ "$GRAFANA_PORT" != "$PROMETHEUS_PORT" ]] || die "Grafana and Prometheus must use different ports."
[[ "$BIND_ADDRESS" == "127.0.0.1" || "$BIND_ADDRESS" == "0.0.0.0" || "$BIND_ADDRESS" == "::1" || "$BIND_ADDRESS" == "::" ]] || die "BIND_ADDRESS must be 127.0.0.1, 0.0.0.0, ::1, or ::."

log "Installing required packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl wget tar gzip adduser gnupg python3

# Create dedicated service users/directories without replacing existing data.
if ! id "$PROM_USER" >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin "$PROM_USER"
fi
install -d -o root -g "$PROM_GROUP" -m 0750 "$PROM_DIR"
install -d -o "$PROM_USER" -g "$PROM_GROUP" -m 0750 "$PROM_DATA"

# Resolve official latest release versions via GitHub API; allow pinning a version.
get_latest_tag() {
  local repo="$1"
  curl -fsSL --retry 3 "https://api.github.com/repos/${repo}/releases/latest" |
    sed -n 's/.*"tag_name":[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' | head -n1
}
if [[ "$PROM_VERSION" == "latest" ]]; then
  PROM_VERSION="$(get_latest_tag prometheus/prometheus)"
  [[ -n "$PROM_VERSION" ]] || die "Could not determine latest Prometheus version."
fi
if [[ "$NODE_EXPORTER_VERSION" == "latest" ]]; then
  NODE_EXPORTER_VERSION="$(get_latest_tag prometheus/node_exporter)"
  [[ -n "$NODE_EXPORTER_VERSION" ]] || die "Could not determine latest node_exporter version."
fi

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64) GOARCH="amd64" ;;
  arm64) GOARCH="arm64" ;;
  armhf) GOARCH="armv7" ;;
  *) die "Unsupported architecture: $ARCH (supported: amd64, arm64, armhf)." ;;
esac
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log "Downloading Prometheus ${PROM_VERSION}..."
PROM_ARCHIVE="prometheus-${PROM_VERSION}.linux-${GOARCH}.tar.gz"
curl -fL --retry 3 "https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/${PROM_ARCHIVE}" -o "$TMP/prometheus.tar.gz"
tar -xzf "$TMP/prometheus.tar.gz" -C "$TMP"
PROM_EXTRACTED="$TMP/prometheus-${PROM_VERSION}.linux-${GOARCH}"
[[ -x "$PROM_EXTRACTED/prometheus" && -x "$PROM_EXTRACTED/promtool" ]] || die "Prometheus archive contents were not as expected."
install -o root -g root -m 0755 "$PROM_EXTRACTED/prometheus" "$PROM_BIN/prometheus"
install -o root -g root -m 0755 "$PROM_EXTRACTED/promtool" "$PROM_BIN/promtool"
install -o root -g "$PROM_GROUP" -m 0640 "$PROM_EXTRACTED/prometheus.yml" "$PROM_DIR/prometheus.yml.new"
if [[ ! -f "$PROM_DIR/prometheus.yml" ]]; then
  mv "$PROM_DIR/prometheus.yml.new" "$PROM_DIR/prometheus.yml"
else
  rm -f "$PROM_DIR/prometheus.yml.new"
fi
# Prometheus release archives may omit optional console assets. They are not
# required for the Prometheus UI or scraping, so copy them only when present.
install -d -o root -g "$PROM_GROUP" -m 0750 "$PROM_DIR/consoles" "$PROM_DIR/console_libraries"
if [[ -d "$PROM_EXTRACTED/consoles" ]]; then
  cp -a "$PROM_EXTRACTED/consoles/." "$PROM_DIR/consoles/"
fi
if [[ -d "$PROM_EXTRACTED/console_libraries" ]]; then
  cp -a "$PROM_EXTRACTED/console_libraries/." "$PROM_DIR/console_libraries/"
fi
chown -R root:"$PROM_GROUP" "$PROM_DIR/consoles" "$PROM_DIR/console_libraries"
chmod -R g+rX "$PROM_DIR/consoles" "$PROM_DIR/console_libraries"

# Install node_exporter to expose host CPU, memory, filesystem, and network metrics.
log "Installing node_exporter ${NODE_EXPORTER_VERSION}..."
NODE_ARCHIVE="node_exporter-${NODE_EXPORTER_VERSION}.linux-${GOARCH}.tar.gz"
curl -fL --retry 3 "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${NODE_ARCHIVE}" -o "$TMP/node_exporter.tar.gz"
tar -xzf "$TMP/node_exporter.tar.gz" -C "$TMP"
NODE_EXTRACTED="$TMP/node_exporter-${NODE_EXPORTER_VERSION}.linux-${GOARCH}"
[[ -x "$NODE_EXTRACTED/node_exporter" ]] || die "node_exporter archive contents were not as expected."
if ! id "$NODE_USER" >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin "$NODE_USER"
fi
install -o root -g root -m 0755 "$NODE_EXTRACTED/node_exporter" "$PROM_BIN/node_exporter"

# Configure a minimal scrape setup, including node_exporter.
cat > "$TMP/prometheus.yml" <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['127.0.0.1:${PROMETHEUS_PORT}']

  - job_name: node
    static_configs:
      - targets: ['127.0.0.1:9100']
EOF
install -o root -g "$PROM_GROUP" -m 0640 "$TMP/prometheus.yml" "$PROM_DIR/prometheus.yml"

cat > /etc/systemd/system/prometheus.service <<EOF
[Unit]
Description=Prometheus Monitoring System
Wants=network-online.target
After=network-online.target

[Service]
User=${PROM_USER}
Group=${PROM_GROUP}
Type=simple
ExecStart=${PROM_BIN}/prometheus \\
  --config.file=${PROM_DIR}/prometheus.yml \\
  --storage.tsdb.path=${PROM_DATA} \\
  --storage.tsdb.retention.time=15d \\
  --web.listen-address=${BIND_ADDRESS}:${PROMETHEUS_PORT} \\
  --web.console.templates=${PROM_DIR}/consoles \\
  --web.console.libraries=${PROM_DIR}/console_libraries
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=${PROM_DATA}

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/node_exporter.service <<'EOF'
[Unit]
Description=Prometheus Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter --web.listen-address=127.0.0.1:9100
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict

[Install]
WantedBy=multi-user.target
EOF

log "Installing Grafana from the official APT repository..."
if ! grep -Rqs 'packages.grafana.com' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null &&
   ! grep -Rqs 'apt.grafana.com' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL --retry 3 https://apt.grafana.com/gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/grafana.gpg
  chmod 0644 /etc/apt/keyrings/grafana.gpg
  echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list
fi
apt-get update
apt-get install -y grafana

# Configure Grafana to listen on the selected port/address. Do not overwrite its
# admin password or existing data. Set the initial password only on first install
# when the caller explicitly supplies GRAFANA_ADMIN_PASSWORD.
GRAFANA_INI="/etc/grafana/grafana.ini"
if [[ -f "$GRAFANA_INI" ]]; then
  cp -a "$GRAFANA_INI" "${GRAFANA_INI}.backup.$(date +%Y%m%d%H%M%S)"
fi
python3 - "$GRAFANA_INI" "$GRAFANA_PORT" "$BIND_ADDRESS" <<'PY'
import configparser, os, sys
path, port, address = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = configparser.ConfigParser(interpolation=None, strict=False)
cfg.optionxform = str
if os.path.exists(path):
    cfg.read(path)
for section in ("server",):
    if not cfg.has_section(section):
        cfg.add_section(section)
cfg.set("server", "http_port", port)
cfg.set("server", "http_addr", address)
with open(path, "w") as f:
    cfg.write(f)
PY

# Provision the Prometheus data source automatically; Grafana provisions this on startup.
install -d -o root -g grafana -m 0750 /etc/grafana/provisioning/datasources
cat > /etc/grafana/provisioning/datasources/prometheus.yml <<EOF
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://127.0.0.1:${PROMETHEUS_PORT}
    isDefault: true
    editable: true
EOF
chown root:grafana /etc/grafana/provisioning/datasources/prometheus.yml
chmod 0640 /etc/grafana/provisioning/datasources/prometheus.yml

if [[ -n "$GRAFANA_ADMIN_PASSWORD" ]]; then
  # grafana-cli is used only to set the password on a first-time install.
  if [[ ! -e /var/lib/grafana/.admin-password-initialized && ! -e /var/lib/grafana/grafana.db ]]; then
    log "A Grafana admin password was supplied; applying it after first startup."
    printf '%s' "$GRAFANA_ADMIN_PASSWORD" > /root/.grafana-admin-password.pending
    chmod 0600 /root/.grafana-admin-password.pending
  else
    log "Grafana password marker exists; preserving the existing admin password."
  fi
fi

log "Validating Prometheus configuration..."
/usr/local/bin/promtool check config "$PROM_DIR/prometheus.yml"
systemctl daemon-reload
systemctl enable --now node_exporter
systemctl enable --now prometheus
systemctl enable --now grafana-server

# Wait for services to start, then optionally set first-install admin password.
sleep 3
if [[ -f /root/.grafana-admin-password.pending ]]; then
  if systemctl is-active --quiet grafana-server; then
    PASS="$(cat /root/.grafana-admin-password.pending)"
    if command -v grafana-cli >/dev/null 2>&1; then
      grafana-cli admin reset-admin-password "$PASS"
      install -o root -g root -m 0600 /dev/null /var/lib/grafana/.admin-password-initialized
      rm -f /root/.grafana-admin-password.pending
    else
      log "grafana-cli not found; password was not changed. See Grafana logs."
    fi
  fi
fi

log "Checking service status..."
systemctl --no-pager --full status prometheus | sed -n '1,12p' || true
systemctl --no-pager --full status grafana-server | sed -n '1,12p' || true
systemctl --no-pager --full status node_exporter | sed -n '1,12p' || true

cat <<EOF

============================================================
Installation finished
============================================================
Grafana:       http://<server-ip>:${GRAFANA_PORT}
Prometheus:    http://<server-ip>:${PROMETHEUS_PORT}
Node metrics:  127.0.0.1:9100
Grafana user:  ${GRAFANA_ADMIN_USER}
Grafana data source: Prometheus (provisioned automatically)
Prometheus retention: 15 days
Services: prometheus, grafana-server, node_exporter

Security note:
  BIND_ADDRESS=${BIND_ADDRESS}
  This setting exposes the web listeners on network interfaces when set to
  0.0.0.0. Restrict inbound ports ${GRAFANA_PORT} and ${PROMETHEUS_PORT} with
  your VPS firewall/UFW. Prometheus has no authentication enabled by default;
  do not expose port ${PROMETHEUS_PORT} to the public internet. For production,
  prefer localhost listeners behind a protected Nginx/LiteSpeed reverse proxy.

Useful commands:
  sudo systemctl status grafana-server prometheus node_exporter
  sudo journalctl -u grafana-server -n 100 --no-pager
  sudo journalctl -u prometheus -n 100 --no-pager
  sudo promtool check config /etc/prometheus/prometheus.yml

Re-run safety:
  The script does not intentionally reset an existing Grafana password or erase
  Prometheus time-series data. Back up /etc/grafana and /var/lib/grafana before
  major upgrades or configuration changes.

To use localhost-only listeners behind a reverse proxy:
  sudo BIND_ADDRESS=127.0.0.1 ./install-grafana-prometheus-ubuntu24.sh
============================================================
EOF
