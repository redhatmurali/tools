#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo $0"
  exit 1
fi

NODE_EXPORTER_BIN="/usr/local/bin/node_exporter"
TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"
EXPORTER_SCRIPT="/usr/local/sbin/firewall_security_exporter.py"
SERVICE_FILE="/etc/systemd/system/node_exporter.service"

if [[ ! -x "$NODE_EXPORTER_BIN" ]]; then
  echo "ERROR: $NODE_EXPORTER_BIN not found. Install Node Exporter first."
  exit 1
fi

apt-get update
apt-get install -y python3 nftables ufw fail2ban

if ! id node_exporter >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin node_exporter
fi

install -d -o node_exporter -g node_exporter -m 0755 "$TEXTFILE_DIR"

# Back up the existing service unit before enabling the textfile collector.
if [[ -f "$SERVICE_FILE" && ! -f "${SERVICE_FILE}.before-firewall-metrics" ]]; then
  cp -a "$SERVICE_FILE" "${SERVICE_FILE}.before-firewall-metrics"
fi

cat > "$EXPORTER_SCRIPT" <<'PYTHON_EXPORTER_EOF'
#!/usr/bin/env python3
"""Emit firewall state metrics for Prometheus node_exporter textfile collector.
Runs locally as root; metrics are snapshots, refreshed by a systemd timer.
"""
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path

OUT = Path("/var/lib/node_exporter/textfile_collector/firewall_security.prom")
METRICS = []

def run(args, timeout=10):
    try:
        p = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           text=True, timeout=timeout, check=False)
        return p.returncode, p.stdout.strip()
    except Exception:
        return 127, ""

def add(name, value, help_text, labels=None):
    labelstr = ""
    if labels:
        def esc(v):
            return str(v).replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')
        labelstr = "{" + ",".join(f'{k}="{esc(v)}"' for k, v in labels.items()) + "}"
    METRICS.append((name, help_text))
    METRICS.append(f"{name}{labelstr} {value}")

def collect_ufw():
    rc, out = run(["ufw", "status", "verbose"])
    ok = rc == 0 and bool(out)
    active = 1 if re.search(r"Status:\s+active", out, re.I) else 0
    rules_rc, rules = run(["ufw", "status", "numbered"])
    rule_count = len(re.findall(r"^\[\s*\d+\]", rules, re.M)) if rules_rc == 0 else 0
    add("firewall_collector_success", int(ok), "Whether collector command succeeded.", {"collector":"ufw"})
    add("firewall_ufw_active", active, "UFW active state, 1=yes.")
    add("firewall_ufw_rules_total", rule_count, "Number of UFW numbered rules.")

def collect_fail2ban():
    rc, out = run(["fail2ban-client", "status"])
    ok = rc == 0
    jails = []
    m = re.search(r"Jail list:\s*(.*)", out)
    if m and m.group(1).strip():
        jails = [x.strip() for x in m.group(1).split(",") if x.strip()]
    add("firewall_collector_success", int(ok), "Whether collector command succeeded.", {"collector":"fail2ban"})
    add("firewall_fail2ban_jails_total", len(jails), "Number of Fail2ban jails.")
    total_banned = 0
    for jail in jails:
        jrc, jout = run(["fail2ban-client", "status", jail])
        failed = 0
        banned = 0
        fm = re.search(r"Currently failed:\s*(\d+)", jout)
        bm = re.search(r"Currently banned:\s*(\d+)", jout)
        if fm: failed = int(fm.group(1))
        if bm: banned = int(bm.group(1))
        total_banned += banned
        add("firewall_fail2ban_jail_failed", failed, "Current failed attempts reported by Fail2ban.", {"jail":jail})
        add("firewall_fail2ban_jail_banned", banned, "Current banned IP count reported by Fail2ban.", {"jail":jail})
    add("firewall_fail2ban_banned_total", total_banned, "Total currently banned IPs across Fail2ban jails.")

def parse_cli_count(args):
    rc, out = run(args)
    if rc != 0:
        return None
    # cscli supports JSON output on common versions; tolerate list/table output.
    try:
        data = json.loads(out)
        if isinstance(data, list):
            return len(data), data
        if isinstance(data, dict):
            for key in ("items", "alerts", "decisions"):
                if isinstance(data.get(key), list):
                    return len(data[key]), data[key]
            return 0, []
    except Exception:
        pass
    lines = [x for x in out.splitlines() if x.strip()]
    # Remove table borders/header/summary lines; fallback is best-effort.
    candidates = [x for x in lines if not re.match(r"^[╭╰├┼─│+\-\s]+$", x) and "ID" not in x.upper() and "SCENARIO" not in x.upper()]
    return max(0, len(candidates) - 2), []

