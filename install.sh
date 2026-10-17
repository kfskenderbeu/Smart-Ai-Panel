#!/usr/bin/env bash
#
# IPTV Panel — installer for a fresh server, straight from GitHub.
#
#   curl -fsSL https://raw.githubusercontent.com/kfskenderbeu/Smart-Ai-Panel/main/install.sh | sudo bash
#
#   # trial build (no licence, runs until the baked-in end date)
#   curl -fsSL .../install.sh | sudo bash -s -- --trial
#
#   # production, with the licence key for this server's HWID
#   curl -fsSL .../install.sh | sudo bash -s -- --license 'eyJjbGllbnQi...'
#
# What it does:
#   1. installs the dependencies (curl, ca-certificates, ffmpeg, sqlite3),
#   2. creates the service user and /opt/iptv-panel/{bin,config,data,logs,web},
#   3. downloads the binary and checks it against the SHA-256 pinned below,
#   4. installs the web UI (HTML/JS/CSS) from the signed update manifest,
#      which the panel verifies itself: Ed25519 signature + SHA-256 per file,
#   5. writes the licence, creates the database and prints the admin password,
#   6. installs and starts the systemd service.
#
# Running it again on an existing installation updates it in place and keeps
# the configuration, the database and the licence.
#
# Nothing here is secret: the manifests carry a signature, and the panel
# verifies it against the public key compiled into the binary.
#
# SPDX-License-Identifier: proprietary
set -euo pipefail

# ── release this script installs (rewritten on every release) ──────────────
VERSION_DEFAULT="2.6.3"
SHA_PROD_DEFAULT="07cb042cb310be6ebcfec6b688a5c9eceb48291fa7d8818aed378db60dc14960"
SHA_TRIAL_DEFAULT="60e4fed1e5002852cb77cff39908833d568a0e36ad0b1e4b463aa014dadc3025"

REPO="kfskenderbeu/Smart-Ai-Panel"
RAW="https://raw.githubusercontent.com/${REPO}/main"

# ── defaults ──────────────────────────────────────────────────────────────
TRIAL="${TRIAL:-0}"
DIR="${PANEL_DIR:-/opt/iptv-panel}"
SVC_USER="${PANEL_USER:-iptvpanel}"
VERSION="${PANEL_VERSION:-$VERSION_DEFAULT}"
LICENSE_KEY="${LICENSE_KEY:-}"
DO_DEPS=1
DO_SERVICE=1
DO_WEB=1
MANIFEST_OVERRIDE=""

usage() {
    cat <<'EOF'
IPTV Panel installer

  install.sh [options]

  --trial              install the trial build (no licence; ends on its baked-in date)
  --license KEY        licence key for this server (production); omit to be shown the HWID
  --version X.Y.Z      install a specific release (default: the one pinned in this script)
  --dir PATH           installation directory          (default: /opt/iptv-panel)
  --user NAME          service user                    (default: iptvpanel)
  --manifest URL       use a different update manifest (default: this repo's)
  --no-web             skip the web UI (binary only)
  --no-deps            skip the dependency install
  --no-service         do not install/start the systemd unit
  -h, --help           this help

Environment: TRIAL=1, LICENSE_KEY=..., PANEL_DIR=..., PANEL_USER=..., PANEL_VERSION=...
EOF
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --trial)      TRIAL=1; shift ;;
        --license)    LICENSE_KEY="${2:-}"; shift 2 ;;
        --version)    VERSION="${2:-}"; shift 2 ;;
        --dir)        DIR="${2:-}"; shift 2 ;;
        --user)       SVC_USER="${2:-}"; shift 2 ;;
        --manifest)   MANIFEST_OVERRIDE="${2:-}"; shift 2 ;;
        --no-web)     DO_WEB=0; shift ;;
        --no-deps)    DO_DEPS=0; shift ;;
        --no-service) DO_SERVICE=0; shift ;;
        -h|--help)    usage 0 ;;
        *) echo "unknown option: $1" >&2; usage 1 ;;
    esac
