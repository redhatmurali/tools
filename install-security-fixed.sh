#!/usr/bin/env bash
# install-security.sh
# Ubuntu 24.04 LTS: UFW + Fail2ban + CrowdSec + nftables firewall bouncer
# Run with: sudo bash ./install-security.sh
set -Eeuo pipefail
umask 077

LOG="/var/log/install-security.log"
exec > >(tee -a "$LOG") 2>&1

say() { printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run as root: sudo bash $0"
[[ -r /etc/os-release ]] || die "Cannot identify operating system."
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]] || \
  die "This script supports Ubuntu 24.04 LTS only (detected: ${PRETTY_NAME:-unknown})."

export DEBIAN_FRONTEND=noninteractive
say "Installing prerequisites and security packages"
apt-get update
apt-get install -y ca-certificates curl gnupg lsb-release ufw fail2ban nftables rsyslog

# Preserve existing UFW rules; add the expected web/SSH rules without deleting custom rules.
say "Configuring UFW defaults and essential rules"
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'

# Ensure auth.log and syslog exist for file-based acquisition.
if ! systemctl is-active --quiet rsyslog; then
  systemctl enable --now rsyslog
fi

say "Installing CrowdSec from the official repository if not already installed"
if ! have cscli; then
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://packagecloud.io/crowdsec/crowdsec/gpgkey \
    | gpg --dearmor --yes -o /etc/apt/keyrings/crowdsec.gpg
  chmod 0644 /etc/apt/keyrings/crowdsec.gpg
  cat >/etc/apt/sources.list.d/crowdsec.list <<'REPO'
deb [signed-by=/etc/apt/keyrings/crowdsec.gpg] https://packagecloud.io/crowdsec/crowdsec/ubuntu/ noble main
REPO
  apt-get update
  apt-get install -y crowdsec
fi

say "Installing the nftables firewall bouncer"
if ! dpkg-query -W -f='${Status}' crowdsec-firewall-bouncer-nftables 2>/dev/null | grep -q 'install ok installed'; then
  apt-get install -y crowdsec-firewall-bouncer-nftables
fi

say "Ensuring SSH and Linux collections are installed"
cscli collections install crowdsecurity/linux || true
cscli collections install crowdsecurity/sshd || true
cscli collections install crowdsecurity/whitelist-good-actors || true
cscli hub update || true

say "Writing explicit file acquisition configuration"
install -d -m 0755 /etc/crowdsec/acquis.d
cat >/etc/crowdsec/acquis.d/setup.sshd.yaml <<'ACQ'
filenames:
  - /var/log/auth.log
labels:
  type: syslog
source: file
ACQ
cat >/etc/crowdsec/acquis.d/setup.linux.yaml <<'ACQ'
filenames:
  - /var/log/syslog
labels:
  type: syslog
source: file
ACQ
chmod 0644 /etc/crowdsec/acquis.d/setup.sshd.yaml /etc/crowdsec/acquis.d/setup.linux.yaml

# Avoid duplicate acquisition of the same files from the legacy top-level file.
if [[ -f /etc/crowdsec/acquis.yaml ]]; then
  cp -a /etc/crowdsec/acquis.yaml "/etc/crowdsec/acquis.yaml.backup.$(date +%Y%m%d%H%M%S)"
  cat >/etc/crowdsec/acquis.yaml <<'EMPTY'
# Acquisition is configured in /etc/crowdsec/acquis.d/*.yaml
[]
EMPTY
fi

say "Configuring Fail2ban SSH jail"
install -d -m 0755 /etc/fail2ban/jail.d
cat >/etc/fail2ban/jail.d/netaport.local <<'JAIL'
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
backend = systemd
banaction = ufw

[sshd]
enabled = true
port = ssh
filter = sshd
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
JAIL

say "Checking CrowdSec bouncer registration"
BOUNCER_NAME="netaport-firewall-bouncer"
BOUNCER_CONFIG="/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml"
install -d -m 0750 /etc/crowdsec/bouncers

# Never replace a package-provided bouncer config wholesale: it contains
# version-specific settings (including nftables mode) required by the service.
if [[ -f "$BOUNCER_CONFIG" ]]; then
  cp -a "$BOUNCER_CONFIG" "$BOUNCER_CONFIG.pre-install.$(date +%Y%m%d%H%M%S)"
fi

# If a previous script replaced the package config with a minimal file, restore
# the newest backup that still contains the package's mode/backend settings.
if [[ -f "$BOUNCER_CONFIG" ]] && ! grep -qE '^[[:space:]]*mode:' "$BOUNCER_CONFIG"; then
  RESTORE_CONFIG=""
  for candidate in /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml.backup.* \
                   /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml.pre-install.* \
                   /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml.bak*; do
    [[ -f "$candidate" ]] || continue
    if grep -qE '^[[:space:]]*mode:' "$candidate"; then
      RESTORE_CONFIG="$candidate"
    fi
  done
  if [[ -n "$RESTORE_CONFIG" ]]; then
    say "Restoring complete bouncer config from $RESTORE_CONFIG"
    cp -a "$RESTORE_CONFIG" "$BOUNCER_CONFIG"
  else
    die "Bouncer config has no 'mode:' setting and no complete backup was found. Check journalctl -u crowdsec-firewall-bouncer before rerunning."
  fi
