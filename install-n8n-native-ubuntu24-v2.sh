#!/usr/bin/env bash
# Native n8n installer for Ubuntu 24.04 LTS. No Docker or containers.
# Installs Node.js 24, PostgreSQL 17, compiles isolated-vm, and creates systemd service.
set -Eeuo pipefail
umask 077

N8N_PORT=5678
DB_NAME=n8n
DB_USER=n8n
INSTALL_DIR=/opt/n8n
ENV_DIR=/etc/n8n
ENV_FILE=${ENV_DIR}/n8n.env
SERVICE_FILE=/etc/systemd/system/n8n.service

if [[ ${EUID} -ne 0 ]]; then
  echo "ERROR: Run as root: sudo bash $0" >&2
  exit 1
fi
source /etc/os-release
if [[ ${ID:-} != ubuntu || ${VERSION_ID:-} != 24.04 ]]; then
  echo "ERROR: This script supports Ubuntu 24.04 LTS only. Found: ${PRETTY_NAME:-unknown}" >&2
  exit 1
fi

# Refuse to overwrite an existing installation or partial previous attempt.
if id n8n >/dev/null 2>&1 || [[ -e ${SERVICE_FILE} || -e ${ENV_FILE} || -d /var/lib/n8n/.n8n ]]; then
  echo "ERROR: Existing n8n user, service, configuration, or data detected." >&2
  echo "This installer will not overwrite existing data. Repair/update the existing installation separately." >&2
  exit 2
fi
if runuser -u postgres -- psql -Atqc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" 2>/dev/null | grep -qx 1; then
  echo "ERROR: PostgreSQL role '${DB_USER}' already exists; refusing to overwrite it." >&2
  exit 2
fi
if runuser -u postgres -- psql -Atqc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" 2>/dev/null | grep -qx 1; then
  echo "ERROR: PostgreSQL database '${DB_NAME}' already exists; refusing to overwrite it." >&2
  exit 2
fi

echo '==> Installing system prerequisites and native build tools'
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates curl gnupg openssl build-essential python3 make g++ \
  postgresql-common

# PostgreSQL Global Development Group repository, so a supported PostgreSQL 17 is installed.
echo '==> Configuring the PostgreSQL repository'
install -d -m 0755 /usr/share/postgresql-common/pgdg
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
  -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
chmod 0644 /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
cat > /etc/apt/sources.list.d/pgdg.list <<'EOF'
deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt noble-pgdg main
EOF

# Node.js 24 is required by the installed isolated-vm dependency seen in n8n 2.44.x.
echo '==> Configuring Node.js 24 repository'
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
  | gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg
chmod 0644 /etc/apt/keyrings/nodesource.gpg
cat > /etc/apt/sources.list.d/nodesource.list <<'EOF'
deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_24.x nodistro main
EOF
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs postgresql-17 postgresql-client-17 postgresql-contrib-17

NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
if [[ ${NODE_MAJOR} != 24 ]]; then
  echo "ERROR: Expected Node.js 24.x; found $(node --version)." >&2
  exit 1
fi

# Start PostgreSQL and ensure the 17/main cluster is running.
systemctl enable --now postgresql
if command -v pg_lsclusters >/dev/null 2>&1; then
  if pg_lsclusters --no-header | awk '$1==17 && $2=="main" {found=1} END{exit !found}'; then
    if ! pg_lsclusters --no-header | awk '$1==17 && $2=="main" && $4=="online" {found=1} END{exit !found}'; then
      pg_ctlcluster 17 main start
    fi
  else
    pg_createcluster 17 main --start
  fi
fi
systemctl restart postgresql

# Use the host's primary IPv4 address for convenient LAN access. If detection fails,
# fall back to loopback and explain the result in the summary.
SERVER_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true)"
if [[ -z ${SERVER_IP} ]]; then SERVER_IP=127.0.0.1; fi

DB_PASSWORD="$(openssl rand -hex 32)"
N8N_ENCRYPTION_KEY="$(openssl rand -hex 32)"

 echo '==> Creating n8n service account and data directories'
useradd --system --create-home --home-dir /var/lib/n8n --shell /usr/sbin/nologin n8n
install -d -o n8n -g n8n -m 0750 "${INSTALL_DIR}" /var/lib/n8n/.n8n
install -d -o root -g n8n -m 0750 "${ENV_DIR}"

echo '==> Creating PostgreSQL role and database'
runuser -u postgres -- psql -v ON_ERROR_STOP=1 \
  --set=db_user="${DB_USER}" --set=db_name="${DB_NAME}" --set=db_password="${DB_PASSWORD}" <<'SQL'
CREATE ROLE :"db_user" LOGIN PASSWORD :'db_password';
CREATE DATABASE :"db_name" OWNER :"db_user";
SQL

echo '==> Installing n8n natively through npm (no Docker)'
# The script uses umask 077 for secrets, but npm's application files must be
# readable by the unprivileged n8n service account. Use a standard package umask.
umask 022
DEBIAN_FRONTEND=noninteractive npm install --global \
  --allow-scripts=@parcel/watcher,isolated-vm,sqlite3,protobufjs,agent-browser,oracledb,msgpackr-extract,ssh2,@sentry/node-native-stacktrace,@sentry/node-cpu-profiler,@confluentinc/kafka-javascript,cpu-features,@scarf/scarf,vue-demi \
  n8n@latest
