#!/usr/bin/env python3
"""YouTube login browser for the IPTV panel -- loopback helper.

Why this exists: YouTube binds a Google session to the network it was created
on. Cookies exported from a home browser keep working here for five or ten
minutes and then "Sign in to confirm you're not a bot" comes back, because the
session is being replayed from a different (datacenter) IP. So the login has
to happen HERE, from the server's own IP: the admin drives a real Chromium
window through the panel (/ytlogin/*), signs in once, and the resulting
session is exported to the same Netscape cookie file yt-dlp already reads.

The service listens on 127.0.0.1 only; the panel proxies /ytlogin/<endpoint>
here and requires an admin session for every call. Endpoints (single path
segment, JSON in / JSON out):

  GET  /state?last=<sig>   browser status + live screenshot
  POST /start              launch Chromium at the Google sign-in page
  POST /stop               export cookies, close Chromium and Xvfb
  POST /goto               {"url": ...} -- google/youtube hosts only
  POST /input              {"type": "click"|"key"|"text"|"wheel", ...}
  POST /export             write the cookie file now

The browser runs headed under Xvfb on purpose: a real Chrome window carries a
normal UA and navigator.webdriver, and any captcha Google shows is a picture
the admin can solve with a click instead of a wall we cannot read.

Env: IPTV_YTLOGIN_PORT (8788), IPTV_YTLOGIN_IDLE_S (600 -- close the browser
after this many seconds without an admin page open), IPTV_YTLOGIN_WARM_HOURS
(12 -- revisit youtube.com this often to keep the session used from its own
IP; 0 disables).
"""

import asyncio
import base64
import hashlib
import json
import os
import signal
import subprocess
import sys
import time
import urllib.parse
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent          # /opt/iptv-panel
PROFILE_DIR = ROOT / "data" / "yt-profile"             # persistent Chromium profile
COOKIE_FILE = ROOT / "data" / "yt-cookies-merged.txt"  # Netscape file yt-dlp reads
PORT = int(os.environ.get("IPTV_YTLOGIN_PORT", "8788"))
IDLE_S = int(os.environ.get("IPTV_YTLOGIN_IDLE_S", "600"))
WARM_H = float(os.environ.get("IPTV_YTLOGIN_WARM_HOURS", "12"))
VIEW_W, VIEW_H = 1280, 800

SIGNIN_URL = ("https://accounts.google.com/ServiceLogin?service=youtube"
              "&continue=https%3A%2F%2Fwww.youtube.com%2F")
HOME_URL = "https://www.youtube.com/?hl=en&persist_hl=1"

# The browser may only be steered at Google/YouTube surfaces: this process can
# read the server's filesystem through Chromium, so an open goto would be an
# admin-only but still pointless local file:// reader.
ALLOWED_HOSTS = ("youtube.com", "google.com", "googleapis.com", "gstatic.com",
                 "googlevideo.com", "googleusercontent.com", "ggpht.com",
                 "ytimg.com", "doubleclick.net", "g.co", "withgoogle.com")

# Present only after a real sign-in on this profile.
AUTH_COOKIE_NAMES = {"SID", "__Secure-1PSID", "LOGIN_INFO"}

ENDPOINTS_GET = {"state"}
ENDPOINTS_POST = {"start", "stop", "goto", "input", "export"}


def log(msg):
    print(time.strftime("[%Y-%m-%d %H:%M:%S]"), msg, file=sys.stderr, flush=True)


def host_allowed(url):
    try:
        parts = urllib.parse.urlsplit(url)
    except ValueError:
        return False
    if parts.scheme not in ("http", "https"):
        return False
    host = (parts.hostname or "").lower()
    return any(host == a or host.endswith("." + a) for a in ALLOWED_HOSTS)


def host_relevant(domain):
    # Cookies yt-dlp will ever send: the auth ones live on .google.com, the
    # player ones on .youtube.com. Everything else in the profile is noise.
    d = (domain or "").lstrip(".").lower()
    for root in ("google.com", "youtube.com"):
        if d == root or d.endswith("." + root):
            return True
    return False


