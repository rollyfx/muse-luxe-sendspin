#!/usr/bin/env python3
"""Mesure RSSI de l'antenne de la Muse Luxe (capteur wifi_info 'Signal WiFi').

Échantillonne le capteur pendant N secondes via l'API ESPHome, affiche
moyenne/min/max/écart-type et le nombre d'échantillons. À relancer tel quel
après un changement d'antenne pour la comparaison A/B (voir mesures_antenne.md).

Usage: .venv-2026.8.3/bin/python mesure_antenne.py [durée_s]
"""
import asyncio
import os
import statistics
import sys

from aioesphomeapi import APIClient

HOST = os.getenv("MUSE_HOST", "muse-luxe-music.local")
PORT = 6053
DURATION = int(sys.argv[1]) if len(sys.argv) > 1 else 60


async def main() -> None:
    cli = APIClient(HOST, PORT, None, noise_psk=None)
    await cli.connect(login=False)
    entities, _ = await cli.list_entities_services()
    target = None
    for ent in entities:
        oid = getattr(ent, "object_id", "").lower().replace("_", "")
        if oid in ("signalwifi", "wifisignal"):
            target = ent
            break
    samples: list[float] = []

    def on_state(state) -> None:
        if state.key == target.key and hasattr(state, "state"):
            samples.append(float(state.state))

    cli.subscribe_states(on_state)
    await asyncio.sleep(DURATION)

    if not samples:
        sys.exit("Aucun échantillon reçu")
    print(f"n={len(samples)}  moy={statistics.mean(samples):.1f} dBm  "
          f"min={min(samples)}  max={max(samples)}  "
          f"ecart-type={statistics.pstdev(samples):.2f}")


asyncio.run(main())
