#!/usr/bin/env bash
# Native Keycloak installation for Ubuntu 24.04 LTS.
# Built-in UI: http://SERVER-IP:8080/admin/
# Use only on a trusted LAN until HTTPS and access restrictions are configured.
set -Eeuo pipefail
umask 077

if [[ "$EUID" -ne 0 ]]; then
  echo "Run as root: sudo bash $0"
  exit 1
fi
source /etc/os-release
if [[ "${ID:-}" != ubuntu || "${VERSION_ID:-}" != "24.04" ]]; then
  echo "This script requires Ubuntu 24.04 LTS. Detected: ${PRETTY_NAME:-unknown}"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl unzip python3 openssl postgresql postgresql-client openjdk-21-jre-headless

JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
JAVA_MAJOR="$(java -version 2>&1 | sed -n '1s/.*version "\([0-9]*\).*/\1/p')"
if [[ "${JAVA_MAJOR:-0}" -lt 21 ]]; then
  echo "Java 21 or newer is required. Detected: ${JAVA_MAJOR:-unknown}"
  exit 1
fi

echo "==> Finding latest stable Keycloak release"
RELEASE_URL="$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/keycloak/keycloak/releases/latest)"
VERSION="${RELEASE_URL##*/}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Could not identify a stable version from ${RELEASE_URL}"
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
DOWNLOAD_URL="https://github.com/keycloak/keycloak/releases/download/${VERSION}/keycloak-${VERSION}.zip"
echo "==> Downloading Keycloak ${VERSION}"
curl -fL --retry 3 --retry-delay 2 "$DOWNLOAD_URL" -o "$TMP_DIR/keycloak.zip"
unzip -q "$TMP_DIR/keycloak.zip" -d "$TMP_DIR/unpacked"
KC_SOURCE="$TMP_DIR/unpacked/keycloak-${VERSION}"
if [[ ! -x "$KC_SOURCE/bin/kc.sh" ]]; then
  echo "Could not find bin/kc.sh in the downloaded archive."
  exit 1
fi

if ! id keycloak >/dev/null 2>&1; then
  useradd --system --home-dir /opt/keycloak --shell /usr/sbin/nologin keycloak
fi
if [[ -e /opt/keycloak ]]; then
  BACKUP="/opt/keycloak.backup.$(date +%Y%m%d%H%M%S)"
  echo "Existing /opt/keycloak found; preserving it at $BACKUP"
  mv /opt/keycloak "$BACKUP"
fi
install -d -o root -g root -m 0755 /opt
mv "$KC_SOURCE" /opt/keycloak
chown -R root:root /opt/keycloak
chmod -R go-w /opt/keycloak

DB_PASSWORD="$(openssl rand -hex 32)"
ADMIN_PASSWORD="$(openssl rand -hex 24)"
ADMIN_USER="kcadmin"

systemctl enable --now postgresql
runuser -u postgres -- psql -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'keycloak') THEN
    CREATE ROLE keycloak LOGIN PASSWORD '${DB_PASSWORD}';
  ELSE
    ALTER ROLE keycloak WITH LOGIN PASSWORD '${DB_PASSWORD}';
  END IF;
END
\$\$;
SELECT 'CREATE DATABASE keycloak OWNER keycloak'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'keycloak')\gexec
ALTER DATABASE keycloak OWNER TO keycloak;
SQL

install -d -o root -g keycloak -m 0750 /etc/keycloak
cat > /etc/keycloak/keycloak.env <<EOF
KC_BOOTSTRAP_ADMIN_USERNAME=${ADMIN_USER}
KC_BOOTSTRAP_ADMIN_PASSWORD=${ADMIN_PASSWORD}
KC_DB=postgres
KC_DB_URL=jdbc:postgresql://127.0.0.1:5432/keycloak
KC_DB_USERNAME=keycloak
KC_DB_PASSWORD=${DB_PASSWORD}
KC_HTTP_ENABLED=true
KC_HOSTNAME_STRICT=false
KC_METRICS_ENABLED=true
KC_HEALTH_ENABLED=true
EOF
chown root:keycloak /etc/keycloak/keycloak.env
chmod 0640 /etc/keycloak/keycloak.env

echo "==> Building Keycloak"
runuser -u keycloak -- env JAVA_HOME="$JAVA_HOME" /opt/keycloak/bin/kc.sh build \
  --db=postgres --metrics-enabled=true --health-enabled=true

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
Environment=KC_HTTP_PORT=8080
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

chown -R keycloak:keycloak /opt/keycloak/data
systemctl daemon-reload
systemctl enable --now keycloak

echo "==> Waiting for startup"
READY=0
for _ in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:9000/health/ready >/dev/null 2>&1 || \
     curl -fsS http://127.0.0.1:8080/ >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 3
done

SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
CRED_FILE="/root/keycloak-credentials.txt"
cat > "$CRED_FILE" <<EOF
Keycloak installation details
Version: ${VERSION}
Admin Console: http://${SERVER_IP:-SERVER-IP}:8080/admin/
Base URL: http://${SERVER_IP:-SERVER-IP}:8080/
Admin username: ${ADMIN_USER}
Admin password: ${ADMIN_PASSWORD}

PostgreSQL database: keycloak
PostgreSQL role: keycloak
PostgreSQL password: ${DB_PASSWORD}

IMPORTANT: Credentials are stored in this root-only file.
Initial HTTP access is intended for trusted LAN/testing only. Do not expose port 8080 publicly.
For production, configure HTTPS with a trusted certificate/reverse proxy and restrict admin access.
EOF
chmod 0600 "$CRED_FILE"

echo
if [[ "$READY" -eq 1 ]]; then
  echo "Keycloak appears to be responding."
else
  echo "Keycloak did not respond in time. Check: journalctl -u keycloak -n 100 --no-pager"
fi
echo "Keycloak version: ${VERSION}"
echo "Admin Console: http://${SERVER_IP:-SERVER-IP}:8080/admin/"
echo "Credentials saved to ${CRED_FILE} (root-only)"
echo
echo "Commands:"
echo "  sudo systemctl status keycloak --no-pager -l"
echo "  sudo journalctl -u keycloak -f"
echo "  sudo cat ${CRED_FILE}"
echo
echo "No firewall rules were changed. For LAN access, allow TCP/8080 only from your trusted LAN."
