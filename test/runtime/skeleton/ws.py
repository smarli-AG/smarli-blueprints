"""Send one websocket command to HA and print the result message as JSON. Runs inside the container.
Usage: python3 /config/ws.py <access_token> <message as base64 JSON, without "id">
Base64 because PowerShell 5.1 mangles double quotes in native-command arguments."""
import asyncio, base64, json, sys, aiohttp

async def main(token, msg):
    async with aiohttp.ClientSession() as s:
        async with s.ws_connect("http://localhost:8123/api/websocket") as ws:
            await ws.receive_json()
            await ws.send_json({"type": "auth", "access_token": token})
            m = await ws.receive_json()
            assert m["type"] == "auth_ok", m
            await ws.send_json({"id": 1, **msg})
            while True:
                m = await ws.receive_json()
                if m.get("id") == 1:
                    print(json.dumps(m))
                    return

asyncio.run(main(sys.argv[1], json.loads(base64.b64decode(sys.argv[2]))))
