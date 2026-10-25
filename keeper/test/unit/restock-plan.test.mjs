import { test } from "node:test";
import assert from "node:assert/strict";
import { COINS, coinsOf } from "../../restock/coins.mjs";
import { bridgeable, plan } from "../../restock/plan.mjs";

const E18 = 10n ** 18n;
const XRP = COINS.find((c) => c.symbol === "XRP");
const SUI = COINS.find((c) => c.symbol === "SUI");
const ALGO = COINS.find((c) => c.symbol === "ALGO");
const usdc = (x) => BigInt(Math.round(x * 1e6));
const usdt = (x) => BigInt(Math.round(x * 1e6)) * 10n ** 12n; // BNB Chain's USDT has 18 decimals

const CFG = {
  bufferBps: 1000,
  minUsd: 100,
  dailyUsd: 50_000,
  keepUsd: 500,
  maxTransferUsd: 20_000,
  floatTargetUsd: 5_000,
  treasuryTargetUsd: 10_000,
  maxLossBps: 100,
  gasMin: new Map(),
};

/// A round with XRP at $2: no stock, no needs, the BNB Chain float at 10,000 USDT, gas everywhere.
function round(over = {}) {
  return {
    coins: [XRP],
    needs: new Map(),
    stock: new Map(),
    inflight: new Map(),
    home: { coins: new Map(), floats: new Map([["bsc", usdt(10_000)]]), gas: new Map([["bsc", E18]]), funding: new Map() },
    treasury: { usdc: 0n, allowance: 0n },
    prices: new Map([["XRP", 2]]),
    spentUsd: 0,
    restockAllowance: new Map(COINS.map((c) => [c.copy, 10n ** 30n])), // the owner's, ample unless a test says
    cfg: CFG,
    ...over,
  };
}
const kinds = (r) => r.actions.map((a) => a.kind);

test("a coin the fills need, with nothing anywhere, is bought for its need and the buffer, priced at Pyth", () => {
  const r = plan(round({ needs: new Map([[XRP.copy, 1_000n * E18]]) }));
  assert.deepEqual(kinds(r), ["buy"]);
  const [buy] = r.actions;
  assert.equal(buy.coin, "XRP");
  assert.equal(buy.usd, 2_200, "1,100 XRP (the need and 10%) at $2");
  assert.equal(buy.amountIn, usdt(2_200), "exact input, in the float's 18 decimals");
  assert.equal(buy.minOut, 1_089n * E18, "at least its worth at Pyth less the 1% loss bound");
  assert.equal(buy.amountOut, 1_100n * E18, "or exact output, the coins at Pyth");
  assert.equal(buy.maxIn, usdt(2_222), "for at most their worth and the 1% bound");
});

test("usable stock and transfers already on their way count against the need", () => {
  const needs = new Map([[XRP.copy, 1_000n * E18]]);
  const stock = new Map([[XRP.copy, { balance: 900n * E18, allowance: 600n * E18 }]]);
  const inflight = new Map([[XRP.copy, { in: 400n * E18, out: 0n }]]);
  assert.deepEqual(kinds(plan(round({ needs, stock, inflight }))), [], "600 usable and 400 coming cover it: the buffer is bought only with a shortfall");
  const r = plan(round({ needs, stock: new Map([[XRP.copy, { balance: 900n * E18, allowance: 500n * E18 }]]), inflight }));
  assert.deepEqual(kinds(r), ["buy"]);
  assert.equal(r.actions[0].usd, 400, "the 200 XRP missing is $400");
});

test("a small shortfall still buys RESTOCK_MIN_USD, so fees do not eat it", () => {
  const r = plan(round({ needs: new Map([[XRP.copy, 10n * E18]]) }));
  assert.equal(r.actions[0].usd, 100);
});

