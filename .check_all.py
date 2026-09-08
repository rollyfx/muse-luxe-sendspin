import asyncio
import os
from aioesphomeapi import APIClient, MediaPlayerInfo

async def main():
    host = os.getenv('MUSE_HOST', 'muse-luxe-music.local')
    cli = APIClient(host, 6053, None, noise_psk=None)
    await cli.connect(login=False)
    ents, _ = await cli.list_entities_services()
    mp = {e.key: (e.object_id, e) for e in ents if isinstance(e, MediaPlayerInfo)}
    ts = {e.key: e.object_id for e in ents if not isinstance(e, MediaPlayerInfo)}
    got = {}
    cli.subscribe_states(lambda st: got.update({st.key: st}))
    await asyncio.sleep(6)
    for k, st in got.items():
        if k in mp:
            print(mp[k][0], '=', st.state, 'vol=', round(st.volume, 2))
        elif k in ts:
            print(ts[k], '=', getattr(st, 'state', '?'))
    await cli.disconnect()

asyncio.run(main())