def netscape_text(cookies):
    now = int(time.time())
    lines = [
        "# Netscape HTTP Cookie File",
        "# Server-side YouTube session (tools/yt_login_server.py).",
        "# Exported from the panel's own browser -- do not overwrite by hand,",
        "# a copy minted on another IP stops working within minutes.",
    ]
    for c in sorted(cookies, key=lambda c: (c.get("domain", ""), c.get("name", ""))):
        domain = c.get("domain", "")
        flag = "TRUE" if domain.startswith(".") else "FALSE"
        path = c.get("path") or "/"
        secure = "TRUE" if c.get("secure") else "FALSE"
        exp = c.get("expires") or -1
        try:
            exp = int(exp)
        except (TypeError, ValueError):
            exp = -1
        if exp <= 0:
            # Session cookies have no date; the format requires one. A week is
            # longer than the browser keeps them but harmless: the warm refresh
            # rewrites the file anyway, and an unknown value is ignored upstream.
            exp = now + 7 * 86400
        name = str(c.get("name", "")).replace("\t", " ").replace("\n", "")
        value = str(c.get("value", "")).replace("\t", " ").replace("\r", "").replace("\n", "")
        prefix = "#HttpOnly_" if c.get("httpOnly") else ""
        lines.append(f"{prefix}{domain}\t{flag}\t{path}\t{secure}\t{exp}\t{name}\t{value}")
    return "\n".join(lines) + "\n"


def ensure_home():
    """Chromium must start with a writable HOME.

    Without one crashpad resolves an empty database path, refuses with
    "--database is required" and the browser dies on SIGTRAP before opening a
    window -- which is exactly what happened when the iptvpanel account had no
    home directory. Prefer the caller's HOME, else fall back to a directory
    this service owns, so a fresh install never depends on account state.
    """
    fallback = ROOT / "data" / "yt-home"
    for candidate in (os.environ.get("HOME") or "", str(fallback)):
        if not candidate:
            continue
        try:
            path = Path(candidate)
            path.mkdir(parents=True, exist_ok=True)
            probe = path / ".write-probe"
            probe.touch()
            probe.unlink()
            os.environ["HOME"] = candidate
            return
        except OSError:
            continue
    raise RuntimeError("no writable HOME for Chromium")


