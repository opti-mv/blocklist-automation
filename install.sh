#!/usr/bin/env bash
# blocklist-automation installer
# Usage: curl -fsSL https://raw.githubusercontent.com/opti-mv/blocklist-automation/main/install.sh | sudo bash

set -Eeuo pipefail

REPO_RAW_BASE_DEFAULT="https://raw.githubusercontent.com/opti-mv/blocklist-automation/main"
REPO_RAW_BASE="${REPO_RAW_BASE:-$REPO_RAW_BASE_DEFAULT}"

DEST_DIR_DEFAULT="/root/blocklist"
DEST_DIR="${DEST_DIR:-$DEST_DIR_DEFAULT}"

CRON_SCHEDULE_DEFAULT="36 * * * *"
CRON_SCHEDULE="${CRON_SCHEDULE:-$CRON_SCHEDULE_DEFAULT}"

LOG_DIR="/var/log/blocklist"

need_cmd() { command -v "$1" >/dev/null 2>&1; }

log() { echo "[blocklist-install] $*"; }

die() { echo "[blocklist-install] ERROR: $*" >&2; exit 1; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "must run as root (use sudo)"
  fi
}

install_packages_best_effort() {
  # Best-effort; supports Debian/Ubuntu via apt.
  local pkgs=(curl ipset iptables)

  if need_cmd apt-get; then
    log "installing packages via apt: ${pkgs[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y || true
    apt-get install -y "${pkgs[@]}" || true
  else
    log "no apt-get found; skipping package installation"
  fi

  need_cmd curl  || die "curl not found"
  need_cmd ipset || die "ipset not found"
  need_cmd iptables || die "iptables not found"
  # ip6tables may be absent on IPv4-only systems
  if ! need_cmd ip6tables; then
    log "note: ip6tables not found (IPv6 rules will be skipped)"
  fi
}

download_file() {
  local url="$1" out="$2"
  mkdir -p "$(dirname "$out")"
  curl -fsSL "$url" -o "$out"
}

ensure_dirs() {
  mkdir -p "$DEST_DIR" "$LOG_DIR"
  chmod 750 "$LOG_DIR" || true
}

sync_blocklist_files() {
  log "syncing files to $DEST_DIR from $REPO_RAW_BASE"

  download_file "$REPO_RAW_BASE/blocklist/blocklists.txt" "$DEST_DIR/blocklists.txt"
  download_file "$REPO_RAW_BASE/blocklist/download_and_create_ipsets.sh" "$DEST_DIR/download_and_create_ipsets.sh"
  download_file "$REPO_RAW_BASE/blocklist/set-ipsets2drop.sh" "$DEST_DIR/set-ipsets2drop.sh"

  chmod 700 "$DEST_DIR/download_and_create_ipsets.sh" "$DEST_DIR/set-ipsets2drop.sh" || true
}

ensure_crontab() {
  local cron_line
  cron_line="$CRON_SCHEDULE cd $DEST_DIR && ./download_and_create_ipsets.sh blocklists.txt && ./set-ipsets2drop.sh >> $LOG_DIR/blocklist_\$(date +\\%F).log 2>&1"

  log "ensuring root crontab entry"

  local tmp
  tmp="$(mktemp)"

  # Fetch current crontab (if any)
  if crontab -l >"$tmp" 2>/dev/null; then
    true
  else
    : >"$tmp"
  fi

  # Remove old lines we previously managed (anything containing /root/blocklist + the two scripts)
  # Keep it conservative.
  grep -vE "download_and_create_ipsets\.sh|set-ipsets2drop\.sh" "$tmp" >"$tmp.new" || true

  {
    cat "$tmp.new"
    echo ""
    echo "# blocklist-automation (managed)"
    echo "$cron_line"
  } >"$tmp.final"

  crontab "$tmp.final"

  rm -f "$tmp" "$tmp.new" "$tmp.final" 2>/dev/null || true
}

main() {
  require_root
  install_packages_best_effort
  ensure_dirs
  sync_blocklist_files
  ensure_crontab
  log "done"
  log "test run: cd $DEST_DIR && ./download_and_create_ipsets.sh blocklists.txt && ./set-ipsets2drop.sh"
}

main "$@"
