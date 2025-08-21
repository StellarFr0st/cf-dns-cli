# Cloudflare DNS CLI

A single-file Bash tool to **list, add, update, and remove** Cloudflare DNS records — with **idempotent updates** (it only changes records that actually need changing).

- ✅ Supports: **A, AAAA, CNAME, TXT, MX, NS, SRV, CAA**
- ✅ **Idempotent**: skips updates if the current record already matches desired content / TTL / proxied (and priority/data where applicable)
- ✅ Bulk update for **A/AAAA** (e.g., update all A records to your current public IP)
- ✅ Works from Linux with `bash`, `curl`, `jq`
- ✅ Proxy defaults to **false**

## Requirements

- Linux
- `bash`, `curl`, `jq`  
  (The script silently checks and tries to install `curl` and `jq` using your package manager. If it can’t, it exits with an error.)

## Install

1) Save the script as `cf-dns-cli.sh` and make it executable:
```bash
chmod +x cf-dns-cli.sh
```

2) (Optional) Move it to your PATH:
```bash
sudo mv cf-dns-cli.sh /usr/local/bin/cf-dns
```

Now you can run it as `./cf-dns-cli.sh` or simply `cf-dns` if you moved it.

## Configuration

Set two environment variables so the script can talk to Cloudflare:

- `CF_API_TOKEN` — a Cloudflare API **Token** with DNS edit permissions for your zone
- `CF_DEFAULT_ZONE` — your zone name (e.g., `example.com`)

You can export them in your shell rc (e.g., `~/.bashrc`):

```bash
export CF_API_TOKEN="your_cloudflare_api_token_here"
export CF_DEFAULT_ZONE="example.com"
```

Reload your shell:
```bash
source ~/.bashrc
```

> You can override the default zone per command with `-z/--zone`.

## Usage

### Help

```bash
./cf-dns-cli.sh --help
```

```
Usage:
  cloudflare-dns-cli.sh <subcommand> [options] [...]

Subcommands:
  list                          List records (all types or filter with --type)
  add     --type TYPE  ARGS...  Create a record of TYPE
  update  --type TYPE  ARGS...  Update record(s) of TYPE (idempotent)
  remove  --type TYPE  NAMES... Remove record(s) of TYPE

Common options:
  -z, --zone ZONE               Zone (default from CF_DEFAULT_ZONE or script)
  --type TYPE                   A, AAAA, CNAME, TXT, MX, NS, SRV, CAA
  --ttl SECONDS                 TTL (default 300; 1 = Auto)
  --proxied true|false          (A/AAAA/CNAME) default false
  --force                       Skip confirmation on remove
  -h, --help                    Show this help
```

Type-specific args:
- **A**: `add/update: NAMES... [--ip IPv4]` (auto-detects if omitted)  
  *(update with **no names** updates **all A** in the zone)*
- **AAAA**: `add/update: NAMES... [--ip6 IPv6]` (auto-detects if omitted)  
  *(update with **no names** updates **all AAAA** in the zone)*
- **CNAME**: `add/update: NAME TARGET` (repeat pairs)
- **TXT**: `add/update: NAME VALUE` (repeat pairs; quote VALUE)
- **MX**: `add/update: NAME EXCHANGE [--priority N]` (repeat pairs)
- **NS**: `add/update: NAME HOST` (repeat pairs)
- **SRV**: `add/update: NAME --service _svc --proto _tcp|_udp --target HOST [--priority N] [--weight N] [--port N]`
- **CAA**: `add/update: NAME --caa-flag 0|128 --caa-tag issue|issuewild|iodef --caa-value VALUE`

### List records

List everything:
```bash
./cf-dns-cli.sh list
```

Filter by type (e.g., only A):
```bash
./cf-dns-cli.sh list --type A
```

### Add records

Add A records (auto-detect public IPv4). `@` means the root (`example.com`):
```bash
./cf-dns-cli.sh add --type A @ www api
```

Add AAAA with explicit IPv6:
```bash
./cf-dns-cli.sh add --type AAAA --ip6 "2001:db8::1" @ www
```

Add a CNAME:
```bash
./cf-dns-cli.sh add --type CNAME blog blog.hosted.example.net
```

