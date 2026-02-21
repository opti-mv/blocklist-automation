#!/usr/bin/env bash

# download_and_create_ipsets.sh
# Aktualisiert ipset-Sets basierend auf heruntergeladenen IP/CIDR-Listen.
# Vorhandene Sets werden geleert und neu befüllt, aber nicht gelöscht.
# Unterstützt IPv4 & IPv6.
# Usage: ./download_and_create_ipsets.sh <url-list-file>

set -Eeuo pipefail

########################################
# Konfiguration
########################################
FACTOR=8          # Max elements = COUNT * FACTOR
MAX_NAME_LEN=31   # Max. ipset-Name
URL_FILE="${1:-}"

LOG_DIR="/var/log/blocklist"
# Use a single logfile for all scripts to simplify collection/rotation
LOGFILE_DEFAULT="${LOG_DIR}/blocklist.log"
LOGFILE="${BLOCKLIST_LOGFILE:-$LOGFILE_DEFAULT}"

########################################
# Logging
########################################
mkdir -p "$LOG_DIR"
chmod 750 "$LOG_DIR" || true

ts() { date "+%F %T%z"; }
log() { echo "[$(ts)] $*"; }

# Redirect all stdout/stderr to the unified logfile
exec >>"$LOGFILE" 2>&1

TMPDIR="$(mktemp -d)"
cleanup() {
  rc=$?
  rm -rf "$TMPDIR" 2>/dev/null || true
  if [[ $rc -eq 0 ]]; then
    log "[✓] done"
  else
    log "[!] failed (rc=$rc)"
  fi
  exit $rc
}
trap cleanup EXIT

########################################
# Hilfsfunktionen
########################################
error() {
  log "[!] Error: $*"
  exit 1
}
next_pow2() {
  local v=$1 p=1
  while (( p < v )); do
    p=$((p << 1))
  done
  echo "$p"
}

########################################
# Validierung & Feature-detection
########################################
[[ -z "$URL_FILE" ]] && error "Usage: $0 <url-list-file>"
[[ ! -f "$URL_FILE" ]] && error "File  not found"
command -v curl  >/dev/null || error "curl not installed"

# nft vs ipset selection: set USE_NFT=1 to force nft-mode, 0 to force ipset-mode, or auto-detect
USE_NFT="${USE_NFT:-auto}"
detect_nft_mode() {
  if [[ "$USE_NFT" == "1" ]]; then
    nft_mode=1
  elif [[ "$USE_NFT" == "0" ]]; then
    nft_mode=0
  else
    # auto: prefer ipset if available, otherwise use nft when present
    if command -v ipset >/dev/null 2>&1; then
      nft_mode=0
    elif command -v nft >/dev/null 2>&1; then
      nft_mode=1
    else
      error "neither ipset nor nft found"
    fi
  fi
}

detect_nft_mode

if [[ "$nft_mode" -eq 1 ]]; then
  log "[*] operating in nftables-native mode"
else
  command -v ipset >/dev/null || error "ipset not installed"
  log "[*] operating in ipset mode"
fi

log "[*] temp dir: $TMPDIR"

########################################
# Hauptschleife
########################################
while IFS= read -r url; do
  url="${url//[[:space:]]/}"
  [[ -z "$url" || "$url" == \#* ]] && continue

  fname="$(basename "$url")"
  base="${fname%.txt}"
  base="${base#blocklist_}"
  setname="${base:0:$MAX_NAME_LEN}"

  if [[ "$base" == *_v6_* ]]; then
    family=inet6
    grep_regex="[0-9A-Fa-f:]+(/[0-9]{1,3})?"
    nft_type="ipv6_addr"
  else
    family=inet
    grep_regex="[0-9]+(\\.[0-9]+){3}(/[0-9]{1,2})?"
    nft_type="ipv4_addr"
  fi

  log "[*] processing: $fname -> ipset  ($family)"

  out_file="$TMPDIR/$fname"
  if ! curl -fsSL "$url" -o "$out_file"; then
    log "[!] download failed: $url (skipped)"
    continue
  fi

  mapfile -t entries < <(grep -E "^${grep_regex}$" "$out_file" | sort -u)
  count=${#entries[@]}
  if (( count == 0 )); then
    log "[!] no valid entries in $fname (skipped)"
    continue
  fi

  maxelem=$(( count * FACTOR ))
  hashsize=$(next_pow2 "$maxelem")
  log "[*] $count valid entries -> hashsize=$hashsize maxelem=$maxelem"

  if [[ "$nft_mode" -eq 1 ]]; then
    # nftables-native: ensure table exists and create/flush set
    nft add table inet blocklist 2>/dev/null || true
    if nft list set inet blocklist "$setname" >/dev/null 2>&1; then
      log "[*] nft set exists -> flush: $setname"
      nft flush set inet blocklist "$setname" 2>/dev/null || true
    else
      log "[*] creating nft set $setname (type=$nft_type)"
      nft add set inet blocklist "$setname" "{ type $nft_type ; flags interval ; }" || true
    fi

    # add elements
    for entry in "${entries[@]}"; do
      if ! nft add element inet blocklist "$setname" "{ $entry }" 2>/dev/null; then
        log "[!] nft add element failed for $entry"
      fi
    done

  else
    if ipset list "$setname" &>/dev/null; then
      log "[*] set exists -> flush"
      ipset flush "$setname"
    else
      log "[*] creating set"
      ipset create "$setname" hash:net family "$family" hashsize "$hashsize" maxelem "$maxelem"
    fi

    for entry in "${entries[@]}"; do
      if ! ipset add "$setname" "$entry"; then
        log "[!] add failed for $entry (set may be full)"
        break
      fi
    done
  fi

done < "$URL_FILE"

log "[✓] ipsets updated"
