"""Interroge l'API websocket native de Music Assistant.

Usage:
  MUSIC_ASSISTANT_WS_URI=ws://<hote>:8095/ws python ma_api.py <commande> [json_args]
Exemples:
  python ma_api.py players/all
  python ma_api.py config/players/get '{"player_id": "..."}'
  python ma_api.py config/players/save '{"player_id": "...", "values": {...}}'
"""
import asyncio
import json
import os
import sys
from pathlib import Path

import websockets

URI = os.getenv("MUSIC_ASSISTANT_WS_URI", "ws://music-assistant.local:8095/ws")
TOKEN = Path(__file__).parent.joinpath(".ma_token").read_text().strip()
TIMEOUT = 10

async def send(command: str, args: dict | None = None):
    async with websockets.connect(URI, max_size=2**24) as ws:
        await ws.recv()  # server info
        await ws.send(json.dumps({"message_id": 0, "command": "auth", "args": {"token": TOKEN}}))
        # attendre le résultat d'auth
        while True:
            msg = json.loads(await asyncio.wait_for(ws.recv(), TIMEOUT))
            if str(msg.get("message_id")) == "0":
                if "error_code" in msg:
                    raise RuntimeError(f"auth refusé: {msg}")
                break
        msg_id = 1
        await ws.send(json.dumps({
            "message_id": msg_id,
            "command": command,
            **({"args": args} if args else {}),
        }))
        while True:
            msg = json.loads(await asyncio.wait_for(ws.recv(), TIMEOUT))
            if str(msg.get("message_id")) == str(msg_id):
                return msg


if __name__ == "__main__":
    cmd = sys.argv[1]
    args = json.loads(sys.argv[2]) if len(sys.argv) > 2 else None
    out = json.dumps(asyncio.run(send(cmd, args)), indent=2, ensure_ascii=False)
    print(out[:60000])