Add a TXT (quote the value if it has spaces):
```bash
./cf-dns-cli.sh add --type TXT _acme-challenge "challenge-token"
```

Add an MX:
```bash
./cf-dns-cli.sh add --type MX --priority 10 @ mx1.mailhost.com
```

Add an NS:
```bash
./cf-dns-cli.sh add --type NS sub ns1.provider.net
```

Add an SRV:
```bash
./cf-dns-cli.sh add --type SRV service   --service _sip --proto _udp --target sip.provider.net   --priority 10 --weight 5 --port 5060
```

Add a CAA:
```bash
./cf-dns-cli.sh add --type CAA @ --caa-flag 0 --caa-tag issue --caa-value "letsencrypt.org"
```

### Update records (idempotent)

Update all **A** records to your current public IPv4:
```bash
./cf-dns-cli.sh update --type A
```

Update specific A names (auto-detect IP):
```bash
./cf-dns-cli.sh update --type A @ www
```

Update AAAA with provided IP:
```bash
./cf-dns-cli.sh update --type AAAA --ip6 "2001:db8::2" @ www
```

Update CNAME:
```bash
./cf-dns-cli.sh update --type CNAME blog blog.hosted.example.net
```

Update TXT:
```bash
./cf-dns-cli.sh update --type TXT _acme-challenge "new-token"
```

Update MX (exchange + priority):
```bash
./cf-dns-cli.sh update --type MX --priority 10 @ mx1.mailhost.com
```

Update NS:
```bash
./cf-dns-cli.sh update --type NS sub ns2.provider.net
```

Update SRV:
```bash
./cf-dns-cli.sh update --type SRV service   --service _sip --proto _udp --target sip.new.net   --priority 20 --weight 10 --port 5061
```

Update CAA:
```bash
./cf-dns-cli.sh update --type CAA @ --caa-flag 0 --caa-tag issue --caa-value "letsencrypt.org"
```

> **Proxied & TTL**:  
> - You can pass `--proxied true|false` (A/AAAA/CNAME). Default is **false**.  
> - You can pass `--ttl N` (default 300; `1` means “Auto” in Cloudflare’s API).

### Remove records

Remove one or more names (confirmation prompt by default):
```bash
./cf-dns-cli.sh remove --type A www api
```

Force remove (no prompt):
```bash
./cf-dns-cli.sh remove --type TXT --force _acme-challenge
```

## Cron (Auto Update)

Update **all A records** every hour to your server’s current public IPv4:

```bash
# open your crontab
crontab -e

# add this line (adjust path if you moved the script to /usr/local/bin/cf-dns)
0 * * * * /usr/local/bin/cf-dns update --type A >> /var/log/cf-dns-update.log 2>&1
```

- This is **idempotent**: if your IP hasn’t changed, it logs “No change” and skips updating.
- Make sure your environment variables (`CF_API_TOKEN`, `CF_DEFAULT_ZONE`) are available to cron.

## Idempotency Details

- **A/AAAA**: compares `content` (IP), `proxied`, `ttl`
- **CNAME**: compares `content` (target), `proxied`, `ttl`
- **TXT**: compares `content` (value), `ttl`
- **MX**: compares `content` (exchange), `priority`, `ttl`
- **NS**: compares `content` (host), `ttl`
- **SRV**: compares `data.service`, `data.proto`, `data.target`, `data.priority`, `data.weight`, `data.port`, `ttl`
- **CAA**: compares `data.flags`, `data.tag`, `data.value`, `ttl`

When nothing needs to change, output shows `No change: ...` and no API call is made. Bulk summary prints accurate `changed` and `skipped` counts.

## Troubleshooting

- Ensure `CF_API_TOKEN` and `CF_DEFAULT_ZONE` are set and valid.
- Cron uses a minimal environment; set env vars in a file it sources or embed them in the job.
- If your counters seem wrong, update to this version (bulk counters fixed).

## Security Notes

- Your `CF_API_TOKEN` grants DNS write access. Restrict file permissions.
- If logging to `/var/log/cf-dns-update.log`, ensure mode `600`.
