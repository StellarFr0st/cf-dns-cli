# Cloudflare DNS CLI Installer & Uninstaller (Linux)

This provides two helper scripts for managing the **Cloudflare DNS CLI** tool:

- `install.sh` → Installs the Cloudflare DNS CLI from GitHub, configures your environment, and optionally sets up an hourly cron job.
- `uninstall.sh` → Cleanly removes the CLI, environment variables, and cron jobs created by the installer.

## Installation

Download the scripts and make them executable:

```bash
wget -O install.sh https://raw.githubusercontent.com/<YOUR_USERNAME>/<YOUR_REPO>/main/install.sh
wget -O uninstall.sh https://raw.githubusercontent.com/<YOUR_USERNAME>/<YOUR_REPO>/main/uninstall.sh
chmod +x install.sh uninstall.sh
```

Run the installer:

```bash
./install.sh
```

The installer will:
1. Download the main script (`cf-dns-cli.sh`) from your GitHub repo (placeholder URL inside `install.sh`).
2. Place it at `/usr/local/bin/cf-dns`.
3. Prompt you for your **Cloudflare API token** (hidden input) and **default zone**.
4. Save them to `~/.bashrc` and **source** it immediately.
5. Offer to install an **hourly cron** (default **Yes**) that runs:
   ```
   0 * * * * /usr/local/bin/cf-dns update --type A >> /var/log/cf-dns-update.log 2>&1
   ```

## Uninstall

```bash
./uninstall.sh
```
This will remove the cron entry, delete `/usr/local/bin/cf-dns`, remove env vars from `~/.bashrc` (backup created), and optionally remove the log file.

## Requirements

- Linux
- `wget` (preferred) or `curl`
- `bash`, `jq`
- Cloudflare API token with DNS edit permissions
