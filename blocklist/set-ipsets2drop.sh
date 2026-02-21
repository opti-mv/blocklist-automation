#!/usr/bin/env bash

set -Eeuo pipefail

LOG_DIR="/var/log/blocklist"
# Write to unified logfile so all runs are collected in one place
LOGFILE_DEFAULT="${LOG_DIR}/blocklist.log"
LOGFILE="${BLOCKLIST_LOGFILE:-$LOGFILE_DEFAULT}"

mkdir -p "$LOG_DIR"
chmod 750 "$LOG_DIR" || true

ts() { date "+%F %T%z"; }
log() { echo "[$(ts)] $*"; }

# Redirect all stdout/stderr to the unified logfile
exec >>"$LOGFILE" 2>&1

log "[*] ensure firewall DROP rules for blocklists (ipset or nftables)"

# Detect mode: if USE_NFT=1 => nft, 0 => iptables/ipset, auto => prefer ipset if present else nft
USE_NFT="${USE_NFT:-auto}"
detect_nft_mode() {
  if [[ "$USE_NFT" == "1" ]]; then
    nft_mode=1
  elif [[ "$USE_NFT" == "0" ]]; then
    nft_mode=0
  else
    if command -v ipset >/dev/null 2>&1; then
      nft_mode=0
    elif command -v nft >/dev/null 2>&1; then
      nft_mode=1
    else
      log "ERROR: neither ipset nor nft available"
      exit 1
    fi
  fi
}

detect_nft_mode

if [[ "$nft_mode" -eq 0 ]]; then
  log "[*] using ipset + iptables path"
  IPSET_SAVE="$(ipset save)"
  for SET in $(ipset list -name); do
    FAMILY=$(echo "$IPSET_SAVE" \
      | grep -E "^create ${SET} " \
      | awk -F"family " '{print $2}' \
      | awk '{print $1}')

    if [[ "$FAMILY" == "inet6" ]]; then
      IPT_CMD="ip6tables"
    else
      IPT_CMD="iptables"
    fi

    log "[] check DROP rule for ipset $SET"

    if $IPT_CMD -C INPUT -m set --match-set "$SET" src -j DROP 2>/dev/null; then
      log "  rule exists"
    else
      log "  inserting rule"
      $IPT_CMD -I INPUT -m set --match-set "$SET" src -j DROP
    fi
  done

else
  log "[*] using nftables-native path"
  # Ensure table and chain exist
  nft add table inet blocklist 2>/dev/null || true
  nft list chain inet blocklist input >/dev/null 2>&1 || \
    nft add chain inet blocklist input '{ type filter hook input priority 0; }'

  # Use blocklists file when available to derive set names (same naming logic as downloader)
  BLOCKLIST_DIR="${BLOCKLIST_DIR:-/opt/blocklist}"
  URL_FILE="$BLOCKLIST_DIR/blocklists.txt"
  if [[ -f "$URL_FILE" ]]; then
    while IFS= read -r url; do
      url="${url//[[:space:]]/}"
      [[ -z "$url" || "$url" == \#* ]] && continue
      fname="$(basename "$url")"
      base="${fname%.txt}"
      base="${base#blocklist_}"
      setname="${base:0:31}"

      # Detect set type by naming convention used in downloader
      if [[ "$base" == *_v6_* ]]; then
        expr_type="ip6 saddr @${setname} drop"
        check_cmd="nft list ruleset | grep -F \"ip6 saddr @${setname}\" || true"
      else
        expr_type="ip saddr @${setname} drop"
        check_cmd="nft list ruleset | grep -F \"ip saddr @${setname}\" || true"
      fi

      if eval "$check_cmd" | grep -q .; then
        log "  nft rule exists for set $setname"
      else
        log "  adding nft rule for set $setname"
        if [[ "$base" == *_v6_* ]]; then
          nft add rule inet blocklist input ip6 saddr @${setname} drop || true
        else
          nft add rule inet blocklist input ip saddr @${setname} drop || true
        fi
      fi
    done < "$URL_FILE"
  else
    log "WARNING: $URL_FILE not found — cannot enumerate nft sets to install rules"
  fi
fi

log "[✓] firewall rules checked/ensured"
