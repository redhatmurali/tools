#!/usr/bin/env bash
# Zammad <-> WAHA integration installer (Ubuntu 24.04)
# Prompts only for WAHA and Zammad API tokens. Secrets are stored root-only.
# Defaults can be overridden before running:
#   WAHA_URL_DEFAULT=http://127.0.0.1:3001
#   WAHA_SESSION_DEFAULT=session_01m5fqwdqkcxjsfrytk2vq7vx5
#   ZAMMAD_URL_DEFAULT=http://192.168.29.101
set -Eeuo pipefail
umask 077

APP_DIR="/opt/zammad-waha"
ENV_FILE="/etc/zammad-waha.env"
SERVICE_FILE="/etc/systemd/system/zammad-waha.service"
APP_FILE="$APP_DIR/app.py"
DB_FILE="$APP_DIR/integration.sqlite3"
PORT="8099"
WAHA_URL="${WAHA_URL_DEFAULT:-http://127.0.0.1:3001}"
WAHA_SESSION="${WAHA_SESSION_DEFAULT:-session_01m5fqwdqkcxjsfrytk2vq7vx5}"
ZAMMAD_URL="${ZAMMAD_URL_DEFAULT:-http://192.168.29.101}"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash $0"
  exit 1
fi

command -v apt-get >/dev/null || { echo "This installer requires Ubuntu/Debian apt."; exit 1; }

echo "=== Zammad-WAHA integration installer ==="
echo "WAHA URL:      $WAHA_URL"
echo "WAHA session:  $WAHA_SESSION"
echo "Zammad URL:    $ZAMMAD_URL"
echo
read -r -s -p "Enter WAHA API key: " WAHA_API_KEY; echo
read -r -s -p "Enter Zammad API token: " ZAMMAD_API_TOKEN; echo
[[ -n "$WAHA_API_KEY" ]] || { echo "WAHA API key cannot be empty."; exit 1; }
[[ -n "$ZAMMAD_API_TOKEN" ]] || { echo "Zammad API token cannot be empty."; exit 1; }

WEBHOOK_SECRET="$(python3 -c 'import secrets; print(secrets.token_urlsafe(40))')"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y python3 python3-venv python3-pip curl ca-certificates

mkdir -p "$APP_DIR"
chmod 750 "$APP_DIR"

# Back up existing application and environment before replacing them.
STAMP="$(date +%Y%m%d-%H%M%S)"
if [[ -f "$APP_FILE" ]]; then
  cp -a "$APP_FILE" "$APP_FILE.bak-$STAMP"
  echo "Backed up existing app.py to $APP_FILE.bak-$STAMP"
fi
if [[ -f "$ENV_FILE" ]]; then
  cp -a "$ENV_FILE" "$ENV_FILE.bak-$STAMP"
  echo "Backed up existing environment to $ENV_FILE.bak-$STAMP"
fi
if [[ -f "$DB_FILE" ]]; then
  cp -a "$DB_FILE" "$DB_FILE.bak-$STAMP"
  echo "Backed up existing SQLite database to $DB_FILE.bak-$STAMP"
fi

python3 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install --upgrade pip
"$APP_DIR/venv/bin/pip" install Flask requests

cat > "$APP_FILE" <<'__ZAMMAD_WAHA_APP_PY__'
import re
import os
import hmac
import json
import hashlib
import sqlite3
import logging
from threading import Lock
from flask import Flask, request, jsonify, abort
import requests

app = Flask(__name__)
logging.basicConfig(level=logging.INFO)

WAHA_URL = os.environ["WAHA_URL"].rstrip("/")
WAHA_SESSION = os.environ["WAHA_SESSION"]
WAHA_API_KEY = os.environ["WAHA_API_KEY"]
ZAMMAD_URL = os.environ["ZAMMAD_URL"].rstrip("/")
ZAMMAD_API_TOKEN = os.environ["ZAMMAD_API_TOKEN"]
WEBHOOK_SECRET = os.environ["WEBHOOK_SECRET"]
PORT = int(os.getenv("INTEGRATION_PORT", "8099"))
DB_PATH = "/opt/zammad-waha/integration.sqlite3"
DB_LOCK = Lock()
GROUP_NAME = "Users"

http = requests.Session()
http.headers.update({
    "Authorization": f"Token token={ZAMMAD_API_TOKEN}",
    "Content-Type": "application/json",
})
waha_headers = {"X-Api-Key": WAHA_API_KEY}


def db():
    conn = sqlite3.connect(DB_PATH, timeout=20)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS chats (
            chat_id TEXT PRIMARY KEY,
            ticket_id INTEGER NOT NULL
        )
    """)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS processed (
            event_id TEXT PRIMARY KEY,
            kind TEXT NOT NULL
        )
    """)
    conn.commit()
    return conn


