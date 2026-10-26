# Journal de bord — Muse Luxe

Chronologie détaillée des incidents, diagnostics et décisions. Le README ne garde
que ce qu'il faut pour comprendre et utiliser le firmware ; tout le reste est ici.
Analyses longues à part : `crash_analysis.md` (backtraces FLAC/Opus/httpd, gel du
2026-09-13) et `mesures_antenne.md` (A/B d'antennes).

## Versions firmware flashées

| Date | ESPHome | sendspin-cpp | Notes |
|---|---|---|---|
| août 2026 | 2026.7.4 | 0.7.0 | timeouts `time_burst` face à un serveur 2026.8.x |
| 2026-08-25 | 2026.8.1 | 0.7.2 | profil PCM validé, `output_power` 11.5 dB |
| 2026-09-08 | 2026.8.2 | 0.7.2 + patch pile httpd 16 Kio | piles sendspin en RAM interne, buffer 1 Mio |
| 2026-09-14 | 2026.8.2 | idem | reflash série après gel, ajout `api.encryption.key` |
| 2026-09-26 | 2026.9.0 | 0.7.2 | OTA (42,3 s), `codecs: [pcm]` |
| 2026-10-26 | 2026.10.0 | 0.9.3 | série, protocole Sendspin chiffré, patch httpd retiré |

## Problèmes rencontrés pendant la mise au point

1. **PSRAM saturée** → réduire `buffer_size` (2 Mio → 512 Kio puis 1 Mio) et le buffer I²S à 100 ms.
2. **API speaker_source incompatible entre versions** → `announcement_speaker`/`media_speaker` (PRs) vs `speaker:` (2026.5.x). Les composants sont natifs depuis 2026.8.
3. **Un seul sendspin media_source par hub** → pas de double pipeline announcement+media avec deux sources sendspin distinctes.
4. **Docker Desktop (VM)** → pas d'accès aux `/dev/ttyUSB*` ; compiler en conteneur puis flasher avec `esptool` natif.
5. **Crash pendant lecture** → `LoadProhibited`, PC dans `vApplicationStackOverflowHook` ; pipeline réduit à une seule voie média, stacks `sendspin`, `speaker_source`, `resampler` en PSRAM (puis ramenées en RAM interne le 2026-09-08).
6. **OTA** → historiquement instable (timeout sur ACK) ; requalifiée le 2026-09-14 depuis la salle de bain (RSSI -54) : upload complet en 9,8 s (`esphome upload --device 192.168.10.86`). Le flash USB reste la référence si le lien radio se dégrade.
7. **Wi-Fi introuvable** → l'ancien BSSID épinglé n'existait plus ; le firmware choisit désormais dynamiquement une radio 2,4 GHz du SSID.
8. **Pic de heap réseau** → le profil haut débit Sendspin réservait 64 buffers RX/TX et des fenêtres TCP de 64 Kio ; 32/32 suffit au débit et laisse de la SRAM au pipeline.
9. **Ratées CPU** → la cible ESP32 générait un firmware à 160 MHz ; fixé à 240 MHz.
10. **Lien Wi-Fi faible** → `output_power` monté à 20,5 dBm (signal -78/-84 dBm), avant de découvrir que c'était contre-productif (voir « Diagnostic final »).
11. **Échec d'association indépendant de Sendspin** → trois firmwares minimaux (ESP-IDF 5.5.2, Arduino 3.3.7, ESP-IDF 5.3.2) reproduisent `Probe Request Unsuccessful` / `Auth Expired` : blocage radio/point d'accès, pas une saturation mémoire.

## Diagnostic final (ce qui bloquait vraiment)

1. **Pas d'OOM global** : le build minimal consomme 32,7 % de DRAM statique (59 Ko / 180 Ko). Le débordement Opus du 2026-09-08 est local à la pile de 6192 octets de la tâche SendSpin.
2. **Lien radio 2,4 GHz défaillant** : `Probe Request Unsuccessful` / `Auth Expired` / `4-Way Handshake Timeout` en boucle sur les AP lointains (canal 9, -78/-84 dBm). Un nouvel AP dans la pièce règle l'association.
3. **Hard hang silencieux sur bursts TX** : toggle lecture → CPU gelé sans log. Disparu avec `output_power: 8.5dB` (+ `sram1_as_iram`, + sendspin-cpp 0.7.2) — cohérent avec un brownout RF : 20,5 dBm + ampli GPIO21 actif sur un rail 3V3 fragile.
4. **Décalage de version protocole** : client 2026.7.4 / sendspin-cpp 0.7.0 face à un serveur Voice PE 2026.8.x. Le passage en 2026.8.1 (0.7.2) a supprimé les timeouts `time_burst`.
5. **mDNS filtré au démarrage** : aucun service visible un moment (`_sendspin._tcp`, `_googlecast._tcp`…) puis réapparu — filtrage multicast (IGMP snooping) sur la Freebox.

## 2026-08-25 : « No matching network found » (radio prétendue HS)

Une édition du bloc `wifi:` a **supprimé la ligne `password:`**. Sans clé, ESPHome ne matche
que les réseaux **ouverts** (`WiFiScanResult::matches()`) → l'ESP voyait les AP (SSID
présent dans le scan, d'où le log « visible network ») mais n'essayait jamais de s'y
connecter. Ne jamais conclure « radio HS » sans vérifier que `password:` est bien là.
L'antenne a été remplacée pendant ce faux diagnostic ; l'A/B est dans `mesures_antenne.md`
(remplaçante gardée, +5,3 dB).

## 2026-08-25 : crash reboots en lecture groupe — le décodeur FLAC

Symptôme : reboots aléatoires toutes les 2–5 min en lecture groupe avec les Voice PE
(`Guru Meditation LoadProhibited`, `rst:0xc SW_CPU_RESET`). Analyse complète dans
`crash_analysis.md` : corruption du heap sur le chemin micro-flac, crash dans
`SyncTask::write_audio_chunk → xRingbufferSendAcquire`.

Mitigation côté serveur MA : forcer le codec PCM pour ce player (« Preferred audio
format » → `PCM 48kHz/16bit mono`, ou `ma_api.py config/players/save` avec la clé
`<id_sendspin>||protocol||preferred_sendspin_format = pcm:48000:16:1`), puis stop/play du
groupe pour renégocier. 12+ min de lecture groupe sans crash en PCM. Le PCM stéréo est
à éviter (test du 2026-09-08 : coupures et `Lost sync` malgré 0 % de perte ICMP).

Synchro fine : « Static playback delay » réglé à **136 ms** à l'oreille avec la Voice PE
(Muse en avance → augmenter ; en retard → diminuer, pas de 20–50 ms). Le
`initial_static_delay: 2000ms` du yaml n'est que la valeur de boot : MA applique son
propre réglage à chaque session.

## 2026-08-25 soir : lag audio à la position définitive (résolu)

Après déplacement à la position définitive (nouvel AP `4f:4e`, canal 6, RSSI −40 dBm) :
audio qui lag.

1. **Ce n'était pas la puissance radio.** Lien propre à l'arrêt (ping 8 ms), RSSI fort ;
   passer `output_power` de 8.5 à 11.5 dB n'a rien changé. La montée du ping sous charge
   (25-400 ms) était un leurre : l'ICMP est dépriorisé, et l'ESP n'a loggé aucun
   `Lost sync` sur les mêmes fenêtres.
2. **C'était la session SendSpin.** Une session née au boot/reconnect peut être dégradée
   et ne se répare jamais seule. Le pause/play du groupe (pas le power-cycle) repart sur
   une session saine.
3. **Le dump de crash au boot est périmé** : c'est l'ancien crash FLAC conservé en mémoire
   RTC (« Captured by a different firmware build »), réimprimé à chaque boot.

Correctif : `player_queues/pause` puis `play` sur le groupe après tout déplacement/reboot
où l'audio lag. `output_power` reste à 11.5 dB. Capteurs `wifi_signal` + `wifi_info/bssid`
ajoutés au yaml et gardés.

État au 2026-08-25 soir (firmware 2026.8.1) :

| Fonction | État |
|----------|------|
| Association Wi-Fi 2,4 GHz | ✅ AP `4f:4e` canal 6, −40 dBm, 0 % de perte, RTT ~8 ms |
| Sortie audio ES8388 (DACPOWER/LOUT1) | ✅ |
| Connexion SendSpin | ✅ |
| Lecture audio radio | ✅ |
| OTA | ⚠️ échoue si l'enceinte crashe mid-upload ; flash série fiable |
| Synchro multiroom | ✅ stable 12+ min en PCM |
| LED, boutons, volume | ✅ |

## 2026-09-08 : watchdog, lecteur invisible et son haché

- Hard reboot confirmé `reset_reason = other watchdogs`.
- L'ESP était joignable mais MA gardait le lecteur `available: false`. Ajouter l'IP fixe
  de la Muse dans les **adresses IP de découverte manuelle** du fournisseur Sendspin a
  rétabli la connexion et rend le retour après reboot indépendant du mDNS.
- PCM stéréo négocié mais haché, sauts de synchro de plusieurs centaines de ms à 1,9 s.
  Après reboot et session PCM mono neuve, la trace est redevenue calme.
- Opus stéréo n'est pas un repli : `stack overflow` dans
  `sendspin::SyncTask::handle_load_chunk()` dès le début du décodage (pile 6192 octets
  codée en dur dans sendspin-cpp 0.7.2). Capture : `captures/2026-09-08-opus-stack-overflow.txt`.
- Correctif firmware : pile de la source SendSpin en RAM interne
  (`media_source.task_stack_in_psram: false`), ring buffer et décodage restant en PSRAM.
- 512 Kio saturaient pendant le burst PCM initial (`Failed to send audio chunk` en rafale,
  logger bloqué 956 ms) → buffer porté à 1 Mio.
- Encore un crash après 42 s, handle de ring buffer corrompu (`EXCVADDR=0x439`) depuis la
  tâche `httpd` : pile ESP-IDF de 4 Kio (Sendspin/sendspin-cpp#102). Patch local à 16 Kio
  + pile du hub en RAM interne. Premier test PCM mono : plus de sept minutes, une
  transition de piste et trois cycles pause/reprise sans chunk rejeté ni reboot.

Configuration MA retenue : `manual_discovery_ip_addresses = ["192.168.10.86"]`,
`preferred_sendspin_format = pcm:48000:16:1`, `sendspin_static_delay = 136`.

## 2026-09-13 : gel complet puis récupération watchdog

Voir `crash_analysis.md` (section du même nom) : gel sans panic réanimé par watchdog,
Muse exclue des membres actifs de `maison-all` jusqu'au reflash série du 2026-09-14.

## 2026-09-26 : son haché après maj MA 2.10.2 → 2.10.4 (HA 2026.9)

Son haché depuis ~1 h sur `maison-all` (radio fip, icecast AAC), ~1 h après la maj MA.
ESP 2026.8.2 inchangé ; HA 2026.9 sans changement Sendspin/audio.

1. **Pacing radio trop juste (MA 2.10.3, PR music-assistant/server#6237)** : les flux
   just-in-time passent à 1.03× avec seulement 3 s d'avance. Sur le lien Wi-Fi marginal,
   chaque creux radio → sous-alimentation. Côté API : `elapsed_time` qui cale puis
   rattrape par sauts de +30 à +62 s.
2. **Réinitialisation des réglages Sendspin du player** : `preferred_sendspin_format`
   revenu à `automatic` et `sendspin_static_delay` 136 → 0 ms. Les réglages provider ont
   survécu. Restauration via `ma_api.py config/players/save`.

Piège : après un pause/play du groupe sous 2.10.4, `elapsed_time` reste figé même quand le
son repart. Stop/play, `play_media`, ungroup/regroup n'ont pas suffi ; **seul un
redémarrage du serveur MA assainit complètement** les sessions.

Réponse firmware : **ESPHome 2026.9.0** (OTA, 42,3 s) avec `codecs: [pcm]` — même un MA
en `automatic` ne peut plus négocier autre chose que PCM, ce qui immunise contre ce type
de reset de config MA.

Liens amont : esphome/esphome#16065 (« sendspin stutters on connection handoff », ouvert) ;
sendspin-cpp v0.7.1 (PR #104) réduit l'usage pile httpd de 51 % ; RASPIAUDIO/esphomeLuxeMusic
52b7ef9 (« 2026.9.3 », ESPHome ≥ 2026.8.2 + IP5306).

## 2026-10-26 : enceinte absente de MA après maj HA/MA (→ ESPHome 2026.10.0)

Contexte : MA serveur passé 2.10.4 → **2.10.8** (via maj HA), firmware ESP en 2026.9.0.

1. **L'ESP était hors réseau** (ping « Destination Host Unreachable ») : un reset (EN via
   la liaison série USB) l'a reconnectée au Wi-Fi puis à MA. Le firmware 2026.9 restait
   compatible MA 2.10.8 (`allow_legacy_clients`) ; la cause de la déconnexion n'est pas
   observable (le reset a écrasé `reset_reason`).
2. **Sortie du groupe `maison-all`** : MA 2.10.8 (PR #7008) libère les membres d'un groupe
   synchronisé qui se dissout à vide. L'enceinte restait dans la config statique du groupe
   mais plus dans ses membres actifs → rejointe via `players/cmd/set_members`
   (`target_player=syncgroup_3aj8ekkc`).

Mise à jour **ESPHome 2026.10.0** (sendspin-cpp 0.9.3, protocole Sendspin 1.0.0-rc1) :

- **Toutes les connexions Sendspin sont chiffrées (Noise)** : exige MA ≥ 2.10.7. Accès
  non appairé actif par défaut, aucun appairage nécessaire.
- **L'id client Sendspin ne dérive plus de la MAC** mais d'une paire de clés stockée en
  NVS (`OhYTf5EqiF0VXHYrANFrDSHPuEYAE23dBS5Bf3kdIn0`). MA a migré seul format PCM mono et
  délai 136 ms vers ce nouvel id, mais `preferred_output_protocol` du player universel
  `upac0bfb201f60` pointait encore l'ancien id MAC → repointé. Un effacement complet de la
  flash (NVS) régénérerait la clé.
- `rgb_order` (LED) remplacé par `channel_colors: GRB` (déprécié, retiré en 2027.3).
- Patch pile HTTPD et `apply_sendspin_patch.sh` supprimés : sendspin-cpp ≥ 0.9 dimensionne
  cette pile par analyse statique et n'y fait plus aucun travail Noise/protocole.
- Clé `api.encryption.key` déplacée dans `secrets.yaml`.
- Firmware 2026.9.0 sauvegardé dans `backups/2026.9.0/` (local, ignoré par git).
- Vérification : ~7 min de lecture groupe sans rien sur la série (ni crash, ni `Lost sync`),
  reconnexion automatique en ~10 s après reflash et retour dans le groupe en cours.
