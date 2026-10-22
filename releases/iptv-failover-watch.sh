#!/bin/bash
# iptv-failover-watch — heartbeat watcher that runs on the MIRROR (standby).
#
# Polls the ACTIVE main's health endpoint. When the main is confirmed dead
# (HEALTH_FAILS consecutive failures), reacts according to MIRROR_FAILOVER_MODE:
#   manual            → alert only (Discord/Telegram webhook). Operator switches
#                       the IP/DNS by hand, or runs failover take-over himself.
#   auto              → run the provider hook automatically:
#                        • cloudflare → update an A record to the mirror IP
#                        • vip        → add/remove a local floating IP (same L2)
#                        • webhook    → POST a JSON event to a custom endpoint
# When the main comes back, auto-VIP is released again (manual mode never
# touches the network).
#
# On a real take-over it can optionally start the local panel service
# (MIRROR_TAKEOVER_START_PANEL=1) from cold standby to hot standby.

set -u
BASE="${IPTV_PANEL_DIR:-/opt/iptv-panel}"
CONF="${IPTV_MIRROR_CONF:-$BASE/etc/mirror.conf}"
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"

: "${HEALTH_URL:=}"
: "${HEALTH_FAILS:=3}"
: "${HEALTH_INTERVAL:=10}"
: "${MIRROR_FAILOVER_MODE:=manual}"
: "${MIRROR_TAKEOVER_START_PANEL:=0}"
: "${ALERT_WEBHOOK:=}"   # Discord webhook URL or Telegram (bot token + chat id below)
: "${ALERT_STATE:=}"

state_file="${IPTV_PANEL_DIR:-$BASE}/data/failover.state"
[ -d "$(dirname "$state_file")" ] || mkdir -p "$(dirname "$state_file")"

log() { echo "[$(date +'%F %T')] failover-watch: $*"; }

alert() {
  local msg="$1"
  log "$msg"
  [ -n "$ALERT_STATE" ] && printf '%s %s\n' "$(date +%s)" "$msg" >> "$state_file"
  if [ -n "$ALERT_WEBHOOK" ]; then
    local payload
    payload=$(python3 -c 'import json,sys; print(json.dumps({"content":"🚨 [failover-watch] "+sys.argv[1], "allowed_mentions":{"parse":[]}}))' "$msg" 2>/dev/null)
    case "$ALERT_WEBHOOK" in
      https://discord.com/api/webhooks/*|https://discordapp.com/api/webhooks/*)
        [ -z "$payload" ] && continue
        curl -s -m 10 -H 'Content-Type: application/json' \
          --data "$payload" "$ALERT_WEBHOOK" >/dev/null ;;
      https://api.telegram.org/*)
        curl -s -m 10 "$ALERT_WEBHOOK" >/dev/null ;;
    esac
  fi
}

take_over() {
  log "MAIN IS DOWN (mode=$MIRROR_FAILOVER_MODE) — taking over"
  if [ "$MIRROR_TAKEOVER_START_PANEL" = "1" ]; then
    systemctl start iptv-panel 2>/dev/null && log "local iptv-panel started"
  fi
  case "$MIRROR_FAILOVER_MODE" in
    manual)
      alert "Main $HEALTH_URL is DOWN. MANUAL mode: switch DNS/floating IP to this mirror now."
      ;;
    auto)
      case "${FAILOVER_PROVIDER:-}" in
        cloudflare)
          curl -s -m 20 -X PUT \
            -H "Authorization: Bearer ${CF_API_TOKEN:-}" \
            -H 'Content-Type: application/json' \
            --data "{\"type\":\"A\",\"name\":\"${CF_RECORD:-}\",\"content\":\"${MIRROR_MY_IP:-}\",\"ttl\":60,\"proxied\":false}" \
            "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID:-}/dns_records/${CF_RECORD_ID:-}" \
            >/dev/null && alert "Cloudflare A ${CF_RECORD:-} moved to ${MIRROR_MY_IP:-}" \
                       || alert "Cloudflare API update FAILED — manual switch needed!"
          ;;
        vip)
          if ip addr add "${VIP:-}" dev "${VIP_IF:-eth0}" 2>/dev/null \
             && ip addr | grep -qw "${VIP%/*}"; then
            alert "took over floating IP ${VIP:-}"
            arping -U -c 3 -I "${VIP_IF:-eth0}" "${VIP%/*}" >/dev/null 2>&1 || true
          else
            alert "failed to claim floating IP ${VIP:-}"
          fi
          ;;
        webhook)
          curl -s -m 10 -H 'Content-Type: application/json' \
            --data "{\"event\":\"main_down\",\"mirror\":\"$(hostname)\",\"ts\":$(date +%s)}" \
            "${FAILOVER_WEBHOOK:-}" >/dev/null \
            && alert "take-over webhook fired" \
            || alert "take-over webhook FAILED"
          ;;
        *)
          alert "FAILover provider '${FAILOVER_PROVIDER:-none}' not configured — do it manually."
          ;;
      esac
      ;;
  esac
}

release() {
  if [ "$last_state" = down ]; then
    log "MAIN IS BACK — standing down"
    if [ "$MIRROR_FAILOVER_MODE" = auto ] && [ "${FAILOVER_PROVIDER:-}" = vip ]; then
      ip addr del "${VIP:-}" dev "${VIP_IF:-eth0}" 2>/dev/null && log "floating IP released"
      # Only stop the local panel when the operator explicitly opted in —
      # an accidental stand-down must never kill a running panel.
      if [ "${MIRROR_STANDDOWN_STOP_PANEL:-0}" = "1" ]; then
        systemctl stop iptv-panel 2>/dev/null || true
      fi
    fi
    alert "Main server is back online; mirror back to standby."
  fi
}

fails=0; last_state=up
# Ops/test hook: FAILOVER_SEED_STATE=down simulates an outage to test recovery.
[ "${FAILOVER_SEED_STATE:-}" = down ] && last_state=down
touch "$state_file"
while :; do
  code=$(curl -s -m 8 -o /dev/null -w '%{http_code}' "${HEALTH_URL:-}" 2>/dev/null)
  [ -n "$code" ] && [ "$code" != "000" ] || code="000"
  if [ "$code" != "200" ]; then
    fails=$((fails + 1))
    log "health miss ($fails/$HEALTH_FAILS): http=$code"
    if [ "$fails" -ge "$HEALTH_FAILS" ] && [ "$last_state" != down ]; then
      take_over
      last_state=down
    fi
  else
    fails=0
    release
    last_state=up
  fi
  sleep "$HEALTH_INTERVAL"
done