def already_processed(event_id, kind):
    if not event_id:
        return False
    with DB_LOCK:
        conn = db()
        try:
            row = conn.execute(
                "SELECT 1 FROM processed WHERE event_id=? AND kind=?",
                (event_id, kind),
            ).fetchone()
            if row:
                return True
            conn.execute(
                "INSERT INTO processed(event_id,kind) VALUES(?,?)",
                (event_id, kind),
            )
            conn.commit()
            return False
        finally:
            conn.close()


def zammad(method, path, **kwargs):
    response = http.request(
        method, f"{ZAMMAD_URL}{path}", timeout=20, **kwargs
    )
    if not response.ok:
        app.logger.error(
            "Zammad API error: %s %s: HTTP %s %s",
            method, path, response.status_code, response.text[:1000]
        )
        response.raise_for_status()
    return response.json() if response.content else {}


def message_text(payload):
    text = payload.get("body") or payload.get("text") or ""
    if not text and isinstance(payload.get("_data"), dict):
        text = payload["_data"].get("body") or ""
    return str(text).strip()



def sender_details(chat_id, payload=None):
    payload = payload or {}
    data = payload.get("_data") or {}
    key = data.get("key") or {}

    # Prefer the real phone JID if WhatsApp supplies an alternate ID.
    jid = chat_id
    for candidate in (
        key.get("remoteJidAlt"),
        data.get("remoteJidAlt"),
        payload.get("from"),
        payload.get("chatId"),
    ):
        if isinstance(candidate, str) and (
            candidate.endswith("@c.us")
            or candidate.endswith("@s.whatsapp.net")
        ):
            jid = candidate
            break

    raw_number = jid.split("@", 1)[0].split(":", 1)[0]
    number = re.sub(r"\D", "", raw_number)

    name = (
        payload.get("notifyName")
        or payload.get("pushName")
        or data.get("notifyName")
        or data.get("pushName")
        or data.get("pushname")
        or key.get("notifyName")
        or ""
    )
    name = str(name).strip()[:150]

    # Do not mistake WhatsApp LID identifiers for phone numbers.
    if "@lid" in jid or len(number) < 7:
        number = ""

    return name, number


def customer_for(chat_id, payload=None):
    display_name, number = sender_details(chat_id, payload)
    digest = hashlib.sha256(chat_id.encode()).hexdigest()[:24]
    email = f"wa-{digest}@whatsapp.invalid"
    firstname = display_name or (f"WhatsApp {number}" if number else "WhatsApp Contact")

    found = zammad("GET", "/api/v1/users/search", params={"query": email})
    users = found if isinstance(found, list) else []

    for user in users:
        if user.get("email") != email:
            continue

        updates = {}
        if number and user.get("phone") != number:
            updates["phone"] = number
        if display_name and user.get("firstname") != display_name:
            updates["firstname"] = display_name

        if updates and user.get("id"):
            result = zammad("PUT", f"/api/v1/users/{user['id']}", json=updates)
            app.logger.info(
                "Zammad customer %s phone update requested=%s response_type=%s",
                user["id"], bool(number), type(result).__name__
            )
        else:
            app.logger.info(
                "Zammad customer match id=%s phone_number_available=%s phone_already_matches=%s",
                user.get("id"), bool(number),
                bool(number and user.get("phone") == number)
            )
        return email

    user_data = {
        "firstname": firstname,
        "lastname": "Customer",
        "email": email,
        "login": f"wa-{digest}",
        "password": hashlib.sha256(os.urandom(32)).hexdigest() + "Aa1!",
        "roles": ["Customer"],
    }
    if number:
        user_data["phone"] = number

    result = zammad("POST", "/api/v1/users", json=user_data)
    app.logger.info(
        "Zammad customer creation requested phone_number_available=%s response_type=%s",
        bool(number), type(result).__name__
    )
    return email

def ticket_for(chat_id):
    conn = db()
    try:
        row = conn.execute(
            "SELECT ticket_id FROM chats WHERE chat_id=?",
            (chat_id,),
        ).fetchone()
        return row[0] if row else None
    finally:
        conn.close()


def save_ticket(chat_id, ticket_id):
    conn = db()
    try:
        conn.execute(
            "INSERT OR REPLACE INTO chats(chat_id,ticket_id) VALUES(?,?)",
            (chat_id, int(ticket_id)),
        )
        conn.commit()
    finally:
        conn.close()


def create_ticket(chat_id, body, payload=None):
    display_name, number = sender_details(chat_id, payload)
    email = customer_for(chat_id, payload)
    label = display_name or (f'+{number}' if number else chat_id.split('@')[0])
    ticket = zammad(
        "POST", "/api/v1/tickets",
        json={
            "title": f"WhatsApp — {label}",
            "group": GROUP_NAME,
            "customer": email,
            "article": {
                "subject": "Incoming WhatsApp message",
                "body": body,
                "type": "note",
                "internal": False,
            },
        },
    )
    save_ticket(chat_id, ticket["id"])
    app.logger.info("Created Zammad ticket %s", ticket["id"])
    return ticket


