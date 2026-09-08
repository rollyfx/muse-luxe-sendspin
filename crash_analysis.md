# Crash analyse — LoadProhibited pendant lecture groupe (2026-08-25)

## Symptôme

Reboots (~2/5 min) pendant lecture en groupe Music Assistant (flux FLAC).
Firmware : ESPHome 2026.8.1, sendspin-cpp 0.7.2, `luxe_music_min.yaml`.

## Capture (16:50:23, /tmp/reboot_watch.txt)

```
Guru Meditation Error: Core 1 panic'ed (LoadProhibited). Exception was unhandled.
EXCVADDR: 0x000000e3
PC: 0x4008c1ee (spinlock_acquire / xPortEnterCriticalTimeout)
Rebooting... rst:0xc (SW_CPU_RESET)
```

## Backtrace symbolisé (addr2line, firmware.elf du build)

```
xt_utils_get_raw_core_id / spinlock_acquire      (xtensa port.c:489)
xPortEnterCritical → prvSendAcquireGeneric       (esp-idf ringbuf.c:779)
xRingbufferSendAcquire                           (esp-idf ringbuf.c:1006)
SpscRingBuffer::acquire                          (spsc_ring_buffer.h:111)
SendspinAudioRingBuffer::write_chunk             (audio_ring_buffer.cpp:56)
SyncTask::write_audio_chunk                      (sync_task.cpp:174)
PlayerRole::Impl::send_audio_chunk               (player_role.cpp:542)
PlayerRole::Impl::handle_binary                  (player_role.cpp:237)
SendspinClient::process_binary_message           (client.cpp:932)
ConnectionManager lambda                         (connection_manager.cpp:521)
SendspinConnection::dispatch_completed_message   (connection.cpp:114)
SendspinServerConnection::handle_data            (server_connection.cpp:243)
SendspinWsServer::websocket_handler              (ws_server.cpp:316)
httpd_req_new / httpd_sess_process / httpd_thread (esp_http_server)
```

## Lecture

- Producteur = tâche httpd (websocket MA) → `xRingbufferSendAcquire`.
- EXCVADDR quasi-NULL (0xE3) : le handle du ring buffer lu depuis un objet
  `SendspinAudioRingBuffer` invalide/corrompu (heap). Valeur 0xE3 ressemble à
  un octet de données audio — signature d'un débordement d'écriture.
- Théories éliminées : destruction du client (le hub ne le détruit jamais),
  réinit du ring buffer (`init()` gardé par `is_initialized()`, `stop()` n'y
  touche pas), TOCTOU du null-check (le pointeur ne change jamais).
- Reste : corruption heap par un débordement voisin (décodeur micro-flac ou
  réassemblage websocket). Le décodeur FLAC tourne en PSRAM (`decode_memory:
  psram`) mais d'autres buffers (httpd/transfer) sont en DRAM, voisins des
  objets du SyncTask.

## Résultat de la mitigation (2026-08-25, 17:49 → 18:01+)

