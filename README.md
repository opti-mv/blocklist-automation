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
- Downloads scripts + `blocklists.txt` + optional `allowlist.txt` from this repo
- Creates `/var/log/blocklist` with safe permissions
- Installs a scheduler:
  - systemd timer when available
  - cron fallback otherwise
- Runs one initial update immediately during installation (does not wait for first timer/cron slot).

- Collects all script output into a single logfile `/var/log/blocklist/blocklist.log` and configures
  `logrotate` to rotate/compress logs (managed by `install.sh`). The installed scheduler
  (`systemd` timer or cron fallback) runs both scripts and appends output into that file.

## Files

- `blocklist/blocklists.txt` – list of source URLs
- `blocklist/allowlist.txt` – optional IP/CIDR exceptions that must never be blocked
- `blocklist/download_and_create_ipsets.sh` – downloads lists and updates ipsets
- `blocklist/set-ipsets2drop.sh` – ensures iptables/ip6tables rules exist
- `install.sh` – installer used by the one-liner
- `uninstall.sh` – removes managed scheduler, rules/sets and managed files

Logging and rotation
- The installer now creates `/var/log/blocklist` and configures `/etc/logrotate.d/blocklist-automation`.
- All scripts write to `/var/log/blocklist/blocklist.log` by default. To override per-run, set the
  `BLOCKLIST_LOGFILE` environment variable before running the scripts.

nftables support
- The scripts auto-detect backend priority in this order:
  - `iptables-nft` + `ipset` (preferred)
  - native `nftables`
  - legacy `iptables` + `ipset` only as last fallback
  - To force behavior, set `USE_NFT=1` (force nft mode) or `USE_NFT=0` (force ipset mode) in the
    environment before running the scripts.
- The installer first tries to provide `iptables-nft` + `ipset`; if unavailable it uses `nft`, and only falls back to legacy `iptables` + `ipset` when nft backends are not available/installable.
- To avoid collisions, blocklist sets are prefixed by default (`BLOCKLIST_SET_PREFIX=blklst_`).
- In nft mode, sets/rules are managed in `inet blocklist_auto` (`BLOCKLIST_NFT_TABLE`) and chain
  `input_blocklist` (`BLOCKLIST_NFT_CHAIN`).

Allowlist support
- Place trusted IPs/CIDRs in `/opt/blocklist/allowlist.txt` (or set `BLOCKLIST_ALLOWLIST_FILE`).
- Matching entries are removed from all downloaded blocklists before sets are updated.

Hash-based updates
- The downloader stores a SHA-256 hash per managed set in `/var/lib/blocklist` (override with `BLOCKLIST_STATE_DIR`).
- Sets are only updated when the final normalized entries actually changed.

Cron behavior
- If systemd is unavailable, existing root crontab entries are preserved and only a managed block is added/updated.
- Cron fallback schedule is twice daily (`*/12`) at a host-randomized minute; override with `CRON_SCHEDULE`.
- With systemd, the timer runs at 00:00 and 12:00 with randomized delay (`RandomizedDelaySec=30m`).

## Notes / assumptions

- Designed for hosts with either `nftables` or `ipset`+`iptables`/`ip6tables`.
- Source of blocklist files: https://ipv64.net/v64_blocklists
  - Hint: The source provides additional blocklists and also GeoBlocklists. If you want to use them, add the corresponding URLs to `blocklist/blocklists.txt` (and re-run the installer or wait for the next cron run).
- Requires privileges to manage firewall sets/rules (root).

Uninstall
- Run `sudo /opt/blocklist/uninstall.sh`
- Optional: `REMOVE_LOGS=1 sudo /opt/blocklist/uninstall.sh` to remove `/var/log/blocklist` as well.
