# SPDX-License-Identifier: BUSL-1.1
"""Writes Solana's address book of Ondo's tokens, `solana/listing/ondo.json`, and the mint accounts it was read from,
`solana/listing/ondo-mints.json`, which the program's tests list one by one (`programs/xindex/tests/ondo_book.rs`).

The list is Ethereum's: every Ondo token `keeper/bot/price-ids.mjs` holds, each at the Pyth feed it has there. For each,
Ondo's asset page names its addresses on every network; the Ethereum address must be the catalogue's, and the Solana
mint is read on chain: a Token-2022 mint whose metadata names the symbol, with the decimals Ondo's page gives.

Run from the repository root, standard library only:

    python3 -I solana/listing/read_ondo.py [--pages CACHE.json]

`--pages` reads the networks of each asset page from a cache a previous run wrote, or writes it there."""

import base64
import json
import re
import sys
import time
import urllib.request

ASSETS = "https://app.ondo.finance/api/v2/assets"
PAGE = "https://app.ondo.finance/assets/"
RPC = "https://api.mainnet-beta.solana.com"
TOKEN_2022 = "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb"
AGENT = {"User-Agent": "Mozilla/5.0 (compatible; index-research)"}
# The nine tokens Pyth prices as tokens ("... ONDO TOKENIZED STOCK"); every other one is priced at its share's feed,
# times the scaled-UI multiplier its mint carries.
TOKEN_FEEDS = {"NVDAon", "AAPLon", "GOOGLon", "MSFTon", "TSLAon", "HOODon", "MSTRon", "COINon", "CRCLon"}
NETWORK = re.compile(
    r'\\"network\\":\\"(ETHEREUM|BSC|SOLANA)\\",\\"chainId\\":(\d+),\\"address\\":\\"([^"\\]+)\\",\\"decimals\\":(\d+)'
)


def get(url, body=None):
    for attempt in range(5):
        try:
            data = None if body is None else json.dumps(body).encode()
            headers = dict(AGENT, **({"Content-Type": "application/json"} if body else {}))
            with urllib.request.urlopen(urllib.request.Request(url, data, headers), timeout=60) as response:
                return response.read()
        except Exception:
            time.sleep(3 * (attempt + 1))
    raise SystemExit(f"could not read {url}")


def catalogue():
    """Ethereum's Ondo tokens: (address, feed, SYMBOL) for every catalogue entry Ondo's list names."""
    text = open("keeper/bot/price-ids.mjs").read()
    block = text[text.index("MAINNET_PRICE_IDS") :]
    block = block[: block.index("});")]
    return re.findall(r'"(0x[0-9a-f]{40})":\s*"(0x[0-9a-f]{64})",\s*//\s*(\S+)', block)


def networks(symbols, cache):
    pages = json.load(open(cache)) if cache else {}
    for symbol in symbols:
        if symbol in pages:
            continue
        html = get(PAGE + symbol.lower()).decode("utf-8", "replace")
        found = {}
        for net, _, address, decimals in NETWORK.findall(html):
            found.setdefault(net, [address, int(decimals)])
        pages[symbol] = found
        time.sleep(0.25)
    if cache:
        json.dump(pages, open(cache, "w"), indent=1)
    return pages


def accounts(mints, encoding):
    slot, values = None, []
    for i in range(0, len(mints), 100):
        reply = json.loads(
            get(RPC, {"jsonrpc": "2.0", "id": 1, "method": "getMultipleAccounts",
                      "params": [mints[i : i + 100], {"encoding": encoding}]})
        )
        slot = reply["result"]["context"]["slot"] if slot is None else min(slot, reply["result"]["context"]["slot"])
        values += reply["result"]["value"]
    return slot, values


def main():
    cache = sys.argv[sys.argv.index("--pages") + 1] if "--pages" in sys.argv else None
    reply = json.loads(get(ASSETS))
    assets = {a["symbol"].upper(): a for a in reply["assets"]}
    listed = [(address, feed, assets[symbol]) for address, feed, symbol in catalogue() if symbol in assets]
    pages = networks([a["symbol"] for _, _, a in listed], cache)

    entries, missing = [], []
    for address, feed, asset in listed:
        found = pages[asset["symbol"]]
        if "SOLANA" not in found:
            missing.append(asset["symbol"])
            continue
        assert found["ETHEREUM"][0].lower() == address, (asset["symbol"], found["ETHEREUM"], address)
        entries.append((asset, found["SOLANA"], feed))

    mints = [solana[0] for _, solana, _ in entries]
    slot, parsed = accounts(mints, "jsonParsed")
    _, raw = accounts(mints, "base64")
    tokens, fixtures, authorities = [], {}, {}
    for (asset, (mint, decimals), feed), info, data in zip(entries, parsed, raw):
        assert info is not None and info["owner"] == TOKEN_2022, (asset["symbol"], mint)
        state = info["data"]["parsed"]["info"]
        extensions = {e["extension"]: e.get("state") for e in state.get("extensions", [])}
        assert state["decimals"] == decimals, (asset["symbol"], state["decimals"], decimals)
        assert extensions["tokenMetadata"]["symbol"] == asset["symbol"], (asset["symbol"], extensions["tokenMetadata"])
        assert "scaledUiAmountConfig" in extensions, asset["symbol"]
        for key in (state.get("mintAuthority"), state.get("freezeAuthority")):
            authorities[key] = authorities.get(key, 0) + 1
        tokens.append({
            "symbol": asset["symbol"],
            "ticker": asset["ticker"],
            "name": asset["assetName"],
            "mint": mint,
            "decimals": decimals,
            "pythFeed": feed,
            "feedKind": "token" if asset["symbol"] in TOKEN_FEEDS else "share",
            "multiplier": extensions["scaledUiAmountConfig"]["multiplier"],
            "paused": bool((extensions.get("pausableConfig") or {}).get("paused")),
            "hookProgram": (extensions.get("transferHook") or {}).get("programId"),
            "permanentDelegate": "permanentDelegate" in extensions,
            "ethereum": pages[asset["symbol"]]["ETHEREUM"][0].lower(),
        })
        fixtures[mint] = data["data"][0]

    book = {
        "read": {"slot": slot, "ondoAssetsUpdatedAt": reply["lastUpdatedAt"], "rpc": RPC},
        "tokenProgram": TOKEN_2022,
        "authorities": authorities,
        "missingOnSolana": missing,
        "tokens": tokens,
    }
    json.dump(book, open("solana/listing/ondo.json", "w"), indent=1)
    json.dump({"slot": slot, "owner": TOKEN_2022, "accounts": fixtures}, open("solana/listing/ondo-mints.json", "w"))
    print(f"{len(tokens)} mints at slot {slot}; {len(missing)} with no Solana mint: {missing}")


if __name__ == "__main__":
    main()