N8N_BIN="$(command -v n8n)"
if [[ -z ${N8N_BIN} || ! -x ${N8N_BIN} ]]; then
  echo 'ERROR: n8n executable not found after npm install.' >&2
  exit 1
fi
N8N_ROOT="$(npm root -g)/n8n"
if [[ ! -d ${N8N_ROOT} ]]; then
  echo "ERROR: Could not locate n8n global package directory: ${N8N_ROOT}" >&2
  exit 1
fi
# npm must install world-readable package files so User=n8n can load them.
chmod -R a+rX "${N8N_ROOT}"

# Critical fix: rebuild native isolated-vm after Node.js and build tools are installed.
echo '==> Rebuilding isolated-vm native module'
if ! (cd "${N8N_ROOT}" && npm rebuild isolated-vm --foreground-scripts); then
  echo 'ERROR: isolated-vm native build failed. See the npm output above.' >&2
  exit 1
fi
if ! (cd "${N8N_ROOT}" && runuser -u n8n -- env NODE_PATH="${N8N_ROOT}/node_modules" node -e "require('isolated-vm'); console.log('isolated-vm native module loaded successfully')"); then
  echo 'ERROR: isolated-vm could not be loaded by the n8n service account.' >&2
  exit 1
fi

# Restore restrictive permissions for the credentials/config file.
umask 077
# Store credentials and persistent encryption key. Never rotate this key on an existing instance.
cat > "${ENV_FILE}" <<EOF
DB_TYPE=postgresdb
DB_POSTGRESDB_HOST=127.0.0.1
DB_POSTGRESDB_PORT=5432
DB_POSTGRESDB_DATABASE=${DB_NAME}
DB_POSTGRESDB_USER=${DB_USER}
DB_POSTGRESDB_PASSWORD=${DB_PASSWORD}
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
N8N_PORT=${N8N_PORT}
N8N_LISTEN_ADDRESS=0.0.0.0
N8N_HOST=${SERVER_IP}
N8N_PROTOCOL=http
N8N_SECURE_COOKIE=false
N8N_USER_FOLDER=/var/lib/n8n/.n8n
WEBHOOK_URL=http://${SERVER_IP}:${N8N_PORT}/
GENERIC_TIMEZONE=Asia/Kolkata
TZ=Asia/Kolkata
N8N_DIAGNOSTICS_ENABLED=false
N8N_PERSONALIZATION_ENABLED=false
N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
EOF
chown root:n8n "${ENV_FILE}"
chmod 0640 "${ENV_FILE}"

# Native systemd service. ProtectSystem is relaxed for global npm native modules where needed.
echo '==> Creating and enabling systemd service'
cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=n8n Workflow Automation (native, no Docker)
After=network-online.target postgresql.service
Wants=network-online.target
Requires=postgresql.service

[Service]
Type=simple
User=n8n
Group=n8n
EnvironmentFile=${ENV_FILE}
WorkingDirectory=/var/lib/n8n
ExecStart=${N8N_BIN} start
Restart=on-failure
RestartSec=5
TimeoutStartSec=180
UMask=0027
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=/var/lib/n8n ${INSTALL_DIR}
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
chmod 0644 "${SERVICE_FILE}"
systemctl daemon-reload
systemctl enable --now n8n

# Open the requested web port in UFW if UFW is installed and currently active.
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow "${N8N_PORT}/tcp" comment 'n8n web interface'
fi

sleep 8
if ! systemctl is-active --quiet n8n; then
  echo 'ERROR: n8n did not remain active. Recent logs:' >&2
  journalctl -u n8n -n 80 --no-pager >&2 || true
  exit 1
fi
if ! ss -lnt | awk -v p=":${N8N_PORT}" '$4 ~ p"$" {found=1} END{exit !found}'; then
  echo "ERROR: n8n service is active but port ${N8N_PORT} is not listening." >&2
  journalctl -u n8n -n 80 --no-pager >&2 || true
  exit 1
fi

N8N_VERSION="$(runuser -u n8n -- "${N8N_BIN}" --version 2>/dev/null || true)"
PG_VERSION="$(runuser -u postgres -- psql -Atqc 'SHOW server_version' 2>/dev/null || true)"

echo
echo '============================================================'
echo ' Native n8n installation completed'
echo '============================================================'
echo 'Docker/containers: NOT USED'
echo "n8n version: ${N8N_VERSION:-check with n8n --version}"
echo "Node.js: $(node --version)"
echo "PostgreSQL: ${PG_VERSION:-check with pg_lsclusters}"
echo "LAN URL: http://${SERVER_IP}:${N8N_PORT}/"
echo "Configuration: ${ENV_FILE} (root:n8n, mode 640)"
echo 'Service: systemctl status n8n'
echo 'Logs: sudo journalctl -u n8n -f'
echo 'Restart: sudo systemctl restart n8n'
echo 'Local health test: curl -I http://127.0.0.1:5678/'
echo
echo 'IMPORTANT SECURITY NOTE:'
echo 'Port 5678 is configured for LAN/direct HTTP access as requested.'
echo 'Do not expose it to the public internet over plain HTTP; use HTTPS via a reverse proxy.'
echo "Keep ${ENV_FILE} private and back it up securely. Never regenerate N8N_ENCRYPTION_KEY for an existing instance."
