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
VERSION_DEFAULT="2.6.26"
SHA_PROD_DEFAULT="fb4279981cda81a000ea3bd1fc147364001245bed8c211059bbd257bd1103a38"
SHA_TRIAL_DEFAULT="836db4f262f3390f97314be9da555abbfdb7bc7cb62572e63ab5a66f5e29e181"
# The YouTube-login helper is a separate Python service the panel proxies to
# on loopback. It is pinned by checksum like the binary, but it is optional:
# if it is missing the panel still runs and only that one page is unusable.
SHA_HELPER_DEFAULT="0ff7f88e2c4a5870e816eb05d7a3aff59accf883e81cd0745d84547ad891f99d"

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
DO_BROWSER=1
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
  --no-browser         skip Playwright + Chromium (the YouTube-login browser)
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
        --no-browser) DO_BROWSER=0; shift ;;
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

# The YouTube-login helper is optional: it only adds the in-panel sign-in
# browser. Without it everything else works, so a failed download is a
# warning and not a failed install.
SHA_HELPER="${PANEL_SHA_HELPER:-$SHA_HELPER_DEFAULT}"
HELPER_URL="$RAW/releases/yt_login_server.py"
HELPER_UNIT_URL="$RAW/releases/iptv-ytlogin.service.in"
# The loopback port the panel and the helper use to talk to each other. It
# has to be the same number on both sides, so it is written into both units.
YTLOGIN_PORT="${IPTV_YTLOGIN_PORT:-8788}"
PYTHON_BIN="$(command -v python3 || true)"

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
        apt-get install -y -qq curl ca-certificates ffmpeg python3 sqlite3 yt-dlp xvfb \
            || apt-get install -y -qq curl ca-certificates ffmpeg python3 sqlite3 xvfb
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl ca-certificates ffmpeg python3 sqlite yt-dlp xvfb \
            || dnf install -y curl ca-certificates ffmpeg python3 sqlite xvfb
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl ca-certificates ffmpeg python3 sqlite xvfb
        yum install -y yt-dlp 2>/dev/null || true
    else
        warn "unknown package manager — make sure curl, ffmpeg and sqlite3 are installed"
    fi
fi
command -v curl >/dev/null 2>&1 || die "curl is required"
if ! command -v ffmpeg >/dev/null 2>&1; then
    warn "ffmpeg was not found on PATH; streaming that needs transcoding will not work"
fi
if ! command -v Xvfb >/dev/null 2>&1; then
    warn "Xvfb was not found; the 'YouTube Login' browser cannot open without it"
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

# ── 3b. the YouTube-login helper ───────────────────────────────────────────
# The panel proxies /ytlogin/* to a small Python service on loopback. Without
# it the panel still runs, but the "YouTube Login" page answers "connection
# refused", which looks like a broken panel rather than a missing optional
# service. The helper needs no network to listen and imports its browser
# driver lazily, so it is safe to install even where no browser is present.
#
# The helper and its systemd unit are one thing: without the unit the helper
# is useless, so both are optional together.
HELPER_INSTALLED=0
HELPER_TMPL=""
if [ -n "$SHA_HELPER" ] && command -v python3 >/dev/null 2>&1; then
    install -d -o "$SVC_USER" -g "$SVC_USER" "$DIR/tools"
    if curl -fsSL -o "$DIR/tools/yt_login_server.py.tmp" "$HELPER_URL" 2>/dev/null &&
       echo "$SHA_HELPER  $DIR/tools/yt_login_server.py.tmp" | sha256sum -c - >/dev/null 2>&1; then
        install -m 0755 -o "$SVC_USER" -g "$SVC_USER" \
            "$DIR/tools/yt_login_server.py.tmp" "$DIR/tools/yt_login_server.py"
        rm -f "$DIR/tools/yt_login_server.py.tmp"
        # The unit template travels with the helper, so a manual install and
        # an automatic one cannot drift apart.
        if curl -fsSL -o "$DIR/tools/iptv-ytlogin.service.in.tmp" "$HELPER_UNIT_URL" 2>/dev/null; then
            install -m 0644 -o "$SVC_USER" -g "$SVC_USER" \
                "$DIR/tools/iptv-ytlogin.service.in.tmp" "$DIR/tools/iptv-ytlogin.service.in"
            rm -f "$DIR/tools/iptv-ytlogin.service.in.tmp"
            HELPER_TMPL="$DIR/tools/iptv-ytlogin.service.in"
        fi
        HELPER_INSTALLED=1
        echo "  helper  : yt_login_server.py installed"
    else
        rm -f "$DIR/tools/yt_login_server.py.tmp"
        warn "the YouTube-login helper could not be installed (download or checksum failed)"
        warn "  the panel works without it; only the 'YouTube Login' page needs it"
    fi