fi

HAS_API_KEY=0
if [[ -f "$BOUNCER_CONFIG" ]] && grep -qE '^[[:space:]]*api_key:[[:space:]]*[^[:space:]#]+' "$BOUNCER_CONFIG"; then
  HAS_API_KEY=1
fi

BOUNCER_EXISTS=0
if cscli bouncers list 2>/dev/null | grep -Fq "$BOUNCER_NAME"; then
  BOUNCER_EXISTS=1
fi

if [[ "$HAS_API_KEY" -eq 1 ]]; then
  say "Existing bouncer API key found; preserving the complete configuration"
elif [[ "$BOUNCER_EXISTS" -eq 1 ]]; then
  die "Bouncer '$BOUNCER_NAME' is already registered but local config has no API key. No config was overwritten. Check cscli bouncers list and /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml."
else
  say "Creating a new bouncer registration"
  BOUNCER_KEY="$(cscli bouncers add "$BOUNCER_NAME" -o raw 2>/dev/null | tail -n1 | tr -d '\r' | xargs)"
  [[ -n "$BOUNCER_KEY" ]] || die "Could not create CrowdSec bouncer API key. Check: cscli bouncers list"

  if [[ ! -f "$BOUNCER_CONFIG" ]]; then
    die "Bouncer package configuration is missing at $BOUNCER_CONFIG. Reinstall crowdsec-firewall-bouncer-nftables and rerun."
  fi

  # Update only api_key, preserving every other package/default setting.
  if grep -qE '^[[:space:]]*api_key:' "$BOUNCER_CONFIG"; then
    sed -i -E "s|^[[:space:]]*api_key:.*$|api_key: ${BOUNCER_KEY}|" "$BOUNCER_CONFIG"
  else
    printf '\napi_key: %s\n' "$BOUNCER_KEY" >> "$BOUNCER_CONFIG"
  fi
  chmod 0600 "$BOUNCER_CONFIG"
fi

say "Restarting and enabling security services"
systemctl enable --now rsyslog
systemctl enable --now crowdsec
systemctl restart crowdsec
systemctl enable crowdsec-firewall-bouncer
if ! systemctl restart crowdsec-firewall-bouncer; then
  echo "ERROR: CrowdSec firewall bouncer failed to start. Diagnostics follow:" >&2
  systemctl --no-pager --full status crowdsec-firewall-bouncer || true
  journalctl -u crowdsec-firewall-bouncer -n 80 --no-pager || true
  echo "The bouncer config backup (if one existed) is named *.pre-install.* in /etc/crowdsec/bouncers/." >&2
  exit 1
fi
systemctl enable --now fail2ban
systemctl restart fail2ban

say "Validating services and configuration"
cscli collections list
cscli bouncers list
fail2ban-client status
fail2ban-client status sshd || true
systemctl --no-pager --full status crowdsec crowdsec-firewall-bouncer fail2ban | sed -n '1,100p'

echo
echo "UFW is currently: $(ufw status | head -n1)"
echo "Existing UFW rules were preserved. The script added SSH (22), HTTP (80), and HTTPS (443)."
read -r -p "Enable UFW now? Ensure SSH port 22 is correct before answering yes [y/N]: " ENABLE_UFW
if [[ "$ENABLE_UFW" =~ ^[Yy]$ ]]; then
  ufw --force enable
else
  echo "UFW was not enabled by this script. Enable later with: sudo ufw enable"
fi

say "CrowdSec diagnostics"
echo "--- Acquisition configuration ---"
for f in /etc/crowdsec/acquis.d/*.yaml; do
  [[ -f "$f" ]] && { echo "### $f"; cat "$f"; }
done
echo "--- CrowdSec metrics ---"
cscli metrics || true
echo "--- Active decisions ---"
cscli decisions list || true

cat <<'NEXT'

Installation/update finished.

Useful checks:
  sudo systemctl status crowdsec crowdsec-firewall-bouncer fail2ban --no-pager
  sudo cscli metrics
  sudo cscli alerts list
  sudo cscli decisions list
  sudo cscli bouncers list
  sudo fail2ban-client status sshd

To test parser matching with a synthetic log (no real login attempt):
  sudo cscli explain --log 'Oct 19 10:00:00 test sshd[1234]: Failed password for invalid user testuser from 203.0.113.10 port 54321 ssh2' --type syslog

Important:
- A fresh install can legitimately show zero alerts/decisions.
- Do not use a sudo command line as the sample for the SSH parser; it is not an SSH event.
- Keep SSH access open before enabling UFW. Add any other required application ports before enabling it.
- Review /var/log/install-security.log if the script reports an error.
NEXT
