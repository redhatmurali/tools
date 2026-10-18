#!/usr/bin/env bash
# One-shot installer: dbt Core + PostgreSQL adapter + Analytics Models Studio web UI
# Supported: Ubuntu 24.04 LTS and AlmaLinux 9.x
# Native installation (no Docker). Web UI defaults to 0.0.0.0:8585.
#
# Optional environment overrides:
#   DBT_HOME=/opt/dbt
#   DBT_PROJECT_DIR=/opt/dbt/project
#   DBT_WEB_PORT=8585
#   DBT_ALLOWED_CIDR=192.168.29.0/24  (firewall source range; set to your trusted LAN)
#
# Run: sudo bash install_dbt_ubuntu24_almalinux9.sh

set -Eeuo pipefail

DBT_HOME="${DBT_HOME:-/opt/dbt}"
VENV_DIR="${DBT_HOME}/venv"
PROJECT_DIR="${DBT_PROJECT_DIR:-${DBT_HOME}/project}"
SERVICE_NAME="dbt-web-ui"
PORT="${DBT_WEB_PORT:-8585}"
ALLOWED_CIDR="${DBT_ALLOWED_CIDR:-192.168.29.0/24}"
SERVICE_USER="dbtweb"
SERVICE_HOME="/var/lib/dbtweb"
PYTHON_BIN=""
PKG_MANAGER=""

log()  { printf '\n[INFO] %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
die()  { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || die "Run as root: sudo bash $0"
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1024 && PORT <= 65535 )) || die "DBT_WEB_PORT must be between 1024 and 65535."
[[ -r /etc/os-release ]] || die "Cannot identify operating system (/etc/os-release missing)."
# shellcheck disable=SC1091
source /etc/os-release

case "${ID:-}" in
  ubuntu)
    [[ "${VERSION_ID:-}" == "24.04" ]] || warn "Designed for Ubuntu 24.04; detected ${PRETTY_NAME:-Ubuntu}."
    PKG_MANAGER="apt"
    ;;
  almalinux)
    [[ "${VERSION_ID%%.*}" == "9" ]] || warn "Designed for AlmaLinux 9.x; detected ${PRETTY_NAME:-AlmaLinux}."
    PKG_MANAGER="dnf"
    ;;
  *) die "Unsupported OS: ${PRETTY_NAME:-unknown}. Supported: Ubuntu 24.04 and AlmaLinux 9.x." ;;
esac

install_os_packages() {
  if [[ "$PKG_MANAGER" == "apt" ]]; then
    log "Installing operating-system dependencies..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends \
      ca-certificates curl git python3 python3-venv python3-pip python3-dev \
      build-essential libpq-dev
  else
    log "Installing operating-system dependencies..."
    dnf -y install \
      ca-certificates curl git python3.11 python3.11-pip python3.11-devel \
      gcc gcc-c++ make libpq-devel
  fi
}

select_python() {
  local candidate version major minor
  local candidates=()
  if [[ "$PKG_MANAGER" == "apt" ]]; then
    candidates=(python3)
  else
    candidates=(python3.11 python3.12 python3.10 python3)
  fi

  for candidate in "${candidates[@]}"; do
    if command -v "$candidate" >/dev/null 2>&1; then
      version="$("$candidate" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || true)"
      major="${version%%.*}"
      minor="${version#*.}"
      if [[ "$major" == "3" && "$minor" =~ ^[0-9]+$ ]] && (( minor >= 10 )); then
        PYTHON_BIN="$(command -v "$candidate")"
        log "Using Python ${version}: ${PYTHON_BIN}"
        return
      fi
    fi
  done
  die "Python 3.10 or newer was not found."
}

install_python_packages() {
  log "Creating/updating Python virtual environment at ${VENV_DIR}..."
  install -d -m 0755 "$DBT_HOME"
  if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
    "$PYTHON_BIN" -m venv "$VENV_DIR"
  fi

  log "Upgrading pip tooling..."
  "${VENV_DIR}/bin/python" -m pip install --upgrade pip setuptools wheel

  log "Installing dbt Core and PostgreSQL adapter..."
  "${VENV_DIR}/bin/python" -m pip install --upgrade 'dbt-core<2' dbt-postgres

  log "Installing Analytics Models Studio and required web dependencies..."
  # These explicit dependencies address startup errors observed with AMS:
  # SQLAlchemy asyncio requires greenlet; FastAPI form routes require python-multipart.
  "${VENV_DIR}/bin/python" -m pip install --upgrade \
    analytics-models-studio \
    'sqlalchemy[asyncio]' \
    greenlet \
    python-multipart

  ln -sfn "${VENV_DIR}/bin/dbt" /usr/local/bin/dbt
  ln -sfn "${VENV_DIR}/bin/ams" /usr/local/bin/ams

  log "Checking installed command versions..."
  "${VENV_DIR}/bin/dbt" --version
  "${VENV_DIR}/bin/ams" serve --help >/dev/null
  "${VENV_DIR}/bin/python" -c 'import greenlet, multipart, sqlalchemy, fastapi; print("AMS Python dependencies OK")'
}

