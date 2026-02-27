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
SET_PREFIX="${BLOCKLIST_SET_PREFIX:-blklst_}"
NFT_TABLE="${BLOCKLIST_NFT_TABLE:-blocklist_auto}"
ALLOWLIST_FILE_DEFAULT="$(dirname "$URL_FILE")/allowlist.txt"
ALLOWLIST_FILE="${BLOCKLIST_ALLOWLIST_FILE:-$ALLOWLIST_FILE_DEFAULT}"

LOG_DIR="/var/log/blocklist"
# Use a single logfile for all scripts to simplify collection/rotation
LOGFILE_DEFAULT="${LOG_DIR}/blocklist.log"
LOGFILE="${BLOCKLIST_LOGFILE:-$LOGFILE_DEFAULT}"
STATE_DIR_DEFAULT="/var/lib/blocklist"
STATE_DIR="${BLOCKLIST_STATE_DIR:-$STATE_DIR_DEFAULT}"

########################################
# Logging
########################################
mkdir -p "$LOG_DIR"
chmod 750 "$LOG_DIR" || true
mkdir -p "$STATE_DIR"
chmod 750 "$STATE_DIR" || true

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
  (( max_base_len > 0 )) || error "BLOCKLIST_SET_PREFIX too long for MAX_NAME_LEN=$MAX_NAME_LEN"
  safe_base="$(sanitize_set_base "$base")"
  echo "${SET_PREFIX}${safe_base:0:$max_base_len}"
}
set_hash_file() {
  local setname="$1"
  local backend="$2"
  echo "$STATE_DIR/sethash_${backend}_${setname}.sha256"
}
hash_entries() {
  local entries_file="$1"
  sha256sum "$entries_file" | awk '{print $1}'
}
iptables_uses_nft_backend() {
  command -v iptables >/dev/null 2>&1 || return 1
  iptables -V 2>/dev/null | grep -qi "nf_tables"
}

########################################
# Validierung & Feature-detection
########################################
[[ -z "$URL_FILE" ]] && error "Usage: $0 <url-list-file>"
[[ ! -f "$URL_FILE" ]] && error "File '$URL_FILE' not found"
command -v curl  >/dev/null || error "curl not installed"
command -v sha256sum >/dev/null || error "sha256sum not installed"

ALLOWLIST_NORM_FILE="$TMPDIR/allowlist.norm"
if [[ -f "$ALLOWLIST_FILE" ]]; then
  grep -Ev '^[[:space:]]*(#|$)' "$ALLOWLIST_FILE" \
    | tr -d '[:space:]' \
    | sort -u > "$ALLOWLIST_NORM_FILE" || true
  log "[*] allowlist loaded: $ALLOWLIST_FILE ($(wc -l < "$ALLOWLIST_NORM_FILE" | tr -d ' ' ) entries)"
else
  : > "$ALLOWLIST_NORM_FILE"
  log "[*] allowlist not found (optional): $ALLOWLIST_FILE"
fi

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

if [[ "$nft_mode" -eq 1 ]]; then
  command -v nft >/dev/null || error "nft not installed (auto selected nft mode)"
  log "[*] operating in nftables-native mode${mode_reason:+ ($mode_reason)}"
