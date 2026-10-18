# Linux Installation Scripts

Scripts for Ubuntu and AlmaLinux. Review each script before running it.

## Install

```bash
git clone https://github.com/redhatmurali/tools.git
cd tools
ls -lh
```

Run a script (example: Docusaurus):

```bash
chmod +x install-docusaurus-v2.sh
./install-docusaurus-v2.sh
```

## Docusaurus

Supports Ubuntu 22.04+ and AlmaLinux 9.x. Installs Node.js 22 LTS, creates/builds the site in `~/docusaurus-site`.

Start for testing:

```bash
cd ~/docusaurus-site
npm run start -- --host 0.0.0.0
```

Open `http://YOUR_SERVER_IP:3000`. Check the server firewall if it does not open. For production, serve the contents of `~/docusaurus-site/build` using LiteSpeed or Nginx.

## Other scripts

Check each script's requirements and options before running it:

```bash
less SCRIPT_NAME.sh
```

Repository: https://github.com/redhatmurali/tools
