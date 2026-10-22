# HA — Main Mirror (Hot Standby) me Failover Manual ose Auto

Nëse digjet disku / CPU / rrjeti i **Main Server-it**, i gjithë paneli bie.
Me këtë sistem, një **server pasqyrë (standby)** merr databazën live çdo
15 sekonda dhe kur main-i vdes ndërron rolet brenda ~30 sekondash — pa humbur
asnjë linjë, asnjë klient dhe asnjë rishitës.

Pjesët (asnjë ndryshim në bërthamën C++, asnjë efekt anësor mbi streaming):

| Pjesë | Ku rrjedh | Çfarë bën |
|---|---|---|
| `scripts/iptv-mirror-sync.sh` | te **main-i aktiv** | Snapshot i databazës me SQLite online-backup API (gjithmonë konsistent, paneli vazhdon punën) + dërgim me rsync (transferohen vetëm bllok-zgjedhur — 103 MB → disa MB) |
| `scripts/iptv-failover-watch.sh` | te **pasqyra** | Poll `GET :18099/health` i main-it. Pas `HEALTH_FAILS` dështimesh radhazi → merr rolin |
| `scripts/setup_mirror.sh` | të dyja | Instalimi i shpejtë i njësisë systemd + skedarit të konfigurimit |
| `scripts/mirror.conf.in` | model | Konfigurimi i plotë i komentuar |

## Instalimi (2 komanda)

### 1. Te main-i aktiv
```bash
sudo scripts/setup_mirror.sh --master <IP-E-E-PASQYRËS>
sudo ssh-copy-id iptvpanel@<IP-E-E-PASQYRËS>
# te pasqyra: mkdir -p /opt/iptv-panel/data/mirror-in && chown iptvpanel: /opt/iptv-panel/data/mirror-in
```
Kjo e aktivizon `systemd: iptv-mirror-sync` — snapshot-i niset automatikisht çdo 15 s.

### 2. Te pasqyra (standby)
```bash
# Manual (ju bëni vetë kalimin e IP/DNS):
sudo scripts/setup_mirror.sh --standby <IP-E-E-MAIN-IT> --mode manual

# Automatik me floating IP / DNS:
sudo scripts/setup_mirror.sh --standby <IP-E-E-MAIN-IT> --mode auto --provider vip
sudo scripts/setup_mirror.sh --standby <IP-E-E-MAIN-IT> --mode auto --provider cloudflare
```

## Modelet e failover-it

### `manual` (i thjeshtë, i rekomanduar pa eksperiencë me VIP)
Kur pasqyra sheh që main-i ka rënë:
1. Shkruan rastin te `data/failover.state`.
2. Dërgon alert (nëse keni vendosur `ALERT_WEBHOOK` — Discord ose Telegram).
3. Ju vetë bëni kalimin: ndërroni A-record te Cloudflare, ose `ip addr add` te
   floating IP, ose startoni shërbimin me dorë.

### `auto` (3 provider-a)
| Provider | Kushti | Si punon |
|---|---|---|
| `vip` | të dy serverat në të njëjtin rrjet fizik / datacenter me IP floating (OVH/Hetzner failover IP) | `ip addr add <VIP> dev <IF>` + `arping` paruke; në rikthim heq IP-në vetë |
| `cloudflare` | regjistruar DNS-ja te Cloudflare | Ndërron A-record te IP-ja e pasqyrës me API (TTL 60) |
| `webhook` | ndonjë mekanizëm i juaji (p.sh. ndryshim IP te routeri) | POST `{"event":"main_down",...}` te endpoint-i juaj |

Konfigurimet përkatëse gjenden te `scripts/mirror.conf.in` (`CF_API_TOKEN`,
`CF_ZONE_ID`, `CF_RECORD_ID`, `VIP`, `VIP_IF`, `FAILOVER_WEBHOOK`…).

### Si sillet kur main-i kthehet
- `vip` → heq IP-në floating nga pasqyra dhe (nëse `MIRROR_STANDDOWN_STOP_PANEL=1`)
  fik shërbimin lokal; main-i merr trafikun sërish.
- `cloudflare` → rikthen A-record te main-i (setoni rekordin sërish me dorë ose
  përsërisni API-call-in nga main-i; nuk prek main-in pa mundësi nga pasqyra).
- `manual` → vetëm alert "main is back".

## Ftohtë → Nxehtë (cold → hot standby)
Kur main-i vdes, `MIRROR_TAKEOVER_START_PANEL=1` (vendosur nga `--standby`)
nisin automatikisht `iptv-panel` te pasqyra. Për ta bërë gjithmonë gati, lërenë
panelin i ndaluar te pasqyra dhe lëreni këtë flag =1; atëherë rikthimi =
start automatik.

## Testi pa pritur vërtetë avarinë
```bash
# Simulim rënieje (nuk prek asgjë):
FAILOVER_SEED_STATE=down sudo -E bash /usr/local/bin/iptv-failover-watch.sh
# → duhet të logojë "MAIN IS BACK — standing down" dhe të lëshojë IP-në
```

## Siguria
- Sinku bëhet **vetëm mbi SSH** (chifruar), snapshot-i është i transaksioneve —
  kurrë gjysmë-prerje të databazës.
- `release()` **nuk fik panelin** veç nëse `MIRROR_STANDDOWN_STOP_PANEL=1`
  (që një rikthim i gabuar të mos vrasë një panel duke punuar).
- Alertet dërgohen me `allowed_mentions: {"parse": []}` (Discord).
- Përveç `panel.db`, mund të dërgohen skedare shtesë (`MIRROR_EXTRA_FILES`):
  çelësa, certifikata, `web/`.
