#!/usr/bin/env bash
# =============================================================================
# Fresh SuiteCRM 8.10.2 installation — Ubuntu 24.04 LTS
# Apache + PHP 8.3 + MariaDB
# SuiteCRM listens on port 3002.
#
# Existing applications on ports 80 and 3000 must remain untouched.
#
# Run:
#   sudo bash install-suitecrm-ubuntu2404.sh
#
# URL:
#   http://YOUR_SERVER_IP:3002/
#
# Database credentials:
#   /root/suitecrm-install/database.txt
# =============================================================================

set -Eeuo pipefail
umask 077

VERSION="8.10.2"
ZIP_URL="https://sourceforge.net/projects/suitecrm/files/v8.10.2/SuiteCRM-8.10.2.zip/download"
ZIP_SHA256="ac4693d10ea2d6cd20b3256098781d134599d88878fb24e8dc127038d624f5a8"

APP_DIR="/var/www/suitecrm"
DB_NAME="suitecrm"
DB_USER="suitecrm_user"
CRED_DIR="/root/suitecrm-install"
ZIP_PATH="/tmp/SuiteCRM-${VERSION}.zip"
PORT="3002"

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Run as root: sudo bash $0" >&2
    exit 1
fi

. /etc/os-release

if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
    echo "ERROR: This script is intended for Ubuntu 24.04 LTS only." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Pre-installation safety checks
# ---------------------------------------------------------------------------

if [[ -e "${APP_DIR}/bin/console" ]]; then
    echo "ERROR: SuiteCRM already exists at ${APP_DIR}." >&2
    echo "Refusing to overwrite the existing installation." >&2
    exit 1
fi

if [[ -e "${CRED_DIR}/database.txt" ]]; then
    echo "ERROR: ${CRED_DIR}/database.txt already exists." >&2
    echo "Refusing to replace existing credentials." >&2
    exit 1
fi

if ss -ltnH "( sport = :${PORT} )" | grep -q .; then
    echo "ERROR: TCP port ${PORT} is already listening." >&2
    echo "Choose a free port before continuing." >&2
    exit 1
fi

# Do not change an existing Apache installation that serves applications
# on port 80. A separate Apache configuration could otherwise disrupt it.
if systemctl is-active --quiet apache2 &&
   ss -ltnpH '( sport = :80 )' | grep -q 'apache2'; then
    echo "ERROR: Apache is already serving port 80." >&2
    echo "This script will not change your existing Apache installation." >&2
    echo "Use a separate Apache instance or configure the existing server manually." >&2
    exit 1
fi

if [[ -e "${APP_DIR}" ]]; then
    echo "ERROR: ${APP_DIR} already exists." >&2
    echo "Refusing to modify an existing directory." >&2
    exit 1
fi

echo "==> Installing Apache, MariaDB, PHP 8.3 and extensions..."

apt-get update

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    apache2 mariadb-server curl unzip openssl ca-certificates \
    php8.3 php8.3-cli libapache2-mod-php8.3 \
    php8.3-curl php8.3-gd php8.3-intl php8.3-mbstring \
    php8.3-mysql php8.3-xml php8.3-zip php8.3-soap \
    php8.3-imap php8.3-bcmath php8.3-opcache php8.3-ldap

# ---------------------------------------------------------------------------
# Configure Apache to listen on port 3002, not port 80.
# Preserve unrelated Listen directives; do not change other applications.
# ---------------------------------------------------------------------------

echo "==> Configuring Apache to listen on port ${PORT}..."

PORTS_CONF="/etc/apache2/ports.conf"

if grep -qE '^[[:space:]]*Listen[[:space:]]+80([[:space:]]|$)' "${PORTS_CONF}"; then
    sed -i -E \
        '/^[[:space:]]*Listen[[:space:]]+80([[:space:]]|$)/d' \
        "${PORTS_CONF}"
fi

if ! grep -qE "^[[:space:]]*Listen[[:space:]]+${PORT}([[:space:]]|$)" "${PORTS_CONF}"; then
    echo "Listen ${PORT}" >> "${PORTS_CONF}"
fi

# ---------------------------------------------------------------------------
# PHP configuration
# ---------------------------------------------------------------------------

echo "==> Configuring PHP..."

cat > /etc/php/8.3/apache2/conf.d/99-suitecrm.ini <<'PHPINI'
memory_limit = 512M
upload_max_filesize = 50M
post_max_size = 50M
max_execution_time = 300
max_input_time = 300
date.timezone = Asia/Kolkata
PHPINI

# ---------------------------------------------------------------------------
# MariaDB and database
# ---------------------------------------------------------------------------

echo "==> Starting MariaDB..."

systemctl enable --now mariadb

if mariadb -NBe \
    "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='${DB_NAME}'" |
    grep -qx "${DB_NAME}"; then
    echo "ERROR: Database ${DB_NAME} already exists." >&2
    echo "Refusing to modify it." >&2
    exit 1
fi

