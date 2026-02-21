# blocklist-automation

Goal: One-liner installation that sets up the blocklist on (multiple) Linux hosts.

## One-liner install

Run as root (or with sudo):

```bash
curl -fsSL https://raw.githubusercontent.com/opti-mv/blocklist-automation/main/install.sh | sudo bash
```

## What it does

- Installs required packages (Debian/Ubuntu via apt; best-effort)
- Creates `/opt/blocklist`
- Downloads scripts + `blocklists.txt` from this repo
- Creates `/var/log/blocklist` with safe permissions
- Installs/updates a root crontab entry to refresh ipsets and ensure iptables/ip6tables DROP rules

- Collects all script output into a single logfile `/var/log/blocklist/blocklist.log` and configures
  `logrotate` to rotate/compress logs (managed by `install.sh`). The crontab entry is updated to
  append both `download_and_create_ipsets.sh` and `set-ipsets2drop.sh` output into that file.

## Files

- `blocklist/blocklists.txt` – list of source URLs
- `blocklist/download_and_create_ipsets.sh` – downloads lists and updates ipsets
- `blocklist/set-ipsets2drop.sh` – ensures iptables/ip6tables rules exist
- `install.sh` – installer used by the one-liner

Logging and rotation
- The installer now creates `/var/log/blocklist` and configures `/etc/logrotate.d/blocklist-automation`.
- All scripts write to `/var/log/blocklist/blocklist.log` by default. To override per-run, set the
  `BLOCKLIST_LOGFILE` environment variable before running the scripts.

nftables support
- The scripts now auto-detect whether to use traditional `ipset`+`iptables` or native `nftables`.
  - Default detection: prefer `ipset` if present; otherwise use `nft`.
  - To force behavior, set `USE_NFT=1` (force nft mode) or `USE_NFT=0` (force ipset mode) in the
    environment before running the scripts.
- When operating in nft mode the downloader creates `nft` sets under table `inet blocklist` and the
  rules installer adds matching drop rules into the `inet blocklist` table's `input` chain.

## Notes / assumptions

- Designed for hosts using `iptables`/`ip6tables` (not nftables-only).
- Source of blocklist files: https://ipv64.net/v64_blocklists
  - Hint: The source provides additional blocklists and also GeoBlocklists. If you want to use them, add the corresponding URLs to `blocklist/blocklists.txt` (and re-run the installer or wait for the next cron run).
- Requires privileges to manage ipset + firewall rules (root).
