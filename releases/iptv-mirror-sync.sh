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

while :; do
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
