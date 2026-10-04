"""Read-only clients for Injective's public endpoints: CometBFT's RPC and the EVM's JSON-RPC, retried."""

import json
import time
import urllib.parse
import urllib.request

COMET = "https://sentry.tm.injective.network"
EVM = "https://sentry.evm-rpc.injective.network/"


def _retry(fn):
    for attempt in range(6):
        try:
            return fn()
        except Exception:
            if attempt == 5:
                raise
            time.sleep(2 * (attempt + 1))


def comet(path, params, url=COMET):
    query = urllib.parse.urlencode(params)

    def go():
        req = urllib.request.Request("%s/%s?%s" % (url, path, query), headers={"User-Agent": "xindex-fixtures"})
        reply = json.load(urllib.request.urlopen(req, timeout=60))
        if "error" in reply:
            raise RuntimeError(reply["error"])
        return reply["result"]

    return _retry(go)


def evm(method, params, url=EVM):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()

    def go():
        req = urllib.request.Request(url, body, {"Content-Type": "application/json", "User-Agent": "xindex-fixtures"})
        reply = json.load(urllib.request.urlopen(req, timeout=60))
        if "error" in reply:
            raise RuntimeError(reply["error"])
        return reply["result"]

    return _retry(go)
