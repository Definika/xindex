"""Adds to `mainnet.json` the flat arrays `forge`'s JSON readers take: each Merkle path's hashes and sides, for the real
outcome and the synthetic one. `generate.py` calls it; run alone, it rewrites the file in place from what it holds.

    python3 solidity_view.py
"""

import json

PATHS = ["outcome_path", "outcome_root_path", "block_path"]


def flatten(out):
    for part in ("outcome", "synthetic"):
        for path in PATHS:
            out[part][path + "_hashes"] = [i["hash"] for i in out[part][path]]
            out[part][path + "_left"] = [i["left"] for i in out[part][path]]
    return out


if __name__ == "__main__":
    with open("mainnet.json") as f:
        data = json.load(f)
    with open("mainnet.json", "w") as f:
        json.dump(flatten(data), f, indent=1)
        f.write("\n")