Bascule serveur MA en `preferred_sendspin_format = pcm:48000:16:2`
(via l'API websocket `config/players/save`, player `upac0bfb201f60`),
puis stop/play du groupe pour renégocier la session.

- Header reçu : `Processed new codec header: pcm, 48000 Hz, 2 ch, 16-bit`.
- **12+ minutes de lecture groupe sans aucun crash** (avant : reboot garanti
  en 2–5 min en FLAC). `reset_reason` inchangé, plus aucun `Lost sync`.
- Un dernier crash `exception/panic` a encore eu lieu pendant la session
  FLAC résiduelle juste avant la bascule — cohérent avec le diagnostic.

**Conclusion : le décodeur micro-flac (chemin consommateur FLAC) corrompt le
heap.** Le chemin PCM (`memcpy` borné, `decoder.cpp:147-154`) est stable.
Corruption par écriture hors-bornes d'un buffer voisin en DRAM ; le décodeur
FLAC alloue en PSRAM mais ses structures de contrôle/métadonnées vivent en
DRAM, à côté des objets du SyncTask crashés.

### Piste pour un rapport upstream (sendspin-cpp / micro-flac)

- Reproduire : ESP32 (PSRAM), sendspin-cpp 0.7.2, MA 2.9.13 en FLAC 48 kHz
  16-bit stéréo, lecture groupe ~2–5 min → `LoadProhibited` EXCVADDR 0xE3
  dans `xRingbufferSendAcquire` appelé depuis `SyncTask::write_audio_chunk`.
- Backtrace complet ci-dessus. Piste d'audit micro-flac : bornage de
  `decode()` sur `output_buffer_size` quand `max_block_size` du STREAMINFO
  est grand, et gestion des frames multi-chunks (NEED_MORE_DATA partiel).

## Second crash en PCM (2026-08-25, 19:12) — la conclusion « FLAC seul » est fausse

Après migration du lecteur à sa position définitive, un crash **identique** s'est
produit sous le firmware courant, **en PCM** :

- `Reason: LoadProhibited (cause 28)`, core 1 (thread httpd), `EXCVADDR: 0x429`.
- Pile (symbolisée par `esphome logs`, build courant — plus de warning
  « Captured by a different firmware build ») :
  `spinlock_acquire / xPortEnterCriticalTimeout ← prvSendAcquireGeneric ←
  xRingbufferSendAcquire ← SpscRingBuffer::acquire (spsc_ring_buffer.h:111) ←
  SendspinAudioRingBuffer::write_chunk (audio_ring_buffer.cpp:56)` — la même
  pile que le crash FLAC, au détail près.
- **Contexte : crash ~19:11-19:12, immédiatement après un
  `players/cmd/group`** (réajout de la Voice PE au syncgroup → arrêt/relance
  de session SendSpin). Pas de warning audio préalable (0 `Lost sync`,
  0 chunk perdu dans les 150 s précédentes).
- L'ESP a rebooté et s'est resynchronisé seul (interruption brève).

**Nouvelle lecture : le site de crash (`handle_` du ring buffer invalide dans
`xRingbufferSendAcquire`) est le point de convergence de DEUX problèmes :**

1. **Micro-flac en lecture continue** (hier) : corruption du heap par le
   décodeur, crash toutes les 2–5 min, contournée par `preferred_sendspin_format
   = pcm` (stable 30+ min à l'ancienne position, et une journée de tests à la
   nouvelle).
2. **Course à la destruction de session** (aujourd'hui, PCM) : probable
   use-after-free — le ring buffer est libéré/re-créé lors d'un teardown de
   session (regroup, stop/relance) pendant que le thread httpd écrit un chunk
   en vol. Déclencheur rare (churn de session), auto-récupérant.

La conclusion « le chemin PCM est stable/sûr » reste vraie pour la lecture
continue ; elle est fausse pour les transitions de session.

### Piste pour le rapport upstream (à fusionner avec la section micro-flac)

- Repro (bug 2) : ESP32, sendspin-cpp 0.7.2, MA 2.9.13, lecture groupe PCM
  48 kHz/16/2 ; retirer puis réajouter un membre au syncgroup pendant la
  lecture → `LoadProhibited EXCVADDR 0x429` dans `xRingbufferSendAcquire` ←
  `SendspinAudioRingBuffer::write_chunk` (core 1, httpd), ~1 essai sur 1.
- Audit suggéré : cycle de vie de `SendspinAudioRingBuffer` / `SpscRingBuffer`
  (qui possède `handle_`, quand est-il détruit, quel verrou protège
  `write_audio_chunk` contre un teardown concurrent côté `PlayerRole`/`SyncTask`).
- Contournement local : aucun patch ; éviter le regroup pendant la lecture
  (ou accepter le reboot ~5 s, auto-récupéré).


## Données brutes

- `/tmp/reboot_watch.txt` : capture série du panic FLAC (16:50).
- `/tmp/ser_mon.txt` : capture série de la session PCM stable (17:48+).
- Symptomatique aussi : `Lost sync (-25 à -63 ms)` fréquents avant le crash
  (jitter du lien Voice PE, cf. README).

## Reprise du diagnostic — 2026-09-08 (MA 2.10.2)

### Disparition après le plantage

Après un hard reboot, l'ESP répondait à nouveau sur son API native
(`<IP_MUSE>`, RSSI -48 à -57 dBm), mais Music Assistant conservait le
lecteur `upac0bfb201f60` avec `available: false`. Le port SendSpin 8928 et
l'annonce `_sendspin._tcp.local.` étaient pourtant présents.

Les diagnostics MA contenaient trois `TimeoutError` du client websocket
`aiosendspin.server.connection.<mac-d4006130>`. Le suffixe `d4006130` est le
hash d'anonymisation de la MAC de la Muse (`<MAC_MUSE>`) : MA perd bien
la connexion parce que l'ESP cesse de répondre, puis la découverte multicast
ne suffit pas toujours à la recréer.

Mitigation validée : ajouter `<IP_MUSE>` dans
`manual_discovery_ip_addresses` du fournisseur SendSpin. Le protocole natif
`<MAC_MUSE>` est redevenu disponible immédiatement. Après le reboot
suivant, malgré environ 94 s d'échecs d'authentification Wi-Fi, MA s'est
reconnecté automatiquement dès que l'ESP a retrouvé le réseau.

### Essais comparatifs des codecs

- PCM stéréo 48 kHz/16 bits : codec correctement négocié, mais son haché et
  pertes de synchro continuelles, avec des écarts allant jusqu'à -1,9 s et des
  opérations SendSpin de 207 ms. Le ping ne perdait aucun paquet
  (moyenne 18 ms, maximum 101 ms), donc le débit radio brut n'était pas la
  seule cause.
- PCM mono 48 kHz/16 bits, basculé depuis la session PCM stéréo déjà dégradée :
  sous-alimentations I2S et écarts jusqu'à -4,57 s.
- Opus stéréo 48 kHz/16 bits : crash immédiat après le premier header codec.
  FreeRTOS a détecté un débordement de pile dans la tâche `pthread`, avec
  `sendspin::SyncTask::handle_load_chunk()` dans la pile. sendspin-cpp 0.7.2
  réserve seulement 6192 octets à cette tâche (`SYNC_TASK_STACK_SIZE`). La
  capture symbolisée est archivée dans
  `captures/2026-09-08-opus-stack-overflow.txt`.
- PCM mono après le reboot provoqué par Opus : une correction initiale de
  8,8 ms, puis aucune nouvelle perte de synchro pendant la première minute de
  capture. Une session froide est donc beaucoup plus stable qu'une
  renégociation au milieu d'un état temporel déjà dégradé.

### État du diagnostic

Trois défauts indépendants sont désormais observés :

1. corruption/handle invalide dans le ring buffer, surtout reproductible en
   FLAC et lors de transitions de session ;
2. pile de décodage insuffisante pour Opus dans sendspin-cpp 0.7.2 ;
3. reconnexion MA dépendante du multicast après un crash, contournée par
   l'adresse de découverte manuelle.

Le profil de stabilisation conservé après ces essais est PCM mono
`pcm:48000:16:1`. Opus est exclu tant que la pile SendSpin n'est pas augmentée
et validée sur un firmware dédié. FLAC reste exclu à cause des crashs
`LoadProhibited` historiques.

### Correctif firmware mis en essai

La pile du `SyncTask` était explicitement allouée en PSRAM par
`media_source.task_stack_in_psram: true`, tandis que le stockage du ring buffer
est lui aussi alloué en PSRAM. Comme le débordement Opus est prouvé et que le
crash PCM finit avec un handle de ring buffer quasi-NULL, le correctif minimal
consiste à passer uniquement cette pile en RAM interne :

```yaml
media_source:
  - platform: sendspin
    task_stack_in_psram: false
```

Le premier essai avec le tampon audio de 512 Kio a démarré sans stack overflow,
mais le buffer s'est rempli dès le burst PCM initial. Des dizaines de
`Failed to send audio chunk` ont alors saturé le logger pendant 956 ms et
provoqué de nouvelles pertes de synchro. Le tampon est donc porté à 1 Mio pour
le second essai ; `decode_memory: psram`, le codec et la puissance Wi-Fi restent
inchangés.

Ce second essai a malgré tout reproduit le crash en 42 s :
`LoadProhibited`, `EXCVADDR=0x439`, toujours dans
`xRingbufferSendAcquire` appelé depuis la tâche `httpd`. Le buffer de 1 Mio
n'est donc pas le correctif du crash. La valeur quasi nulle du handle est
compatible avec une corruption de pile de la tâche HTTPD : ESP-IDF ne lui
réserve que 4096 octets par défaut, alors que tout le chemin WebSocket,
déchiffrement et dispatch Sendspin s'exécute dessus. Le problème de pile HTTPD
est aussi documenté par Sendspin/sendspin-cpp#102 et son usage a été réduit par
le correctif amont #104, sans augmentation de la pile dans la version 0.7.2.

Correctif local appliqué et flashé :

- `config.stack_size = 16384` dans `SendspinWsServer::start()` ;
- `sendspin.task_stack_in_psram: false` pour placer cette pile en RAM interne ;
- patch reproductible dans `patches/sendspin-httpd-stack.patch`, appliqué par
  `apply_sendspin_patch.sh` et automatiquement par `flash.sh` après génération
  des dépendances ESPHome.

Validation initiale : plus de sept minutes de PCM mono sans
`Failed to send audio chunk` ni panic, alors que le build précédent échouait
dès 42 s. Une transition de piste et trois cycles pause/reprise ont aussi été
absorbés sans reboot ; deux corrections `Lost sync` brèves sont apparues
pendant le churn forcé, puis la session finale est restée propre. Une validation
longue reste nécessaire avant de déclarer le défaut définitivement résolu.
