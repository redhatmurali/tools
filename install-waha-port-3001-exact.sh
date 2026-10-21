#!/usr/bin/env bash
#===============================================================================
# WAHA (WhatsApp HTTP API) - Installer for a box that ALREADY runs another Node
# Target : the 'crm' VPS (Ubuntu, system Node 20 in use by n8n + Redis)
# Method : Build WAHA Core from source, but with Node 24 ISOLATED under the
#          'waha' user via nvm. System Node 20 is NEVER touched -> n8n is safe.
# Result : WAHA on http://127.0.0.1:3001  (local to n8n; no cross-network needed)
#===============================================================================
set -euo pipefail

#--- Tunables ------------------------------------------------------------------
WAHA_USER="waha"
WAHA_DIR="/opt/waha"
WAHA_PORT="3001"                   # n8n=5678, Redis=6379 -> no conflict
WAHA_BRANCH="core"                    # tracks the latest Core branch; pin a release tag for production
WAHA_ENGINE="NOWEB"                # NOWEB (light, no browser) | WEBJS (needs Chromium libs)
NODE_MAJOR="24"                    # WAHA's Node, installed ONLY for the waha user
TZ_REGION="Asia/Kolkata"
NVM_VERSION="v0.40.1"
#-------------------------------------------------------------------------------

log() { echo -e "\e[1;32m[WAHA]\e[0m $*"; }
err() { echo -e "\e[1;31m[ERR ]\e[0m $*" >&2; }

[[ $EUID -eq 0 ]] || { err "Run as root: sudo bash $0"; exit 1; }
export DEBIAN_FRONTEND=noninteractive

#--- 0. Safety report -----------------------------------------------------------
SYS_NODE="$(command -v node >/dev/null 2>&1 && node -v || echo none)"
log "System Node (left untouched): ${SYS_NODE}"
log "WAHA will use an isolated Node ${NODE_MAJOR} under user '${WAHA_USER}'."
if [[ "${WAHA_PORT}" == "5678" ]]; then err "Port 5678 is n8n. Change WAHA_PORT."; exit 1; fi

#--- 1. Base packages (no nodejs here!) -----------------------------------------
log "Installing prerequisites..."
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg git build-essential \
  python3 openssl ffmpeg jq unzip wget >/dev/null

if [[ "${WAHA_ENGINE}" == "WEBJS" ]]; then
  log "Installing Chromium runtime libraries for WEBJS..."
  apt-get install -y -qq \
    libnss3 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 libxkbcommon0 \
    libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1 libasound2 \
    libpango-1.0-0 libcairo2 libx11-xcb1 libxcb-dri3-0 fonts-liberation \
    libappindicator3-1 xdg-utils >/dev/null
fi

#--- 2. Service user (needs bash so nvm works) ----------------------------------
id -u "${WAHA_USER}" >/dev/null 2>&1 || useradd -r -m -d "${WAHA_DIR}" -s /bin/bash "${WAHA_USER}"
mkdir -p "${WAHA_DIR}"
chown "${WAHA_USER}:${WAHA_USER}" "${WAHA_DIR}"

#--- 3. Isolated Node 24 via nvm (under waha user only) --------------------------
log "Installing isolated Node ${NODE_MAJOR} for '${WAHA_USER}' via nvm (system Node stays ${SYS_NODE})..."
sudo -u "${WAHA_USER}" -H bash -c '
  set -e
  export NVM_DIR="$HOME/.nvm"
  if [ ! -s "$NVM_DIR/nvm.sh" ]; then
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/'"${NVM_VERSION}"'/install.sh | bash >/dev/null 2>&1
  fi
  . "$NVM_DIR/nvm.sh"
  nvm install '"${NODE_MAJOR}"' >/dev/null 2>&1
  nvm alias default '"${NODE_MAJOR}"' >/dev/null 2>&1
  corepack enable >/dev/null 2>&1 || npm install -g yarn >/dev/null 2>&1
'
NODE_BIN="$(sudo -u "${WAHA_USER}" -H bash -c '. "$HOME/.nvm/nvm.sh"; command -v node')"
log "Isolated node: ${NODE_BIN}  ($(sudo -u "${WAHA_USER}" -H bash -c '. "$HOME/.nvm/nvm.sh"; node -v'))"