else
  command -v ipset >/dev/null || error "ipset not installed"
  command -v iptables >/dev/null || error "iptables not installed"
  log "[*] operating in ipset mode${mode_reason:+ ($mode_reason)}"
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
  setname="$(build_set_name "$base")"

  if [[ "$base" == *_v6_* ]]; then
    family=inet6
    grep_regex="[0-9A-Fa-f:]+(/[0-9]{1,3})?"
    nft_type="ipv6_addr"
  else
    family=inet
    grep_regex="[0-9]+(\\.[0-9]+){3}(/[0-9]{1,2})?"
    nft_type="ipv4_addr"
  fi

  log "[*] processing: $fname -> set=$setname ($family)"

  out_file="$TMPDIR/$fname"
  if ! curl -fsSL "$url" -o "$out_file"; then
    log "[!] download failed: $url (skipped)"
    continue
  fi

  mapfile -t entries < <(grep -E "^${grep_regex}$" "$out_file" | sort -u)
  before_allow=${#entries[@]}
  if [[ -s "$ALLOWLIST_NORM_FILE" && "$before_allow" -gt 0 ]]; then
    entries_file="$TMPDIR/entries_${setname}"
    filtered_file="$TMPDIR/entries_${setname}.filtered"
    printf "%s\n" "${entries[@]}" > "$entries_file"
    grep -vxF -f "$ALLOWLIST_NORM_FILE" "$entries_file" > "$filtered_file" || true
    mapfile -t entries < "$filtered_file"
    removed=$(( before_allow - ${#entries[@]} ))
    if (( removed > 0 )); then
      log "[*] allowlist excluded $removed entries for $setname"
    fi
  fi

  count=${#entries[@]}
  if (( count == 0 )); then
    log "[!] no valid entries in $fname (skipped)"
    continue
  fi

  entries_file="$TMPDIR/entries_${setname}.final"
  printf "%s\n" "${entries[@]}" > "$entries_file"
  current_hash="$(hash_entries "$entries_file")"
  backend_name="ipset"
  if [[ "$nft_mode" -eq 1 ]]; then
    backend_name="nft"
  fi
  hash_file="$(set_hash_file "$setname" "$backend_name")"
  previous_hash=""
  if [[ -f "$hash_file" ]]; then
    previous_hash="$(tr -d '[:space:]' < "$hash_file")"
  fi
  if [[ -n "$previous_hash" && "$previous_hash" == "$current_hash" ]]; then
    if [[ "$nft_mode" -eq 1 ]]; then
      if nft list set inet "$NFT_TABLE" "$setname" >/dev/null 2>&1; then
        log "[*] no changes for $setname (hash=$current_hash) -> skip update"
        continue
      fi
      log "[*] hash unchanged but nft set missing for $setname -> recreate"
    else
      if ipset list "$setname" >/dev/null 2>&1; then
        log "[*] no changes for $setname (hash=$current_hash) -> skip update"
        continue
      fi
      log "[*] hash unchanged but ipset missing for $setname -> recreate"
    fi
  fi

  maxelem=$(( count * FACTOR ))
  hashsize=$(next_pow2 "$maxelem")
  log "[*] $count valid entries -> hashsize=$hashsize maxelem=$maxelem"

  if [[ "$nft_mode" -eq 1 ]]; then
    # nftables-native: ensure table exists and create set if missing
    nft add table inet "$NFT_TABLE" 2>/dev/null || true
    if ! nft list set inet "$NFT_TABLE" "$setname" >/dev/null 2>&1; then
      log "[*] creating nft set $setname (type=$nft_type)"
      nft add set inet "$NFT_TABLE" "$setname" "{ type $nft_type ; flags interval ; }" || true
    else
      log "[*] nft set exists -> flush: $setname"
      nft flush set inet "$NFT_TABLE" "$setname" 2>/dev/null || true
    fi

    # Batch insert elements to reduce number of nft calls
    batch_size=${NFT_BATCH_SIZE:-1000}
    total=${#entries[@]}
    i=0
    while (( i < total )); do
      end=$(( i + batch_size ))
      if (( end > total )); then end=$total; fi
      # build comma-separated list
      elems=""
      for ((j=i;j<end;j++)); do
        e=${entries[j]}
        # ensure proper quoting for IPv6 addresses with slash
        if [[ "$elems" == "" ]]; then
          elems="$e"
        else
          elems+=" , $e"
        fi
      done
      # use nft add element with a batch
      if ! nft add element inet "$NFT_TABLE" "$setname" "{ $elems }" 2>/dev/null; then
        log "[!] nft add element batch failed for items $i..$((end-1))"
      fi
      i=$end
    done
    echo "$current_hash" > "$hash_file"
    log "[*] updated hash for $setname"

  else
    # ipset bulk update: create a temporary set, populate it via ipset restore, then swap/rename
    tmp="${setname}_tmp_$$_$RANDOM"
    # ensure tmp name fits within MAX_NAME_LEN
    tmp=${tmp:0:$MAX_NAME_LEN}
    log "[*] creating temporary ipset $tmp for bulk update"
    ipset destroy "$tmp" 2>/dev/null || true

    # prepare restore content
    restore_file="$TMPDIR/ipset_restore_$setname"
    {
      echo "create $tmp hash:net family $family hashsize $hashsize maxelem $maxelem"
      for entry in "${entries[@]}"; do
        echo "add $tmp $entry"
      done
    } > "$restore_file"

    if ! ipset restore -f "$restore_file" 2>/dev/null; then
      log "[!] ipset restore failed for $setname"
      ipset destroy "$tmp" 2>/dev/null || true
    else
      if ipset list "$setname" &>/dev/null; then
        log "[*] swapping $tmp -> $setname"
        ipset swap "$tmp" "$setname" 2>/dev/null || true
        ipset destroy "$tmp" 2>/dev/null || true
      else
        log "[*] renaming $tmp -> $setname"
        ipset rename "$tmp" "$setname" 2>/dev/null || true
      fi
      echo "$current_hash" > "$hash_file"
      log "[*] updated hash for $setname"
    fi
  fi

done < "$URL_FILE"

log "[✓] ipsets updated"
