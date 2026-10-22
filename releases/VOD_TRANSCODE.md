# VOD Transcoding & Convert to MP4

Filmat dhe episodet që vijnë si **MKV/Bluray remux me audio DTS/E-AC3 dhe titra
PGS** nuk hapen në SmartSTB, MAG ose Smart TV: dekoderi pranon vetëm MPEG-TS me
audio që njeh. Paneli ofron dy zgjidhje, të zgjedhshme për çdo film, seri ose
episod veç e veç.

## 1. Live transcode

Te **Movies → Edit** ose **Series → Edit** dhe (për një episod të vetëm)
**Series → Episodes → Edit**, seksioni **⚙️ Transcoding & Playback**:

| Profil | Çfarë bën | Kur ta zgjidhni |
|---|---|---|
| **`auto`** | Zbulon kodekun (0.2 s, cache 1 h): H.264/MPEG-2 → **copy + AAC**; HEVC/AV1/VP9 → **H.264 1080p + AAC** | **Zgjedhja e rekomanduar** — mbulon të dyja rastet pa menduar |
| `pass` | Stream copy, asnjë transkodim | Burimi është tashmë H.264 + AAC dhe s'ka DTS |
| `aac` | Video **copy** (0% CPU), audio → **AAC 192k**, PGS hiqet | DTS/E-AC3 mbi video **H.264** |
| `fhd` | Video → H.264 1080p 4.5 Mbps + AAC (pa upscale) | Bitrate shumë i lartë për rrjetin |
| `hd` | Video → H.264 720p 2.2 Mbps + AAC | Lidhje e dobët |
| `sd` | Video → H.264 480p 900 kbps + AAC | Kursim maksimal |

> ⚠️ **10-bit**: libraritë e reja x264 e ruajnë thellësinë e burimit, pra një
> HEVC Main 10 rikodohej si **H.264 High 10** — po aq i palexueshëm sa HEVC.
> Rikodimi tani detyron gjithmonë `yuv420p` (8-bit, High ≤4.1). `auto` e
> trajton edhe H.264 10-bit si "nuk kopjohet".

> ⚠️ **HEVC (H.265)**: MAG, SmartSTB dhe shumica e Smart TV-ve nuk e dekodojnë.
> Me `pass`/`aac` video kopjohet ashtu si është dhe pajisja mbyll lidhjen pas
> ~2 MB pa asnjë gabim të dukshëm. `auto` e rikodon në H.264 automatikisht;
> `fhd`/`hd`/`sd` e rikodojnë gjithmonë.

- **Seria** vendos profilin default për të gjitha episodet.
- **Episodi** e anashkalon serinë kur ka vlerë të vet (opsioni *— Inherit from
  series —* e kthen te trashëgimia).
- Zgjedhja ruhet te `streams.transcode_profile` / `series_episodes.transcode_profile`.
- Nëse episodi ka `local_path`, ffmpeg lexon **nga disku** (jo nga interneti):
  transkodimi punon edhe kur burimi remot ka rënë.

## 2. Convert to MP4 (një herë, pastaj zero CPU)

Butoni **⚡ Convert** (te lista e filmave dhe te episodet) ose **⚡ Convert
Season** (te dritarja e episodve) nis një punë në sfond që prodhon:

- H.264 (`libx264`, CRF 22, faststart) + **AAC 192k**, pa titra PGS
- Skedari shkon te `data/vod/movie_<id>.mp4` / `episode_<id>.mp4`
  (gjithmonë `vod/` pranë databazës — një instancë testi nuk shkruan në
  direktorin e prodhimit)
- Në fund paneli shkruan `local_path`; luajtja pastaj është **zero-copy**

Episodet që kanë tashmë `local_path` anashkalohen; `{"force": true}` i
rikonverton. Progresi shihet te `GET /api/v1/jobs` ose `GET
/api/v1/jobs/status?job_id=N`.

## API

```
POST /api/v1/streams/<id>/convert-local          # film
POST /api/v1/episodes/<id>/convert-local         # episod
POST /api/v1/series/<id>/convert-season          # {"season": 1} ose {"season": 0} = të gjitha
PUT  /api/v1/episodes/<id>                       # {"transcode_profile":"aac","use_ffmpeg":1}
```

`transcode_profile` pranon `""` (trashëgo serinë), `auto`, `pass`, `aac`, `fhd`,
`hd`, `sd`; çdo vlerë tjetër kthehet `400`.

## Multi-server (LB)

`local_path` mbahet absolutisht; në main luhet direkt nga disku. Në një LB që
nuk e ka skedarin, paneli kthehet automatikisht te burimi remot me
transkodimin e zgjedhur — pra filmi/episodi luan gjithsesi, thjesht jo zero-copy.
Për zero-copy në të gjitha nodet, montoni të njëjtin direktor (`data/vod`) ose
vendosni `local_media_root` të përbashkët.