# Helper: run a command as waha with its nvm Node on PATH
waha_run() { sudo -u "${WAHA_USER}" -H bash -c '. "$HOME/.nvm/nvm.sh"; cd "'"${WAHA_DIR}"'"; '"$*"; }

#--- 4. Clone source ------------------------------------------------------------
if [[ -d "${WAHA_DIR}/.git" ]]; then
  log "Existing checkout - pulling latest ${WAHA_BRANCH}..."
  waha_run "git pull --ff-only"
else
  log "Cloning WAHA (${WAHA_BRANCH})..."
  find "${WAHA_DIR}" -maxdepth 1 -mindepth 1 ! -name '.nvm' -exec rm -rf {} +
  sudo -u "${WAHA_USER}" -H git clone --depth 1 --branch "${WAHA_BRANCH}" \
    https://github.com/devlikeapro/waha "${WAHA_DIR}/repo"
  shopt -s dotglob
  mv "${WAHA_DIR}/repo/"* "${WAHA_DIR}/"
  shopt -u dotglob
  rmdir "${WAHA_DIR}/repo"
fi
mkdir -p "${WAHA_DIR}/.sessions" "${WAHA_DIR}/.media"
chown -R "${WAHA_USER}:${WAHA_USER}" "${WAHA_DIR}"

#--- 5. Install deps + build (with isolated Node) -------------------------------
log "Installing dependencies (pulls whatsapp-web.js/Baileys forks - a few minutes)..."
waha_run "COREPACK_ENABLE_DOWNLOAD_PROMPT=0 YARN_ENABLE_IMMUTABLE_INSTALLS=false YARN_HTTP_TIMEOUT=600000 YARN_HTTP_RETRY=5 yarn install --network-timeout 600000"

log "Building (nest build)..."
waha_run "yarn build"
[[ -f "${WAHA_DIR}/dist/main.js" ]] || { err "Build failed - dist/main.js missing."; exit 1; }

#--- 5b. Pre-built Web Dashboard ------------------------------------------------
# Download the exact dashboard revision pinned by this WAHA source checkout.
# Discover the archive root instead of assuming it is named dashboard-${DASH_SHA}.
log "Fetching Web Dashboard (pinned in waha.config.json)..."
DASH_REPO="$(jq -r '.waha.dashboard.repo // empty' "${WAHA_DIR}/waha.config.json")"
DASH_SHA="$(jq -r '.waha.dashboard.ref // empty' "${WAHA_DIR}/waha.config.json")"
if [[ -z "${DASH_REPO}" || -z "${DASH_SHA}" ]]; then
  err "Dashboard repository/ref missing in waha.config.json; refusing to leave a broken dashboard."
  exit 1
fi

log "Dashboard: ${DASH_REPO}@${DASH_SHA:0:12}"
TMPZ="$(mktemp -d)"
trap 'rm -rf "${TMPZ}"' EXIT
curl -fL --retry 3 --retry-delay 2 \
  "https://github.com/${DASH_REPO}/archive/${DASH_SHA}.zip" \
  -o "${TMPZ}/dash.zip"
unzip -q "${TMPZ}/dash.zip" -d "${TMPZ}/x"
DASH_INDEX="$(find "${TMPZ}/x" -type f -name index.html -print -quit)"
if [[ -z "${DASH_INDEX}" ]]; then
  err "Downloaded dashboard archive contains no index.html."
  find "${TMPZ}/x" -maxdepth 4 -type f | head -n 30 >&2 || true
  exit 1
fi
DASH_SOURCE="$(dirname "${DASH_INDEX}")"
# Stage first, then replace the old dashboard only after validating the download.
rm -rf "${TMPZ}/dashboard-stage"
mkdir -p "${TMPZ}/dashboard-stage"
cp -a "${DASH_SOURCE}/." "${TMPZ}/dashboard-stage/"
test -f "${TMPZ}/dashboard-stage/index.html"
rm -rf "${WAHA_DIR}/dist/dashboard"
mkdir -p "${WAHA_DIR}/dist/dashboard"
cp -a "${TMPZ}/dashboard-stage/." "${WAHA_DIR}/dist/dashboard/"
chown -R "${WAHA_USER}:${WAHA_USER}" "${WAHA_DIR}/dist/dashboard"
test -f "${WAHA_DIR}/dist/dashboard/index.html"
log "Dashboard installed: ${WAHA_DIR}/dist/dashboard/index.html"
rm -rf "${TMPZ}"
trap - EXIT

