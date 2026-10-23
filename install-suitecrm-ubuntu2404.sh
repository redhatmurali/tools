#!/usr/bin/env bash
# Fresh SuiteCRM 8.10.2 installation for Ubuntu 24.04 LTS
# Apache + PHP 8.3 + MariaDB; HTTP by IP initially.
# Run: sudo bash install-suitecrm-ubuntu2404.sh
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

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: Run as root: sudo bash $0" >&2
  exit 1
fi

. /etc/os-release
if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
  echo "ERROR: This script is intended for Ubuntu 24.04 LTS only." >&2
  exit 1
fi

if [[ -e "${APP_DIR}/bin/console" ]]; then
  echo "ERROR: SuiteCRM already exists at ${APP_DIR}; refusing to overwrite it." >&2
  echo "This script is for a fresh installation only." >&2
  exit 1
fi

if ss -ltnH '( sport = :80 )' | grep -q .; then
  echo "ERROR: TCP port 80 is already listening. Check existing web server configuration first." >&2
  exit 1
fi

if [[ -e "${CRED_DIR}/database.txt" ]]; then
  echo "ERROR: ${CRED_DIR}/database.txt already exists; refusing to replace credentials." >&2
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

echo "==> Setting PHP defaults..."
cat > /etc/php/8.3/apache2/conf.d/99-suitecrm.ini <<'PHPINI'
memory_limit = 512M
upload_max_filesize = 50M
post_max_size = 50M
max_execution_time = 300
max_input_time = 300
date.timezone = Asia/Kolkata
PHPINI

echo "==> Starting MariaDB..."
systemctl enable --now mariadb

if mariadb -NBe "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='${DB_NAME}'" | grep -qx "${DB_NAME}"; then
  echo "ERROR: Database ${DB_NAME} already exists. Refusing to modify it." >&2
  exit 1
fi
if mariadb -NBe "SELECT User FROM mysql.user WHERE User='${DB_USER}' AND Host='localhost'" | grep -qx "${DB_USER}"; then
  echo "ERROR: Database user ${DB_USER}@localhost already exists. Refusing to modify it." >&2
  exit 1
fi

DB_PASS="$(openssl rand -hex 32)"
mariadb <<SQL
CREATE DATABASE \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

echo "==> Downloading SuiteCRM ${VERSION}..."
curl -fL --retry 3 --connect-timeout 20 "${ZIP_URL}" -o "${ZIP_PATH}"
echo "${ZIP_SHA256}  ${ZIP_PATH}" | sha256sum -c -

echo "==> Extracting package..."
TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "${TMP_DIR}"; }
trap cleanup EXIT
unzip -q "${ZIP_PATH}" -d "${TMP_DIR}"

if [[ ! -f "${TMP_DIR}/bin/console" || ! -f "${TMP_DIR}/public/install.php" || ! -f "${TMP_DIR}/vendor/autoload.php" ]]; then
  echo "ERROR: Downloaded archive does not have the expected prebuilt SuiteCRM package layout." >&2
  echo "No application files were deployed. Inspect ${ZIP_PATH} before continuing." >&2
  exit 1
fi

install -d -o root -g www-data -m 0750 "${APP_DIR}"
cp -a "${TMP_DIR}/." "${APP_DIR}/"

# The web installer needs to write configuration/cache files. This initial
# ownership matches the interactive installation workflow; harden writable
# paths after the installer has completed and before production use.
chown -R www-data:www-data "${APP_DIR}"
find "${APP_DIR}" -type d -exec chmod 2755 {} +
find "${APP_DIR}" -type f -exec chmod 0644 {} +
chmod 0755 "${APP_DIR}/bin/console"

echo "==> Configuring Apache virtual host..."
a2enmod rewrite headers
a2dissite 000-default.conf >/dev/null 2>&1 || true

cat > /etc/apache2/sites-available/suitecrm.conf <<APACHE
<VirtualHost *:80>
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

echo 'ServerName localhost' > /etc/apache2/conf-available/servername.conf
a2enconf servername
a2ensite suitecrm.conf
apache2ctl configtest
systemctl enable --now apache2
systemctl restart apache2

echo "==> Saving database credentials..."
install -d -m 0700 "${CRED_DIR}"
cat > "${CRED_DIR}/database.txt" <<CREDS
Database: ${DB_NAME}
Username: ${DB_USER}
Password: ${DB_PASS}
Host: localhost
CREDS
chmod 0600 "${CRED_DIR}/database.txt"

rm -f "${ZIP_PATH}"

echo
echo "=============================================================="
echo "SuiteCRM ${VERSION} files deployed successfully."
echo "=============================================================="
echo "Open: http://YOUR_SERVER_IP/"
echo "Document root: ${APP_DIR}/public"
echo "Database credentials: sudo cat ${CRED_DIR}/database.txt"
echo
echo "Next:"
echo "  1. Open http://YOUR_SERVER_IP/ and complete the browser installer."
echo "  2. Use database name ${DB_NAME}, user ${DB_USER}, host localhost."
echo "  3. Configure the SuiteCRM scheduler and Messenger worker."
echo "  4. Restrict public access until HTTPS is configured."
echo "  5. Harden file permissions after the installer completes."
echo
echo "WARNING: HTTP is unencrypted. Do not enter real customer data over public HTTP."