test("what the home wallet bought is bridged in, not sold, while the fills still need it", () => {
  const needs = new Map([[XRP.copy, 1_000n * E18]]);
  const atHome = 1_100n * E18 + 123n; // the dust below eight decimals stays home
  const r = plan(round({ needs, home: { ...round().home, coins: new Map([["XRP", atHome]]) } }));
  assert.deepEqual(kinds(r), ["bridgeIn"]);
  assert.equal(r.actions[0].amount, 1_100n * E18);

  // Part of it at home: that part is bridged in and the rest bought.
  const part = plan(round({ needs, home: { ...round().home, coins: new Map([["XRP", 500n * E18]]) } }));
  assert.deepEqual(kinds(part), ["bridgeIn", "buy"]);
  assert.equal(part.actions[0].amount, 500n * E18);
  assert.equal(part.actions[1].usd, 1_200, "the other 600 XRP");
});

test("once covered, the home wallet's coins are sold and the executor's spare stock beyond the keep goes home", () => {
  const stock = new Map([[XRP.copy, { balance: 5_000n * E18, allowance: 0n }]]);
  const r = plan(round({ stock, home: { ...round().home, coins: new Map([["XRP", 300n * E18]]) } }));
  assert.deepEqual(kinds(r), ["sell", "bridgeOut"]);
  assert.equal(r.actions[0].amount, 300n * E18);
  assert.equal(r.actions[0].minOut, usdt(594), "$600 less the 1% bound, in USDT");
  assert.equal(r.actions[1].amount, 4_750n * E18, "all but the $500 keep");

  const going = new Map([[XRP.copy, { in: 0n, out: 1n }]]);
  assert.deepEqual(kinds(plan(round({ stock, inflight: going }))), [], "never a second bridge out while one is on its way");
});

test("transfers and buys are cut to RESTOCK_MAX_TRANSFER_USD, and buys to what is left of the day's budget", () => {
  const needs = new Map([[XRP.copy, 100_000n * E18]]);
  const r = plan(round({ needs, home: { ...round().home, floats: new Map([["bsc", usdt(50_000)]]) } }));
  assert.equal(r.actions[0].usd, 20_000);
  const spent = plan(round({ needs, spentUsd: 45_000, home: { ...round().home, floats: new Map([["bsc", usdt(50_000)]]) } }));
  assert.deepEqual(kinds(spent), ["buy"]);
  assert.equal(spent.actions[0].usd, 5_000, "the $5,000 left of the day, not nothing (RS-7)");
});

test("a buy short of float waits: CCTP funds it, drawn from the executor, and BNB Chain is flagged for a hand top-up", () => {
  const sui = round({
    coins: [SUI],
    needs: new Map([[SUI.copy, 1_000n * 10n ** 9n]]),
    prices: new Map([["SUI", 3]]),
    home: { coins: new Map(), floats: new Map([["sui", usdc(100)]]), gas: new Map([["sui", 10n ** 9n]]), funding: new Map() },
    treasury: { usdc: usdc(1_000), allowance: usdc(100_000) },
  });
  const r = plan(sui);
  assert.deepEqual(kinds(r), ["draw", "fund"]);
  assert.equal(r.actions[1].amount, usdc(3_333 - 100 + 5_000), "what the buy lacks with its 1% bound, and the float's target on top");
  assert.equal(r.actions[0].amount, r.actions[1].amount - usdc(1_000), "the treasury draws only what it lacks");

  const onItsWay = plan({ ...sui, home: { ...sui.home, funding: new Map([["sui", 1n]]) } });
  assert.deepEqual(kinds(onItsWay), [], "not twice while a funding is on its way");

  const bsc = plan(round({ needs: new Map([[XRP.copy, 1_000n * E18]]), home: { ...round().home, floats: new Map() } }));
  assert.deepEqual(kinds(bsc), []);
  assert.match(bsc.notes.join("\n"), /bsc: top up its USDT float by hand/);

  const small = plan({ ...sui, treasury: { usdc: 0n, allowance: usdc(10) } });
  assert.deepEqual(kinds(small), ["fund"]);
  assert.match(small.notes.join("\n"), /allowance on the executor is too small/);
});

test("a chain without gas is left alone and flagged, a coin without a price too", () => {
  const cfg = { ...CFG, gasMin: new Map([["bsc", E18]]) };
  const r = plan(round({ cfg, needs: new Map([[XRP.copy, 1_000n * E18]]), home: { ...round().home, gas: new Map([["bsc", 1n]]) } }));
  assert.deepEqual(kinds(r), []);
  assert.match(r.notes.join("\n"), /bsc: gas below its minimum: top up BNB/);
  const unpriced = plan(round({ needs: new Map([[XRP.copy, 1n]]), prices: new Map() }));
  assert.deepEqual(kinds(unpriced), []);
  assert.match(unpriced.notes.join("\n"), /XRP: no Pyth price/);
});

