# Smart AI IPTV Panel — releases

Download-only repository. It holds the compiled panel binaries and the signed
update manifests that the panel reads to update itself. **No source code lives
here.**

## Contact & support

Questions, licence requests, bug reports and news: join the Discord server
**https://discord.gg/nPT3D4Sct**

## Downloads

| Build | Who is it for | Direct link |
|---|---|---|
| **Production** | licensed installations | [`releases/iptv-panel-<version>`](releases) |
| **Trial** | bug testing, no licence needed | [`releases/iptv-panel-trial-<version>`](releases) |
| **Web UI** (admin) | installed automatically by the panel | [`releases/web-admin-<version>.webpkg`](releases) |
| **Web UI** (portal) | installed automatically by the panel | [`releases/web-portal-<version>.webpkg`](releases) |

Every file is listed in [`SHA256SUMS`](SHA256SUMS).

The two `.webpkg` files carry the interface (HTML/JS/CSS). The panel installs
them by itself during an update, so they only need to be downloaded by hand if
you are assembling an installation offline.

## Installing on a new server

One command, straight from this repository:

```bash
curl -fsSL https://raw.githubusercontent.com/kfskenderbeu/Smart-Ai-Panel/main/install.sh | sudo bash
```

It installs the dependencies (`curl`, `ca-certificates`, `ffmpeg`, `python3`,
`sqlite3`), creates the `iptvpanel` user and `/opt/iptv-panel/{bin,config,data,logs,web}`,
downloads the binary and checks it against the SHA-256 pinned in the script,
installs the web UI from the signed manifest (the panel verifies the Ed25519
signature and every file checksum itself), prints the admin password and starts
the systemd service.

The first run prints this server's **HWID** and stops, because a production
licence is bound to it. Send the HWID to the vendor, then run it again with the
key:

```bash
curl -fsSL https://raw.githubusercontent.com/kfskenderbeu/Smart-Ai-Panel/main/install.sh \
  | sudo bash -s -- --license '<KEY>'
```

**Trial** (no licence, ends on its built-in date):

```bash
curl -fsSL https://raw.githubusercontent.com/kfskenderbeu/Smart-Ai-Panel/main/install.sh \
  | sudo bash -s -- --trial
```

Running the same command again on an existing installation updates it in place
and keeps the configuration, the database and the licence.

### Manual install

```bash
install -m 0755 iptv-panel /opt/iptv-panel/bin/iptv-panel
systemctl restart iptv-panel
```

The panel's own update mechanism installs the web UI, so an existing
installation only needs the binary:

```bash
iptv-panel --update-apply https://raw.githubusercontent.com/kfskenderbeu/Smart-Ai-Panel/main/updates.json
```

For a **fresh** installation, unpack the web UI next to the panel as well:

```bash
install -d /opt/iptv-panel/bin /opt/iptv-panel/web
install -m 0755 iptv-panel /opt/iptv-panel/bin/iptv-panel
iptv-panel --update-apply <manifest-url> --web-root /opt/iptv-panel/web
```

The trial build is a separate file (`iptv-panel-trial`) so it can never be
confused with a licensed binary:

```bash
install -m 0755 iptv-panel-trial /opt/iptv-panel/bin/iptv-panel-trial
```

## Updating from the panel

*Settings → General & Ports → **Update manifest URL***

| Track | Manifest URL |
|---|---|
| Production | `https://raw.githubusercontent.com/kfskenderbeu/Smart-Ai-Panel/main/updates.json` |
| Trial | `https://raw.githubusercontent.com/kfskenderbeu/Smart-Ai-Panel/main/updates-trial.json` |

Then open *Settings → License → ⬆️ Software Updates* and press
**Check for updates** → **Update now**. The panel restarts itself on the new
build; *Roll back* restores the previous one.

An update installs the binary **and** the interface that belongs to it
(HTML/JS/CSS), so the panel never ends up with a new backend and an old UI. If a
panel was updated before the interface was shipped this way, the update card
offers **🩹 Sync web UI** to install the matching files.

## Why downloading is safe

The panel installs a build only when **both** hold:

1. the manifest (`updates.json`) carries a valid **Ed25519** signature made with
   the vendor private key, and
2. the downloaded file's **SHA-256** matches the value inside that signed
   manifest.

Authenticity comes from the signature, not from secrecy, which is why the
binaries can be hosted publicly. A tampered or unsigned manifest is refused, and
so is a file whose content does not match.

## Trial builds

The trial build runs without a licence until the date baked into it, then stops
starting. The date and the badge are visible in *Settings → License*. Asking for
a newer trial build simply means downloading the latest one listed here.
