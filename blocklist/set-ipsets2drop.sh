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
require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "[blocklist] ERROR: must run as root (sudo)" >&2
    exit 1
  fi
}
init_logging() {
  local fallback_log="/tmp/blocklist.log"
  if touch "$LOGFILE" 2>/dev/null; then
    exec >>"$LOGFILE" 2>&1
  elif touch "$fallback_log" 2>/dev/null; then
    LOGFILE="$fallback_log"
    exec >>"$LOGFILE" 2>&1
    log "[!] cannot write default logfile; using fallback: $LOGFILE"
  else
    echo "[blocklist] ERROR: cannot open logfile '$LOGFILE' or fallback '$fallback_log'" >&2
    exit 1
  fi
}
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
iptables_uses_nft_backend() {
  command -v iptables >/dev/null 2>&1 || return 1
  iptables -V 2>/dev/null | grep -qi "nf_tables"
}

require_root
init_logging

log "[*] ensure firewall DROP rules for blocklists (ipset or nftables)"

# Backend selection:
# - USE_NFT=1: force nft mode
# - USE_NFT=0: force ipset+iptables mode
# - auto (default): prefer iptables-nft+ipset, then nft-native, then legacy iptables+ipset fallback
USE_NFT="${USE_NFT:-auto}"
detect_nft_mode() {
  if [[ "$USE_NFT" == "1" ]]; then
    nft_mode=1
  elif [[ "$USE_NFT" == "0" ]]; then
    nft_mode=0
  else
    if command -v ipset >/dev/null 2>&1 && iptables_uses_nft_backend; then
      nft_mode=0
      mode_reason="iptables-nft+ipset"
    elif command -v nft >/dev/null 2>&1; then
      nft_mode=1
      mode_reason="nft-native"
    elif command -v ipset >/dev/null 2>&1 && command -v iptables >/dev/null 2>&1; then
      nft_mode=0
      mode_reason="legacy iptables+ipset fallback"
    else
      nft_mode=1
      mode_reason="auto-default to nft"
    fi
  fi
}

detect_nft_mode

if [[ "$nft_mode" -eq 0 ]]; then
  log "[*] using ipset + iptables path${mode_reason:+ ($mode_reason)}"
  if [[ ! -f "$URL_FILE" ]]; then
    alt_url_file="$(dirname "$0")/blocklists.txt"
    if [[ -f "$alt_url_file" ]]; then
      URL_FILE="$alt_url_file"
      log "[*] using local blocklists file: $URL_FILE"
    else
      log "WARNING: $URL_FILE not found — no managed sets to process"
      exit 0
    fi
  fi

  while IFS= read -r url; do
    url="${url//[[:space:]]/}"
    [[ -z "$url" || "$url" == \#* ]] && continue
    fname="$(basename "$url")"
    base="${fname%.txt}"
    base="${base#blocklist_}"
    setname="$(build_set_name "$base")"

    if ! ipset list "$setname" >/dev/null 2>&1; then
      if [[ "$base" == *_v6_* ]]; then
        set_family="inet6"
      else
        set_family="inet"
      fi
      log "  set not found, creating: $setname (family=$set_family)"
      if ! ipset create "$setname" hash:net family "$set_family" hashsize 16384 maxelem 131072 -exist 2>/dev/null; then
        log "  failed to create set (skipped): $setname"
        continue
      fi
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
    else
      log "  inserting rule"
      $IPT_CMD -I INPUT -m set --match-set "$setname" src -j DROP
    fi
  done < "$URL_FILE"

else
  log "[*] using nftables-native path${mode_reason:+ ($mode_reason)}"
  command -v nft >/dev/null || { log "ERROR: nft not installed (auto selected nft mode)"; exit 1; }
  # Ensure table and chain exist
  nft add table inet "$NFT_TABLE" 2>/dev/null || true
  nft list chain inet "$NFT_TABLE" "$NFT_CHAIN" >/dev/null 2>&1 || \
    nft add chain inet "$NFT_TABLE" "$NFT_CHAIN" '{ type filter hook input priority 0; }'

  # Use blocklists file when available to derive set names (same naming logic as downloader)
  if [[ ! -f "$URL_FILE" ]]; then
    alt_url_file="$(dirname "$0")/blocklists.txt"
    if [[ -f "$alt_url_file" ]]; then
      URL_FILE="$alt_url_file"
      log "[*] using local blocklists file: $URL_FILE"
    fi
  fi

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
