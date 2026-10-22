#!/bin/bash
# setup_mirror.sh — installs the Main-Mirror (Hot Standby) tooling.
#
#   On the ACTIVE main:    scripts/setup_mirror.sh --master  <standby-ip>
#   On the MIRROR/standby: scripts/setup_mirror.sh --standby <active-ip> [--mode manual|auto] [--provider cloudflare|vip|webhook]
#
# Installs:
#   master  → /usr/local/bin/iptv-mirror-sync.sh + systemd unit iptv-mirror-sync
#   standby → /usr/local/bin/iptv-failover-watch.sh + systemd unit iptv-failover-watch
# Config for both lives at /opt/iptv-panel/etc/mirror.conf (if the file exists,
# it is left untouched unless --force is given).

set -euo pipefail

PANEL_DIR="${IPTV_PANEL_DIR:-/opt/iptv-panel}"
CONF_DIR="$PANEL_DIR/etc"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

MODE="" PEER="" FOV_MODE=manual PROVIDER="" SSH_PORT=22 FORCE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --master|--standby) MODE="$1"; shift; PEER="${1:-}"; [ -n "$PEER" ] && shift;;
    --mode) FOV_MODE="$2"; shift 2;;
    --provider) PROVIDER="$2"; shift 2;;
    --ssh-port) SSH_PORT="$2"; shift 2;;
    --force) FORCE=1; shift;;
    *) shift;;
  esac
done
[ -z "$MODE" ] && { echo "usage: $0 --master <standby-ip> | --standby <active-ip> [--mode manual|auto] [--provider cloudflare|vip|webhook]" >&2; exit 1; }

mkdir -p "$CONF_DIR"

if [ "$MODE" = "--master" ]; then
  install -m 0755 "$SRC_DIR/iptv-mirror-sync.sh" /usr/local/bin/iptv-mirror-sync.sh
  conf="$CONF_DIR/mirror.conf"
  if [ -n "$FORCE" ]; then : > "$conf"; fi
  touch "$conf"
  if ! grep -q '^# marker:mirror-sync' "$conf"; then
    cat >> "$conf" <<MACRO

# marker:mirror-sync (written by setup_mirror.sh --master)
IPTV_PANEL_DIR=$PANEL_DIR
MIRROR_HOST=$PEER
MIRROR_SSH_PORT=$SSH_PORT
MIRROR_SSH_USER=iptvpanel
MIRROR_REMOTE_DIR=/opt/iptv-panel/data/mirror-in
MIRROR_SYNC_INTERVAL=15
MIRROR_KEEP=6
MIRROR_EXTRA_FILES=
MACRO
  fi
  cat > /etc/systemd/system/iptv-mirror-sync.service <<'UNIT'
[Unit]
Description=IPTV Panel mirror sync (live DB snapshot to standby)
After=network-online.target iptv-panel.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/iptv-mirror-sync.sh
Environment=IPTV_PANEL_DIR=PANEL_DIR_PLACEHOLDER
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT
  sed -i "s|PANEL_DIR_PLACEHOLDER|$PANEL_DIR|" /etc/systemd/system/iptv-mirror-sync.service
  systemctl daemon-reload
  systemctl enable --now iptv-mirror-sync
  echo "── master done ─────────────────────────────────────────────"
  echo "Next: place the SSH key so the master can write to the standby:"
  [ -f /root/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519
  echo "  ssh-copy-id -p $SSH_PORT iptvpanel@$PEER "
  echo "  (and on the standby: mkdir -p $PANEL_DIR/data/mirror-in && chown iptvpanel: $PANEL_DIR/data/mirror-in)"

else
  install -m 0755 "$SRC_DIR/iptv-failover-watch.sh" /usr/local/bin/iptv-failover-watch.sh
  conf="$CONF_DIR/mirror.conf"
  if [ -n "$FORCE" ]; then : > "$conf"; fi
  touch "$conf"
  if ! grep -q '^# marker:failover-watch' "$conf"; then
    cat >> "$conf" <<MACRO

# marker:failover-watch (written by setup_mirror.sh --standby)
IPTV_PANEL_DIR=$PANEL_DIR
HEALTH_URL=http://$PEER:18099/health
HEALTH_INTERVAL=10
HEALTH_FAILS=3
MIRROR_FAILOVER_MODE=$FOV_MODE
MIRROR_TAKEOVER_START_PANEL=1
ALERT_WEBHOOK=
FAILOVER_PROVIDER=$PROVIDER
MACRO
  fi
  cat > /etc/systemd/system/iptv-failover-watch.service <<'UNIT'
[Unit]
Description=IPTV Panel failover heartbeat watcher (standby side)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/iptv-failover-watch.sh
Environment=IPTV_PANEL_DIR=PANEL_DIR_PLACEHOLDER
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT
  sed -i "s|PANEL_DIR_PLACEHOLDER|$PANEL_DIR|" /etc/systemd/system/iptv-failover-watch.service
  systemctl daemon-reload
  systemctl enable --now iptv-failover-watch
  echo "── standby done ────────────────────────────────────────────"
  [ "$FOV_MODE" = auto ] && [ "$PROVIDER" = cloudflare ] && \
    echo "remember to set CF_API_TOKEN / CF_ZONE_ID / CF_RECORD_ID / CF_RECORD / MIRROR_MY_IP in $conf" || true
fi

# .service.in templates kept in the repo for packaging parity
command -v svc >/dev/null 2>&1 || true
