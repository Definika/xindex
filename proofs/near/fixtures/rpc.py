"""A NEAR JSON-RPC client for the fixture generator: read-only calls, retried."""

import json
import time
import urllib.request

MAINNET = "https://rpc.mainnet.near.org"


def call(method, params, url=MAINNET):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    for attempt in range(6):
        try:
            req = urllib.request.Request(url, body, {"Content-Type": "application/json"})
            reply = json.load(urllib.request.urlopen(req, timeout=60))
            if "error" in reply:
                raise RuntimeError(reply["error"])
            return reply["result"]
        except Exception:
            if attempt == 5:
                raise
            time.sleep(2 * (attempt + 1))
