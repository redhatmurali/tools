#!/usr/bin/env bash
# =============================================================================
# Zammad one-click installer — Ubuntu 24.04 LTS (package method, no Docker)
# Source: https://docs.zammad.org/en/latest/install/package.html
#         + Elasticsearch 9 install / connect pages + webserver page
#
# Installs: prerequisites, locale, Elasticsearch 9, Zammad (apt repo),
#           connects Zammad<->Elasticsearch, builds search index,
#           configures nginx (+ optional Let's Encrypt), opens UFW if active.
#
# Usage (as root):
#   bash install-zammad-ubuntu2404.sh
#
# Optional environment variables:
#   ZAMMAD_FQDN=support.example.com   # server_name (default: server IP)
#   LE_EMAIL=you@example.com          # with ZAMMAD_FQDN -> issue Let's Encrypt cert
#   SKIP_ES=1                         # skip Elasticsearch (not recommended)
#   ES_HEAP=auto|none|2g              # ES JVM heap; auto = 1g if RAM <= 8GB (default)
#
# Example:
#   ZAMMAD_FQDN=support.example.com LE_EMAIL=admin@example.com bash install-zammad-ubuntu2404.sh
# =============================================================================
set -Eeuo pipefail

ZAMMAD_FQDN="${ZAMMAD_FQDN:-}"
LE_EMAIL="${LE_EMAIL:-}"
SKIP_ES="${SKIP_ES:-0}"
ES_HEAP="${ES_HEAP:-auto}"

LOG=/var/log/zammad-install.log
CREDS=/root/zammad-install-credentials.txt
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1

exec > >(tee -a "$LOG") 2>&1

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
trap 'die "Failed at line $LINENO. See $LOG"' ERR

# ---------------------------------------------------------------- preflight --
step "Preflight checks"
[[ $EUID -eq 0 ]] || die "Run as root (sudo -i)."
. /etc/os-release
[[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]] || die "Ubuntu 24.04 required (found: ${PRETTY_NAME:-unknown})."

RAM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
CPUS=$(nproc)
(( RAM_MB >= 3500 )) || warn "RAM ${RAM_MB}MB < 4GB recommended. Zammad + Elasticsearch may be unstable."

if [[ -z "$ZAMMAD_FQDN" ]]; then
  ZAMMAD_FQDN="$(hostname -I | awk '{print $1}')"
  warn "ZAMMAD_FQDN not set; using $ZAMMAD_FQDN (HTTP only)."
  LE_EMAIL=""
fi
IS_IP=0; [[ "$ZAMMAD_FQDN" =~ ^[0-9.]+$ ]] && IS_IP=1
(( IS_IP == 1 )) && LE_EMAIL=""

curl -fsS -o /dev/null --max-time 15 https://go.packager.io || die "Cannot reach go.packager.io (note: IPv6-only hosts are unsupported)."

# ------------------------------------------------ 1. required tools + locale --
step "Installing required tools"
apt-get update -y
apt-get install -y curl apt-transport-https gnupg ca-certificates locales

step "Ensuring UTF-8 locale"
if ! locale 2>/dev/null | grep -qi 'LANG=.*utf-\?8'; then
  locale-gen en_US.UTF-8
  echo "LANG=en_US.UTF-8" > /etc/default/locale
fi
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
locale-gen en_US.UTF-8 >/dev/null

