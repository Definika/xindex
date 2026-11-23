// The executor's source, read as an attacker reads it (audit/2026-11-23-attack-replay.md): the constructs that the
// hacks of 2024 to 2026 went through are not in it, and the one mark that opens its callback is written in one
// place, cleared in one and read in one.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const source = readFileSync(new URL("../../src/KeeperExecutor.sol", import.meta.url), "utf8");
const count = (needle) => source.split(needle).length - 1;

test("HK-03, HK-04: the executor makes no call a caller can aim and has no code it can replace", () => {
  for (const banned of ["delegatecall", "selfdestruct", "callcode", "tx.origin", "ecrecover", ".call(", ".call{", "assembly", "sstore("]) {
    assert.equal(count(banned), 0, `KeeperExecutor.sol has ${banned}`);
  }
});

test("HK-03: the executor pulls a token from nobody but its caller, in one place", () => {
  assert.equal(count("ransferFrom("), 1);
  assert.equal(count("SafeERC20.safeTransferFrom(IERC20(USDC), msg.sender, address(this), amount)"), 1);
});

test("HK-01: the callback's mark is the executor's only transient storage: set once, cleared once, read once", () => {
  assert.equal(count(" transient "), 1);
  assert.equal(count("address private transient _filling;"), 1);
  assert.equal(count("_filling"), 4, "the declaration, the write, the clear and the check");
  assert.equal(count("_filling = address(index);"), 1);
  assert.equal(count("_filling = address(0);"), 1);
  assert.equal(count("if (msg.sender != _filling) revert UnexpectedCaller(msg.sender);"), 1);
  assert.equal(count("tstore"), 0);
  assert.equal(count("tload"), 0);
});