def collect_crowdsec():
    success = 1
    alerts = parse_cli_count(["cscli", "alerts", "list", "-o", "json"])
    decisions = parse_cli_count(["cscli", "decisions", "list", "-o", "json"])
    if alerts is None:
        success = 0
        alert_count = 0
    else:
        alert_count = alerts[0]
    if decisions is None:
        success = 0
        decision_count = 0
        decision_data = []
    else:
        decision_count, decision_data = decisions
    add("firewall_collector_success", success, "Whether collector command succeeded.", {"collector":"crowdsec"})
    add("firewall_crowdsec_alerts_active", alert_count, "Number of active CrowdSec alerts.")
    add("firewall_crowdsec_decisions_active", decision_count, "Number of active CrowdSec decisions.")
    origins = {}
    for item in decision_data if isinstance(decision_data, list) else []:
        origin = str(item.get("origin", "unknown")) if isinstance(item, dict) else "unknown"
        origins[origin] = origins.get(origin, 0) + 1
    if not origins:
        origins["unknown"] = decision_count
    for origin, count in origins.items():
        add("firewall_crowdsec_decision_origin", count, "Active CrowdSec decisions by origin.", {"origin":origin})

    brc, bout = run(["cscli", "bouncers", "list"])
    valid = 0
    if brc == 0:
        # Table has a Valid column; count rows where a checkmark appears.
        for line in bout.splitlines():
            if "✔" in line or "✓" in line:
                valid += 1
    add("firewall_crowdsec_bouncers_valid", valid, "Number of valid CrowdSec bouncers.")
    add("firewall_collector_success", int(brc == 0), "Whether collector command succeeded.", {"collector":"crowdsec_bouncers"})

def collect_nft():
    rc, out = run(["nft", "-j", "list", "ruleset"])
    ok = rc == 0
    rules = chains = packets = 0
    if ok:
        try:
            data = json.loads(out)
            for item in data.get("nftables", []):
                if "rule" in item:
                    rules += 1
                    rule = item["rule"]
                    # nft JSON rule counters are commonly represented as expressions.
                    for expr in rule.get("expr", []):
                        if isinstance(expr, dict) and "counter" in expr:
                            counter = expr["counter"]
                            if isinstance(counter, dict):
                                packets += int(counter.get("packets", 0) or 0)
                if "chain" in item:
                    chains += 1
        except Exception:
            ok = False
    add("firewall_collector_success", int(ok), "Whether collector command succeeded.", {"collector":"nftables"})
    add("firewall_nft_rules_total", rules, "Number of rules in nftables ruleset.")
    add("firewall_nft_chains_total", chains, "Number of chains in nftables ruleset.")
    add("firewall_nft_rule_packets_total", packets, "Sum of packet counters on nftables rules that expose counters.")

def main():
    collect_ufw()
    collect_fail2ban()
    collect_crowdsec()
    collect_nft()
    # Deduplicate HELP/TYPE headers while emitting valid text exposition format.
    lines = []
    seen = set()
    for item in METRICS:
        if isinstance(item, tuple):
            name, help_text = item
            if name not in seen:
                lines.append(f"# HELP {name} {help_text}")
                lines.append(f"# TYPE {name} gauge")
                seen.add(name)
        else:
            lines.append(item)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    fd, tmpname = tempfile.mkstemp(prefix="firewall_security.", suffix=".prom.tmp", dir=str(OUT.parent))
    try:
        with os.fdopen(fd, "w") as f:
            f.write("\n".join(lines) + "\n")
        os.chmod(tmpname, 0o644)
        os.replace(tmpname, OUT)
    finally:
        if os.path.exists(tmpname):
            os.unlink(tmpname)

if __name__ == "__main__":
    main()
PYTHON_EXPORTER_EOF
chmod 0755 "$EXPORTER_SCRIPT"
chown root:root "$EXPORTER_SCRIPT"

# This is the same localhost-only Node Exporter service as the existing stack,
# with the textfile collector added. Preserve the prior unit as a backup above.
cat > "$SERVICE_FILE" <<'SYSTEMD_EOF'
[Unit]
Description=Prometheus Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter --web.listen-address=127.0.0.1:9100 --collector.textfile.directory=/var/lib/node_exporter/textfile_collector
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/var/lib/node_exporter/textfile_collector

[Install]
WantedBy=multi-user.target
SYSTEMD_EOF

cat > /etc/systemd/system/firewall-security-metrics.service <<'SERVICE_EOF'
[Unit]
Description=Collect UFW, Fail2ban, CrowdSec and nftables metrics for Prometheus
After=network-online.target crowdsec.service fail2ban.service
Wants=network-online.target

[Service]
Type=oneshot
User=root
Group=root
ExecStart=/usr/bin/python3 /usr/local/sbin/firewall_security_exporter.py
SERVICE_EOF

cat > /etc/systemd/system/firewall-security-metrics.timer <<'TIMER_EOF'
[Unit]
Description=Refresh firewall security metrics every minute

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=10s
Unit=firewall-security-metrics.service

[Install]
WantedBy=timers.target
TIMER_EOF

systemctl daemon-reload
systemctl enable --now firewall-security-metrics.timer
systemctl restart node_exporter
systemctl start firewall-security-metrics.service

echo
echo "===== Collector service ====="
systemctl --no-pager --full status firewall-security-metrics.service || true
echo
echo "===== Firewall metrics ====="
curl -fsS http://127.0.0.1:9100/metrics | grep '^firewall_' || true
echo
echo "===== Prometheus target health ====="
curl -fsS http://127.0.0.1:9090/api/v1/targets |
  python3 -c 'import json,sys; d=json.load(sys.stdin); [print(t["labels"].get("job"), t["health"], t.get("lastError","")) for t in d["data"]["activeTargets"]]'
echo
echo "If firewall metrics are now listed above, refresh Grafana and set the dashboard time range to Last 1 hour."
echo "The dashboard JSON is imported separately; this installer only installs the metrics collector."
