# VOD Transcoding & Convert to MP4

Filmat dhe episodet që vijnë si **MKV/Bluray remux me audio DTS/E-AC3 dhe titra
PGS** nuk hapen në SmartSTB, MAG ose Smart TV: dekoderi pranon vetëm MPEG-TS me
audio që njeh. Paneli ofron dy zgjidhje, të zgjedhshme për çdo film, seri ose
episod veç e veç.

## 1. Live transcode (0% CPU video, vetëm audio)

Te **Movies → Edit** ose **Series → Edit** dhe (për një episod të vetëm)
**Series → Episodes → Edit**, seksioni **⚙️ Transcoding & Playback**:

| Profil | Çfarë bën | Kur ta zgjidhni |
|---|---|---|
| `pass` | Stream copy, asnjë transkodim | Burimi është tashmë H.264 + AAC |
| **`aac`** | Video **copy** (0% CPU), audio → **AAC 192k**, PGS hiqet | **Rasti tipik:** DTS/E-AC3 që STB nuk e lexon |
| `fhd` | Video → H.264 1080p 4.5 Mbps + AAC | Bitrate shumë i lartë për rrjetin |
| `hd` | Video → H.264 720p 2.2 Mbps + AAC | Lidhje e dobët |
| `sd` | Video → H.264 480p 900 kbps + AAC | Kursim maksimal |

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

`transcode_profile` pranon `""` (trashëgo serinë), `pass`, `aac`, `fhd`, `hd`,
`sd`; çdo vlerë tjetër kthehet `400`.

## Multi-server (LB)

`local_path` mbahet absolutisht; në main luhet direkt nga disku. Në një LB që
nuk e ka skedarin, paneli kthehet automatikisht te burimi remot me
transkodimin e zgjedhur — pra filmi/episodi luan gjithsesi, thjesht jo zero-copy.
Për zero-copy në të gjitha nodet, montoni të njëjtin direktor (`data/vod`) ose
vendosni `local_media_root` të përbashkët.
