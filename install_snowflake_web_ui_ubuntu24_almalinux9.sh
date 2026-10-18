#!/usr/bin/env bash
# Self-hosted Snowflake SQL web UI for Ubuntu 24.04 / AlmaLinux 9+
# Installs Streamlit + Snowflake Connector in /opt/snowflake-web.
set -Eeuo pipefail
umask 027
LOG_FILE="/var/log/snowflake-web-install.log"
APP_DIR="/opt/snowflake-web"
VENV="${APP_DIR}/venv"
SERVICE="snowflake-web"
PORT="${PORT:-8601}"
LAN_CIDR="${LAN_CIDR:-192.168.29.0/24}"

[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo bash $0"; exit 1; }
mkdir -p /var/log
touch "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1
log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
trap 'rc=$?; log "ERROR at line ${LINENO} (exit ${rc}); see ${LOG_FILE}"; exit "$rc"' ERR

source /etc/os-release
case "${ID:-}" in
  ubuntu)
    [[ "${VERSION_ID:-}" == 24.04* ]] || { echo "Requires Ubuntu 24.04"; exit 1; }
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y python3 python3-venv python3-dev build-essential libssl-dev libffi-dev ca-certificates
    ;;
  almalinux|rhel|rocky)
    [[ "${VERSION_ID%%.*}" -ge 9 ]] || { echo "Requires AlmaLinux/RHEL/Rocky 9+"; exit 1; }
    dnf -y install python3 python3-devel gcc gcc-c++ make openssl-devel libffi-devel ca-certificates
    ;;
  *) echo "Unsupported OS: ${PRETTY_NAME:-$ID}"; exit 1 ;;
esac

mkdir -p "$APP_DIR"
if ! id snowflakeweb >/dev/null 2>&1; then
  useradd --system --home-dir "$APP_DIR" --shell /usr/sbin/nologin snowflakeweb
fi

if [[ ! -x "${VENV}/bin/python" ]]; then
  python3 -m venv "$VENV"
fi
"${VENV}/bin/python" -m pip install --upgrade pip
"${VENV}/bin/python" -m pip install --upgrade streamlit snowflake-connector-python pandas

# Generate an app access password once and retain it across reruns.
if [[ ! -s "${APP_DIR}/.env" ]]; then
  APP_PASSWORD="$(python3 -c 'import secrets; print(secrets.token_urlsafe(18))')"
  printf 'APP_PASSWORD=%s\n' "$APP_PASSWORD" > "${APP_DIR}/.env"
  chmod 600 "${APP_DIR}/.env"
fi

cat > "${APP_DIR}/app.py" <<'PYAPP'
import os
import hmac
import pandas as pd
import streamlit as st
import snowflake.connector
from snowflake.connector.errors import Error as SnowflakeError

