#!/usr/bin/env bash
# blocklist-automation installer
# Usage: curl -fsSL https://raw.githubusercontent.com/opti-mv/blocklist-automation/main/install.sh | sudo bash

set -Eeuo pipefail

REPO_RAW_BASE_DEFAULT="https://raw.githubusercontent.com/opti-mv/blocklist-automation/main"
REPO_RAW_BASE="${REPO_RAW_BASE:-$REPO_RAW_BASE_DEFAULT}"

DEST_DIR_DEFAULT="/opt/blocklist"
DEST_DIR="${DEST_DIR:-$DEST_DIR_DEFAULT}"

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
  local pkgs=(curl ipset iptables nftables)

  if need_cmd apt-get; then
    log "installing packages via apt: ${pkgs[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y || true
    apt-get install -y "${pkgs[@]}" || true
  else
    log "no apt-get found; skipping package installation"
  fi

  need_cmd curl || die "curl not found"

  if need_cmd nft; then
    log "nft found; nftables mode is available"
  elif need_cmd ipset && need_cmd iptables; then
    log "ipset+iptables found; legacy mode is available"
    # ip6tables may be absent on IPv4-only systems
    if ! need_cmd ip6tables; then
      log "note: ip6tables not found (IPv6 rules will be skipped)"
    fi
  else
    log "no firewall backend detected; attempting nftables fallback install"
    if need_cmd apt-get; then
      apt-get update -y || true
      apt-get install -y nftables || true
    elif need_cmd yum; then
      yum install -y nftables || true
    elif need_cmd apk; then
      apk add --no-cache nftables || true
    fi

    need_cmd nft || die "no supported firewall backend found (need nft or ipset+iptables)"
    log "nft installed; nftables mode will be used"
  fi
}

pick_random_minute() {
  local minute
  if [[ -r /etc/machine-id ]]; then
    minute="$(cksum < /etc/machine-id | awk '{print $1 % 60}')"
  else
    minute="$(hostname | cksum | awk '{print $1 % 60}')"
  fi
  echo "$minute"
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

configure_logrotate() {
  # Ensure logrotate is installed and place a rotation policy for the unified logfile
  if ! command -v logrotate >/dev/null 2>&1; then
    if need_cmd apt-get; then
      log "installing logrotate"
      apt-get update -y || true
      apt-get install -y logrotate || true
    elif need_cmd yum; then
      yum install -y logrotate || true
    elif need_cmd apk; then
      apk add --no-cache logrotate || true
    else
      log "logrotate not installed and no supported package manager found; please install logrotate manually"
    fi
  fi

  cat > /etc/logrotate.d/blocklist-automation <<'EOF'
/var/log/blocklist/blocklist.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root adm
    sharedscripts
}
EOF

  # Try to force a rotate once to ensure config validity (non-fatal)
  logrotate -f /etc/logrotate.d/blocklist-automation || true
}

sync_blocklist_files() {
  log "syncing files to $DEST_DIR from $REPO_RAW_BASE"

  download_file "$REPO_RAW_BASE/blocklist/blocklists.txt" "$DEST_DIR/blocklists.txt"
  download_file "$REPO_RAW_BASE/blocklist/download_and_create_ipsets.sh" "$DEST_DIR/download_and_create_ipsets.sh"
  download_file "$REPO_RAW_BASE/blocklist/set-ipsets2drop.sh" "$DEST_DIR/set-ipsets2drop.sh"

  chmod 700 "$DEST_DIR/download_and_create_ipsets.sh" "$DEST_DIR/set-ipsets2drop.sh" || true
}

ensure_crontab() {
  local schedule minute
  local cron_line
  local marker_begin="# BEGIN blocklist-automation (managed)"
  local marker_end="# END blocklist-automation (managed)"

  if [[ -n "${CRON_SCHEDULE:-}" ]]; then
    schedule="$CRON_SCHEDULE"
  else
    minute="$(pick_random_minute)"
    schedule="${minute} * * * *"
  fi

  # Run both scripts and append all output to the single unified logfile
  cron_line="$schedule cd $DEST_DIR && (./download_and_create_ipsets.sh blocklists.txt && ./set-ipsets2drop.sh) >> $LOG_DIR/blocklist.log 2>&1"

  log "ensuring root crontab entry"

  local tmp
  tmp="$(mktemp)"

  # Fetch current crontab (if any)
  if crontab -l >"$tmp" 2>/dev/null; then
    true
  else
    : >"$tmp"
  fi

  # Keep existing user entries. Remove only our managed block (new and legacy marker).
  awk -v begin="$marker_begin" -v end="$marker_end" '
    $0 == begin { inblock=1; next }
    $0 == end { inblock=0; next }
    inblock != 1 { print }
  ' "$tmp" \
    | grep -vE "^[[:space:]]*# blocklist-automation \(managed\)[[:space:]]*$" \
    | grep -vE "download_and_create_ipsets\.sh blocklists\.txt && \./set-ipsets2drop\.sh" \
    >"$tmp.new" || true

  {
    cat "$tmp.new"
    echo ""
    echo "$marker_begin"
    echo "$cron_line"
    echo "$marker_end"
  } >"$tmp.final"

  crontab "$tmp.final"

  rm -f "$tmp" "$tmp.new" "$tmp.final" 2>/dev/null || true
}

main() {
  require_root
  install_packages_best_effort
  ensure_dirs
  sync_blocklist_files
  configure_logrotate
  ensure_crontab
  log "done"
  log "test run: cd $DEST_DIR && ./download_and_create_ipsets.sh blocklists.txt && ./set-ipsets2drop.sh"
}

main "$@"
