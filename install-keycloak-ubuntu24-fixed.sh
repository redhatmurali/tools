#!/usr/bin/env bash
# Keycloak native installation for Ubuntu 24.04 LTS.
# Built-in Admin Console: http://SERVER-IP:8081/admin/
# Initial HTTP configuration is intended for trusted LAN/testing only.
set -Eeuo pipefail
umask 077

log() { printf '\n==> %s\n' "$*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

[[ "$EUID" -eq 0 ]] || fail "Run with sudo: sudo bash $0"
[[ -r /etc/os-release ]] || fail "Cannot identify operating system."
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]] ||
  fail "This script is for Ubuntu 24.04 LTS. Detected: ${PRETTY_NAME:-unknown}"

# Avoid overwriting a live or partially configured installation silently.
if systemctl is-active --quiet keycloak 2>/dev/null; then
  fail "Keycloak service is already running. Stop it and back up its database before reinstalling."
fi

export DEBIAN_FRONTEND=noninteractive
log "Installing dependencies"
apt-get update
apt-get install -y ca-certificates curl unzip openssl postgresql postgresql-client openjdk-21-jre-headless

JAVA_PATH="$(readlink -f "$(command -v java)")"
JAVA_HOME="$(dirname "$(dirname "$JAVA_PATH")")"
JAVA_MAJOR="$(java -version 2>&1 | sed -n '1s/.*version "\([0-9]*\).*/\1/p')"
[[ "${JAVA_MAJOR:-0}" -ge 21 ]] || fail "Java 21+ required; found ${JAVA_MAJOR:-unknown}"

log "Finding latest stable Keycloak release"
RELEASE_URL="$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/keycloak/keycloak/releases/latest)"
VERSION="${RELEASE_URL##*/}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  fail "Could not determine stable Keycloak version from ${RELEASE_URL}"
DOWNLOAD_URL="https://github.com/keycloak/keycloak/releases/download/${VERSION}/keycloak-${VERSION}.zip"

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

log "Downloading Keycloak ${VERSION}"
curl -fL --retry 3 --retry-delay 2 "$DOWNLOAD_URL" -o "$TMP_DIR/keycloak.zip"
unzip -q "$TMP_DIR/keycloak.zip" -d "$TMP_DIR/unpacked"
KC_SOURCE="$TMP_DIR/unpacked/keycloak-${VERSION}"
[[ -x "$KC_SOURCE/bin/kc.sh" ]] || fail "Keycloak archive did not contain bin/kc.sh"

if id keycloak >/dev/null 2>&1; then
  :
else
  useradd --system --home-dir /opt/keycloak --shell /usr/sbin/nologin keycloak
fi

if [[ -e /opt/keycloak ]]; then
  BACKUP="/opt/keycloak.backup.$(date +%Y%m%d%H%M%S)"
  log "Preserving existing /opt/keycloak at ${BACKUP}"
  mv /opt/keycloak "$BACKUP"
fi
install -d -o root -g root -m 0755 /opt
mv "$KC_SOURCE" /opt/keycloak
chown -R keycloak:keycloak /opt/keycloak
chmod -R go-w /opt/keycloak

DB_PASSWORD="$(openssl rand -hex 32)"
ADMIN_PASSWORD="$(openssl rand -hex 24)"
ADMIN_USER="kcadmin"
DB_NAME="keycloak"
DB_USER="keycloak"

log "Preparing PostgreSQL"
systemctl enable --now postgresql
runuser -u postgres -- psql -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${DB_USER}') THEN
    CREATE ROLE ${DB_USER} LOGIN PASSWORD '${DB_PASSWORD}';
  ELSE
    ALTER ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASSWORD}';
  END IF;
END
\$\$;
SELECT 'CREATE DATABASE ${DB_NAME} OWNER ${DB_USER}'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${DB_NAME}')\\gexec
ALTER DATABASE ${DB_NAME} OWNER TO ${DB_USER};
SQL