def add_ticket_article(ticket_id, body):
    return zammad(
        "POST", "/api/v1/ticket_articles",
        json={
            "ticket_id": int(ticket_id),
            "subject": "Incoming WhatsApp message",
            "body": body,
            "type": "note",
            "internal": False,
        },
    )


@app.get("/health")
def health():
    return jsonify({"status": "ok"})


@app.post("/webhooks/waha")
def waha_webhook():
    supplied = request.headers.get("X-Webhook-Secret", "")
    if not hmac.compare_digest(supplied, WEBHOOK_SECRET):
        abort(401)

    event = request.get_json(silent=True) or {}
    if event.get("event") not in ("message", "message.any"):
        return jsonify({"ignored": "event"}), 200

    payload = event.get("payload") or {}
    if isinstance(payload, dict):
        data = payload.get("_data") or {}
        key = data.get("key") or {}
        app.logger.info(
            "WAHA sender fields: from=%r chatId=%r notifyName=%r "
            "pushName=%r remoteJidAlt=%r participantAlt=%r",
            payload.get("from"),
            payload.get("chatId"),
            payload.get("notifyName"),
            payload.get("pushName"),
            key.get("remoteJidAlt"),
            key.get("participantAlt"),
        )
    if not isinstance(payload, dict):
        return jsonify({"ignored": "payload"}), 200

    if payload.get("fromMe") is True:
        return jsonify({"ignored": "outgoing message"}), 200

    chat_id = payload.get("from") or payload.get("chatId") or ""
    if not chat_id or "@g.us" in chat_id or "@broadcast" in chat_id:
        return jsonify({"ignored": "not a one-to-one chat"}), 200

    body = message_text(payload)
    if not body:
        return jsonify({"ignored": "empty or media-only message"}), 200

    event_id = payload.get("id") or payload.get("_data", {}).get("id")
    if event_id and already_processed(str(event_id), "incoming"):
        return jsonify({"duplicate": True}), 200

    ticket_id = ticket_for(chat_id)
    if ticket_id:
        # Refresh the customer phone and ticket title using the real number.
        customer_for(chat_id, payload)
        _, sender_number = sender_details(chat_id, payload)
        if sender_number:
            zammad("PUT", f"/api/v1/tickets/{ticket_id}", json={
                "title": f"WhatsApp — +{sender_number}"
            })
        add_ticket_article(ticket_id, body)
        app.logger.info("Added message to ticket %s", ticket_id)
    else:
        # create_ticket() already calls customer_for(); do not call twice.
        create_ticket(chat_id, body, payload)

    return jsonify({"received": True}), 200


@app.post("/webhooks/zammad")
def zammad_webhook():
    supplied = request.headers.get("X-Webhook-Secret", "")
    if not hmac.compare_digest(supplied, WEBHOOK_SECRET):
        abort(401)

    data = request.get_json(silent=True) or {}
    article = data.get("article") or {}
    ticket = data.get("ticket") or {}

    # Only send public replies authored by an agent.
    if article.get("internal") is not False:
        return jsonify({"ignored": "internal or unspecified article"}), 200

    sender = article.get("sender")
    if isinstance(sender, dict):
        sender = sender.get("name")
    if str(sender).lower() != "agent":
        return jsonify({"ignored": "not an agent reply"}), 200

    article_id = article.get("id")
    ticket_id = ticket.get("id") or article.get("ticket_id")
    body = str(article.get("body") or "").strip()

    if not article_id or not ticket_id or not body:
        return jsonify({"ignored": "missing article fields"}), 200

    if already_processed(str(article_id), "outgoing"):
        return jsonify({"duplicate": True}), 200

    conn = db()
    try:
        row = conn.execute(
            "SELECT chat_id FROM chats WHERE ticket_id=?",
            (int(ticket_id),),
        ).fetchone()
    finally:
        conn.close()

    if not row:
        return jsonify({"ignored": "no WhatsApp chat mapped to ticket"}), 200

    response = requests.post(
        f"{WAHA_URL}/api/sendText",
        headers={**waha_headers, "Content-Type": "application/json"},
        json={
            "session": WAHA_SESSION,
            "chatId": row[0],
            "text": body,
        },
        timeout=20,
    )
    if not response.ok:
        app.logger.error(
            "WAHA sendText failed: HTTP %s %s",
            response.status_code, response.text[:1000]
        )
        response.raise_for_status()

    app.logger.info("Sent public reply for ticket %s", ticket_id)
    return jsonify({"sent": True}), 200


if __name__ == "__main__":
    db().close()
    app.run(host="127.0.0.1", port=PORT)