if mariadb -NBe \
    "SELECT User FROM mysql.user WHERE User='${DB_USER}' AND Host='localhost'" |
    grep -qx "${DB_USER}"; then
    echo "ERROR: Database user ${DB_USER}@localhost already exists." >&2
    echo "Refusing to modify it." >&2
    exit 1
fi

DB_PASS="$(openssl rand -hex 32)"

mariadb <<SQL
CREATE DATABASE \`${DB_NAME}\`
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;

CREATE USER '${DB_USER}'@'localhost'
    IDENTIFIED BY '${DB_PASS}';

GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.*
    TO '${DB_USER}'@'localhost';

FLUSH PRIVILEGES;
SQL

# ---------------------------------------------------------------------------
# Download and verify SuiteCRM
# ---------------------------------------------------------------------------

echo "==> Downloading SuiteCRM ${VERSION}..."

curl -fL --retry 3 --connect-timeout 20 \
    "${ZIP_URL}" -o "${ZIP_PATH}"

echo "${ZIP_SHA256}  ${ZIP_PATH}" | sha256sum -c -

echo "==> Extracting SuiteCRM..."

TMP_DIR="$(mktemp -d)"
cleanup() {
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

unzip -q "${ZIP_PATH}" -d "${TMP_DIR}"

if [[ ! -f "${TMP_DIR}/bin/console" ||
      ! -f "${TMP_DIR}/public/install.php" ||
      ! -f "${TMP_DIR}/vendor/autoload.php" ]]; then
    echo "ERROR: The archive does not have the expected SuiteCRM package layout." >&2
    echo "No application files were deployed." >&2
    exit 1
fi

install -d -o root -g www-data -m 0750 "${APP_DIR}"
cp -a "${TMP_DIR}/." "${APP_DIR}/"

# Initial ownership supports the interactive web installer.
# Harden writable paths after completing the installer.
chown -R www-data:www-data "${APP_DIR}"
find "${APP_DIR}" -type d -exec chmod 2755 {} +
find "${APP_DIR}" -type f -exec chmod 0644 {} +
chmod 0755 "${APP_DIR}/bin/console"

# ---------------------------------------------------------------------------
# Apache virtual host — port 3002 only
# ---------------------------------------------------------------------------

echo "==> Configuring the SuiteCRM virtual host..."

a2enmod rewrite headers

cat > /etc/apache2/sites-available/suitecrm.conf <<APACHE
<VirtualHost *:${PORT}>
    ServerName localhost
    DocumentRoot ${APP_DIR}/public

    <Directory ${APP_DIR}/public>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    <Directory ${APP_DIR}>
        Require all denied
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/suitecrm-error.log
    CustomLog \${APACHE_LOG_DIR}/suitecrm-access.log combined
</VirtualHost>
APACHE

# Enable only the SuiteCRM site. Do not disable existing sites.
a2ensite suitecrm.conf

apache2ctl configtest

systemctl enable apache2
systemctl restart apache2

# Verify Apache actually bound to port 3002.
if ! ss -ltnH "( sport = :${PORT} )" | grep -q .; then
    echo "ERROR: Apache did not start listening on port ${PORT}." >&2
    echo "Check: systemctl status apache2" >&2
    echo "Check: journalctl -u apache2 -n 100 --no-pager" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Securely save credentials
# ---------------------------------------------------------------------------

echo "==> Saving database credentials..."

install -d -m 0700 "${CRED_DIR}"

cat > "${CRED_DIR}/database.txt" <<CREDS
SuiteCRM version: ${VERSION}
Database: ${DB_NAME}
Username: ${DB_USER}
Password: ${DB_PASS}
Host: localhost
Port: 3306
CREDS

chmod 0600 "${CRED_DIR}/database.txt"

rm -f "${ZIP_PATH}"

# ---------------------------------------------------------------------------
# Completion
# ---------------------------------------------------------------------------

echo
echo "=============================================================="
echo "SuiteCRM ${VERSION} files deployed successfully."
echo "=============================================================="
echo
echo "URL:                 http://YOUR_SERVER_IP:${PORT}/"
echo "Application directory: ${APP_DIR}"
echo "Document root:        ${APP_DIR}/public"
echo "Apache port:          ${PORT}"
echo "Database:             ${DB_NAME}"
echo "Database user:        ${DB_USER}"
echo "Credentials:          sudo cat ${CRED_DIR}/database.txt"
echo
echo "Next steps:"
echo "  1. Allow TCP ${PORT} in your firewall if required."
echo "  2. Open http://YOUR_SERVER_IP:${PORT}/."
echo "  3. Complete the browser installer."
echo "  4. Use database ${DB_NAME}, user ${DB_USER}, host localhost."
echo "  5. Configure the SuiteCRM scheduler and Messenger worker."
echo "  6. Configure HTTPS before entering real customer data."
echo "  7. Harden writable directories after installation."
echo
echo "Existing applications on ports 80 and 3000 have not been"
echo "intentionally reconfigured by this script."
echo "WARNING: HTTP is unencrypted; do not enter real customer data"
echo "over public HTTP."
