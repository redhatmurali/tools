# Linux Installation Scripts

This repository contains installation scripts for development and data tools.

## Repository contents

| Script | Purpose | Supported OS |
|---|---|---|
| `install-docusaurus-v2.sh` | Installs Node.js 22 LTS, creates or updates a Docusaurus Classic TypeScript site, and builds it | Ubuntu 22.04+ / AlmaLinux 9.x |
| `install_dbt_ubuntu24_almalinux9_updated.sh` | dbt installation | Check the script for exact requirements and options |
| `install_snowflake_web_ui_ubuntu24_almalinux9.sh` | Snowflake web UI installation | Check the script for exact requirements and options |

**Security:** Review each script before running it. Only run scripts you trust. Scripts can change packages, repositories, services, and firewall settings.

## 1. Requirements

- A supported Linux server for the selected script.
- A normal user with `sudo` privileges.
- Internet access and SSH access.
- Sufficient disk space.

Run scripts as a normal user unless the specific script says otherwise. The Docusaurus script must not be run using `sudo`; it uses `sudo` for system package installation.

## 2. Clone this repository

### Ubuntu

```bash
sudo apt update
sudo apt install -y git
```

### AlmaLinux 9

```bash
sudo dnf install -y git
```

Clone and enter the repository:

```bash
git clone https://github.com/redhatmurali/tools.git
cd tools
ls -lh
```

## 3. Review a script

For example:

```bash
less install-docusaurus-v2.sh
```

Press `q` to exit. If supported, view its options:

```bash
bash install-docusaurus-v2.sh --help
```

## 4. Install Docusaurus

Make the script executable and run it as your normal user:

```bash
chmod +x install-docusaurus-v2.sh
./install-docusaurus-v2.sh
```

The script supports Ubuntu 22.04+ and AlmaLinux 9.x. It installs Node.js 22 LTS, creates a Docusaurus Classic TypeScript site, installs dependencies, and runs a production build. The default project directory is `~/docusaurus-site`.

The script does not pre-create the destination directory before calling the Docusaurus project generator. If it finds an existing Docusaurus project, it installs dependencies and rebuilds it. If the destination is non-empty and not a Docusaurus project, it stops without deleting files.

### Start the website for testing

```bash
cd ~/docusaurus-site
npm run start -- --host 0.0.0.0
```

Open `http://YOUR_SERVER_IP:3000` in your browser, replacing `YOUR_SERVER_IP` with the server IP. Keep the terminal open while testing and stop the process with `Ctrl+C`.

You can also install/build and start the development server in one step:

```bash
./install-docusaurus-v2.sh --serve
```

### If the website does not open

Check local access and the listening port:

```bash
curl -I http://127.0.0.1:3000
sudo ss -lntp | grep ':3000'
```

If local access works but remote access fails, check the operating system firewall and your VPS/provider firewall. Only expose port 3000 to trusted IP addresses for temporary testing.

Ubuntu with UFW:

```bash
sudo ufw status
sudo ufw allow 3000/tcp
```

AlmaLinux 9 with firewalld:

```bash
sudo firewall-cmd --permanent --add-port=3000/tcp
sudo firewall-cmd --reload
sudo firewall-cmd --list-ports
```

### Production hosting

Build the site:

```bash
cd ~/docusaurus-site
npm run build
```

The generated static files are in `~/docusaurus-site/build`. Configure LiteSpeed, Nginx, or another static web server to serve the **contents** of that directory. A permanent Node.js development server is not needed to serve the static output. Do not use the development server as a permanent public production service.

### Use a custom directory

```bash
./install-docusaurus-v2.sh --dir "$HOME/postgres-docs" --name postgres-docs
```

## 5. Run the other scripts

Script requirements and options may differ. Inspect each script and follow its own instructions:

```bash
less SCRIPT_NAME.sh
bash SCRIPT_NAME.sh --help
chmod +x SCRIPT_NAME.sh
./SCRIPT_NAME.sh
```

Replace `SCRIPT_NAME.sh` with the actual filename. Do not assume every script supports `--help`.

## 6. Update the repository

```bash
cd ~/tools
git pull
```

Review changes before running updated scripts, especially changes affecting repositories, firewall rules, services, or credentials.

## Troubleshooting

- **Permission denied:** Use `chmod +x SCRIPT_NAME.sh`.
- **Directory already exists:** Inspect the directory; do not delete files unless you have confirmed they are disposable.
- **Website unreachable:** Confirm the process is running, check the listening address/port, and check host and provider firewalls.
- **Package installation failure:** Check internet/DNS connectivity, repositories, and the full error output.

## Links

- GitHub repository: <https://github.com/redhatmurali/tools>
- Docusaurus installation guide: <https://docusaurus.io/docs/installation>

## Disclaimer

Review scripts and keep backups before making system changes. Test on a non-production server before using them in production.