# ------------------------------------------------------- 2. Elasticsearch 9 --
ES_PASS=""
if [[ "$SKIP_ES" != "1" ]]; then
  step "Adding Elasticsearch 9 repository"
  curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch \
    | gpg --batch --yes --dearmor -o /usr/share/keyrings/elasticsearch-keyring.gpg
  chmod 644 /usr/share/keyrings/elasticsearch-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/elasticsearch-keyring.gpg] https://artifacts.elastic.co/packages/9.x/apt stable main" \
    > /etc/apt/sources.list.d/elastic-9.x.list

  step "Installing Elasticsearch"
  apt-get update -y
  apt-get install -y elasticsearch

  step "Configuring Elasticsearch"
  ESYML=/etc/elasticsearch/elasticsearch.yml
  grep -q '^http.max_content_length' "$ESYML" || echo 'http.max_content_length: 400mb' >> "$ESYML"

  HEAP=""
  case "$ES_HEAP" in
    auto) (( RAM_MB <= 8192 )) && HEAP="1g" || true ;;
    none) ;;
    *)    HEAP="$ES_HEAP" ;;
  esac
  if [[ -n "$HEAP" ]]; then
    printf -- '-Xms%s\n-Xmx%s\n' "$HEAP" "$HEAP" > /etc/elasticsearch/jvm.options.d/heap.options
    echo "ES heap set to $HEAP"
  fi

  step "Starting Elasticsearch"
  systemctl daemon-reload
  systemctl enable elasticsearch.service --now

  printf 'Waiting for Elasticsearch'
  for _ in $(seq 1 90); do
    code=$(curl -sk -o /dev/null -w '%{http_code}' https://localhost:9200 || true)
    [[ "$code" == "200" || "$code" == "401" ]] && break
    printf '.'; sleep 2
  done
  echo
  [[ "$code" == "200" || "$code" == "401" ]] || die "Elasticsearch did not come up. Check: journalctl -u elasticsearch"

  step "Generating elastic superuser password"
  ES_PASS="$(/usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic -b -s 2>/dev/null | tail -n1 | tr -d '\r\n')"
  [[ -n "$ES_PASS" ]] || die "Could not generate Elasticsearch password."
fi

# ------------------------------------------------------------ 3. Zammad pkg --
step "Adding Zammad repository (Ubuntu 24.04)"
curl -fsSL "https://go.packager.io/srv/deb/zammad/zammad/gpg-key.gpg" -o /usr/share/keyrings/zammad.gpg
chmod 644 /usr/share/keyrings/zammad.gpg
curl -fsSL "https://go.packager.io/srv/zammad/zammad/stable/installer/ubuntu/24.04.list" \
  -o /etc/apt/sources.list.d/zammad.list

step "Installing Zammad (this pulls PostgreSQL, nginx, Redis deps)"
apt-get update -y
apt-get install -y zammad

# ------------------------------------------------ 4. Connect Elasticsearch --
if [[ "$SKIP_ES" != "1" ]]; then
  step "Connecting Zammad to Elasticsearch"
  zammad run rails r "Setting.set('es_url', 'https://localhost:9200')"
  zammad run rails r "Setting.set('es_user', 'elastic')"
  zammad run rails r "Setting.set('es_password', '${ES_PASS}')"
  zammad run rails r "Setting.set('es_attachment_max_size_in_mb', 50)"
  cat /etc/elasticsearch/certs/http_ca.crt \
    | zammad run rails r 'SSLCertificate.create!(certificate: STDIN.read)' \
    || warn "CA certificate import skipped (likely already present)."

  step "Building search index"
  zammad run rake "zammad:searchindex:rebuild[${CPUS}]"
fi

# ----------------------------------------------------------- 5. Web server --
step "Configuring nginx"
rm -f /etc/nginx/sites-enabled/default
if [[ -f /etc/nginx/sites-available/zammad.conf ]]; then
  ln -sf /etc/nginx/sites-available/zammad.conf /etc/nginx/sites-enabled/zammad.conf
elif [[ -f /etc/nginx/conf.d/zammad.conf ]]; then
  :
else
  install -m 644 /opt/zammad/contrib/nginx/zammad.conf /etc/nginx/sites-available/zammad.conf
  ln -sf /etc/nginx/sites-available/zammad.conf /etc/nginx/sites-enabled/zammad.conf
fi
NGCONF=""
for f in /etc/nginx/sites-available/zammad.conf /etc/nginx/conf.d/zammad.conf; do
  [[ -f "$f" ]] && { NGCONF="$f"; break; }
done
[[ -n "$NGCONF" ]] || die "Zammad nginx config not found."
sed -i -E "s/^(\s*server_name\s+)[^;]+;/\1${ZAMMAD_FQDN};/" "$NGCONF"
nginx -t
systemctl enable nginx
systemctl reload nginx || systemctl restart nginx

SCHEME="http"
if [[ -n "$LE_EMAIL" ]]; then
  step "Issuing Let's Encrypt certificate for $ZAMMAD_FQDN"
  apt-get install -y certbot python3-certbot-nginx
  if certbot --nginx -d "$ZAMMAD_FQDN" -m "$LE_EMAIL" --agree-tos --non-interactive --redirect; then
    SCHEME="https"
  else
    warn "Certbot failed (check DNS A record + port 80 reachability). Continuing on HTTP."
  fi
fi

# ---------------------------------------------------------------- Firewall --
if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
  step "Opening ports 80/443 in UFW"
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw reload
fi

# ---------------------------------------------------------------- Services --
step "Enabling and restarting Zammad services"
systemctl enable zammad
systemctl restart zammad

printf 'Waiting for Zammad web'
for _ in $(seq 1 90); do
  code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/ || true)
  [[ "$code" =~ ^(200|301|302)$ ]] && break
  printf '.'; sleep 3
done
echo

# ----------------------------------------------------------------- Summary --
umask 077
{
  echo "Zammad URL            : ${SCHEME}://${ZAMMAD_FQDN}/"
  echo "Elasticsearch URL     : https://localhost:9200"
  echo "Elasticsearch user    : elastic"
  echo "Elasticsearch password: ${ES_PASS:-n/a}"
  echo "Install log           : $LOG"
} > "$CREDS"

step "DONE"
cat "$CREDS"
cat <<EOF

Next: open ${SCHEME}://${ZAMMAD_FQDN}/ and complete the Zammad getting-started wizard.
Services : systemctl status zammad zammad-web zammad-worker zammad-websocket
Credentials saved to $CREDS (chmod 600).
EOF