__ZAMMAD_WAHA_APP_PY__
chmod 640 "$APP_FILE"
chown root:root "$APP_FILE"

cat > "$ENV_FILE" <<EOF
WAHA_URL=$WAHA_URL
WAHA_SESSION=$WAHA_SESSION
WAHA_API_KEY=$WAHA_API_KEY
ZAMMAD_URL=$ZAMMAD_URL
ZAMMAD_API_TOKEN=$ZAMMAD_API_TOKEN
WEBHOOK_SECRET=$WEBHOOK_SECRET
INTEGRATION_PORT=$PORT
EOF
chmod 600 "$ENV_FILE"
chown root:root "$ENV_FILE"
unset WAHA_API_KEY ZAMMAD_API_TOKEN WEBHOOK_SECRET

cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=Zammad-WAHA WhatsApp Integration
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/opt/zammad-waha
EnvironmentFile=/etc/zammad-waha.env
ExecStart=/opt/zammad-waha/venv/bin/python /opt/zammad-waha/app.py
Restart=always
RestartSec=3
PrivateTmp=true
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
chmod 644 "$SERVICE_FILE"

systemctl daemon-reload
systemctl enable zammad-waha
systemctl restart zammad-waha
sleep 2

if ! systemctl is-active --quiet zammad-waha; then
  echo "ERROR: service did not start. Recent logs:"
  journalctl -u zammad-waha -n 60 --no-pager
  exit 1
fi

if ! curl -fsS http://127.0.0.1:${PORT}/health >/dev/null; then
  echo "ERROR: health endpoint failed. Recent logs:"
  journalctl -u zammad-waha -n 60 --no-pager
  exit 1
fi

# Configure WAHA's session webhook while preserving existing session settings.
# The API accepts a full session configuration, so read the current config first.
echo "Configuring WAHA incoming-message webhook..."
if "$APP_DIR/venv/bin/python" - <<'PY'
import json, os, sys, requests
env = {}
with open("/etc/zammad-waha.env") as f:
    for line in f:
        line=line.strip()
        if line and not line.startswith("#") and "=" in line:
            k,v=line.split("=",1); env[k]=v
base=env["WAHA_URL"].rstrip("/")
headers={"X-Api-Key":env["WAHA_API_KEY"],"Accept":"application/json","Content-Type":"application/json"}
session=env["WAHA_SESSION"]
try:
    r=requests.get(f"{base}/api/sessions/{session}",headers=headers,timeout=15)
    r.raise_for_status()
    current=r.json()
    config=current.get("config") or {}
    webhooks=config.get("webhooks") or []
    url="http://127.0.0.1:8099/webhooks/waha"
    hook={
      "url":url,
      "events":["message","message.any"],
      "customHeaders":[{"name":"X-Webhook-Secret","value":env["WEBHOOK_SECRET"]}],
      "retries":{"policy":"constant","delaySeconds":2,"attempts":10}
    }
    # Replace this integration's prior webhook, preserve all unrelated webhooks.
    webhooks=[w for w in webhooks if w.get("url") != url]
    webhooks.append(hook)
    config["webhooks"]=webhooks
    payload={"name":session,"config":config}
    put=requests.put(f"{base}/api/sessions/{session}",headers=headers,json=payload,timeout=20)
    if not put.ok:
        print(f"WAHA webhook API update failed: HTTP {put.status_code} {put.text[:500]}",file=sys.stderr)
        sys.exit(2)
    print("WAHA incoming webhook configured.")
except Exception as e:
    print(f"Could not automatically configure WAHA webhook: {e}",file=sys.stderr)
    sys.exit(2)
PY
then
  WAHA_WEBHOOK_OK=1
else
  WAHA_WEBHOOK_OK=0
fi

echo
echo "=== Installation complete ==="
echo "Service:  systemctl status zammad-waha --no-pager"
echo "Logs:     journalctl -u zammad-waha -f"
echo "Health:   curl http://127.0.0.1:${PORT}/health"
echo
if [[ "$WAHA_WEBHOOK_OK" -ne 1 ]]; then
  echo "WARNING: WAHA webhook was not configured automatically."
  echo "Check WAHA URL/API key/session, then rerun this installer after correcting them."
fi
echo "IMPORTANT: Configure the Zammad outgoing webhook/trigger for public agent replies:"
echo "  Webhook URL: http://127.0.0.1:${PORT}/webhooks/zammad"
echo "  HTTP method: POST"
echo "  Header:      X-Webhook-Secret: (value stored in $ENV_FILE)"
echo "  Send article/ticket data including article.id, article.body, article.internal,"
echo "  article.sender, ticket.id. Trigger only for public agent replies."
echo "The existing SQLite chat-to-ticket mappings were preserved; do not delete $DB_FILE."
echo "Secrets are stored in $ENV_FILE with permissions 600."