#--- 6. Env + systemd -----------------------------------------------------------
# Keep credentials stable across installer reruns and service restarts.
# Generate .env only once; do not overwrite an existing file with new secrets.
ENV_FILE="${WAHA_DIR}/.env"
if [[ ! -s "${ENV_FILE}" ]]; then
  log "Creating initial persistent environment file and credentials..."
  API_KEY="$(openssl rand -hex 32)"
  SWAGGER_USER="api"; SWAGGER_PASS="$(openssl rand -base64 24 | tr -d '=+/')"
  DASH_USER="admin"; DASH_PASS="$(openssl rand -base64 24 | tr -d '=+/')"

  cat > "${ENV_FILE}" <<EOF
TZ=${TZ_REGION}
PORT=${WAHA_PORT}
WHATSAPP_DEFAULT_ENGINE=${WAHA_ENGINE}
WHATSAPP_API_KEY=${API_KEY}
WHATSAPP_SWAGGER_USERNAME=${SWAGGER_USER}
WHATSAPP_SWAGGER_PASSWORD=${SWAGGER_PASS}
WAHA_DASHBOARD_ENABLED=true
WAHA_DASHBOARD_USERNAME=${DASH_USER}
WAHA_DASHBOARD_PASSWORD=${DASH_PASS}
WHATSAPP_NOWEB_STORE_ENABLED=true
WHATSAPP_NOWEB_STORE_FULLSYNC=true
WHATSAPP_RESTART_ALL_SESSIONS=true
WAHA_PRINT_QR=false
WAHA_LOG_FORMAT=JSON
WAHA_LOG_LEVEL=info
WHATSAPP_SESSIONS_FOLDER=${WAHA_DIR}/.sessions
WHATSAPP_FILES_FOLDER=${WAHA_DIR}/.media
WHATSAPP_FILES_LIFETIME=180
EOF
  chmod 600 "${ENV_FILE}"
else
  log "Existing ${ENV_FILE} found; preserving API key and passwords."
  # Add missing non-secret settings without replacing existing credentials.
  set_env_default() {
    local key="$1" value="$2"
    if ! grep -qE "^${key}=" "${ENV_FILE}"; then
      printf '%s=%s\n' "$key" "$value" >> "${ENV_FILE}"
    fi
  }
  set_env_default TZ "${TZ_REGION}"
  set_env_default PORT "${WAHA_PORT}"
  set_env_default WHATSAPP_DEFAULT_ENGINE "${WAHA_ENGINE}"
  set_env_default WHATSAPP_API_KEY "$(openssl rand -hex 32)"
  set_env_default WHATSAPP_SWAGGER_USERNAME "api"
  set_env_default WHATSAPP_SWAGGER_PASSWORD "$(openssl rand -base64 24 | tr -d '=+/')"
  set_env_default WAHA_DASHBOARD_ENABLED "true"
  set_env_default WAHA_DASHBOARD_USERNAME "admin"
  set_env_default WAHA_DASHBOARD_PASSWORD "$(openssl rand -base64 24 | tr -d '=+/')"
  set_env_default WHATSAPP_NOWEB_STORE_ENABLED "true"
  set_env_default WHATSAPP_NOWEB_STORE_FULLSYNC "true"
  set_env_default WHATSAPP_RESTART_ALL_SESSIONS "true"
  set_env_default WAHA_PRINT_QR "false"
  set_env_default WAHA_LOG_FORMAT "JSON"
  set_env_default WAHA_LOG_LEVEL "info"
  set_env_default WHATSAPP_SESSIONS_FOLDER "${WAHA_DIR}/.sessions"
  set_env_default WHATSAPP_FILES_FOLDER "${WAHA_DIR}/.media"
  set_env_default WHATSAPP_FILES_LIFETIME "180"
  chmod 600 "${ENV_FILE}"