log "Writing Keycloak environment"
install -d -o root -g keycloak -m 0750 /etc/keycloak
cat > /etc/keycloak/keycloak.env <<EOF
KC_BOOTSTRAP_ADMIN_USERNAME=${ADMIN_USER}
KC_BOOTSTRAP_ADMIN_PASSWORD=${ADMIN_PASSWORD}
KC_DB=postgres
KC_DB_URL=jdbc:postgresql://127.0.0.1:5432/${DB_NAME}
KC_DB_USERNAME=${DB_USER}
KC_DB_PASSWORD=${DB_PASSWORD}
KC_HTTP_ENABLED=true
KC_HOSTNAME_STRICT=false
KC_HTTP_PORT=8081
KC_HTTP_MANAGEMENT_PORT=9000
KC_METRICS_ENABLED=true
KC_HEALTH_ENABLED=true
EOF
chown root:keycloak /etc/keycloak/keycloak.env
chmod 0640 /etc/keycloak/keycloak.env

log "Building Keycloak as the service user"
runuser -u keycloak -- env JAVA_HOME="$JAVA_HOME" /opt/keycloak/bin/kc.sh build \
  --db=postgres --metrics-enabled=true --health-enabled=true

# Keep executable/application files root-owned after build. Only runtime data is writable.
chown -R root:root /opt/keycloak
install -d -o keycloak -g keycloak -m 0750 /opt/keycloak/data
chmod -R go-w /opt/keycloak

log "Creating systemd service"
cat > /etc/systemd/system/keycloak.service <<EOF
[Unit]
Description=Keycloak Identity and Access Management
Wants=network-online.target
After=network-online.target postgresql.service
Requires=postgresql.service

[Service]
Type=simple
User=keycloak
Group=keycloak
WorkingDirectory=/opt/keycloak
EnvironmentFile=/etc/keycloak/keycloak.env
Environment=JAVA_HOME=${JAVA_HOME}
ExecStart=/opt/keycloak/bin/kc.sh start --optimized
Restart=on-failure
RestartSec=10
TimeoutStartSec=180
TimeoutStopSec=60
LimitNOFILE=65536
UMask=0027
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=/opt/keycloak/data

[Install]
WantedBy=multi-user.target
EOF
chmod 0644 /etc/systemd/system/keycloak.service

log "Starting Keycloak"
systemctl daemon-reload
systemctl enable keycloak
systemctl restart keycloak

READY=0
for _ in $(seq 1 80); do
  if curl -fsS http://127.0.0.1:9000/health/ready >/dev/null 2>&1; then
    READY=1
    break
  fi
  if ! systemctl is-active --quiet keycloak; then
    break
  fi
  sleep 3
done

SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
CRED_FILE="/root/keycloak-credentials.txt"
cat > "$CRED_FILE" <<EOF
Keycloak version: ${VERSION}
Admin Console: http://${SERVER_IP:-SERVER-IP}:8081/admin/
Base URL: http://${SERVER_IP:-SERVER-IP}:8081/
Admin username: ${ADMIN_USER}
Admin password: ${ADMIN_PASSWORD}

PostgreSQL database: ${DB_NAME}
PostgreSQL username: ${DB_USER}
PostgreSQL password: ${DB_PASSWORD}

Security: initial HTTP setup is for trusted LAN/testing only. Configure HTTPS before public production use.
EOF
chmod 0600 "$CRED_FILE"

echo
if [[ "$READY" -eq 1 ]]; then
  echo "Keycloak is ready."
else
  echo "Keycloak did not become ready. Inspect: sudo journalctl -u keycloak -n 100 --no-pager"
fi
echo "Version: ${VERSION}"
echo "Admin Console: http://${SERVER_IP:-SERVER-IP}:8081/admin/"
echo "Credentials: ${CRED_FILE} (root-only)"
echo
echo "Checks:"
echo "  sudo systemctl status keycloak --no-pager -l"
echo "  sudo journalctl -u keycloak -n 100 --no-pager"
echo "  curl -fsS http://127.0.0.1:9000/health/ready"
echo "  sudo ss -lntp | grep -E ':8080|:8081|:9000|:5432'"
echo
echo "No firewall rules were changed."
echo "For trusted LAN access, add a rule using your actual LAN subnet, e.g.:"
echo "  sudo ufw allow from YOUR_LAN_CIDR to any port 8081 proto tcp"
echo "Do not expose port 9000 or PostgreSQL 5432 publicly."
