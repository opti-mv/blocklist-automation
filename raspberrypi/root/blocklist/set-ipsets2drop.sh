#!/usr/bin/env bash

set -Eeuo pipefail

LOG_DIR="/var/log/blocklist"
LOGFILE_DEFAULT="${LOG_DIR}/blocklist_rules_$(date +%F).log"
LOGFILE="${BLOCKLIST_LOGFILE:-$LOGFILE_DEFAULT}"

mkdir -p "$LOG_DIR"
chmod 750 "$LOG_DIR" || true

ts() { date "+%F %T%z"; }
log() { echo "[$(ts)] $*"; }

exec >>"$LOGFILE" 2>&1

log "[*] ensure iptables/ip6tables DROP rules for ipsets"

IPSET_SAVE="$(ipset save)"

for SET in $(ipset list -name); do
  FAMILY=$(echo "$IPSET_SAVE" \
    | grep -E "^create ${SET} " \
    | awk -F"family " "{print \$2}" \
    | awk "{print \$1}")

  if [[ "$FAMILY" == "inet6" ]]; then
    IPT_CMD="ip6tables"
    VERSION="IPv6"
  else
    IPT_CMD="iptables"
    VERSION="IPv4"
  fi

  log "[] check DROP rule for ipset "

  if $IPT_CMD -C INPUT -m set --match-set "$SET" src -j DROP 2>/dev/null; then
    log "  rule exists"
  else
    log "  inserting rule"
    $IPT_CMD -I INPUT -m set --match-set "$SET" src -j DROP
  fi
done

log "[✓] rules checked/set"
