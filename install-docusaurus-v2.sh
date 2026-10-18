#!/usr/bin/env bash
# Docusaurus installer for Ubuntu 22.04+ and AlmaLinux 9.x
# Run as a normal user with sudo access (do not run this script with sudo).
set -Eeuo pipefail

SITE_DIR="${SITE_DIR:-$HOME/docusaurus-site}"
SITE_NAME="${SITE_NAME:-$(basename "$SITE_DIR")}"
SKIP_BUILD=0
START_SERVER=0

usage() {
  cat <<'EOF'
Docusaurus installer for Ubuntu 22.04+ and AlmaLinux 9.x

Options:
  --dir PATH       Destination directory (default: ~/docusaurus-site)
  --name NAME      Project name
  --skip-build     Skip the production build
  --serve           Start the dev server after install/build on 0.0.0.0:3000
  --help            Show this help

Examples:
  ./install-docusaurus.sh
  ./install-docusaurus.sh --dir "$HOME/postgres-docs" --name postgres-docs
  ./install-docusaurus.sh --serve
EOF
}

while (($#)); do
  case "$1" in
    --dir) SITE_DIR="${2:?Missing path after --dir}"; shift 2 ;;
    --name) SITE_NAME="${2:?Missing name after --name}"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --serve) START_SERVER=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "ERROR: Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ $EUID -eq 0 ]]; then
  echo "ERROR: Run this script as a normal user, not with sudo."
  exit 1
fi
command -v sudo >/dev/null 2>&1 || { echo "ERROR: sudo is required." >&2; exit 1; }
sudo -v

[[ "$SITE_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || {
  echo "ERROR: Invalid project name: $SITE_NAME" >&2; exit 1;
}
SITE_DIR="$(mkdir -p "$(dirname "$SITE_DIR")" && cd "$(dirname "$SITE_DIR")" && pwd)/$(basename "$SITE_DIR")"
PARENT_DIR="$(dirname "$SITE_DIR")"
PROJECT_DIR="$(basename "$SITE_DIR")"

[[ -f /etc/os-release ]] || { echo "ERROR: Cannot identify Linux distribution." >&2; exit 1; }
# shellcheck disable=SC1091
. /etc/os-release
echo "==> Detected OS: ${PRETTY_NAME:-$ID}"

case "${ID:-}" in
  ubuntu)
    major="${VERSION_ID%%.*}"
    [[ "$major" =~ ^[0-9]+$ ]] && (( major >= 22 )) || { echo "ERROR: Ubuntu 22.04+ required." >&2; exit 1; }
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl git build-essential
    curl -fsSL https://deb.nodesource.com/setup_22.x -o /tmp/docusaurus-nodesource-setup.sh
    sudo -E bash /tmp/docusaurus-nodesource-setup.sh
    sudo apt-get install -y nodejs
    rm -f /tmp/docusaurus-nodesource-setup.sh
    ;;
  almalinux)
    major="${VERSION_ID%%.*}"
    [[ "$major" == "9" ]] || { echo "ERROR: AlmaLinux 9.x required." >&2; exit 1; }
    sudo dnf install -y ca-certificates curl git gcc-c++ make
    curl -fsSL https://rpm.nodesource.com/setup_22.x -o /tmp/docusaurus-nodesource-setup.sh
    sudo bash /tmp/docusaurus-nodesource-setup.sh
    sudo dnf install -y nodejs
    rm -f /tmp/docusaurus-nodesource-setup.sh
    ;;
  *)
    echo "ERROR: Supported OS: Ubuntu 22.04+ or AlmaLinux 9.x. Detected: ${ID:-unknown}" >&2
    exit 1
    ;;
esac

echo "==> Node.js: $(node --version)"
echo "==> npm: $(npm --version)"

if [[ -f "$SITE_DIR/package.json" ]]; then
  echo "==> Existing project found: $SITE_DIR"
  cd "$SITE_DIR"
  if ! node -e "const p=require('./package.json'); if(!p.dependencies?.['@docusaurus/core'] && !p.devDependencies?.['@docusaurus/core']) process.exit(1)" 2>/dev/null; then
    echo "ERROR: package.json exists, but this is not a Docusaurus project: $SITE_DIR" >&2
    exit 1
  fi
  if [[ -f package-lock.json ]]; then npm ci; else npm install; fi
elif [[ -e "$SITE_DIR" ]] && [[ -n "$(find "$SITE_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
  echo "ERROR: Destination is not empty and is not a recognized Docusaurus project:"
  echo "  $SITE_DIR"
  echo "Nothing was deleted. Choose another --dir or move/backup the files first." >&2
  exit 1
else
  # Do not pre-create SITE_DIR: create-docusaurus must create the project directory itself.
  echo "==> Creating Docusaurus Classic TypeScript site at $SITE_DIR"
  mkdir -p "$PARENT_DIR"
  cd "$PARENT_DIR"
  npx --yes create-docusaurus@latest "$PROJECT_DIR" classic --typescript
  cd "$SITE_DIR"
fi

if (( SKIP_BUILD == 0 )); then
  echo "==> Building production site..."
  npm run build
else
  echo "==> Skipping production build."
fi

cat <<EOF

============================================================
Docusaurus setup completed
Project directory: $SITE_DIR
Documentation:     $SITE_DIR/docs
Static output:     $SITE_DIR/build

Start locally:
  cd "$SITE_DIR" && npm run start

Allow LAN/network access for a temporary test:
  cd "$SITE_DIR" && npm run start -- --host 0.0.0.0
  Then open http://SERVER-IP:3000

Production:
  Serve the contents of "$SITE_DIR/build" with LiteSpeed/Nginx.
  Do not expose the development server publicly for permanent production.
Official guide: https://docusaurus.io/docs/installation
============================================================
EOF

if (( START_SERVER == 1 )); then
  echo "==> Starting dev server on 0.0.0.0:3000. Press Ctrl+C to stop."
  cd "$SITE_DIR"
  exec npm run start -- --host 0.0.0.0
fi
