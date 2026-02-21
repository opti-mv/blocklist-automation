# blocklist-automation

Goal: One-liner installation that sets up the blocklist on (multiple) Linux hosts.

## One-liner install

Run as root (or with sudo):

```bash
curl -fsSL https://raw.githubusercontent.com/opti-mv/blocklist-automation/main/install.sh | sudo bash
```

## What it does

- Installs required packages (Debian/Ubuntu via apt; best-effort)
- Creates `/root/blocklist`
- Downloads scripts + `blocklists.txt` from this repo
- Creates `/var/log/blocklist` with safe permissions
- Installs/updates a root crontab entry to refresh ipsets and ensure iptables/ip6tables DROP rules

## Files

- `blocklist/blocklists.txt` – list of source URLs
- `blocklist/download_and_create_ipsets.sh` – downloads lists and updates ipsets
- `blocklist/set-ipsets2drop.sh` – ensures iptables/ip6tables rules exist
- `install.sh` – installer used by the one-liner

## Notes / assumptions

- Designed for hosts using `iptables`/`ip6tables` (not nftables-only).
- Requires privileges to manage ipset + firewall rules (root).
