"""Read-only clients for VeChainThor's public REST API, retried. Nothing here sends a transaction: `inspect` runs clauses
against a block's state (`POST /accounts/*`), as a node's call simulation does, and commits nothing."""

import json
import time
import urllib.request

MAINNET = "https://mainnet.vechain.org"
TESTNET = "https://testnet.vechain.org"


def _retry(fn):
    for attempt in range(8):
        try:
            return fn()
        except Exception:
            if attempt == 7:
                raise
            time.sleep(2 * (attempt + 1))


def get(node, path):
    def go():
        req = urllib.request.Request(node + path, headers={"User-Agent": "xindex-fixtures"})
        return json.load(urllib.request.urlopen(req, timeout=60))

    return _retry(go)


def inspect(node, clauses, revision):
    """The outputs of `clauses` run on the state of block `revision`, simulated."""
    body = json.dumps({"clauses": clauses}).encode()

    def go():
        req = urllib.request.Request(
            "%s/accounts/*?revision=%s" % (node, revision), body,
            {"Content-Type": "application/json", "User-Agent": "xindex-fixtures"},
        )
        return json.load(urllib.request.urlopen(req, timeout=60))

    return _retry(go)