fi
chown "${WAHA_USER}:${WAHA_USER}" "${ENV_FILE}"

# Read the effective credentials from the persistent .env, not newly generated values.
env_value() { sed -n "s/^$1=//p" "${ENV_FILE}" | tail -n 1; }
API_KEY="$(env_value WHATSAPP_API_KEY)"
SWAGGER_USER="$(env_value WHATSAPP_SWAGGER_USERNAME)"
SWAGGER_PASS="$(env_value WHATSAPP_SWAGGER_PASSWORD)"
DASH_USER="$(env_value WAHA_DASHBOARD_USERNAME)"
DASH_PASS="$(env_value WAHA_DASHBOARD_PASSWORD)"
[[ -n "${API_KEY}" && -n "${SWAGGER_PASS}" && -n "${DASH_PASS}" ]] || {
  err "One or more credentials are empty in ${ENV_FILE}. Fix the file before continuing."
  exit 1
}

log "Creating systemd service (ExecStart pinned to isolated Node)..."
cat > /etc/systemd/system/waha.service <<EOF
[Unit]
Description=WAHA - WhatsApp HTTP API (isolated Node)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${WAHA_USER}
Group=${WAHA_USER}
WorkingDirectory=${WAHA_DIR}
EnvironmentFile=${WAHA_DIR}/.env
ExecStart=${NODE_BIN} ${WAHA_DIR}/dist/main.js
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=${WAHA_DIR}
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now waha

#--- 7. Health ------------------------------------------------------------------
log "Waiting for WAHA to respond on :${WAHA_PORT}..."
for i in {1..40}; do
  curl -fs "http://127.0.0.1:${WAHA_PORT}/ping" >/dev/null 2>&1 && break
  sleep 3
  [[ $i -eq 40 ]] && { err "No response in 120s. Check: journalctl -u waha -f"; exit 1; }
done

#--- 8. Summary -----------------------------------------------------------------
CREDS_FILE="${WAHA_DIR}/credentials.txt"
cat > "${CREDS_FILE}" <<EOF
========== WAHA INSTALLED ON crm (isolated Node) ==========
System Node : ${SYS_NODE}  (unchanged - n8n safe)
WAHA Node   : $(sudo -u "${WAHA_USER}" -H bash -c '. "$HOME/.nvm/nvm.sh"; node -v')  (isolated via nvm)

API base  : http://127.0.0.1:${WAHA_PORT}
Dashboard : http://127.0.0.1:${WAHA_PORT}/dashboard   (tunnel or proxy to reach remotely)
  user    : ${DASH_USER}
  pass    : ${DASH_PASS}
Swagger   : http://127.0.0.1:${WAHA_PORT}/
  user    : ${SWAGGER_USER}
  pass    : ${SWAGGER_PASS}
API Key (header X-Api-Key): ${API_KEY}
Engine    : ${WAHA_ENGINE}  (NOWEB store enabled)

>>> n8n integration (same box, local call - no networking needed):
  URL    : http://127.0.0.1:${WAHA_PORT}/api/sendText
  Header : X-Api-Key: ${API_KEY}
  Body   : {"session":"default","chatId":"91XXXXXXXXXX@c.us","text":"..."}

Pair your phone (dashboard is easiest):
  ssh -L 3001:127.0.0.1:${WAHA_PORT} ubuntu@<crm-public-ip>   # from your laptop
  then open http://127.0.0.1:3001/dashboard locally, log in, create session
  'default', scan QR with WhatsApp > Linked Devices, wait for WORKING.

Manage:
  systemctl status waha
  journalctl -u waha -f
  systemctl restart waha

Upgrade:
  cd ${WAHA_DIR} && sudo -u ${WAHA_USER} -H bash -c '. \$HOME/.nvm/nvm.sh; git pull && yarn install && yarn build'
  systemctl restart waha
  # then re-run this script once to refresh the pinned dashboard
===========================================================
EOF
chmod 600 "${CREDS_FILE}"

log "Done. System Node ${SYS_NODE} untouched - your n8n is safe."
echo
cat "${CREDS_FILE}"