create_starter_project() {
  log "Preparing dbt project at ${PROJECT_DIR}..."
  install -d -m 0755 "${PROJECT_DIR}/models" "${PROJECT_DIR}/tests" \
    "${PROJECT_DIR}/seeds" "${PROJECT_DIR}/macros" "${PROJECT_DIR}/snapshots"

  if [[ ! -f "${PROJECT_DIR}/dbt_project.yml" ]]; then
    cat > "${PROJECT_DIR}/dbt_project.yml" <<'YAML'
name: dbt_learning
version: '1.0.0'
config-version: 2
profile: dbt_learning
model-paths: ["models"]
test-paths: ["tests"]
seed-paths: ["seeds"]
macro-paths: ["macros"]
snapshot-paths: ["snapshots"]
target-path: "target"
clean-targets: ["target", "dbt_packages"]
models:
  dbt_learning:
    +materialized: view
YAML
  fi

  if [[ ! -f "${PROJECT_DIR}/models/example.sql" ]]; then
    cat > "${PROJECT_DIR}/models/example.sql" <<'SQL'
select 1 as example_id, 'dbt is installed' as message
SQL
  fi

  if command -v git >/dev/null 2>&1 && [[ ! -d "${PROJECT_DIR}/.git" ]]; then
    git -C "$PROJECT_DIR" init -q || true
    git -C "$PROJECT_DIR" config user.name "dbt local" || true
    git -C "$PROJECT_DIR" config user.email "dbt-local@localhost" || true
    git -C "$PROJECT_DIR" add dbt_project.yml models/example.sql || true
    git -C "$PROJECT_DIR" commit -qm "Initial dbt project" || true
  fi
}

install_service() {
  log "Creating service account..."
  if ! id "$SERVICE_USER" >/dev/null 2>&1; then
    if [[ "$PKG_MANAGER" == "apt" ]]; then
      useradd --system --home-dir "$SERVICE_HOME" --create-home --shell /usr/sbin/nologin "$SERVICE_USER"
    else
      useradd --system --home-dir "$SERVICE_HOME" --create-home --shell /sbin/nologin "$SERVICE_USER"
    fi
  fi
  install -d -o "$SERVICE_USER" -g "$SERVICE_USER" "$SERVICE_HOME"
  chown -R "$SERVICE_USER":"$SERVICE_USER" "$PROJECT_DIR" "$SERVICE_HOME"
  chmod -R a+rX "$VENV_DIR"

  log "Initializing AMS project metadata (safe to skip if already initialized)..."
  runuser -u "$SERVICE_USER" -- env HOME="$SERVICE_HOME" \
    "${VENV_DIR}/bin/ams" init --project-dir "$PROJECT_DIR" \
    || warn "AMS init returned non-zero; continuing. Check the web UI and logs if setup is incomplete."

  log "Writing systemd service with explicit host, port and project directory..."
  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<UNIT
[Unit]
Description=Analytics Models Studio web UI for dbt Core
After=network.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${PROJECT_DIR}
Environment=HOME=${SERVICE_HOME}
Environment=PYTHONUNBUFFERED=1
ExecStart=${VENV_DIR}/bin/ams serve --host 0.0.0.0 --port ${PORT} --project-dir ${PROJECT_DIR}
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=${SERVICE_HOME} ${PROJECT_DIR}

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME.service"
  systemctl restart "$SERVICE_NAME.service"

  log "Waiting for web UI to listen on port ${PORT}..."
  local attempt
  for attempt in $(seq 1 20); do
    if ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:|\\])${PORT}$"; then
      log "Port ${PORT} is listening."
      return 0
    fi
    if ! systemctl is-active --quiet "$SERVICE_NAME.service"; then
      break
    fi
    sleep 1
  done

  warn "Web UI did not start listening on port ${PORT}."
  systemctl status "$SERVICE_NAME.service" --no-pager -l || true
  journalctl -u "$SERVICE_NAME.service" -n 80 --no-pager || true
  die "Installation finished but the web service failed its port check. Fix the logged application error before using the UI."
}

configure_firewall() {
  log "Configuring firewall access for trusted LAN range ${ALLOWED_CIDR}..."
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw allow from "$ALLOWED_CIDR" to any port "$PORT" proto tcp
    log "UFW rule added for ${ALLOWED_CIDR} on TCP ${PORT}."
  elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=${ALLOWED_CIDR} port port=${PORT} protocol=tcp accept"
    firewall-cmd --reload
    log "Firewalld rule added for ${ALLOWED_CIDR} on TCP ${PORT}."
  else
    log "No active UFW/firewalld detected; no host firewall change needed."
  fi
}

verify_installation() {
  log "Final local HTTP check..."
  if command -v curl >/dev/null 2>&1 && curl --silent --show-error --max-time 5 "http://127.0.0.1:${PORT}/" >/dev/null; then
    log "HTTP response received from local web UI."
  else
    warn "Port is listening, but the root page did not return a successful curl result. Check UI routes/logs."
    journalctl -u "$SERVICE_NAME.service" -n 40 --no-pager || true
  fi
}

main() {
  install_os_packages
  select_python
  install_python_packages
  create_starter_project
  install_service
  configure_firewall
  verify_installation

  log "Installation completed."
  printf '\nWeb UI:       http://SERVER-IP:%s/\n' "$PORT"
  printf 'Project:      %s\n' "$PROJECT_DIR"
  printf 'dbt version:  dbt --version\n'
  printf 'Service:      systemctl status %s --no-pager -l\n' "$SERVICE_NAME"
  printf 'Logs:         journalctl -u %s -f\n' "$SERVICE_NAME"
  printf 'Local test:   curl -v http://127.0.0.1:%s/\n' "$PORT"
  printf '\nFirewall source range configured: %s\n' "$ALLOWED_CIDR"
  printf 'Change DBT_ALLOWED_CIDR before running if your trusted LAN uses a different subnet.\n'
  printf 'Next: configure the dbt profile for your PostgreSQL target in the service user home (%s/.dbt/profiles.yml).\n' "$SERVICE_HOME"
  printf 'Docs: https://docs.getdbt.com/ | https://github.com/data-diving/dbt-ui\n'
}

main "$@"
