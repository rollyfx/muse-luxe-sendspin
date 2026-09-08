# Mesures d'antenne — Muse Luxe (ESP32)

Comparaison A/B de l'antenne 2,4 GHz. Contexte : l'antenne a été remplacée le
2026-08-25 pendant le diagnostic « radio HS » (qui était en réalité une ligne
`password:` supprimée du yaml — voir README). La radio n'a jamais été en cause ;
ces mesures servent à décider objectivement quelle antenne garder.

## Protocole (à respecter pour que A et B soient comparables)

- **Enceinte immobile** : même position/orientation au bureau, même distance au
  satellite Orbi. Ne pas la déplacer entre A et B.
- **AP de référence** : `<BSSID_AP>` (2,4 GHz, canal 6, satellite du
  bureau, vu à 100 % du PC au même endroit). RSSI mesuré côté ESP.
- **Mesures** (depuis le PC, dans `muse-luxe/`) :
  ```bash
  # RSSI côté ESP : 60 s, 1 échantillon / 2 s (capteur temporaire wifi_signal du yaml)
  ./.venv-2026.8.3/bin/python mesure_antenne.py 60
  # RTT + perte (voie TX+RX aller-retour)
  ping -c 30 -i 0.3 -q <IP_MUSE>
  ```
- **Lecture des résultats** : une différence n'est significative que si
  Δmoyenne ≥ 3 dB (l'écart-type intra-mesure est ~1,2 dB → 2σ ≈ 2,5 dB).
  Le RSSI absolu dépend du AP choisi ; si la moyenne saute de > 10 dB,
  vérifier que l'ESP n'a pas changé d'AP avant de conclure.

## Résultats

### Mesure A — antenne actuelle (remplaçante posée le 2026-08-25)

| Métrique | Valeur |
|---|---|
| RSSI moyen côté ESP | **−32,8 dBm** |
| min / max | −35,0 / −30,0 dBm |
| Écart-type | 1,20 dB (n = 31) |
| Ping PC → ESP | 30/30, RTT moyen 17,0 ms (σ 10,8, max 49,9) |
| AP | `4c:c9` 2,4 GHz ch 6 (supposé — RSSI cohérent avec l'AP à 100 % du PC) |

### Mesure B — autre antenne (l'originale)

| Métrique | Valeur |
|---|---|
| RSSI moyen côté ESP | **−38,1 dBm** |
| min / max | −41,0 / −35,0 dBm |
| Écart-type | 1,71 dB (n = 31) |
| Ping PC → ESP | 30/30, RTT moyen 12,8 ms (σ 7,1, max 45,5) |
| AP | inchangé (enceinte non déplacée, pas de roaming observé entre A et B) |

## Verdict

**L'antenne A (remplaçante, posée le 2026-08-25) est meilleure de 5,3 dB** — écart
largement significatif (seuil 3 dB ; σ respectifs 1,2 / 1,7 dB). La différence de
ping (17,0 vs 12,8 ms) n'est pas discriminante : les deux liens sont sans perte et
loin du plancher de sensibilité. **Garder l'antenne A montée.**

Remarque : −38 dBm pour l'originale reste un excellent lien ; si un jour l'antenne A
est endommagée, l'originale reste parfaitement utilisable.