else
    warn "skipping the YouTube-login helper (no python3, or the release pins none)"
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
# Both sides of the YouTube-login proxy read this port; keeping it in one
# place stops the panel and the helper from drifting apart.
Environment=IPTV_YTLOGIN_PORT=$YTLOGIN_PORT
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

    # ── 7b. the YouTube-login helper service ──────────────────────────────
    # The panel proxies /ytlogin/* to this service on loopback. It is
    # optional: if it cannot be installed the panel is still complete, so
    # this never fails the install.
    if [ "$HELPER_INSTALLED" = 1 ]; then
        say "Installing the YouTube-login helper service"
        # Chromium refuses to start without a writable HOME (it resolves its
        # crashpad database under it and dies on SIGTRAP otherwise).
        SVC_HOME="$(getent passwd "$SVC_USER" | cut -d: -f6)"
        [ -n "$SVC_HOME" ] || SVC_HOME="$DIR"
        install -d -o "$SVC_USER" -g "$SVC_USER" "$SVC_HOME"
        # Playwright's browsers may live outside the home directory on this
        # layout, so the helper is told where to look. When they are not
        # there, Playwright's own default is used instead.
        PW_ENV=""
        if [ -d "$DIR/bin/playwright" ]; then
            PW_ENV="Environment=PLAYWRIGHT_BROWSERS_PATH=$DIR/bin/playwright"
        fi
        # One template, rendered here and published with the release, so a
        # manual install and an automatic one cannot drift apart.
        if [ -n "$HELPER_TMPL" ]; then
            sed -e "s|@USER@|$SVC_USER|g" \
                -e "s|@DIR@|$DIR|g" \
                -e "s|@HOME@|$SVC_HOME|g" \
                -e "s|@PORT@|$YTLOGIN_PORT|g" \
                -e "s|@PYTHON@|${PYTHON_BIN:-/usr/bin/python3}|g" \
                -e "s|@PLAYWRIGHT@|$PW_ENV|g" \
                "$HELPER_TMPL" | sed -e '/^[[:space:]]*$/d' \
                > /etc/systemd/system/iptv-ytlogin.service
            chmod 0644 /etc/systemd/system/iptv-ytlogin.service
        else
            warn "the ytlogin unit template is missing, so the service is not installed"
            warn "  the helper is installed but nothing will start it"
        fi

        # The browser itself. The helper starts and answers without it, but
        # "Start browser" cannot: Playwright drives Chromium, and Chromium
        # needs an X server to run on. Both are installed here so the feature
        # works on a fresh machine; a failure is a warning, not a dead
        # install.
        if [ "$DO_BROWSER" = 1 ]; then
            say "Installing the browser for the YouTube-login helper"
            install -d -o "$SVC_USER" -g "$SVC_USER" "$DIR/bin/playwright"
            if ! python3 -m pip install --quiet --break-system-packages playwright 2>/dev/null; then
                python3 -m pip install --quiet playwright 2>/dev/null \
                    || warn "playwright could not be installed"
            fi
            if ! PLAYWRIGHT_BROWSERS_PATH="$DIR/bin/playwright" \
                 python3 -m playwright install chromium 2>/dev/null; then
                warn "Chromium could not be downloaded for Playwright"
                warn "  the browser will not open until it is:"
                warn "  PLAYWRIGHT_BROWSERS_PATH=$DIR/bin/playwright python3 -m playwright install chromium"
            else
                chown -R "$SVC_USER:$SVC_USER" "$DIR/bin/playwright" 2>/dev/null || true
            fi
        fi
        systemctl daemon-reload
        systemctl enable iptv-ytlogin >/dev/null 2>&1 || true
        systemctl restart iptv-ytlogin >/dev/null 2>&1 || true
        sleep 2
        if systemctl is-active --quiet iptv-ytlogin; then
            echo "  helper service : active (127.0.0.1:$YTLOGIN_PORT)"
        else
            warn "the iptv-ytlogin service did not start; the 'YouTube Login' page will say so"
        fi
    fi

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