class BrowserSession:
    """One Chromium-under-Xvfb at a time, plus the exported cookie file."""

    def __init__(self):
        self.pw = None            # started playwright driver
        self.ctx = None           # persistent browser context
        self.xvfb = None
        self.display = None
        self.lock = asyncio.Lock()
        self.last_seen = time.time()
        self.last_warm = 0.0
        self.stop_reason = "not started yet"

    # ── lifecycle ───────────────────────────────────────────────────────

    async def _start_xvfb(self):
        for num in range(99, 89, -1):
            lock = Path(f"/tmp/.X{num}-lock")
            sock = Path(f"/tmp/.X11-unix/X{num}")
            if lock.exists() or sock.exists():
                continue
            proc = subprocess.Popen(
                ["Xvfb", f":{num}", "-screen", "0", f"{VIEW_W}x{VIEW_H}x24",
                 "-nolisten", "tcp"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            await asyncio.sleep(0.7)
            if proc.poll() is None:
                self.xvfb, self.display = proc, f":{num}"
                log(f"xvfb on {self.display}")
                return
            log(f"xvfb :{num} exited rc={proc.returncode}")
        raise RuntimeError("no free X display for Xvfb")

    async def _launch(self, url):
        # Order matters twice over: ensure_home() must run before the driver
        # starts (it snapshots the environment), and Xvfb's DISPLAY before
        # Chromium starts for the same reason -- the Playwright driver is a
        # child process, so a DISPLAY set afterwards never reaches Chrome
        # ("missing X server").
        ensure_home()
        if self.xvfb is None:
            await self._start_xvfb()
        os.environ["DISPLAY"] = self.display
        if self.pw is None:
            from playwright.async_api import async_playwright
            self.pw = await async_playwright().start()
        PROFILE_DIR.mkdir(parents=True, exist_ok=True)
        args = [
            "--no-sandbox",              # non-root service in a container-ish env
            "--disable-dev-shm-usage",   # /tmp-sized /dev/shm
            "--disable-blink-features=AutomationControlled",
            f"--window-size={VIEW_W},{VIEW_H}",
        ]
        self.ctx = await self.pw.chromium.launch_persistent_context(
            str(PROFILE_DIR),
            headless=False,
            args=args,
            viewport={"width": VIEW_W, "height": VIEW_H},
            device_scale_factor=1,
            locale="en-US",
            timezone_id="Europe/Tirane",
            ignore_https_errors=False,
        )
        page = self.ctx.pages[0] if self.ctx.pages else await self.ctx.new_page()
        try:
            await page.goto(url, wait_until="domcontentloaded", timeout=60000)
        except Exception as e:
            # A slow consent/login load is not fatal -- the window is up and
            # the admin can see what happened in the screenshot.
            log(f"initial goto warning: {e}")
        self.stop_reason = ""
        log(f"browser up for {url}")

    async def start(self, url=None):
        url = url or SIGNIN_URL
        if url != SIGNIN_URL and not host_allowed(url):
            raise ValueError("only google/youtube URLs can be opened")
        async with self.lock:
            self.last_seen = time.time()
            if self.ctx is not None:
                return {"ok": True, "already_running": True}
            try:
                await self._launch(url)
            except Exception as e:
                orig = e
                # A crashed Chromium leaves SingletonLock behind; nobody is
                # using the profile (ctx is None), so drop it and retry once.
                stale = PROFILE_DIR / "SingletonLock"
                if stale.exists() or stale.is_symlink():
                    try:
                        stale.unlink()
                        log("removed stale profile lock, retrying launch")
                        await self._launch(url)
                        orig = None
                    except Exception as e2:
                        orig = e2
                if orig is not None:
                    log(f"launch failed: {orig!r}")
                    await self._teardown()
                    raise RuntimeError(f"launch failed: {orig}") from orig
            return {"ok": True}

    async def _teardown(self):
        if self.ctx is not None:
            try:
                await self.ctx.close()
            except Exception:
                pass
            self.ctx = None
        if self.pw is not None:
            try:
                await self.pw.stop()
            except Exception:
                pass
            self.pw = None
        if self.xvfb is not None:
            self.xvfb.terminate()
            try:
                self.xvfb.wait(timeout=5)
            except Exception:
                self.xvfb.kill()
            self.xvfb = None
            self.display = None

    async def stop(self, reason="manual"):
        async with self.lock:
            return await self._stop_locked(reason)

    async def _stop_locked(self, reason):
        exported = None
        if self.ctx is not None:
            try:
                exported = await self._export_locked()
            except Exception as e:
                log(f"export on stop failed: {e}")
        await self._teardown()
        self.stop_reason = reason
        log(f"browser stopped ({reason})")
        return {"ok": True, "reason": reason, "exported": exported}

    # ── cookies ─────────────────────────────────────────────────────────

    async def _export_locked(self):
        if self.ctx is None:
            raise RuntimeError("browser is not running")
        cookies = await self.ctx.cookies()
        wanted = [c for c in cookies if host_relevant(c.get("domain", ""))]
        text = netscape_text(wanted)
        tmp = COOKIE_FILE.with_name(COOKIE_FILE.name + ".tmp")
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.replace(tmp, COOKIE_FILE)
        if os.geteuid() == 0:
            try:
                import pwd
                st = pwd.getpwnam("iptvpanel")
                os.chown(COOKIE_FILE, st.pw_uid, st.pw_gid)
            except Exception:
                pass
        log(f"exported {len(wanted)} cookies to {COOKIE_FILE}")
        return {"count": len(wanted), "path": str(COOKIE_FILE)}

    async def export(self):
        async with self.lock:
            self.last_seen = time.time()
            return {"ok": True, **await self._export_locked()}

    # ── state / input ───────────────────────────────────────────────────

    def _page(self):
        if self.ctx is None or not self.ctx.pages:
            return None
        return self.ctx.pages[-1]

    async def _logged_in(self):
        try:
            cookies = await self.ctx.cookies()
        except Exception:
            return False
        return any(c.get("name") in AUTH_COOKIE_NAMES and
                   host_relevant(c.get("domain", "")) for c in cookies)

    async def state(self, last_sig):
        async with self.lock:
            self.last_seen = time.time()
            out = {
                "running": self.ctx is not None,
                "reason": self.stop_reason,
                "viewport": {"w": VIEW_W, "h": VIEW_H},
                "idle_s": 0,
                "exported_at": exported_mtime(),
            }
            page = self._page()
            if page is None:
                if self.ctx is not None:   # context died under us
                    await self._teardown()
                    self.stop_reason = "browser exited"
                return out
            out["idle_s"] = min(IDLE_S, int(time.time() - self.last_seen))
            try:
                out["url"] = page.url
            except Exception:
                out["url"] = ""
            try:
                out["title"] = await page.title()
            except Exception:
                out["title"] = ""
            out["logged_in"] = await self._logged_in()
            try:
                shot = await page.screenshot(type="jpeg", quality=72, timeout=8000)
            except Exception as e:
                out["shot_error"] = str(e)[:200]
                return out
            sig = hashlib.sha1(shot).hexdigest()[:16]
            out["sig"] = sig
            if sig != last_sig:
                out["shot"] = base64.b64encode(shot).decode("ascii")
            return out

    async def goto(self, url):
        if not host_allowed(url):
            raise ValueError("only google/youtube URLs can be opened")
        async with self.lock:
            self.last_seen = time.time()
            page = self._page()
            if page is None:
                raise RuntimeError("browser is not running")
            try:
                await page.goto(url, wait_until="domcontentloaded", timeout=60000)
            except Exception as e:
                # The navigation still usually committed; the screenshot tells.
                log(f"goto warning: {e}")
            return {"ok": True, "url": page.url}

    async def handle_input(self, payload):
        kind = payload.get("type")
        async with self.lock:
            self.last_seen = time.time()
            page = self._page()
            if page is None:
                raise RuntimeError("browser is not running")
            if kind == "click":
                x, y = clamp_point(payload)
                await page.mouse.click(x, y)
            elif kind == "move":
                x, y = clamp_point(payload)
                await page.mouse.move(x, y)
            elif kind == "wheel":
                x, y = clamp_point(payload)
                dx = int(payload.get("dx") or 0)
                dy = int(payload.get("dy") or 0)
                await page.mouse.move(x, y)
                await page.mouse.wheel(dx, dy)
            elif kind == "key":
                key = str(payload.get("key") or "")
                if not key:
                    raise ValueError("missing key")
                await page.keyboard.press(key)
            elif kind == "text":
                text = str(payload.get("text") or "")
                if not text:
                    raise ValueError("missing text")
                # keyboard.type(): real key events, what sites expect -- unlike
                # insert_text it drives password fields and keydown listeners.
                await page.keyboard.type(text, delay=25)
            else:
                raise ValueError(f"unknown input type: {kind!r}")
            return {"ok": True}


def clamp_point(payload):
    try:
        x = int(payload.get("x"))
        y = int(payload.get("y"))
    except (TypeError, ValueError):
        raise ValueError("click needs numeric x/y")
    return max(0, min(VIEW_W - 1, x)), max(0, min(VIEW_H - 1, y))


def exported_mtime():
    try:
        return int(COOKIE_FILE.stat().st_mtime)
    except OSError:
        return 0


# ── background loops ────────────────────────────────────────────────────

async def idle_watch(sess):
    while True:
        await asyncio.sleep(15)
        if sess.ctx is None:
            continue
        idle = time.time() - sess.last_seen
        if idle > IDLE_S:
            log(f"no admin page for {int(idle)}s -- closing browser")
            try:
                await sess.stop(f"idle {int(idle)}s")
            except Exception as e:
                log(f"idle stop failed: {e}")


async def warm_loop(sess):
    # Keeps the session visibly used from the IP it was created on, and folds
    # any rotated short-lived cookies back into the exported file.
    await asyncio.sleep(90)
    while True:
        await asyncio.sleep(1800)
        if WARM_H <= 0 or sess.ctx is not None:
            continue
        if time.time() - sess.last_warm < WARM_H * 3600:
            continue
        sess.last_warm = time.time()
        log("warm refresh: visiting youtube.com from the server IP")
        try:
            await sess.start(HOME_URL)
            await asyncio.sleep(6)
            await sess.stop("warm refresh")
        except Exception as e:
            log(f"warm refresh failed: {e}")
            try:
                await sess.stop("warm refresh failed")
            except Exception:
                pass


# ── HTTP front (loopback only) ──────────────────────────────────────────

def http_status_line(code):
    return {200: "200 OK", 400: "400 Bad Request", 404: "404 Not Found",
            405: "405 Method Not Allowed", 413: "413 Payload Too Large",
            500: "500 Internal Server Error"}.get(code, f"{code} Status")


async def write_json(writer, code, obj):
    body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
    head = (f"HTTP/1.1 {http_status_line(code)}\r\n"
            f"Content-Type: application/json; charset=utf-8\r\n"
            f"Content-Length: {len(body)}\r\n"
            f"Cache-Control: no-store\r\n"
            f"Connection: close\r\n\r\n").encode("ascii")
    writer.write(head + body)
    await writer.drain()


async def route(sess, method, seg, query, body):
    """Returns (http_code, json_object)."""
    if seg == "state" and method == "GET":
        params = urllib.parse.parse_qs(query)
        last = (params.get("last") or [""])[0]
        return 200, await sess.state(last)
    if seg in ENDPOINTS_POST and method == "POST":
        payload = {}
        if body:
            try:
                payload = json.loads(body.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                return 400, {"error": "invalid JSON body"}
            if not isinstance(payload, dict):
                return 400, {"error": "JSON object expected"}
        if seg == "start":
            return 200, await sess.start(payload.get("url"))
        if seg == "stop":
            return 200, await sess.stop(payload.get("reason") or "manual")
        if seg == "goto":
            url = str(payload.get("url") or "")
            if not url:
                return 400, {"error": "missing url"}
            return 200, await sess.goto(url)
        if seg == "input":
            return 200, await sess.handle_input(payload)
        if seg == "export":
            return 200, await sess.export()
    if seg in ENDPOINTS_GET or seg in ENDPOINTS_POST:
        return 405, {"error": f"use {'GET' if seg in ENDPOINTS_GET else 'POST'}"}
    return 404, {"error": "unknown endpoint"}


async def handle_client(reader, writer, sess):
    peer = writer.get_extra_info("peername")
    peer_ip = peer[0] if peer else ""
    if peer_ip not in ("127.0.0.1", "::1"):
        writer.close()
        return
    try:
        head = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), timeout=10)
    except Exception:
        writer.close()
        return
    if len(head) > 64 * 1024:
        await write_json(writer, 413, {"error": "headers too large"})
        writer.close()
        return
    lines = head.split(b"\r\n")
    try:
        method, target, _version = lines[0].decode("latin-1").split(" ", 2)
    except ValueError:
        await write_json(writer, 400, {"error": "bad request line"})
        writer.close()
        return
    headers = {}
    for line in lines[1:]:
        if b":" in line:
            k, v = line.split(b":", 1)
            headers[k.decode("latin-1").strip().lower()] = v.decode("latin-1").strip()
    try:
        clen = int(headers.get("content-length", "0") or "0")
    except ValueError:
        clen = 0
    if clen > 4 * 1024 * 1024:
        await write_json(writer, 413, {"error": "body too large"})
        writer.close()
        return
    body = b""
    if clen:
        try:
            body = await asyncio.wait_for(reader.readexactly(clen), timeout=10)
        except Exception:
            await write_json(writer, 400, {"error": "truncated body"})
            writer.close()
            return

    path, _, query = target.partition("?")
    seg = path.lstrip("/")
    code, obj = 404, {"error": "unknown endpoint"}
    try:
        if "/" in seg or not seg:
            code, obj = 404, {"error": "unknown endpoint"}
        else:
            code, obj = await route(sess, method, seg, query, body)
    except ValueError as e:
        code, obj = 400, {"error": str(e)}
    except Exception as e:  # noqa: BLE001 -- report, keep serving
        log(f"error in /{seg}: {e!r}")
        code, obj = 500, {"error": str(e)[:300]}
    try:
        await write_json(writer, code, obj)
    except Exception:
        pass
    writer.close()


async def main():
    PROFILE_DIR.mkdir(parents=True, exist_ok=True)
    sess = BrowserSession()
    stop_evt = asyncio.Event()

    def on_signal(sig, _frame):
        log(f"signal {sig} -- shutting down")
        stop_evt.set()

    for s in (signal.SIGTERM, signal.SIGINT):
        signal.signal(s, on_signal)

    server = await asyncio.start_server(
        lambda r, w: handle_client(r, w, sess), "127.0.0.1", PORT)
    log(f"yt-login helper on 127.0.0.1:{PORT} "
        f"(profile={PROFILE_DIR}, cookies={COOKIE_FILE}, idle={IDLE_S}s, "
        f"warm={WARM_H}h)")

    loops = [asyncio.create_task(idle_watch(sess)),
             asyncio.create_task(warm_loop(sess))]
    async with server:
        wait_server = asyncio.create_task(server.serve_forever())
        await stop_evt.wait()
        wait_server.cancel()
    for task in loops:
        task.cancel()
    if sess.ctx is not None:
        try:
            await asyncio.wait_for(sess.stop("service stopping"), timeout=10)
        except Exception as e:
            log(f"shutdown stop failed: {e}")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
