#!/usr/bin/env bash

set -Eeuo pipefail

LOG_DIR="/var/log/blocklist"
# Write to unified logfile so all runs are collected in one place
LOGFILE_DEFAULT="${LOG_DIR}/blocklist.log"
LOGFILE="${BLOCKLIST_LOGFILE:-$LOGFILE_DEFAULT}"
MAX_NAME_LEN=31
SET_PREFIX="${BLOCKLIST_SET_PREFIX:-blklst_}"
NFT_TABLE="${BLOCKLIST_NFT_TABLE:-blocklist_auto}"
NFT_CHAIN="${BLOCKLIST_NFT_CHAIN:-input_blocklist}"
BLOCKLIST_DIR="${BLOCKLIST_DIR:-/opt/blocklist}"
URL_FILE="$BLOCKLIST_DIR/blocklists.txt"

mkdir -p "$LOG_DIR"
chmod 750 "$LOG_DIR" || true

ts() { date "+%F %T%z"; }
log() { echo "[$(ts)] $*"; }
sanitize_set_base() {
  local input="$1"
  local cleaned
  cleaned="$(printf '%s' "$input" | tr -c '[:alnum:]_' '_' | tr '[:upper:]' '[:lower:]')"
  while [[ "$cleaned" == _* ]]; do cleaned="${cleaned#_}"; done
  while [[ "$cleaned" == *_ ]]; do cleaned="${cleaned%_}"; done
  [[ -z "$cleaned" ]] && cleaned="set"
  echo "$cleaned"
}
build_set_name() {
  local base="$1"
  local max_base_len=$((MAX_NAME_LEN - ${#SET_PREFIX}))
  local safe_base
  (( max_base_len > 0 )) || { log "ERROR: BLOCKLIST_SET_PREFIX too long"; exit 1; }
  safe_base="$(sanitize_set_base "$base")"
  echo "${SET_PREFIX}${safe_base:0:$max_base_len}"
}

# Redirect all stdout/stderr to the unified logfile
exec >>"$LOGFILE" 2>&1

log "[*] ensure firewall DROP rules for blocklists (ipset or nftables)"

# Detect mode: if USE_NFT=1 => nft, 0 => iptables/ipset, auto => prefer ipset+iptables else nft
USE_NFT="${USE_NFT:-auto}"
detect_nft_mode() {
  if [[ "$USE_NFT" == "1" ]]; then
    nft_mode=1
  elif [[ "$USE_NFT" == "0" ]]; then
    nft_mode=0
  else
    # auto: prefer ipset only when iptables is available as well.
    if command -v ipset >/dev/null 2>&1 && command -v iptables >/dev/null 2>&1; then
      nft_mode=0
    elif command -v nft >/dev/null 2>&1; then
      nft_mode=1
    else
      nft_mode=1
    fi
  fi
}

detect_nft_mode

rules_added=0
rules_existing=0
rules_failed=0
sets_missing=0

if [[ "$nft_mode" -eq 0 ]]; then
  log "[*] using ipset + iptables path"
  [[ -f "$URL_FILE" ]] || { log "WARNING: $URL_FILE not found — no managed sets to process"; exit 0; }

  while IFS= read -r url; do
    url="${url//[[:space:]]/}"
    [[ -z "$url" || "$url" == \#* ]] && continue
    fname="$(basename "$url")"
    base="${fname%.txt}"
    base="${base#blocklist_}"
    setname="$(build_set_name "$base")"

    if ! ipset list "$setname" >/dev/null 2>&1; then
      log "  set not found (skipped): $setname"
      sets_missing=$((sets_missing + 1))
      continue
    fi

    if [[ "$base" == *_v6_* ]]; then
      IPT_CMD="ip6tables"
    else
      IPT_CMD="iptables"
    fi

    if ! command -v "$IPT_CMD" >/dev/null 2>&1; then
      log "  command not found (skipped): $IPT_CMD for set $setname"
      continue
    fi

    log "[] check DROP rule for ipset $setname"

    if $IPT_CMD -C INPUT -m set --match-set "$setname" src -j DROP 2>/dev/null; then
      log "  rule exists"
      rules_existing=$((rules_existing + 1))
    else
      log "  inserting rule"
      if $IPT_CMD -I INPUT -m set --match-set "$setname" src -j DROP 2>/dev/null; then
        rules_added=$((rules_added + 1))
      else
        log "  failed to insert rule for $setname via $IPT_CMD"
        rules_failed=$((rules_failed + 1))
      fi
    fi
  done < "$URL_FILE"

else
  log "[*] using nftables-native path"
  command -v nft >/dev/null || { log "ERROR: nft not installed (auto selected nft mode)"; exit 1; }
  # Ensure table and chain exist
  nft add table inet "$NFT_TABLE" 2>/dev/null || true
  nft list chain inet "$NFT_TABLE" "$NFT_CHAIN" >/dev/null 2>&1 || \
    nft add chain inet "$NFT_TABLE" "$NFT_CHAIN" '{ type filter hook input priority 0; }'

  # Use blocklists file when available to derive set names (same naming logic as downloader)
  if [[ -f "$URL_FILE" ]]; then
    while IFS= read -r url; do
      url="${url//[[:space:]]/}"
      [[ -z "$url" || "$url" == \#* ]] && continue
      fname="$(basename "$url")"
      base="${fname%.txt}"
      base="${base#blocklist_}"
      setname="$(build_set_name "$base")"

      # Detect set type by naming convention used in downloader
      if [[ "$base" == *_v6_* ]]; then
        if nft list chain inet "$NFT_TABLE" "$NFT_CHAIN" 2>/dev/null | grep -F "ip6 saddr @${setname}" >/dev/null; then
          log "  nft rule exists for set $setname"
        else
          log "  adding nft rule for set $setname"
          nft add rule inet "$NFT_TABLE" "$NFT_CHAIN" ip6 saddr @${setname} drop || true
        fi
      else
        if nft list chain inet "$NFT_TABLE" "$NFT_CHAIN" 2>/dev/null | grep -F "ip saddr @${setname}" >/dev/null; then
          log "  nft rule exists for set $setname"
        else
          log "  adding nft rule for set $setname"
          nft add rule inet "$NFT_TABLE" "$NFT_CHAIN" ip saddr @${setname} drop || true
        fi
      fi
    done < "$URL_FILE"
  else
    log "WARNING: $URL_FILE not found — cannot enumerate nft sets to install rules"
  fi
fi

log "[✓] firewall rules checked/ensured"
if [[ "$nft_mode" -eq 0 ]]; then
  log "[*] summary: existing=$rules_existing added=$rules_added failed=$rules_failed sets_missing=$sets_missing"
fi
