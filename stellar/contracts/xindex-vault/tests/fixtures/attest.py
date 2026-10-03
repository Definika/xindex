#!/usr/bin/env python3
"""Builds attest.json: the vectors `attest`'s record and the hub's slot keys are pinned against, computed by Solidity's
own encoder (`cast abi-encode`) and `cast keccak`, independently of the vault's code.

- The record: `abi.encode(ATTEST_DOMAIN, chainId, vaultId, slots, values)`, as `bytes32, uint256, bytes32, bytes32[],
  bytes32[]` (`design/2026-10-03-near-stellar-interfaces.md`).
- The keys the hub reads a vault's storage at: an index's digest at `keccak256(abi.encode(index, 14))`, an intake's at
  `keccak256(abi.encode(intakeId, keccak256(abi.encode(index, 15))))` (`HybridHubStorage`).

Needs foundry's `cast`. From the repository root:

    python3 stellar/contracts/xindex-vault/tests/fixtures/attest.py
"""

import json
import os
import subprocess

OUT = os.path.join(os.path.dirname(__file__), "attest.json")
ATTEST_DOMAIN = "0xb0ec2b25fdd79b42b523d5b0e641474599bbba254460db808de33f7bc0c25d5c"
CHAIN_ID = 17_667_989_177_921_016_935  # Stellar testnet's registry id
VAULT = "0x1fe52b378c4f36f86bb4aa3eafe30f9045c01bcc23182cd8ea8d01d43515728a"
INDEX = "0x5FbDB2315678afecb367f032d93F642f64180aa3"
INTAKE_ID = "0x" + format((1_800_003_600 << 192) | 7, "064x")


def cast(*args):
    return subprocess.run(["cast", *args], capture_output=True, text=True, check=True).stdout.strip()


def main():
    assert cast("keccak", "xindex.v4.vault-attest") == ATTEST_DOMAIN
    index_slot = cast("keccak", cast("abi-encode", "f(address,uint256)", INDEX, "14"))
    inner = cast("keccak", cast("abi-encode", "f(address,uint256)", INDEX, "15"))
    intake_slot = cast("keccak", cast("abi-encode", "f(uint256,bytes32)", INTAKE_ID, inner))
    slots = [index_slot, intake_slot, "0x" + "00" * 31 + "19"]
    values = ["0x" + "11" * 32, "0x" + "22" * 32, "0x" + "00" * 32]
    record = cast("abi-encode", "f(bytes32,uint256,bytes32,bytes32[],bytes32[])", ATTEST_DOMAIN, str(CHAIN_ID), VAULT,
                  "[" + ",".join(slots) + "]", "[" + ",".join(values) + "]")
    fixture = {
        "chain_id": CHAIN_ID,
        "vault": VAULT,
        "index": INDEX,
        "intake_id": INTAKE_ID,
        "index_slot": index_slot,
        "intake_slot": intake_slot,
        "slots": slots,
        "values": values,
        "record": record,
    }
    with open(OUT, "w") as f:
        json.dump(fixture, f, indent=1)
        f.write("\n")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
