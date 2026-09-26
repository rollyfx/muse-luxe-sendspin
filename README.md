# Muse Luxe — Firmware SendSpin allégé pour ESP32

Ce projet contient un firmware ESPHome pour l'enceinte **Raspiaudio Muse Luxe** utilisant le protocole **SendSpin** (Music Assistant / Home Assistant).

## Problème initial

Le firmware officiel `esphomeLuxeMusic` ([RASPIAUDIO/esphomeLuxeMusic](https://github.com/RASPIAUDIO/esphomeLuxeMusic)) alloue trop de mémoire PSRAM au démarrage :

- `buffer_size: 2000000` (2 Mo) pour le sendspin source → **PSRAM saturée**
- `buffer_duration: 500ms` sur le speaker I2S → **buffers I2S trop gros**
- Pipeline audio complet (FLAC + mixer + 2 resamplers + announcement) → **RAM insuffisante**

Résultat : la musique ne passe pas ou s'interrompt, l'ESP32 n'a plus de RAM pour traiter l'audio.

## Solution : alléger le firmware

### Changements clés par rapport au firmware officiel

| Paramètre | Officiel | Allégé | Économie |
|-----------|----------|--------|----------|
| `buffer_size` sendspin | 2 000 000 | **1 048 576** | **-0,95 Mo PSRAM** |
| `buffer_duration` I2S | 500ms | **100ms** | **-76,8 Ko à 48 kHz stéréo** |
| `external_components` | PRs git spécifiques | **PRs git spécifiques sans mixer** | moins de code et une tâche audio en moins |
| `captive_portal` | ✅ | ❌ | RAM |
| `improv_serial` | ✅ | ❌ | RAM |
| `battery sensor` | ✅ | ❌ | RAM + ADC |
| Startup sound (WAV) | ✅ | ❌ | PSRAM + source fichier supprimée |
| LED effects (pulse) | ✅ | ❌ | RAM |
| `logger.level` | warn | warn | CPU |
| Pipeline announcement | ✅ | ❌ | moins de tâches audio |
| Stack loop ESPHome | 8192 | **16384** | marge contre stack overflow |
| Buffers Wi-Fi dynamiques RX/TX | 64/64 | **32/32** | marge heap au pic de lecture |
| Fenêtres TCP / mailboxes | 64 Kio / 64 | **32 Kio / 32** | marge heap réseau |
| Fréquence CPU | 160 MHz implicite | **240 MHz** | marge décodage/resampling |

**Économie totale estimée : ~1 Mo de buffers audio + ~50 Ko DRAM**

### Architecture audio

```
sendspin_source (1 Mio buffer)
  → media_resampling_input (resampler 48kHz 16bit)
    → box_speaker (I2S ES8388)
      → GPIO26 (DOUT)
```

L'amplificateur externe (GPIO21) est activé au boot pour alimenter le speaker.

## Compilation et flash

### Prérequis

- **Docker** ou **esphome CLI** installé
- Connexion USB via CP210x UART Bridge (`lsusb` → `ID 10c4:ea60 Silicon Labs CP210x`)

### Compilation avec Docker

```bash
# Compiler le firmware (ne nécessite pas d'accès USB)
docker run --rm -v "$(pwd)":/config \
  esphome/esphome:2026.9.0 compile /config/luxe_music_min.yaml

# Flasher via esptool (accès USB nécessaire)
esptool --chip esp32 --port /dev/ttyUSB0 --baud 115200 \
  write-flash 0x0 .esphome/build/muse-luxe-music/.pioenvs/muse-luxe-music/firmware.factory.bin
```

### Script automatisé

```bash
chmod +x flash.sh
./flash.sh
```

## Notes techniques

### Pourquoi ESPHome 2026.2.0 ?

Le firmware officiel RASPIAUDIO utilise des **Pull Requests** ESPHome (PR #12253–#12258, #12284, #12429, #3552) qui n'étaient pas encore mergées dans la branche principale. Ces PRs ajoutent :
- `mixer` — composant speaker mixer
- `resampler` — composant resampling audio
- `audio` / `ring_buffer` — infrastructure audio
- `media_player` / `media_source` / `speaker_source` — lecteur média
- `sendspin` / `mdns` — protocole SendSpin
- `es8388` — DAC audio

ESPHome 2026.2.0 est la version compatible avec ces PRs git. Les versions 2026.5.x ont intégré ces composants nativement mais avec une API différente (incompatible).

### Problèmes rencontrés

1. **PSRAM saturée** → solution : réduire `buffer_size` à 512 Kio et le buffer I²S à 100 ms
2. **API speaker_source incompatible entre versions** → `announcement_speaker`/`media_speaker` (PRs) vs `speaker:` (2026.5.x)
3. **Un seul sendspin media_source par hub** → pas de double pipeline announcement+media avec deux sources sendspin distinctes
4. **Docker Desktop (VM)** → ne peut pas accéder aux device USB `/dev/ttyUSB*` directement ; utiliser `esptool` en natif après compilation Docker
5. **Crash pendant lecture** → logs ESPHome: `LoadProhibited`, PC dans `vApplicationStackOverflowHook`; le pipeline a donc été réduit à une seule voie média et les stacks `sendspin`, `speaker_source`, `resampler` passent en PSRAM.
6. **OTA** → historiquement instable (timeout sur ACK) à l'ancienne position ;
   requalifiée le 2026-09-14 depuis la salle de bain (RSSI -54) : upload
   complet en 9,8 s sans erreur (`esphome upload --device 192.168.10.86`).
   Le flash USB série reste la voie de référence si le lien radio se dégrade.
7. **Wi-Fi introuvable** → l'ancien BSSID n'existait plus; le firmware sélectionne désormais dynamiquement une radio 2,4 GHz du SSID au démarrage au lieu de rester lié à un BSSID/canal périssable.
8. **Pic de heap réseau** → le profil haut débit demandé par Sendspin réservait jusqu'à 64 buffers RX/TX et des fenêtres TCP de 64 Kio; un profil 32/32 suffit au débit FLAC et laisse davantage de SRAM au pipeline.
9. **Ratées CPU** → la cible ESP32 générait implicitement un firmware à 160 MHz; la fréquence est fixée à 240 MHz pour le décodage FLAC, le resampling et la synchronisation.
10. **Lien Wi-Fi faible** → la puissance d'émission ESP32 est explicitement fixée à 20,5 dBm pour compenser le signal 2,4 GHz mesuré entre -78 et -84 dBm dans la Muse.
11. **Échec d'association indépendant de Sendspin** → trois firmwares minimaux (ESP-IDF 5.5.2, Arduino 3.3.7 et ESP-IDF 5.3.2) reproduisent `Probe Request Unsuccessful` et `Auth Expired`; le blocage actuel est donc radio/point d'accès, pas une saturation mémoire du pipeline audio ni une régression propre à ESP-IDF 5.5.2.

### Grouper Squeezelite + SendSpin (multiroom)

**Deux protocoles incompatibles :**
- **Squeezelite** → protocole **SlimProto** (Logitech Media Server)
- **SendSpin** → protocole **Music Assistant** (Home Assistant)

**Options :**
1. **Tout migrer en SendSpin** — flasher toutes les enceinte avec ESPHome SendSpin (solution recommandée)
2. **Pont LMS** — Music Assistant peut découvrir les players Squeezelite via l'intégration Squeezebox (synchro approximative)
3. **AirPlay** — Squeezelite-ESP32 inclut AirPlay, mais pas de synchro multiroom native

```
muse-luxe/
├── luxe_music_min.yaml    # Firmware strict minimum SendSpin (ESPHome ≥ 2026.9.0 natif, à utiliser)
├── ma_api.py              # Client API websocket Music Assistant (auth par .ma_token)
├── .ma_token              # Jeton API long-durée MA (chmod 600, ne pas committer)
├── .check_all.py          # État ESP via API native (reset_reason + player + volume)
├── mesure_antenne.py      # Mesure RSSI côté ESP (test A/B d'antennes) — cf. mesures_antenne.md
├── mesures_antenne.md     # Protocole + résultats des mesures d'antenne
├── crash_analysis.md      # Analyse du crash FLAC (backtrace + conclusion PCM)
├── flash.sh               # Script de compilation + flash (défaut : luxe_music_min.yaml)
└── README.md              # Ce fichier
```

## GPIO Muse Luxe

| GPIO | Fonction |
|------|----------|
| 5 | I2S BCLK (strapping pin — utiliser avec précaution) |
| 18 | I2C SDA |
| 19 | Bouton Volume Up |
| 21 | Amplificateur enable |
| 22 | LED WS2812 |
| 23 | I2C SCL |
| 25 | I2S LRCLK |
| 26 | I2S DOUT |
| 27 | Jack detection |
| 32 | Bouton Volume Down |
| 33 | Battery ADC |
| 35 | SPI MISO |
| 12 | Bouton play/pause |

## Fonctionne / Ne fonctionne pas (2026-08-25 soir, firmware `luxe_music_min.yaml` 2026.8.1)

| Fonction | État |
|----------|------|
| Association Wi-Fi 2,4 GHz | ✅ position définitive : AP `4f:4e` canal 6, −40 dBm, 0 % de perte, idle RTT ~8 ms (`output_power` 11.5 dB) |
| Sortie audio ES8388 (DACPOWER/LOUT1) | ✅ son confirmé — voir « DAC ES8388 » ci-dessous |
| Connexion SendSpin au serveur Music Assistant | ✅ flux radio actif, sync_task en marche |
| Lecture audio radio | ✅ son audible de bout en bout |
| OTA | ⚠️ `esphome run --device <IP_MUSE>` — échoue si l'enceinte crashe mid-upload (bug FLAC) ; flash série USB fiable (`esptool`, 115200 bauds) |
| Synchro multiroom | ✅ groupe principal avec Voice PE ; **stable 12+ min en PCM** (crash FLAC contourné — voir section dédiée) |
| LED verte/rouge, boutons, volume | ✅ |

### DAC ES8388 : pourquoi le son manquait

Le composant `es8388` natif n'écrit jamais le registre **DACPOWER (0x04)** ; au reset la puce a
LOUT1/ROUT1 **OFF** → silence total même avec un pipeline parfait. Correctifs dans le yaml :

- `i2s_mclk_pin: GPIO0` + `mclk_multiple: 256` (l'ES8388 esclave exige un MCLK externe) ;
- `select: es8388` `dac_output` → `select.set: LINE1` au boot (écrit DACPOWER) ;
- lambda boot : `0x2E/0x2F = 0x21` (LOUT1/ROUT1VOL +4,5 dB, max puce) ;
- `volume_max: 1.0` (0.9 plafonnait à −9,5 dB).

### Incident du 2026-08-25 : « No matching network found » (radio prétendue HS)

Une édition du bloc `wifi:` a **supprimé la ligne `password:`**. Sans clé, ESPHome ne matche
que les réseaux **ouverts** (`WiFiScanResult::matches()`) → l'ESP voyait les AP (SSID
présent dans le scan, d'où le log « visible network ») mais n'essayait jamais de s'y
connecter. Ne jamais conclure « radio HS » sans vérifier que `password:` est bien là.


### Incident du 2026-08-25 soir : lag audio à la position définitive (résolu)

Après déplacement de l'enceinte à sa position définitive (nouvel AP `4f:4e`, canal 6,
RSSI −40 dBm) : audio qui lag. Diagnostic en trois temps :

1. **Ce n'était pas la puissance radio.** Lien propre à l'arrêt (ping 8 ms), RSSI fort,
   canal 6 peu chargé ; passer `output_power` de 8.5 à **11.5 dB** n'a rien changé.
   La montée sous charge (ping 25-400 ms pendant la lecture) était un leurre : l'ICMP
   est depriorisé, et sur les mêmes fenêtres l'ESP n'a loggé **aucun** `Lost sync`
   ni chunk perdu — le pipeline audio absorbait tout.
2. **C'était la session SendSpin.** Comme pour le codec hier : une session née au
   boot/reconnect peut être dégradée et ne se répare jamais seule. Le pause/play du
   groupe (seulement le groupe, pas le power-cycle) repart sur une session saine.
3. **Le dump de crash dans les logs au boot est périmé** : c'est l'ancien crash FLAC
   (16:50) conservé en mémoire RTC (l'en-tête dit « Captured by a different firmware
   build »). Il se réimprime à chaque boot tant que la RTC n'est pas effacée —
   pas un crash du firmware courant.

**Correctif : `player_queues/pause` puis `play` sur le groupe synchronisé** (ou pause/play
du groupe dans l'UI MA) après tout déplacement/reboot où l'audio lag. `output_power`
reste à 11.5 dB (palier validé, marge uplink). Capteurs `wifi_signal` + `wifi_info/bssid`
ajoutés au yaml — gardés, coût nul, ils ont servi au diagnostic.

### Crash reboots en lecture groupe : le décodeur FLAC (mitigation PCM)

Symptôme : reboots aléatoires toutes les 2–5 min en lecture groupe avec les
Voice PE (`Guru Meditation LoadProhibited`, `rst:0xc SW_CPU_RESET`).
Analyse complète dans **`crash_analysis.md`** (backtrace symbolisé) :
corruption du heap sur le chemin micro-flac, crash dans
`SyncTask::write_audio_chunk → xRingbufferSendAcquire`.

**Mitigation (côté serveur MA, pas de patch firmware)** : forcer le codec PCM
pour ce player — l'annonce de codecs de l'ESP est codée en dur
(`[FLAC, OPUS, PCM]`, `esphome/components/sendspin/__init__.py:295`) et MA
choisit. Réglage dans l'UI MA : player → ⚙ → options avancées →
**« Preferred audio format »** → `PCM 48kHz/16bit mono` (l'entrée n'apparaît
que si le player est connecté). Ou via l'API : `ma_api.py config/players/save`
avec la clé protocole `<MAC_MUSE>||protocol||preferred_sendspin_format`
à `pcm:48000:16:1`, puis stop/play du groupe pour renégocier la session.
Le PCM stéréo reste à éviter sur cette installation : le test du 2026-09-08
a produit des coupures et de nombreux `Lost sync` malgré 0 % de perte ICMP.

**Synchro fine** : le curseur **« Static playback delay »** du même écran
(0–5000 ms) — réglé à **136 ms** le 2026-08-25 à l'oreille avec la Voice PE.
Muse en avance → augmenter ; en retard → diminuer (pas de 20–50 ms). Le
`initial_static_delay: 2000ms` du yaml n'est que la valeur de boot : MA
applique son propre réglage à chaque session (commande SET_STATIC_DELAY).

### Diagnostic final (ce qui bloquait vraiment)

1. **Pas d'OOM global** : le build minimal consomme 32,7 % de DRAM statique
   (59 Ko / 180 Ko). Le débordement Opus identifié le 2026-09-08 est local à
   la pile de 6192 octets de la tâche SendSpin, pas à la heap globale.
2. **Lien radio 2,4 GHz défaillant** : `Probe Request Unsuccessful` / `Auth Expired` / `4-Way Handshake Timeout` en boucle sur les AP lointains (canal 9, signal −78/−84 dBm côté enceinte). Le nouvel AP ajouté dans la pièce règle l'association.
3. **Hard hang silencieux sur bursts TX** : toggle lecture → CPU gelé sans log (série muet, réseau mort). Disparu avec `output_power: 8.5dB` (+ `sram1_as_iram`, + sendspin-cpp 0.7.2) — cohérent avec un brownout RF : 20,5 dBm + ampli GPIO21 actif sur un rail 3V3 fragile.
4. **Décalage de version protocole** : client ESPHome 2026.7.4 / sendspin-cpp 0.7.0 face à un serveur Voice PE en 2026.8.x. Le passage en 2026.8.1 (sendspin-cpp 0.7.2) a supprimé les timeouts `time_burst`.
5. **mDNS filtré au démarrage** : aucun service visible un moment (`_sendspin._tcp`, `_googlecast._tcp`…) puis réapparu — comportement d'un mécanisme de filtrage multicast (IGMP snooping) sur la Freebox.

### Incident du 2026-09-08 : watchdog, lecteur invisible et son haché

- Le hard reboot a confirmé `reset_reason = other watchdogs`. La LED rouge est
  normale : le yaml l'utilise pour l'état arrêté et la passe au vert pendant
  la lecture.
- L'ESPHome était joignable mais MA gardait le lecteur `available: false`, donc
  invisible dans l'interface. Ajouter l'adresse IP fixe de la Muse dans les **adresses IP de
  découverte manuelle** du fournisseur SendSpin a rétabli immédiatement la
  connexion et rend désormais le retour après reboot indépendant du mDNS.
- PCM stéréo a négocié correctement mais hachait, avec des sauts de synchro de
  plusieurs centaines de ms à 1,9 s. PCM mono réutilisé après cette session
  dégradée n'a pas suffi ; après un reboot et une session PCM mono neuve, la
  trace est redevenue calme.
- Opus stéréo n'est pas un repli sûr dans le firmware courant : il provoque un
  `stack overflow` dans `sendspin::SyncTask::handle_load_chunk()` dès le début
  du décodage. La pile codée en dur dans sendspin-cpp 0.7.2 ne fait que 6192
  octets.
- Le correctif firmware testé déplace donc uniquement la pile de la source
  SendSpin en RAM interne (`media_source.task_stack_in_psram: false`). Le
  ring buffer et le buffer de décodage restent en PSRAM ; l'objectif est
  d'empêcher un dépassement de pile externe de corrompre leur stockage.
- Le premier essai avec cette pile interne a montré que le tampon de 512 Kio
  saturait pendant le burst PCM initial (`Failed to send audio chunk` en
  rafale, puis logger bloqué 956 ms). Il est porté à 1 Mio pour absorber ce
  burst sans revenir aux 2 Mio du pipeline officiel.
- Le test 1 Mio a encore planté après 42 s avec un handle de ring buffer
  corrompu (`EXCVADDR=0x439`) depuis la tâche `httpd`. La cause la plus précise
  est sa pile ESP-IDF de seulement 4 Kio, déjà signalée dans
  Sendspin/sendspin-cpp#102. Le firmware flashé porte cette pile à 16 Kio et
  place aussi la pile du hub en RAM interne. Le patch est conservé dans
  `patches/sendspin-httpd-stack.patch` et `flash.sh` le réapplique après toute
  régénération des dépendances. Le premier test PCM mono corrigé a tenu plus de
  sept minutes, une transition de piste et trois cycles pause/reprise sans
  chunk rejeté ni reboot. Deux `Lost sync` brefs n'ont eu lieu que pendant le
  churn forcé ; une endurance longue reste à faire.

Configuration MA retenue :

- fournisseur SendSpin : `manual_discovery_ip_addresses = ["<IP_MUSE>"]` ;
- protocole Muse `<MAC_MUSE>` :
  `preferred_sendspin_format = "pcm:48000:16:1"` ;
- délai statique conservé à 136 ms.

La capture détaillée et les critères d'escalade vers un patch sendspin-cpp sont
documentés dans `crash_analysis.md`.

### Incident du 2026-09-26 : son haché après maj MA 2.10.2 → 2.10.4 (HA 2026.9)

Symptôme : son haché depuis ~1 h sur `maison-all`, pendant la lecture de la radio
fip (icecast AAC). Contexte : MA serveur passé 2.10.2 → 2.10.4 (via maj HA 2026.9)
~1 h plus tôt. ESP 2026.8.2 inchangé ; HA 2026.9 lui-même n'a aucun changement
Sendspin/audio (vérifié changelog).

Deux effets de la maj identifiés :

1. **Pacing radio trop juste (MA 2.10.3, PR music-assistant/server#6237)** : les
   flux just-in-time (radio) passent à 1.03× avec seulement **3 s d'avance**.
   Sur le lien Wi-Fi marginal de la Muse (mesh Orbi, salle de bain), chaque
   creux radio → sous-alimentation → haché. Observé côté API : `elapsed_time`
   qui cale puis rattrape par sauts de +30 à +62 s toutes les 30–60 s.
2. **Réinitialisation des réglages Sendspin du player** : `preferred_sendspin_format`
   revenu à `automatic` (→ MA renégocie, l'ESP annonce [FLAC, OPUS, PCM] en dur)
   et `sendspin_static_delay` 136 → 0 ms. Les réglages provider
   (`manual_discovery_ip_addresses = [192.168.10.86]`) ont survécu. Restauration
   via `ma_api.py config/players/save` (format `pcm:48000:16:1`, délai 136).

Piège supplémentaire : après un pause/play du groupe sous 2.10.4, la télémétrie
`elapsed_time` de la queue reste figée (re-anchor uniquement sur regroup/play_media)
même quand le son repart — ne pas conclure « silence » sur cette seule base.
Un stop/play, un `player_queues/play_media` (`media: [uri]`, `queue_id`) puis un
ungroup/regroup du player web Chrome n'ont pas suffi à assainir la session ;
**seul un redémarrage du serveur MA assainit complètement** (sessions neuves).

Liens amont utiles à ce dossier :

- esphome/esphome#16065 « sendspin stutters on connection handoff » (ouvert,
  symptôme ~toutes les 30–60 min — réassociation mesh Orbi candidate) ;
- sendspin-cpp **v0.7.1** (PR #104) réduit l'usage pile httpd de 51 % : notre
  patch local 16 Kio devient redondant dès que sendspin-cpp ≥ 0.7.1 (déjà le cas
  en 2026.8.2) — le garder ne coûte rien, le retirer à la prochaine regen ;
- ESPHome **2026.9.0** ajoute `codecs:` (liste de préférence côté client, PR #19047) :
  **flashé par OTA le 2026-09-26** (upload 42,3 s, reboot propre
  `Reboot request from esphome.ota`) — `codecs: [pcm]` dans `luxe_music_min.yaml` :
  même un MA en `automatic` ne peut plus négocier autre chose que PCM (FLAC/Opus ni
  annoncés ni choisis), immunise contre ce type de reset de config MA ;
- sendspin-cpp **v0.8.0** (15/09, breaking) + bump ESPHome PR #19357 fusionné le
  18/09 : pas encore dans une release stable ESPHome, à suivre avant upgrade ;
- RASPIAUDIO/esphomeLuxeMusic : commit 52b7ef9 (24/09, « 2026.9.3 », ESPHome
  ≥ 2026.8.2 + IP5306) — référence à relire, mais notre firmware min reste la base.

Configuration MA re-vérifiée après restauration : provider Sendspin
`manual_discovery_ip_addresses = ["192.168.10.86"]` ; player `<MAC_MUSE>` :
`preferred_sendspin_format = pcm:48000:16:1`, `sendspin_static_delay = 136`.

### Ce que fait le firmware minimal

- Composants 100 % natifs ESPHome 2026.8.1 (plus aucune `external_components` git/PR).
- Pipeline audio réduit à une voie : `sendspin_source` (1 Mio) → `speaker_source` → `box_speaker` I2S. **Pas de resampler** (MA transcode en 48 kHz/16-bit ; le profil stable actuel est mono). `format: WAV` du pipeline local n'influence pas le codec reçu — c'est MA qui le choisit (voir « Crash reboots » ci-dessous).
- Ampli GPIO21 activé au boot (absent des anciennes versions lite — sortie muette sinon).
- `output_power: 11.5dB` (position définitive ; historique : 20,5 dBm gelait le CPU
  par brownout RF, 8.5 dB au bureau, 11.5 validé sans incident à la nouvelle
  position), `power_save_mode: NONE` (latence), `sram1_as_iram: true` (+40 Ko IRAM).
- Pas de BSSID épinglé : le mesh Orbi change d'AP selon la pièce, l'ESP sélectionne
  dynamiquement la meilleure radio 2,4 GHz du SSID.

## Améliorations possibles

1. **Rapporter les deux bugs sendspin-cpp upstream** : micro-flac (corruption
   heap en lecture, toutes les 2–5 min) et course au teardown de session
   (crash PCM au regroup, 2026-08-25 19:12) — données prêtes dans
   `crash_analysis.md` (backtraces, repros, pistes d'audit).
2. **Affiner la synchro multiroom à l'oreille** : curseur « Static playback delay »
   dans les réglages MA du player — 136 ms trouvé le 2026-08-25, à réévaluer
   si le réseau/groupe change (pas de 20–50 ms).
3. **Retirer l'instrumentation de diagnostic** (`debug:`, `text_sensor reset_reason`)
   une fois la stabilité PCM confirmée sur plusieurs jours — ou les garder, coût nul.
4. **Remonter `output_power` à 14.5 dBm** uniquement si un futur emplacement
   l'exige, en surveillant un retour des hangs (11.5 dB depuis le 2026-08-25 soir).
5. ~~Ménage des yaml obsolètes~~ ✅ fait le 2026-08-25 (`luxe_music_lite*.yaml` supprimés,
   mesures d'antenne archivées dans `mesures_antenne.md` — antenne A conservée, +5,3 dB).