done

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\033[31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root:  curl -fsSL $RAW/install.sh | sudo bash"

# ── which track ───────────────────────────────────────────────────────────
if [ "$TRIAL" = 1 ]; then
    BIN="iptv-panel-trial"
    MANIFEST="${MANIFEST_OVERRIDE:-$RAW/updates-trial.json}"
    SHA_EXPECT="${PANEL_SHA:-$SHA_TRIAL_DEFAULT}"
    TRACK_NAME="trial"
else
    BIN="iptv-panel"
    MANIFEST="${MANIFEST_OVERRIDE:-$RAW/updates.json}"
    SHA_EXPECT="${PANEL_SHA:-$SHA_PROD_DEFAULT}"
    TRACK_NAME="production"
fi

echo "IPTV Panel installer"
echo "  track   : $TRACK_NAME"
echo "  version : $VERSION"
echo "  target  : $DIR"

# ── 1. dependencies ───────────────────────────────────────────────────────
if [ "$DO_DEPS" = 1 ]; then
    say "Installing dependencies"
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq curl ca-certificates ffmpeg python3 sqlite3 yt-dlp \
            || apt-get install -y -qq curl ca-certificates ffmpeg python3 sqlite3
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl ca-certificates ffmpeg python3 sqlite yt-dlp \
            || dnf install -y curl ca-certificates ffmpeg python3 sqlite
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl ca-certificates ffmpeg python3 sqlite
        yum install -y yt-dlp 2>/dev/null || true
    else
        warn "unknown package manager — make sure curl, ffmpeg and sqlite3 are installed"
    fi
fi
command -v curl >/dev/null 2>&1 || die "curl is required"
if ! command -v ffmpeg >/dev/null 2>&1; then
    warn "ffmpeg was not found on PATH; streaming that needs transcoding will not work"
fi

# ── 2. user + directories ─────────────────────────────────────────────────
say "Creating the service user and directories"
if ! id -u "$SVC_USER" >/dev/null 2>&1; then
    useradd -r -s /usr/sbin/nologin "$SVC_USER" 2>/dev/null \
        || useradd -r -s /sbin/nologin "$SVC_USER"
fi
install -d -o "$SVC_USER" -g "$SVC_USER" \
    "$DIR" "$DIR/bin" "$DIR/config" "$DIR/data" "$DIR/logs" "$DIR/web"

# ── 3. binary ─────────────────────────────────────────────────────────────
say "Downloading $BIN $VERSION"
curl -fsSL -o "$DIR/bin/$BIN" "$RAW/releases/$BIN-$VERSION"
echo "$SHA_EXPECT  $DIR/bin/$BIN" | sha256sum -c - \
    || die "checksum mismatch — refusing to install (truncated download?)"
chmod 0755 "$DIR/bin/$BIN"
chown "$SVC_USER:$SVC_USER" "$DIR/bin/$BIN"

REPORTED="$("$DIR/bin/$BIN" --version 2>/dev/null | awk '{print $2}')"
[ -n "$REPORTED" ] || die "the downloaded binary does not run"
echo "  binary reports: $REPORTED"
if [ "$REPORTED" != "$VERSION" ]; then
    warn "the script pins $VERSION but the binary reports $REPORTED"
fi

# ── 4. web UI, from the signed manifest ───────────────────────────────────
# --update-apply re-verifies everything with the vendor Ed25519 signature and
# the per-file SHA-256, so the interface can never be a stale or tampered copy.
if [ "$DO_WEB" = 1 ]; then
    say "Installing the web UI from the signed manifest"
    runuser -u "$SVC_USER" -- "$DIR/bin/$BIN" -c "$DIR/config/config.json" \
        --update-apply "$MANIFEST" --web-root "$DIR/web"
    WEB_FILES="$(find "$DIR/web" -type f 2>/dev/null | wc -l)"
    [ "$WEB_FILES" -gt 0 ] || die "the web UI was not installed"
    echo "  web files: $WEB_FILES"
fi

# ── 5. configuration (storage paths + licence) ────────────────────────────
# The compiled-in defaults point at /opt/iptv-panel, so a different --dir has
# to be written out explicitly or the panel would use the default database.
CFG="$DIR/config/config.json"

if [ "$TRIAL" != 1 ] && [ -z "$LICENSE_KEY" ]; then
    HWID="$("$DIR/bin/$BIN" --hwid 2>/dev/null | awk '{print $NF}')"
    cat <<EOF

────────────────────────────────────────────────────────────────────
 Licence required.

 This server's HWID:

     $HWID

 Send it to the vendor to get a licence key, then run:

   curl -fsSL $RAW/install.sh | sudo bash -s -- --license '<KEY>'

 (Re-running is safe: the binary and the web UI are already installed.)
────────────────────────────────────────────────────────────────────
EOF
    exit 0
fi

command -v python3 >/dev/null 2>&1 || die "python3 is required to write the configuration"

say "Writing $CFG"
python3 - "$CFG" "$DIR" "$LICENSE_KEY" <<'PY'
import json, sys, os
path, base, key = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = {}
if os.path.exists(path):
    try:
        with open(path) as fh:
            cfg = json.load(fh)
    except Exception:
        cfg = {}
# Only fill in what is missing, so an operator edit is never overwritten.
for k, v in (("db_path",  base + "/data/panel.db"),
             ("log_dir",  base + "/logs"),
             ("web_root", base + "/web")):
    if not cfg.get(k):
        cfg[k] = v
if key:
    cfg["license_key"] = key
with open(path, "w") as fh:
    json.dump(cfg, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
chown "$SVC_USER:$SVC_USER" "$CFG"
chmod 0600 "$CFG"

# ── 6. database, secrets, first admin ─────────────────────────────────────
# Only on a fresh install: --init-admin refuses to start while another panel
# holds the ports, and an existing installation already has its admin account.
if [ -f "$DIR/data/panel.db" ]; then
    say "Existing database found — keeping it (admin account untouched)"
else
    say "Creating the database and the first admin account"
    if ! runuser -u "$SVC_USER" -- "$DIR/bin/$BIN" -c "$CFG" --init-admin; then
        warn "the panel could not initialise — last log lines:"
        tail -n 15 "$DIR/logs/panel.log" 2>/dev/null | sed 's/^/    /' || true
        die "fix the problem above (ports 18080/18081/18099 must be free) and re-run"
    fi
fi

# Point the panel at the update manifest, but never overwrite a value the
# operator already chose.
if [ -f "$DIR/data/panel.db" ]; then
    runuser -u "$SVC_USER" -- python3 - "$DIR/data/panel.db" "$MANIFEST" <<'PY'
import sqlite3, sys
db, manifest = sys.argv[1], sys.argv[2]
con = sqlite3.connect(db)
row = con.execute("SELECT value FROM settings WHERE key='update_url'").fetchone()
if row and row[0]:
    print("  update manifest kept: " + row[0])
else:
    con.execute(
        "INSERT INTO settings(key,value,updated_at) VALUES('update_url',?,datetime('now')) "
        "ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=datetime('now')",
        (manifest,))
    con.commit()
    print("  update manifest: " + manifest)
con.close()
PY
fi

# ── 7. systemd ────────────────────────────────────────────────────────────
if [ "$DO_SERVICE" = 1 ]; then
    say "Installing the systemd service"
    cat > /etc/systemd/system/iptv-panel.service <<UNIT
[Unit]
Description=IPTV Panel (delivery node)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SVC_USER
Group=$SVC_USER
WorkingDirectory=$DIR
ExecStart=$DIR/bin/$BIN -c $DIR/config/config.json
# The panel replaces its own binary and exits 0 to activate it; this is what
# brings it back on the new build.
Restart=always
RestartSec=3
LimitNOFILE=65536
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable iptv-panel >/dev/null 2>&1 || true
    systemctl restart iptv-panel
    sleep 4

    say "Result"
    echo "  service : $(systemctl is-active iptv-panel)"
    echo "  version : $("$DIR/bin/$BIN" --version 2>/dev/null)"
    echo "  health  : HTTP $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18080/health || echo '?')"
    echo "  admin UI: http://<this-server>:18080"
    echo
    if [ "$TRIAL" = 1 ]; then
        warn "this is the TRIAL build — not for production; it stops on its end date"
    fi
    echo "  Update it later with:"
    echo "    runuser -u $SVC_USER -- $DIR/bin/$BIN -c $DIR/config/config.json \\"
    echo "        --update-apply $MANIFEST"
    echo "    systemctl restart iptv-panel"
else
    say "Skipping the service (--no-service)"
    echo "  start it with: $DIR/bin/$BIN -c $DIR/config/config.json"
fi

echo
echo "Open http://<this-server>:18080 and log in with the admin password printed above."
echo "Remember to set the public host in Settings → General & Ports."
