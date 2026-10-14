# Smart AI IPTV Panel — releases

Download-only repository. It holds the compiled panel binaries and the signed
update manifests that the panel reads to update itself. **No source code lives
here.**

## Downloads

| Build | Who is it for | Direct link |
|---|---|---|
| **Production** | licensed installations | [`releases/iptv-panel-<version>`](releases) |
| **Trial** | bug testing, no licence needed | [`releases/iptv-panel-trial-<version>`](releases) |

Every file is listed in [`SHA256SUMS`](SHA256SUMS).

## Installing

```bash
install -m 0755 iptv-panel /opt/iptv-panel/bin/iptv-panel
systemctl restart iptv-panel
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
