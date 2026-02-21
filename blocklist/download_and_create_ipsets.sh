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
# Validierung
########################################
[[ -z "$URL_FILE" ]] && error "Usage: $0 <url-list-file>"
[[ ! -f "$URL_FILE" ]] && error "File  not found"
command -v ipset >/dev/null || error "ipset not installed"
command -v curl  >/dev/null || error "curl not installed"

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
  else
    family=inet
    grep_regex="[0-9]+(\\.[0-9]+){3}(/[0-9]{1,2})?"
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

done < "$URL_FILE"

log "[✓] ipsets updated"
