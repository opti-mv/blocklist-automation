#!/usr/bin/env bash
# blocklist-automation installer
# Usage: curl -fsSL https://raw.githubusercontent.com/opti-mv/blocklist-automation/main/install.sh | sudo bash

set -Eeuo pipefail

REPO_RAW_BASE_DEFAULT="https://raw.githubusercontent.com/opti-mv/blocklist-automation/main"
REPO_RAW_BASE="${REPO_RAW_BASE:-$REPO_RAW_BASE_DEFAULT}"

DEST_DIR_DEFAULT="/opt/blocklist"
DEST_DIR="${DEST_DIR:-$DEST_DIR_DEFAULT}"

LOG_DIR="/var/log/blocklist"
SYSTEMD_SERVICE_NAME="blocklist-automation.service"
SYSTEMD_TIMER_NAME="blocklist-automation.timer"
SYSTEMD_SERVICE_PATH="/etc/systemd/system/${SYSTEMD_SERVICE_NAME}"
SYSTEMD_TIMER_PATH="/etc/systemd/system/${SYSTEMD_TIMER_NAME}"

need_cmd() { command -v "$1" >/dev/null 2>&1; }

log() { echo "[blocklist-install] $*"; }

die() { echo "[blocklist-install] ERROR: $*" >&2; exit 1; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "must run as root (use sudo)"
  fi
}

iptables_uses_nft_backend() {
  need_cmd iptables || return 1
  iptables -V 2>/dev/null | grep -qi "nf_tables"
}

install_pkgs_best_effort() {
  local pkgs=("$@")
  (( ${#pkgs[@]} > 0 )) || return 0

  if need_cmd apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y || true
    apt-get install -y "${pkgs[@]}" || true
  elif need_cmd yum; then
    yum install -y "${pkgs[@]}" || true
  elif need_cmd apk; then
    apk add --no-cache "${pkgs[@]}" || true
  else
    log "no supported package manager found; cannot install: ${pkgs[*]}"
  fi
}

try_switch_iptables_to_nft() {
  local nft_path
  if ! need_cmd update-alternatives; then
    return 1
  fi

  nft_path="$(update-alternatives --list iptables 2>/dev/null | grep -E 'iptables-nft$' | head -n1 || true)"
  if [[ -n "$nft_path" ]]; then
    update-alternatives --set iptables "$nft_path" >/dev/null 2>&1 || true
  fi

  nft_path="$(update-alternatives --list ip6tables 2>/dev/null | grep -E 'ip6tables-nft$' | head -n1 || true)"
  if [[ -n "$nft_path" ]]; then
    update-alternatives --set ip6tables "$nft_path" >/dev/null 2>&1 || true
  fi

  iptables_uses_nft_backend
}

install_packages_best_effort() {
  need_cmd curl || install_pkgs_best_effort curl
  need_cmd curl || die "curl not found"

  # Prefer iptables with nft backend. Ensure iptables/ipset are available first.
  if ! need_cmd iptables || ! need_cmd ipset; then
    log "trying preferred backend prerequisites: iptables + ipset"
    install_pkgs_best_effort iptables ipset
  fi

  if need_cmd iptables && ! iptables_uses_nft_backend; then
    log "iptables present but not nft backend; trying switch to iptables-nft"
    try_switch_iptables_to_nft || true
  fi

  if need_cmd iptables && need_cmd ipset && iptables_uses_nft_backend; then
    log "iptables-nft + ipset available (preferred backend)"
    return 0
  fi

  # Second priority: native nftables.
  if ! need_cmd nft; then
    log "preferred backend unavailable; trying nftables"
    install_pkgs_best_effort nftables
  fi
  if need_cmd nft; then
    log "nftables available (secondary backend)"
    return 0
  fi

  # Final fallback: legacy iptables + ipset.
  if need_cmd iptables && need_cmd ipset; then
    log "falling back to legacy iptables + ipset (nft backends unavailable)"
    return 0
  fi

  die "no supported firewall backend found (need iptables-nft+ipset, nft, or legacy iptables+ipset)"
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

has_systemd() {
  command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]
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
  download_file "$REPO_RAW_BASE/blocklist/allowlist.txt" "$DEST_DIR/allowlist.txt"
  download_file "$REPO_RAW_BASE/blocklist/download_and_create_ipsets.sh" "$DEST_DIR/download_and_create_ipsets.sh"
  download_file "$REPO_RAW_BASE/blocklist/set-ipsets2drop.sh" "$DEST_DIR/set-ipsets2drop.sh"
  download_file "$REPO_RAW_BASE/uninstall.sh" "$DEST_DIR/uninstall.sh"

  chmod 700 "$DEST_DIR/download_and_create_ipsets.sh" "$DEST_DIR/set-ipsets2drop.sh" "$DEST_DIR/uninstall.sh" || true
}

remove_managed_cron_block() {
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
}

ensure_crontab() {
  local schedule minute
  local cron_line
  local marker_begin="# BEGIN blocklist-automation (managed)"
  local marker_end="# END blocklist-automation (managed)"
  local tmp

  need_cmd crontab || die "crontab not found (required for cron fallback scheduler)"

  if [[ -n "${CRON_SCHEDULE:-}" ]]; then
    schedule="$CRON_SCHEDULE"
  else
    minute="$(pick_random_minute)"
    schedule="${minute} */12 * * *"
  fi

  # Run both scripts and append all output to the single unified logfile
  cron_line="$schedule cd $DEST_DIR && (./download_and_create_ipsets.sh blocklists.txt && ./set-ipsets2drop.sh) >> $LOG_DIR/blocklist.log 2>&1"

  log "ensuring root crontab entry"
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

install_systemd_timer() {
  log "configuring systemd timer ($SYSTEMD_TIMER_NAME)"

  cat > "$SYSTEMD_SERVICE_PATH" <<EOF
[Unit]
Description=Update blocklist sets and ensure firewall drop rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=$DEST_DIR
ExecStart=/bin/sh -c './download_and_create_ipsets.sh blocklists.txt && ./set-ipsets2drop.sh'
EOF

  cat > "$SYSTEMD_TIMER_PATH" <<'EOF'
[Unit]
Description=Run blocklist automation twice daily at randomized delay

[Timer]
OnCalendar=*-*-* 00,12:00:00
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now "$SYSTEMD_TIMER_NAME"
}

ensure_scheduler() {
  if has_systemd; then
    log "systemd detected; using systemd timer"
    install_systemd_timer
    remove_managed_cron_block
  else
    log "systemd not available; falling back to cron"
    ensure_crontab
  fi
}

run_initial_update() {
  log "running initial update now"
  (
    cd "$DEST_DIR"
    ./download_and_create_ipsets.sh blocklists.txt
    ./set-ipsets2drop.sh
  ) || die "initial update failed; check logs in /var/log/blocklist/blocklist.log (or /tmp/blocklist.log)"
  log "initial update completed"
}

main() {
  require_root
  install_packages_best_effort
  ensure_dirs
  sync_blocklist_files
  configure_logrotate
  ensure_scheduler
  run_initial_update
  log "done"
}

main "$@"