test("idle float above twice its target comes home to the treasury, and the treasury repays beyond twice its own", () => {
  const algoChain = coinsOf(["SUI"]);
  const r = plan(
    round({
      coins: algoChain,
      prices: new Map([["SUI", 3]]),
      home: { coins: new Map(), floats: new Map([["sui", usdc(12_000)]]), gas: new Map([["sui", 10n ** 9n]]), funding: new Map() },
      treasury: { usdc: usdc(25_000), allowance: 0n },
    }),
  );
  assert.deepEqual(kinds(r), ["sweep", "repay"]);
  assert.equal(r.actions[0].amount, usdc(7_000), "down to the 5,000 target");
  assert.equal(r.actions[1].amount, usdc(15_000), "down to the 10,000 target");
  const algo = plan(round({ coins: [ALGO], prices: new Map([["ALGO", 0.2]]), home: { coins: new Map(), floats: new Map([["algorand", usdc(50_000)]]), gas: new Map(), funding: new Map() } }));
  assert.deepEqual(kinds(algo), [], "Algorand has no CCTP to sweep through");
});

test("the bridge carries eight decimals", () => {
  assert.equal(bridgeable(123_456_789_012_345_678n, 18), 123_456_780_000_000_000n);
  assert.equal(bridgeable(123_456_789n, 9), 123_456_780n);
  assert.equal(bridgeable(123_456_789n, 8), 123_456_789n);
  assert.equal(bridgeable(123_456n, 6), 123_456n);
});

test("a coin, chain or treasury with a move still to settle is left alone", () => {
  const needs = new Map([[XRP.copy, 1_000n * E18]]);
  assert.deepEqual(kinds(plan(round({ needs, busy: new Set(["XRP"]) }))), []);
  const sui = {
    coins: [SUI],
    needs: new Map([[SUI.copy, 1_000n * 10n ** 9n]]),
    prices: new Map([["SUI", 3]]),
    home: { coins: new Map(), floats: new Map(), gas: new Map([["sui", 10n ** 9n]]), funding: new Map() },
    treasury: { usdc: 0n, allowance: usdc(100_000) },
  };
  assert.deepEqual(kinds(plan(round({ ...sui, busy: new Set(["sui"]) }))), []);
  assert.deepEqual(kinds(plan(round({ ...sui, busy: new Set(["treasury"]) }))), [], "funded once the treasury's draw lands");
});

test("RS-1: a coin short of stock is brought in and bought only within what its restock allowance has left", () => {
  const r = plan(
    round({
      needs: new Map([[XRP.copy, 1_000n * E18]]),
      restockAllowance: new Map([[XRP.copy, 400n * E18]]),
      home: { ...round().home, coins: new Map([["XRP", 150n * E18]]) },
    }),
  );
  assert.deepEqual(kinds(r), ["bridgeIn", "buy"]);
  assert.equal(r.actions[0].amount, 150n * E18, "what the home wallet holds comes in first");
  assert.equal(r.actions[1].amountOut, 250n * E18, "and the buy stops at what the allowance has left");
});

test("RS-1: a coin whose restock allowance is spent is neither bought nor brought in, and the owner's call is named", () => {
  const r = plan(
    round({
      needs: new Map([[XRP.copy, 1_000n * E18]]),
      restockAllowance: new Map([[XRP.copy, 0n]]),
      home: { ...round().home, coins: new Map([["XRP", 150n * E18]]) },
    }),
  );
  assert.deepEqual(kinds(r), []);
  assert.match(r.notes.join("\n"), new RegExp(`XRP: short .*restock allowance.*setRestockAllowance\\(${XRP.copy}`));
});

