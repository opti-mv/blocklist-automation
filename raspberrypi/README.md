# Raspberry Pi blocklist automation

Source host: `root@raspberrypi`

## Cron

See: `raspberrypi/root/crontab.txt`

Relevant entry (from that file):

- Runs hourly:
  - `cd /root/blocklist && ./download_and_create_ipsets.sh blocklists.txt && ./set-ipsets2drop.sh`
  - Appends logs to: `/var/log/blocklist/blocklist_<YYYY-MM-DD>.log`

## Files synced

- `/root/blocklist/blocklists.txt`
- `/root/blocklist/download_and_create_ipsets.sh`
- `/root/blocklist/set-ipsets2drop.sh`

## Notes

- Scripts use `ipset`, `iptables`, `ip6tables`.
- Be careful committing secrets: these files currently contain no obvious tokens.
