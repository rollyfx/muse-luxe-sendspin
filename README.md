# Muse Luxe — Firmware SendSpin allégé pour ESP32

Firmware ESPHome pour l'enceinte **Raspiaudio Muse Luxe**, lecteur **SendSpin** pour
Music Assistant / Home Assistant. Composants 100 % natifs ESPHome ≥ 2026.10.0.

L'historique détaillé des incidents et diagnostics est dans [`JOURNAL.md`](JOURNAL.md).

## Problème initial

Le firmware officiel [RASPIAUDIO/esphomeLuxeMusic](https://github.com/RASPIAUDIO/esphomeLuxeMusic)
alloue trop de mémoire au démarrage sur cet ESP32 (4 Mo PSRAM, 180 Ko DRAM) :

- `buffer_size: 2000000` (2 Mo) pour la source sendspin → **PSRAM saturée** ;
- `buffer_duration: 500ms` sur le speaker I2S → **buffers I2S trop gros** ;
- pipeline audio complet (FLAC + mixer + 2 resamplers + announcement) → **RAM insuffisante**.

Résultat : la musique ne passe pas ou s'interrompt, l'ESP32 n'a plus de RAM pour traiter l'audio.

## Solution : alléger le firmware

| Paramètre | Officiel | Allégé | Économie |
|-----------|----------|--------|----------|
| `buffer_size` sendspin | 2 000 000 | **1 048 576** | ~1 Mo PSRAM |
| `buffer_duration` I2S | 500ms | **100ms** | −76,8 Ko à 48 kHz stéréo |
| Pipeline | mixer + 2 resamplers + announcement | **une voie média, sans resampler** | tâches et stacks en moins |
| `captive_portal`, `improv_serial`, batterie, son de démarrage, effets LED | ✅ | ❌ | RAM / PSRAM |
| Stack loop ESPHome | 8192 | **16384** | marge contre stack overflow |
| Buffers Wi-Fi RX/TX, fenêtres TCP | 64/64, 64 Kio | **32/32, 32 Kio** | marge heap réseau |
| Fréquence CPU | 160 MHz implicite | **240 MHz** | décodage / synchronisation |
| `sram1_as_iram` | ✅ | ✅ | +40 Ko IRAM |

Pipeline résultant :

```
sendspin_source (1 Mio, PCM)
  → speaker_source media_player
    → box_speaker (I2S, ES8388)
      → GPIO26 (DOUT)
```

### Codec : PCM uniquement

Le firmware n'annonce que `pcm` au serveur (`codecs: [pcm]`). Sur ce build, micro-flac
corrompt le heap (reboots toutes les 2–5 min) et Opus déborde la pile de la tâche de
synchronisation ; MA transcode donc en PCM 48 kHz / 16 bit, et c'est aussi le serveur qui
impose le mono (le PCM stéréo hache sur ce lien Wi-Fi). Détails dans `crash_analysis.md`.

### DAC ES8388 : pourquoi le son manquait

Le composant `es8388` natif n'écrit jamais le registre **DACPOWER (0x04)** ; au reset la
puce a LOUT1/ROUT1 **OFF** → silence total même avec un pipeline parfait. Correctifs dans
le yaml :

- `i2s_mclk_pin: GPIO0` + `mclk_multiple: 256` (l'ES8388 esclave exige un MCLK externe) ;
- `select: es8388` `dac_output` → `select.set: LINE1` au boot (écrit DACPOWER) ;
- lambda boot : `0x2E/0x2F = 0x21` (LOUT1/ROUT1VOL +4,5 dB, max puce) ;
- ampli externe GPIO21 activé au boot ;
- `volume_max: 1.0` (0.9 plafonnait à −9,5 dB).

### Wi-Fi

- `output_power: 11.5dB` : le maximum (20,5 dBm) gelait le CPU (brownout RF avec l'ampli
  actif) ; 8,5 dB rendait l'uplink marginal à la position définitive.
- Pas de BSSID épinglé : le mesh change d'AP selon la pièce.
- `power_save_mode: NONE` (latence) et IP statique (`secrets.yaml`).

### Mémoire et piles

Les piles des tâches sendspin (hub et source) restent en **RAM interne**
(`task_stack_in_psram: false`) : en PSRAM, un débordement corrompait le ring buffer
voisin sans que le canari FreeRTOS le détecte. Le ring buffer et le décodage restent en PSRAM.

## Compilation et flash

Prérequis : Python 3, un CP210x UART (`lsusb` → `10c4:ea60 Silicon Labs CP210x`),
l'utilisateur dans le groupe `dialout`.

```bash
python3 -m venv .venv-2026.10
.venv-2026.10/bin/pip install esphome==2026.10.0 websockets
cp secrets.example.yaml secrets.yaml   # puis renseigner

./flash.sh                 # compile + flash série (firmware.factory.bin à 0x0)
.venv-2026.10/bin/esphome upload luxe_music_min.yaml --device <IP_MUSE>   # OTA
```

`flash.sh` prend le premier `esphome` trouvé dans `.venv-2026.10`, `.venv` puis le
PATH, et se rabat sur Docker (`esphome/esphome`) + `esptool` natif.
Le flash série reste la voie de référence si l'OTA échoue (lien radio faible ou crash
pendant l'upload).

Le flash série ne touche pas la NVS : la paire de clés Sendspin (identité du lecteur côté
MA) et le volume survivent. Un effacement complet (`esptool erase-flash`) régénère la
clé et crée un nouveau player dans MA.

## Configuration côté Music Assistant

Firmware 2026.10 : le protocole Sendspin est chiffré, **MA ≥ 2.10.7 requis**. Accès non
appairé actif par défaut, aucun appairage nécessaire.

Réglages à vérifier après une mise à jour de MA (ils ont déjà été réinitialisés par une maj) :

| Où | Réglage | Valeur |
|---|---|---|
| Fournisseur Sendspin | adresses IP de découverte manuelle | `<IP_MUSE>` — rend le retour après reboot indépendant du mDNS |
| Player → protocole Sendspin | Preferred audio format | `PCM 48kHz/16bit mono` |
| Player → protocole Sendspin | Static playback delay | 136 ms (réglé à l'oreille avec la Voice PE ; Muse en avance → augmenter) |
| Player universel | Preferred output protocol | l'id Sendspin courant (change si la NVS est effacée) |

Si l'enceinte disparaît d'un groupe après une maj MA : depuis 2.10.8 un groupe qui se
dissout à vide libère ses membres ; la réintégrer via l'UI ou
`ma_api.py players/cmd/set_members '{"target_player": "<groupe>", "player_ids_to_add": ["<player>"]}'`.

Si l'audio lag après un déplacement/reboot : pause/play du groupe (pas de power-cycle) —
une session Sendspin née dégradée ne se répare pas seule.

## Outils

| Fichier | Rôle |
|---|---|
| `luxe_music_min.yaml` | Firmware (à utiliser) |
| `flash.sh` | Compilation + flash série |
| `ma_api.py` | Client API websocket MA (`MUSIC_ASSISTANT_WS_URI`, jeton dans `.ma_token`, chmod 600) |
| `check_all.py` | État de la Muse via l'API native (`MUSE_API_KEY`, `MUSE_HOST`) |
| `mesure_antenne.py` | Mesure RSSI côté ESP (A/B d'antennes, cf. `mesures_antenne.md`) |
| `JOURNAL.md` | Chronologie des incidents et versions |
| `crash_analysis.md` | Backtraces et analyses (FLAC, Opus, httpd, gel watchdog) |
| `captures/` | Logs série bruts référencés par les analyses |

Capteurs de diagnostic exposés dans HA : RSSI, BSSID associé, raison du dernier reset.

## GPIO Muse Luxe

| GPIO | Fonction |
|------|----------|
| 5 | I2S BCLK (strapping pin) |
| 0 | I2S MCLK (ES8388) |
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

## Multiroom avec des enceintes Squeezelite

Squeezelite (SlimProto) et SendSpin sont deux protocoles incompatibles. Options : tout
migrer en SendSpin (recommandé), ou laisser MA découvrir les players Squeezelite via
l'intégration Squeezebox (synchro approximative).

## Pistes

- **Réessayer FLAC** : ESPHome 2026.10 embarque microFLAC 0.3.0 ; si la corruption heap
  (`crash_analysis.md`) a disparu, `codecs: [flac, pcm]` réduirait le débit radio. Sinon,
  rapporter le bug upstream avec les backtraces du dossier.
- **Endurance longue** sur 2026.10 (pile httpd revenue à sa taille par défaut) : quelques
  heures de lecture groupe avec la console série attachée.