test("RS-1: transfers on their way count only as far as the restock allowance goes", () => {
  // 1,000 XRP on their way, but only 300 of them can earn allowance: the need of 500 is not covered.
  const r = plan(
    round({
      needs: new Map([[XRP.copy, 500n * E18]]),
      inflight: new Map([[XRP.copy, { in: 1_000n * E18, out: 0n }]]),
      restockAllowance: new Map([[XRP.copy, 300n * E18]]),
    }),
  );
  assert.deepEqual(kinds(r), []);
  assert.match(r.notes.join("\n"), /XRP: short .*restock allowance/);
});

test("RS-1: what the restock allowance has left below RESTOCK_MIN_USD buys nothing", () => {
  const r = plan(round({ needs: new Map([[XRP.copy, 1_000n * E18]]), restockAllowance: new Map([[XRP.copy, 10n * E18]]) }));
  assert.deepEqual(kinds(r), [], "$20 of room is below the $100 minimum");
  assert.match(r.notes.join("\n"), /XRP: .*restock allowance.*RESTOCK_MIN_USD/);
});

test("RS-1: what the home wallet holds is brought in only as far as the restock allowance goes", () => {
  const r = plan(
    round({
      needs: new Map([[XRP.copy, 1_000n * E18]]),
      restockAllowance: new Map([[XRP.copy, 100n * E18]]),
      home: { ...round().home, coins: new Map([["XRP", 150n * E18]]) },
    }),
  );
  assert.deepEqual(kinds(r), ["bridgeIn"], "no buy: the room is taken by what comes in");
  assert.equal(r.actions[0].amount, 100n * E18, "100 of the 150 at home, the rest left there");
});

test("RS-3: a buy is for exactly what the need and its buffer lack, not that amount through floating point", () => {
  // The end-to-end test's AERO: 1,876.76 at $0.6927, whose round trip through USD lost 393,216 wei.
  const need = 1_876_760n * 10n ** 15n;
  const r = plan(round({ needs: new Map([[XRP.copy, need]]), prices: new Map([["XRP", 0.6927]]) }));
  assert.deepEqual(kinds(r), ["buy"]);
  assert.equal(r.actions[0].amountOut, need + need / 10n, "the need and its 10%, to the wei");
});

test("RS-3: coins at home that cover the need are brought in, and the buffer's last wei starts no buy", () => {
  const need = 1_000n * E18;
  const want = need + need / 10n;
  const atHome = want - 1_000n; // a buy that landed 1,000 wei short
  const r = plan(round({ needs: new Map([[XRP.copy, need]]), home: { ...round().home, coins: new Map([["XRP", atHome]]) } }));
  assert.deepEqual(kinds(r), ["bridgeIn"], "no RESTOCK_MIN_USD buy for 1,000 wei, which the next round would sell");
  assert.equal(r.actions[0].amount, bridgeable(atHome, 18));

  // The need covered at home but not its buffer, the rest worth RESTOCK_MIN_USD or more: the buffer is still bought.
  const exact = plan(round({ needs: new Map([[XRP.copy, need]]), home: { ...round().home, coins: new Map([["XRP", need]]) } }));
  assert.deepEqual(kinds(exact), ["bridgeIn", "buy"]);
  assert.equal(exact.actions[1].amountOut, 100n * E18, "the other 100 XRP, $200");
});

test("RS-4: a sweep in the same round as a buy counts the float the buy may spend", () => {
  const sui = coinsOf(["SUI"]);
  const at = (float) =>
    plan(
      round({
        coins: sui,
        needs: new Map([[sui[0].copy, 1_000n * 10n ** 9n]]),
        prices: new Map([["SUI", 3]]),
        home: { coins: new Map(), floats: new Map([["sui", usdc(float)]]), gas: new Map([["sui", 10n ** 9n]]), funding: new Map() },
      }),
    );
  const r = at(12_000);
  assert.deepEqual(kinds(r), ["buy"], "12,000 less the buy's 3,333 is below twice the 5,000 target: nothing goes back");
  const more = at(20_000);
  assert.deepEqual(kinds(more), ["buy", "sweep"]);
  assert.equal(more.actions[1].amount, usdc(20_000 - 3_333 - 5_000), "what the buy leaves, down to the target");
});

const floats50k = { ...round().home, floats: new Map([["bsc", usdt(50_000)]]) };

