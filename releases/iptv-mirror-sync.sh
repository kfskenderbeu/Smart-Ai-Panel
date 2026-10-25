#!/bin/bash
# iptv-mirror-sync — ships a live, consistent snapshot of the panel database
# (plus optional extra files) from the ACTIVE main server to a PASSIVE mirror.
#
# Runs on the MASTER. Installed as the systemd unit "iptv-mirror-sync".
# The snapshot uses the SQLite online-backup API ("sqlite3 file .backup"),
# so it is always transactionally consistent while the panel keeps running.
# rsync then transfers only the changed blocks (a 10 MB db costs kilobytes).
#
# Configuration lives in /opt/iptv-panel/etc/mirror.conf  (see mirror.conf.in).

set -u
BASE="${IPTV_PANEL_DIR:-/opt/iptv-panel}"
CONF="${IPTV_MIRROR_CONF:-$BASE/etc/mirror.conf}"
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"

: "${MIRROR_SYNC_INTERVAL:=15}"
: "${MIRROR_DB:=data/panel.db}"
: "${MIRROR_KEEP:=6}"

if [ -z "${MIRROR_HOST:-}" ]; then
  echo "[$(date +'%F %T')] mirror-sync: MIRROR_HOST not set in $CONF, exiting" >&2
  exit 1
fi

ssh_target="${MIRROR_SSH_USER:-iptvpanel}@${MIRROR_HOST}"
db_path="$BASE/$MIRROR_DB"
snap_dir="$BASE/data/mirror-snap"
remote_dir="${MIRROR_REMOTE_DIR:-/opt/iptv-panel/data/mirror-in}"
rsync_opts=(-az --delete --partial
  -e "ssh -p ${MIRROR_SSH_PORT:-22} -o BatchMode=yes -o ConnectTimeout=10${MIRROR_SSH_KEY:+ -i $MIRROR_SSH_KEY}")

mkdir -p "$snap_dir"
snap="$snap_dir/latest.db"
tmp="$snap_dir/.new.db"

# The standby must run with the main's jwt_secret: since 2.6.38 the secret
# settings (AI/payment keys), DRM keys and sessions are sealed with it, and
# the database shipped below is unreadable in those parts under any other
# key. A panel started without one makes up its own, so a fresh standby is
# wrong by default. Only hashes are compared; the secret never leaves here.
: "${MIRROR_SECRET_CHECK_EVERY:=40}"      # loops between checks (~10 min)
config_rel="${MIRROR_CONFIG:-config/config.json}"
secret_hash() {   # stdin: config.json -> sha256 of the jwt_secret value, or ""
  sed -n 's/.*"jwt_secret"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1 \
    | { read -r v; [ -n "$v" ] && printf '%s' "$v" | sha256sum | cut -d' ' -f1; }
}
check_secret() {
  local mine theirs
  mine=$(secret_hash < "$BASE/$config_rel" 2>/dev/null)
  theirs=$(ssh -p "${MIRROR_SSH_PORT:-22}" -o BatchMode=yes -o ConnectTimeout=10 \
             ${MIRROR_SSH_KEY:+-i "$MIRROR_SSH_KEY"} "$ssh_target" \
             "cat '$BASE/$config_rel'" 2>/dev/null | secret_hash)
  if [ -z "$mine" ]; then
    echo "[$(date +'%F %T')] mirror-sync: WARNING no jwt_secret in $BASE/$config_rel" >&2
  elif [ -z "$theirs" ]; then
    echo "[$(date +'%F %T')] mirror-sync: WARNING cannot read the standby's $config_rel" \
         "(jwt_secret not verified)" >&2
  elif [ "$mine" != "$theirs" ]; then
    echo "[$(date +'%F %T')] mirror-sync: WARNING the standby's jwt_secret differs from this" \
         "server's -- after a failover it cannot decrypt the secret settings, DRM keys or" \
         "sessions. Copy $config_rel to the standby (see docs/HA.md)." >&2
  else
    echo "[$(date +'%F %T')] mirror-sync: standby jwt_secret matches"
  fi
}
loops=0

while :; do
  if [ $((loops % MIRROR_SECRET_CHECK_EVERY)) -eq 0 ]; then check_secret; fi
  loops=$((loops + 1))

  if [ -f "$db_path" ]; then
    # Prune old WAL so the snapshot does not grow unbounded; harmless live.
    sqlite3 "$db_path" "PRAGMA wal_checkpoint(PASSIVE);" >/dev/null 2>&1
    if sqlite3 "$db_path" ".backup '$tmp'" >/dev/null 2>&1; then
      mv "$tmp" "$snap"
      if rsync "${rsync_opts[@]}" "$snap" "$ssh_target:$remote_dir/panel.db" 2>/dev/null; then
        echo "[$(date +'%F %T')] mirror-sync: shipped $(du -h "$snap" | cut -f1) snapshot"
      else
        echo "[$(date +'%F %T')] mirror-sync: rsync to $MIRROR_HOST failed" >&2
      fi
      # Rotate local snapshots for quick local restore (keep MIRROR_KEEP).
      cp "$snap" "$snap_dir/snap_$(date +%Y%m%d_%H%M%S).db" 2>/dev/null
      ls -1t "$snap_dir"/snap_*.db 2>/dev/null | tail -n +$((MIRROR_KEEP + 1)) | xargs -r rm -f --
    else
      echo "[$(date +'%F %T')] mirror-sync: sqlite .backup failed" >&2
    fi
  fi

  # Extra payload (optional): relative paths under $BASE, newline separated.
  if [ -n "${MIRROR_EXTRA_FILES:-}" ] && [ -f "$BASE/$MIRROR_EXTRA_FILES" ]; then
    (cd "$BASE" && tar -czf - $(tr -d '[:space:]' < "$BASE/$MIRROR_EXTRA_FILES")) \
      | ssh -p "${MIRROR_SSH_PORT:-22}" -o BatchMode=yes ${MIRROR_SSH_KEY:+-i "$MIRROR_SSH_KEY"} \
        "$ssh_target" "tar -xzf - -C $BASE 2>/dev/null"
  fi

  sleep "$MIRROR_SYNC_INTERVAL"
done
