#!/usr/bin/env bash
# blocklist-automation uninstall/cleanup

set -Eeuo pipefail

DEST_DIR="${DEST_DIR:-/opt/blocklist}"
LOG_DIR="/var/log/blocklist"
MAX_NAME_LEN=31
SET_PREFIX="${BLOCKLIST_SET_PREFIX:-blklst_}"
NFT_TABLE="${BLOCKLIST_NFT_TABLE:-blocklist_auto}"
NFT_CHAIN="${BLOCKLIST_NFT_CHAIN:-input_blocklist}"
SYSTEMD_SERVICE_NAME="blocklist-automation.service"
SYSTEMD_TIMER_NAME="blocklist-automation.timer"
URL_FILE="$DEST_DIR/blocklists.txt"

log() { echo "[blocklist-uninstall] $*"; }
die() { echo "[blocklist-uninstall] ERROR: $*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "must run as root (use sudo)"
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
  (( max_base_len > 0 )) || die "BLOCKLIST_SET_PREFIX too long for MAX_NAME_LEN=$MAX_NAME_LEN"
  safe_base="$(sanitize_set_base "$base")"
  echo "${SET_PREFIX}${safe_base:0:$max_base_len}"
}

collect_set_names() {
  local names_file="$1"
  : > "$names_file"

  if [[ -f "$URL_FILE" ]]; then
    while IFS= read -r url; do
      url="${url//[[:space:]]/}"
      [[ -z "$url" || "$url" == \#* ]] && continue
      fname="$(basename "$url")"
      base="${fname%.txt}"
      base="${base#blocklist_}"
      build_set_name "$base" >> "$names_file"
    done < "$URL_FILE"
  fi

  if need_cmd ipset; then
    ipset list -name 2>/dev/null | grep -E "^${SET_PREFIX}" >> "$names_file" || true
  fi

  sort -u "$names_file" -o "$names_file"
}

remove_systemd_units() {
  if need_cmd systemctl; then
    systemctl disable --now "$SYSTEMD_TIMER_NAME" 2>/dev/null || true
    rm -f "/etc/systemd/system/$SYSTEMD_SERVICE_NAME" "/etc/systemd/system/$SYSTEMD_TIMER_NAME"
    systemctl daemon-reload 2>/dev/null || true
    log "systemd timer/service removed (if present)"
  fi
}

remove_cron_block() {
  local marker_begin="# BEGIN blocklist-automation (managed)"
  local marker_end="# END blocklist-automation (managed)"
  local tmp

  if ! need_cmd crontab; then
    log "crontab not found; skipping cron cleanup"
    return 0
  fi

  tmp="$(mktemp)"
  if crontab -l >"$tmp" 2>/dev/null; then
    true
  else
    : >"$tmp"
  fi

  awk -v begin="$marker_begin" -v end="$marker_end" '
    $0 == begin { inblock=1; next }
    $0 == end { inblock=0; next }
    inblock != 1 { print }
  ' "$tmp" \
    | grep -vE "^[[:space:]]*# blocklist-automation \(managed\)[[:space:]]*$" \
    | grep -vE "download_and_create_ipsets\.sh blocklists\.txt && \./set-ipsets2drop\.sh" \
    >"$tmp.new" || true

  crontab "$tmp.new" || true
  rm -f "$tmp" "$tmp.new" 2>/dev/null || true
  log "managed cron block removed (if present)"
}

remove_iptables_rules_and_sets() {
  local names_file="$1"
  local setname
  local cmd

  while IFS= read -r setname; do
    [[ -z "$setname" ]] && continue
    if [[ "$setname" == *_v6_* ]]; then
      cmd="ip6tables"
    else
      cmd="iptables"
    fi

    if need_cmd "$cmd"; then
      while $cmd -C INPUT -m set --match-set "$setname" src -j DROP 2>/dev/null; do
        $cmd -D INPUT -m set --match-set "$setname" src -j DROP 2>/dev/null || break
      done
    fi

    if need_cmd ipset; then
      ipset destroy "$setname" 2>/dev/null || true
    fi
  done < "$names_file"

  log "iptables/ipset cleanup completed"
}

remove_nft_table() {
  if need_cmd nft; then
    nft delete table inet "$NFT_TABLE" 2>/dev/null || true
    log "nft table cleanup completed (table: inet $NFT_TABLE)"
  fi
}

remove_files() {
  rm -f /etc/logrotate.d/blocklist-automation 2>/dev/null || true
  rm -f "$DEST_DIR/download_and_create_ipsets.sh" "$DEST_DIR/set-ipsets2drop.sh" \
        "$DEST_DIR/blocklists.txt" "$DEST_DIR/allowlist.txt" "$DEST_DIR/uninstall.sh" 2>/dev/null || true
  rmdir "$DEST_DIR" 2>/dev/null || true
  log "managed files removed (destination/logrotate)"

  # Keep logs by default. Remove only when explicitly requested.
  if [[ "${REMOVE_LOGS:-0}" == "1" ]]; then
    rm -rf "$LOG_DIR" 2>/dev/null || true
    log "logs removed: $LOG_DIR"
  fi
}

main() {
  require_root

  names_file="$(mktemp)"
  trap 'if [[ -n "${names_file:-}" ]]; then rm -f "$names_file" 2>/dev/null || true; fi' EXIT

  collect_set_names "$names_file"
  remove_systemd_units
  remove_cron_block
  remove_iptables_rules_and_sets "$names_file"
  remove_nft_table
  remove_files

  log "done"
}

main "$@"