def read_env(path="/opt/snowflake-web/.env"):
    values = {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    values[k.strip()] = v.strip()
    except OSError:
        pass
    return values

APP_PASSWORD = read_env().get("APP_PASSWORD", "")
st.set_page_config(page_title="Snowflake SQL Web", page_icon="❄️", layout="wide")
st.title("❄️ Snowflake SQL Web")
st.caption("Self-hosted browser SQL workspace. Queries execute in your Snowflake account and may consume warehouse credits.")

if "app_authenticated" not in st.session_state:
    st.session_state.app_authenticated = False

if not st.session_state.app_authenticated:
    st.subheader("Sign in to this web app")
    entered = st.text_input("Web app access password", type="password")
    if st.button("Sign in", type="primary"):
        if APP_PASSWORD and hmac.compare_digest(entered, APP_PASSWORD):
            st.session_state.app_authenticated = True
            st.rerun()
        else:
            st.error("Incorrect web app password.")
    st.stop()

with st.sidebar:
    st.header("Snowflake connection")
    account = st.text_input("Account identifier", placeholder="org-account or account locator")
    user = st.text_input("Snowflake username")
    auth_method = st.selectbox("Authentication", ["Password"])
    password = st.text_input("Snowflake password", type="password")
    role = st.text_input("Role (optional)")
    warehouse = st.text_input("Warehouse (optional)")
    database = st.text_input("Database (optional)")
    schema = st.text_input("Schema (optional)")
    connect_clicked = st.button("Connect", type="primary", use_container_width=True)
    if st.button("Disconnect / clear session", use_container_width=True):
        old = st.session_state.pop("sf_connection", None)
        if old:
            try: old.close()
            except Exception: pass
        for key in ["sf_connection", "sf_connected"]:
            st.session_state.pop(key, None)
        st.rerun()

if connect_clicked:
    if not all([account.strip(), user.strip(), password]):
        st.error("Enter your Snowflake account identifier, username, and password.")
    else:
        try:
            kwargs = {"account": account.strip(), "user": user.strip(), "password": password}
            if role.strip(): kwargs["role"] = role.strip()
            if warehouse.strip(): kwargs["warehouse"] = warehouse.strip()
            if database.strip(): kwargs["database"] = database.strip()
            if schema.strip(): kwargs["schema"] = schema.strip()
            conn = snowflake.connector.connect(**kwargs)
            st.session_state.sf_connection = conn
            st.session_state.sf_connected = True
            st.success("Connected to Snowflake.")
        except SnowflakeError as exc:
            st.error(f"Connection failed: {exc}")

conn = st.session_state.get("sf_connection")
if conn is not None:
    st.success("Snowflake connection is active for this browser session.")
    st.subheader("SQL worksheet")
    sql = st.text_area(
        "SQL statement",
        value="SELECT CURRENT_USER(), CURRENT_ROLE(), CURRENT_WAREHOUSE(), CURRENT_DATABASE(), CURRENT_SCHEMA();",
        height=180,
    )
    if st.button("Run SQL", type="primary"):
        if not sql.strip():
            st.warning("Enter a SQL statement.")
        else:
            try:
                cur = conn.cursor()
                try:
                    cur.execute(sql)
                    if cur.description:
                        rows = cur.fetchall()
                        cols = [c[0] for c in cur.description]
                        df = pd.DataFrame(rows, columns=cols)
                        st.caption(f"{len(df)} row(s) returned")
                        st.dataframe(df, use_container_width=True, hide_index=True)
                        st.download_button("Download results as CSV", df.to_csv(index=False).encode("utf-8"), "snowflake_results.csv", "text/csv")
                    else:
                        st.success(f"Statement completed. Rows affected: {cur.rowcount}")
                finally:
                    cur.close()
            except SnowflakeError as exc:
                st.error(f"SQL error: {exc}")
else:
    st.info("Enter your Snowflake connection details in the sidebar, then select Connect.")
    st.markdown("""
    **What this provides**
    - Browser-based SQL editor and results grid
    - CSV export for query results
    - Credentials entered in the browser session, not saved to a profile file

    **Security notes**
    - Keep this service on a trusted LAN or behind HTTPS/VPN.
    - Use a least-privilege Snowflake role and a dedicated user.
    - This first version uses password authentication; accounts requiring SSO, OAuth, or key-pair authentication need a different auth flow.
    - Do not run untrusted SQL. DDL/DML statements can change data and queries can incur warehouse costs.
    """)
PYAPP

chown -R snowflakeweb:snowflakeweb "$APP_DIR"
chmod 750 "$APP_DIR"
chmod 600 "${APP_DIR}/.env"

cat > "/etc/systemd/system/${SERVICE}.service" <<EOF
[Unit]
Description=Self-hosted Snowflake SQL Web UI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=snowflakeweb
Group=snowflakeweb
WorkingDirectory=${APP_DIR}
EnvironmentFile=${APP_DIR}/.env
Environment=HOME=${APP_DIR}
ExecStart=${VENV}/bin/streamlit run ${APP_DIR}/app.py --server.address 0.0.0.0 --server.port ${PORT} --server.headless true --browser.gatherUsageStats false
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=${APP_DIR}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "${SERVICE}"
sleep 2
systemctl --no-pager --full status "${SERVICE}" || true

# Open only to the configured LAN subnet when UFW/firewalld is available.
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  ufw allow from "$LAN_CIDR" to any port "$PORT" proto tcp comment 'Snowflake SQL Web LAN'
elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=${LAN_CIDR} port port=${PORT} protocol=tcp accept"
  firewall-cmd --reload
else
  log "No active UFW/firewalld detected. If needed, allow TCP ${PORT} from ${LAN_CIDR} manually."
fi

APP_PASSWORD="$(sed -n 's/^APP_PASSWORD=//p' "${APP_DIR}/.env")"
SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
log "SUCCESS: Snowflake SQL Web UI installed."
log "Open from a device on the allowed LAN: http://${SERVER_IP:-SERVER-IP}:${PORT}"
log "Web app access password: ${APP_PASSWORD}"
log "Service: systemctl status ${SERVICE}"
log "Logs: journalctl -u ${SERVICE} -n 100 --no-pager"
log "Install log: ${LOG_FILE}"
