"""Mint a long-lived token over the HA websocket. Runs inside the container.
Usage: python3 /config/mint.py <access_token>  -> prints the long-lived token."""
import asyncio, sys, aiohttp

async def main(access):
    async with aiohttp.ClientSession() as s:
        async with s.ws_connect("http://localhost:8123/api/websocket") as ws:
            await ws.receive_json()
            await ws.send_json({"type": "auth", "access_token": access})
            msg = await ws.receive_json()
            assert msg["type"] == "auth_ok", msg
            await ws.send_json({"id": 1, "type": "auth/long_lived_access_token",
                                "client_name": sys.argv[2] if len(sys.argv) > 2 else "smarli-test", "lifespan": 365})
            msg = await ws.receive_json()
            print(msg.get("result") or ("ERR " + str(msg)))

asyncio.run(main(sys.argv[1]))