test("RS-7: a buy larger than what is left of the day's budget is cut to it, not skipped", () => {
  const cfg = { ...CFG, dailyUsd: 20_000, maxTransferUsd: 25_000 }; // the defaults: a day's budget below one transfer
  const big = plan(round({ cfg, needs: new Map([[XRP.copy, 15_000n * E18]]), home: floats50k }));
  assert.deepEqual(kinds(big), ["buy"]);
  assert.equal(big.actions[0].amountOut, 10_000n * E18, "$20,000 of the $33,000 short: the day's whole budget");
  const late = plan(round({ cfg, needs: new Map([[XRP.copy, 4_000n * E18]]), spentUsd: 15_000, home: floats50k }));
  assert.equal(late.actions[0].amountOut, 2_500n * E18, "the $5,000 left of it");
  const spent = plan(round({ cfg, needs: new Map([[XRP.copy, 4_000n * E18]]), spentUsd: 19_950, home: floats50k }));
  assert.deepEqual(kinds(spent), [], "$50 left is below RESTOCK_MIN_USD");
  assert.match(spent.notes.join("\n"), /past RESTOCK_DAILY_USD/);
});

test("RS-8: with the keeper's needs unknown, no coin is bought, sold or bridged out", () => {
  const stock = new Map([[XRP.copy, { balance: 5_000n * E18, allowance: 5_000n * E18 }]]);
  const r = plan(round({ needs: null, stock, home: { ...round().home, coins: new Map([["XRP", 300n * E18]]) } }));
  assert.deepEqual(kinds(r), [], "neither the 300 at home sold nor the stock beyond the keep bridged out");
  assert.match(r.notes.join("\n"), /missing, unreadable or stale/);
});

test("RS-9: spare stock is what the executor holds beyond the need and the keep, not what is on its way", () => {
  const held = (n) => new Map([[XRP.copy, { balance: n * E18, allowance: n * E18 }]]);
  const coming = new Map([[XRP.copy, { in: 1_100n * E18, out: 0n }]]);
  const gone = plan(round({ stock: held(600n), inflight: coming }));
  assert.deepEqual(kinds(gone), ["bridgeOut"]);
  assert.equal(gone.actions[0].amount, 350n * E18, "the need gone: 600 held less the 250 kept, not all 600");
  const met = plan(round({ needs: new Map([[XRP.copy, 1_000n * E18]]), stock: held(1_000n), inflight: coming }));
  assert.deepEqual(kinds(met), [], "the need met by what is held: nothing leaves before what is coming lands");
});

test("RS-10: coins at home top a covered coin up to its buffer before any is sold", () => {
  const needs = new Map([[XRP.copy, 1_000n * E18]]);
  const stock = new Map([[XRP.copy, { balance: 1_000n * E18, allowance: 1_000n * E18 }]]);
  const at = (n) => plan(round({ needs, stock, home: { ...round().home, coins: new Map([["XRP", n * E18]]) } }));
  const r = at(300n);
  assert.deepEqual(kinds(r), ["bridgeIn", "sell"]);
  assert.equal(r.actions[0].amount, 100n * E18, "the buffer's 100 brought in");
  assert.equal(r.actions[1].amount, 200n * E18, "and only the other 200 sold");
  assert.deepEqual(kinds(at(20n)), [], "20 within the buffer, worth less than RESTOCK_MIN_USD to move, stay home");
  const home300 = { ...round().home, coins: new Map([["XRP", 300n * E18]]) };
  const spent = plan(round({ needs, stock, restockAllowance: new Map([[XRP.copy, 0n]]), home: home300 }));
  assert.deepEqual(kinds(spent), ["sell"], "the restock allowance spent: none brought in to earn nothing, all sold");
});

test("RS-11: a sweep is cut to RESTOCK_MAX_TRANSFER_USD, the rest following in later rounds", () => {
  const sui = coinsOf(["SUI"]);
  const r = plan(
    round({
      coins: sui,
      prices: new Map([["SUI", 3]]),
      home: { coins: new Map(), floats: new Map([["sui", usdc(100_000)]]), gas: new Map([["sui", 10n ** 9n]]), funding: new Map() },
    }),
  );
  assert.deepEqual(kinds(r), ["sweep"]);
  assert.equal(r.actions[0].amount, usdc(20_000), "not the 95,000 above the target in one transfer");
});
