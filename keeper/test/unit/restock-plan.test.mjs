import { test } from "node:test";
import assert from "node:assert/strict";
import { COINS, coinsOf } from "../../restock/coins.mjs";
import { bridgeable, plan } from "../../restock/plan.mjs";

const E18 = 10n ** 18n;
const AERO = COINS.find((c) => c.symbol === "AERO");
const AVAX = COINS.find((c) => c.symbol === "AVAX");
const usdc = (x) => BigInt(Math.round(x * 1e6));

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

/// A round with AERO at $2: no stock, no needs, the Base float at 10,000 USDC, gas everywhere.
function round(over = {}) {
  return {
    coins: [AERO],
    needs: new Map(),
    stock: new Map(),
    inflight: new Map(),
    home: { coins: new Map(), floats: new Map([["base", usdc(10_000)]]), gas: new Map([["base", E18]]), funding: new Map() },
    treasury: { usdc: 0n, allowance: 0n },
    prices: new Map([["AERO", 2]]),
    spentUsd: 0,
    restockAllowance: new Map(COINS.map((c) => [c.copy, 10n ** 30n])), // the owner's, ample unless a test says
    cfg: CFG,
    ...over,
  };
}
const kinds = (r) => r.actions.map((a) => a.kind);
/// A Base float of $50,000, for the budget's tests, and a float target that leaves it unswept: on a chain with CCTP a
/// float above twice its target is brought home, which those tests leave aside.
const floats50k = { ...round().home, floats: new Map([["base", usdc(50_000)]]) };
const RICH = { ...CFG, floatTargetUsd: 25_000 };

test("a coin the fills need, with nothing anywhere, is bought for its need and the buffer, priced at Pyth", () => {
  const r = plan(round({ needs: new Map([[AERO.copy, 1_000n * E18]]) }));
  assert.deepEqual(kinds(r), ["buy"]);
  const [buy] = r.actions;
  assert.equal(buy.coin, "AERO");
  assert.equal(buy.usd, 2_200, "1,100 AERO (the need and 10%) at $2");
  assert.equal(buy.amountIn, usdc(2_200), "exact input, in the float's 6 decimals");
  assert.equal(buy.minOut, 1_089n * E18, "at least its worth at Pyth less the 1% loss bound");
  assert.equal(buy.amountOut, 1_100n * E18, "or exact output, the coins at Pyth");
  assert.equal(buy.maxIn, usdc(2_222), "for at most their worth and the 1% bound");
});

test("usable stock and transfers already on their way count against the need", () => {
  const needs = new Map([[AERO.copy, 1_000n * E18]]);
  const stock = new Map([[AERO.copy, { balance: 900n * E18, allowance: 600n * E18 }]]);
  const inflight = new Map([[AERO.copy, { in: 400n * E18, out: 0n }]]);
  assert.deepEqual(kinds(plan(round({ needs, stock, inflight }))), [], "600 usable and 400 coming cover it: the buffer is bought only with a shortfall");
  const r = plan(round({ needs, stock: new Map([[AERO.copy, { balance: 500n * E18, allowance: 500n * E18 }]]), inflight }));
  assert.deepEqual(kinds(r), ["buy"]);
  assert.equal(r.actions[0].usd, 400, "the 200 AERO missing is $400");
});

test("RZ-20: stock held beyond its stock allowance is not bought again: the owner is asked to raise the allowance", () => {
  const needs = new Map([[AERO.copy, 800n * E18]]);
  // 1,000 AERO in the executor, 200 of them deliverable: the coins are there, the allowance is not.
  const held = plan(round({ needs, stock: new Map([[AERO.copy, { balance: 1_000n * E18, allowance: 200n * E18 }]]) }));
  assert.deepEqual(kinds(held), [], "nothing bought, brought in or sent home");
  assert.match(held.notes.join("\n"), new RegExp(`AERO: the executor holds 1600 USD of it beyond its stock allowance: the owner must raise it with setStockAllowance\\(${AERO.copy}`));
  assert.doesNotMatch(held.notes.join("\n"), /setRestockAllowance/, "not the restock allowance, which only adds coins");
  // The usual case: the coins arrived beyond the restock room, which is spent. The note named setRestockAllowance,
  // and raising it bought coins the executor already held.
  const spent = plan(
    round({ needs, stock: new Map([[AERO.copy, { balance: 1_000n * E18, allowance: 200n * E18 }]]), restockAllowance: new Map([[AERO.copy, 0n]]) }),
  );
  assert.deepEqual(kinds(spent), []);
  assert.match(spent.notes.join("\n"), /setStockAllowance/);
  assert.doesNotMatch(spent.notes.join("\n"), /short|setRestockAllowance/);

  // 300 held, 200 of them deliverable: only what the executor does not hold is bought, and the owner is told the rest.
  const part = plan(round({ needs, stock: new Map([[AERO.copy, { balance: 300n * E18, allowance: 200n * E18 }]]) }));
  assert.deepEqual(kinds(part), ["buy"]);
  assert.equal(part.actions[0].amountOut, 580n * E18, "880 wanted less the 300 held, not less the 200 deliverable");
  assert.match(part.notes.join("\n"), /AERO: the executor holds 200 USD of it beyond its stock allowance/);
});

test("RZ-21: coins at home worth less than RESTOCK_MIN_USD wait for the round's buy, to come in with its coins", () => {
  const needs = new Map([[AERO.copy, 1_000n * E18]]);
  const home = (n) => ({ ...round().home, coins: new Map([["AERO", n * E18]]) });
  // 20 AERO at home, $40: the buy of the other 1,080 lands beside them, and the next round brings all 1,100 in at once.
  const r = plan(round({ needs, home: home(20n) }));
  assert.deepEqual(kinds(r), ["buy"], "no transfer, and an Ethereum redeem, for $40 on its own");
  assert.equal(r.actions[0].amountOut, 1_080n * E18, "the buy still counts them");
  assert.match(r.notes.join("\n"), /AERO: 40 USD at home waits to come in with the coins this round buys/);
  const next = plan(round({ needs, home: home(1_100n) }));
  assert.deepEqual(kinds(next), ["bridgeIn"]);
  assert.equal(next.actions[0].amount, 1_100n * E18, "one transfer for both");

  // With nothing to buy, what the home wallet holds comes in however small: it is what the fills wait for.
  const small = plan(round({ needs: new Map([[AERO.copy, 10n * E18]]), home: home(20n) }));
  assert.deepEqual(kinds(small), ["bridgeIn"]);
  assert.equal(small.actions[0].amount, 11n * E18, "the need and its buffer, $22");
  // A buy that waits for its float does not hold them back either.
  const waiting = plan(round({ needs, home: { ...home(20n), floats: new Map([["base", 0n]]) } }));
  assert.deepEqual(kinds(waiting), ["bridgeIn"]);
});

test("a small shortfall still buys RESTOCK_MIN_USD, so fees do not eat it", () => {
  const r = plan(round({ needs: new Map([[AERO.copy, 10n * E18]]) }));
  assert.equal(r.actions[0].usd, 100);
});

test("what the home wallet bought is bridged in, not sold, while the fills still need it", () => {
  const needs = new Map([[AERO.copy, 1_000n * E18]]);
  const atHome = 1_100n * E18 + 123n; // the dust below eight decimals stays home
  const r = plan(round({ needs, home: { ...round().home, coins: new Map([["AERO", atHome]]) } }));
  assert.deepEqual(kinds(r), ["bridgeIn"]);
  assert.equal(r.actions[0].amount, 1_100n * E18);

  // Part of it at home: that part is bridged in and the rest bought.
  const part = plan(round({ needs, home: { ...round().home, coins: new Map([["AERO", 500n * E18]]) } }));
  assert.deepEqual(kinds(part), ["bridgeIn", "buy"]);
  assert.equal(part.actions[0].amount, 500n * E18);
  assert.equal(part.actions[1].usd, 1_200, "the other 600 AERO");
});

test("once covered, the home wallet's coins are sold and the executor's spare stock beyond the keep goes home", () => {
  const stock = new Map([[AERO.copy, { balance: 5_000n * E18, allowance: 0n }]]);
  const r = plan(round({ stock, home: { ...round().home, coins: new Map([["AERO", 300n * E18]]) } }));
  assert.deepEqual(kinds(r), ["sell", "bridgeOut"]);
  assert.equal(r.actions[0].amount, 300n * E18);
  assert.equal(r.actions[0].minOut, usdc(594), "$600 less the 1% bound, in USDC");
  assert.equal(r.actions[1].amount, 4_750n * E18, "all but the $500 keep");

  const going = new Map([[AERO.copy, { in: 0n, out: 1n }]]);
  assert.deepEqual(kinds(plan(round({ stock, inflight: going }))), [], "never a second bridge out while one is on its way");
});

test("transfers and buys are cut to RESTOCK_MAX_TRANSFER_USD, and buys to what is left of the day's budget", () => {
  const needs = new Map([[AERO.copy, 100_000n * E18]]);
  const cfg = RICH;
  const r = plan(round({ cfg, needs, home: floats50k }));
  assert.equal(r.actions[0].usd, 20_000);
  const spent = plan(round({ cfg, needs, spentUsd: 45_000, home: floats50k }));
  assert.deepEqual(kinds(spent), ["buy"]);
  assert.ok(Math.abs(spent.actions[0].maxUsd - 5_000) < 1e-6, "the $5,000 left of the day, not nothing (RS-7)");
  assert.ok(Math.abs(spent.actions[0].usd - 5_000 / 1.01) < 1e-6, "which is the most the buy may cost, loss bound included (CA-M13)");
});

test("a buy short of float waits: CCTP funds it, drawn from the executor", () => {
  const avax = round({
    coins: [AVAX],
    needs: new Map([[AVAX.copy, 1_000n * E18]]),
    prices: new Map([["AVAX", 3]]),
    home: { coins: new Map(), floats: new Map([["avalanche", usdc(100)]]), gas: new Map([["avalanche", E18]]), funding: new Map() },
    treasury: { usdc: usdc(1_000), allowance: usdc(100_000) },
  });
  const r = plan(avax);
  assert.deepEqual(kinds(r), ["draw", "fund"]);
  assert.equal(r.actions[1].amount, usdc(3_333 - 100 + 5_000), "what the buy lacks with its 1% bound, and the float's target on top");
  assert.equal(r.actions[0].amount, r.actions[1].amount - usdc(1_000), "the treasury draws only what it lacks");

  const onItsWay = plan({ ...avax, home: { ...avax.home, funding: new Map([["avalanche", 1n]]) } });
  assert.deepEqual(kinds(onItsWay), [], "not twice while a funding is on its way");

  const small = plan({ ...avax, treasury: { usdc: 0n, allowance: usdc(10) } });
  assert.deepEqual(kinds(small), [], "no funding is planned that nothing could pay");
  assert.match(small.notes.join("\n"), /avalanche: the treasury's USDC and its allowance on the executor are too small/);
});

test("CA-R2-10: what a buy waits for is funded first, and the float's target with what the treasury has left", () => {
  // A buy worth $200 waits for float; the treasury holds nothing and may draw $1,000. The float's $5,000 target is
  // out of reach, and the buy is not: planned as one sum of $5,202, the funding had no draw and never ran.
  const avax = (treasury, floatUsd = 0) =>
    plan(
      round({
        coins: [AVAX],
        needs: new Map([[AVAX.copy, 60n * E18]]),
        prices: new Map([["AVAX", 3]]),
        cfg: { ...CFG, bufferBps: 0, minUsd: 100 },
        home: { coins: new Map(), floats: new Map([["avalanche", usdc(floatUsd)]]), gas: new Map([["avalanche", E18]]), funding: new Map() },
        treasury,
      }),
    );
  const short = avax({ usdc: 0n, allowance: usdc(1_000) });
  assert.deepEqual(kinds(short), ["draw", "fund"]);
  assert.equal(short.actions[1].amount, usdc(1_000), "all the treasury can send: the buy's $181.80 and what is left toward the target");
  assert.equal(short.actions[0].amount, usdc(1_000), "drawn in full, within the allowance");

  const exact = avax({ usdc: usdc(100), allowance: usdc(81.8) });
  assert.deepEqual(kinds(exact), ["draw", "fund"]);
  assert.equal(exact.actions[1].amount, usdc(181.8), "exactly what the buy waits for, and nothing for the target");
  assert.equal(exact.actions[0].amount, usdc(81.8), "the treasury's own USDC first");

  const under = avax({ usdc: usdc(100), allowance: usdc(81.7) });
  assert.deepEqual(kinds(under), [], "a cent short of the buy, nothing is sent: part of it would start no buy");

  const ample = avax({ usdc: usdc(50_000), allowance: 0n });
  assert.deepEqual(kinds(ample), ["fund"]);
  assert.equal(ample.actions[0].amount, usdc(5_181.8), "with the means, the buy and the whole target");
});

test("CA-R2-09: spare stock is not sent to a chain whose wallet is short of gas", () => {
  const cfg = { ...CFG, gasMin: new Map([["base", E18]]) };
  const stock = new Map([[AERO.copy, { balance: 5_000n * E18, allowance: 0n }]]);
  const dry = plan(round({ cfg, stock, home: { ...round().home, gas: new Map([["base", E18 - 1n]]) } }));
  assert.deepEqual(kinds(dry), [], "it could not be redeemed there, and would wait at the bridge");
  assert.match(dry.notes.join("\n"), /base: gas below its minimum/);
  const funded = plan(round({ cfg, stock, home: { ...round().home, gas: new Map([["base", E18]]) } }));
  assert.deepEqual(kinds(funded), ["bridgeOut"], "at the reserve it goes");
});

test("CA-M13: a day of buys may cost RESTOCK_DAILY_USD at most, each one's loss bound included", () => {
  const cfg = { ...RICH, dailyUsd: 20_000, maxTransferUsd: 25_000 };
  const first = plan(round({ cfg, needs: new Map([[AERO.copy, 15_000n * E18]]), home: floats50k }));
  const [buy] = first.actions;
  // In the float's raw units: the planner rounds the bound down, so it takes all of the day but one raw unit at most.
  assert.ok(buy.maxIn <= usdc(20_000), `the most the swap may spend, ${buy.maxIn}, is inside the day's budget`);
  assert.ok(buy.maxIn >= usdc(20_000) - 1n, "and takes all of it");
  assert.ok(Math.abs(buy.maxUsd - 20_000) < 1e-6 && buy.usd < 19_802, "it buys what $20,000 can pay for at the 1% bound");
  // The journal sums what each buy may have cost, so the day is then spent.
  const next = plan(round({ cfg, needs: new Map([[AERO.copy, 15_000n * E18]]), spentUsd: buy.maxUsd, home: floats50k }));
  assert.deepEqual(kinds(next), []);
  assert.match(next.notes.join("\n"), /past RESTOCK_DAILY_USD/);
});

test("a chain without gas is left alone and flagged, a coin without a price too", () => {
  const cfg = { ...CFG, gasMin: new Map([["base", E18]]) };
  const r = plan(round({ cfg, needs: new Map([[AERO.copy, 1_000n * E18]]), home: { ...round().home, gas: new Map([["base", 1n]]) } }));
  assert.deepEqual(kinds(r), []);
  assert.match(r.notes.join("\n"), /base: gas below its minimum: top up ETH/);
  const unpriced = plan(round({ needs: new Map([[AERO.copy, 1n]]), prices: new Map() }));
  assert.deepEqual(kinds(unpriced), []);
  assert.match(unpriced.notes.join("\n"), /AERO: no Pyth price/);
});

test("idle float above twice its target comes home to the treasury, and the treasury repays beyond twice its own", () => {
  const avaxChain = coinsOf(["AVAX"]);
  const r = plan(
    round({
      coins: avaxChain,
      prices: new Map([["AVAX", 3]]),
      home: { coins: new Map(), floats: new Map([["avalanche", usdc(12_000)]]), gas: new Map([["avalanche", E18]]), funding: new Map() },
      treasury: { usdc: usdc(25_000), allowance: 0n },
    }),
  );
  assert.deepEqual(kinds(r), ["sweep", "repay"]);
  assert.equal(r.actions[0].amount, usdc(7_000), "down to the 5,000 target");
  assert.equal(r.actions[1].amount, usdc(15_000), "down to the 10,000 target");
});

test("the bridge carries eight decimals", () => {
  assert.equal(bridgeable(123_456_789_012_345_678n, 18), 123_456_780_000_000_000n);
  assert.equal(bridgeable(123_456_789n, 9), 123_456_780n);
  assert.equal(bridgeable(123_456_789n, 8), 123_456_789n);
  assert.equal(bridgeable(123_456n, 6), 123_456n);
});

test("a coin, chain or treasury with a move still to settle is left alone", () => {
  const needs = new Map([[AERO.copy, 1_000n * E18]]);
  assert.deepEqual(kinds(plan(round({ needs, busy: new Set(["AERO"]) }))), []);
  const avax = {
    coins: [AVAX],
    needs: new Map([[AVAX.copy, 1_000n * E18]]),
    prices: new Map([["AVAX", 3]]),
    home: { coins: new Map(), floats: new Map(), gas: new Map([["avalanche", E18]]), funding: new Map() },
    treasury: { usdc: 0n, allowance: usdc(100_000) },
  };
  assert.deepEqual(kinds(plan(round({ ...avax, busy: new Set(["avalanche"]) }))), []);
  assert.deepEqual(kinds(plan(round({ ...avax, busy: new Set(["treasury"]) }))), [], "funded once the treasury's draw lands");
});

test("RS-1: a coin short of stock is brought in and bought only within what its restock allowance has left", () => {
  const r = plan(
    round({
      needs: new Map([[AERO.copy, 1_000n * E18]]),
      restockAllowance: new Map([[AERO.copy, 400n * E18]]),
      home: { ...round().home, coins: new Map([["AERO", 150n * E18]]) },
    }),
  );
  assert.deepEqual(kinds(r), ["bridgeIn", "buy"]);
  assert.equal(r.actions[0].amount, 150n * E18, "what the home wallet holds comes in first");
  assert.equal(r.actions[1].amountOut, 250n * E18, "and the buy stops at what the allowance has left");
});

test("RS-1: a coin whose restock allowance is spent is neither bought nor brought in, and the owner's call is named", () => {
  const r = plan(
    round({
      needs: new Map([[AERO.copy, 1_000n * E18]]),
      restockAllowance: new Map([[AERO.copy, 0n]]),
      home: { ...round().home, coins: new Map([["AERO", 150n * E18]]) },
    }),
  );
  assert.deepEqual(kinds(r), []);
  assert.match(r.notes.join("\n"), new RegExp(`AERO: short .*restock allowance.*setRestockAllowance\\(${AERO.copy}`));
});

test("RS-1: transfers on their way count only as far as the restock allowance goes", () => {
  // 1,000 AERO on their way, but only 300 of them can earn allowance: the need of 500 is not covered.
  const r = plan(
    round({
      needs: new Map([[AERO.copy, 500n * E18]]),
      inflight: new Map([[AERO.copy, { in: 1_000n * E18, out: 0n }]]),
      restockAllowance: new Map([[AERO.copy, 300n * E18]]),
    }),
  );
  assert.deepEqual(kinds(r), []);
  assert.match(r.notes.join("\n"), /AERO: short .*restock allowance/);
});

test("RS-1: what the restock allowance has left below RESTOCK_MIN_USD buys nothing", () => {
  const r = plan(round({ needs: new Map([[AERO.copy, 1_000n * E18]]), restockAllowance: new Map([[AERO.copy, 10n * E18]]) }));
  assert.deepEqual(kinds(r), [], "$20 of room is below the $100 minimum");
  assert.match(r.notes.join("\n"), /AERO: .*restock allowance.*RESTOCK_MIN_USD/);
});

test("RS-1: what the home wallet holds is brought in only as far as the restock allowance goes", () => {
  const r = plan(
    round({
      needs: new Map([[AERO.copy, 1_000n * E18]]),
      restockAllowance: new Map([[AERO.copy, 100n * E18]]),
      home: { ...round().home, coins: new Map([["AERO", 150n * E18]]) },
    }),
  );
  assert.deepEqual(kinds(r), ["bridgeIn"], "no buy: the room is taken by what comes in");
  assert.equal(r.actions[0].amount, 100n * E18, "100 of the 150 at home, the rest left there");
});

test("RS-3: a buy is for exactly what the need and its buffer lack, not that amount through floating point", () => {
  // The end-to-end test's AERO: 1,876.76 at $0.6927, whose round trip through USD lost 393,216 wei.
  const need = 1_876_760n * 10n ** 15n;
  const r = plan(round({ needs: new Map([[AERO.copy, need]]), prices: new Map([["AERO", 0.6927]]) }));
  assert.deepEqual(kinds(r), ["buy"]);
  assert.equal(r.actions[0].amountOut, need + need / 10n, "the need and its 10%, to the wei");
});

test("RS-3: coins at home that cover the need are brought in, and the buffer's last wei starts no buy", () => {
  const need = 1_000n * E18;
  const want = need + need / 10n;
  const atHome = want - 1_000n; // a buy that landed 1,000 wei short
  const r = plan(round({ needs: new Map([[AERO.copy, need]]), home: { ...round().home, coins: new Map([["AERO", atHome]]) } }));
  assert.deepEqual(kinds(r), ["bridgeIn"], "no RESTOCK_MIN_USD buy for 1,000 wei, which the next round would sell");
  assert.equal(r.actions[0].amount, bridgeable(atHome, 18));

  // The need covered at home but not its buffer, the rest worth RESTOCK_MIN_USD or more: the buffer is still bought.
  const exact = plan(round({ needs: new Map([[AERO.copy, need]]), home: { ...round().home, coins: new Map([["AERO", need]]) } }));
  assert.deepEqual(kinds(exact), ["bridgeIn", "buy"]);
  assert.equal(exact.actions[1].amountOut, 100n * E18, "the other 100 AERO, $200");
});

test("RS-4: a sweep in the same round as a buy counts the float the buy may spend", () => {
  const avax = coinsOf(["AVAX"]);
  const at = (float) =>
    plan(
      round({
        coins: avax,
        needs: new Map([[avax[0].copy, 1_000n * E18]]),
        prices: new Map([["AVAX", 3]]),
        home: { coins: new Map(), floats: new Map([["avalanche", usdc(float)]]), gas: new Map([["avalanche", E18]]), funding: new Map() },
      }),
    );
  const r = at(12_000);
  assert.deepEqual(kinds(r), ["buy"], "12,000 less the buy's 3,333 is below twice the 5,000 target: nothing goes back");
  const more = at(20_000);
  assert.deepEqual(kinds(more), ["buy", "sweep"]);
  assert.equal(more.actions[1].amount, usdc(20_000 - 3_333 - 5_000), "what the buy leaves, down to the target");
});


test("RS-7: a buy larger than what is left of the day's budget is cut to it, not skipped", () => {
  const cfg = { ...RICH, dailyUsd: 20_000, maxTransferUsd: 25_000 }; // the defaults: a day's budget below one transfer
  const big = plan(round({ cfg, needs: new Map([[AERO.copy, 15_000n * E18]]), home: floats50k }));
  assert.deepEqual(kinds(big), ["buy"]);
  const coins = (action) => Number(action.amountOut) / 1e18;
  assert.ok(Math.abs(coins(big.actions[0]) - 10_000 / 1.01) < 1e-6, "of the $33,000 short, what the day's whole $20,000 may cost");
  const late = plan(round({ cfg, needs: new Map([[AERO.copy, 4_000n * E18]]), spentUsd: 15_000, home: floats50k }));
  assert.ok(Math.abs(coins(late.actions[0]) - 2_500 / 1.01) < 1e-6, "the $5,000 left of it");
  const spent = plan(round({ cfg, needs: new Map([[AERO.copy, 4_000n * E18]]), spentUsd: 19_950, home: floats50k }));
  assert.deepEqual(kinds(spent), [], "$50 left is below RESTOCK_MIN_USD");
  assert.match(spent.notes.join("\n"), /past RESTOCK_DAILY_USD/);
});

test("RS-8: with the keeper's needs unknown, no coin is bought, sold or bridged out", () => {
  const stock = new Map([[AERO.copy, { balance: 5_000n * E18, allowance: 5_000n * E18 }]]);
  const r = plan(round({ needs: null, stock, home: { ...round().home, coins: new Map([["AERO", 300n * E18]]) } }));
  assert.deepEqual(kinds(r), [], "neither the 300 at home sold nor the stock beyond the keep bridged out");
  assert.match(r.notes.join("\n"), /missing, unreadable or stale/);
});

test("RS-9: spare stock is what the executor holds beyond the need and the keep, not what is on its way", () => {
  const held = (n) => new Map([[AERO.copy, { balance: n * E18, allowance: n * E18 }]]);
  const coming = new Map([[AERO.copy, { in: 1_100n * E18, out: 0n }]]);
  const gone = plan(round({ stock: held(600n), inflight: coming }));
  assert.deepEqual(kinds(gone), ["bridgeOut"]);
  assert.equal(gone.actions[0].amount, 350n * E18, "the need gone: 600 held less the 250 kept, not all 600");
  const met = plan(round({ needs: new Map([[AERO.copy, 1_000n * E18]]), stock: held(1_000n), inflight: coming }));
  assert.deepEqual(kinds(met), [], "the need met by what is held: nothing leaves before what is coming lands");
});

test("RS-10: coins at home top a covered coin up to its buffer before any is sold", () => {
  const needs = new Map([[AERO.copy, 1_000n * E18]]);
  const stock = new Map([[AERO.copy, { balance: 1_000n * E18, allowance: 1_000n * E18 }]]);
  const at = (n) => plan(round({ needs, stock, home: { ...round().home, coins: new Map([["AERO", n * E18]]) } }));
  const r = at(300n);
  assert.deepEqual(kinds(r), ["bridgeIn", "sell"]);
  assert.equal(r.actions[0].amount, 100n * E18, "the buffer's 100 brought in");
  assert.equal(r.actions[1].amount, 200n * E18, "and only the other 200 sold");
  assert.deepEqual(kinds(at(20n)), [], "20 within the buffer, worth less than RESTOCK_MIN_USD to move, stay home");
  const home300 = { ...round().home, coins: new Map([["AERO", 300n * E18]]) };
  const spent = plan(round({ needs, stock, restockAllowance: new Map([[AERO.copy, 0n]]), home: home300 }));
  assert.deepEqual(kinds(spent), ["sell"], "the restock allowance spent: none brought in to earn nothing, all sold");
});

test("RS-11: a sweep is cut to RESTOCK_MAX_TRANSFER_USD, the rest following in later rounds", () => {
  const avax = coinsOf(["AVAX"]);
  const r = plan(
    round({
      coins: avax,
      prices: new Map([["AVAX", 3]]),
      home: { coins: new Map(), floats: new Map([["avalanche", usdc(100_000)]]), gas: new Map([["avalanche", E18]]), funding: new Map() },
    }),
  );
  assert.deepEqual(kinds(r), ["sweep"]);
  assert.equal(r.actions[0].amount, usdc(20_000), "not the 95,000 above the target in one transfer");
});

// ---------------------------------------------------------------------
// Local coins: bought through UniswapX on Ethereum and deposited
// ---------------------------------------------------------------------

/// NVDAon at $180, the treasury holding 5,000 USDC and allowed 20,000 more: no stock, no needs.
const NVDA = coinsOf(["NVDAON"])[0];
function localRound(over = {}) {
  return round({
    coins: [NVDA],
    home: { coins: new Map(), floats: new Map(), gas: new Map(), funding: new Map() },
    treasury: { usdc: usdc(5_000), allowance: usdc(20_000) },
    prices: new Map([["NVDAON", 180]]),
    restockAllowance: new Map([[NVDA.copy, 10n ** 30n]]),
    ...over,
  });
}

test("a local coin the fills need is bought through a UniswapX order of exact USDC, bounded at Pyth less the loss bound", () => {
  const r = plan(localRound({ needs: new Map([[NVDA.copy, 10n * E18]]) }));
  assert.deepEqual(kinds(r), ["order"], "no draw: the treasury's 5,000 USDC covers it");
  const [o] = r.actions;
  assert.equal(o.coin, "NVDAON");
  assert.equal(o.usd, 1_980, "11 NVDAon, the need and its buffer, at $180");
  assert.equal(o.amountIn, usdc(1_980), "exactly its worth at Pyth, in USDC");
  assert.equal(o.maxIn, o.amountIn, "an exact spend: nothing above it");
  assert.equal(o.maxUsd, 1_980, "so the day's budget is charged its worth alone");
  assert.equal(o.minOut, 1089n * 10n ** 16n, "10.89 NVDAon: its worth less 1%");
  assert.equal(o.amountOut, 11n * E18);
});

test("a local coin's order draws what the treasury lacks first, and keeps the treasury from repaying", () => {
  const r = plan(localRound({ needs: new Map([[NVDA.copy, 50n * E18]]), treasury: { usdc: usdc(1_000), allowance: usdc(20_000) } }));
  assert.deepEqual(kinds(r), ["draw", "order"], "the draw lands before the order is signed");
  assert.equal(r.actions[0].amount, usdc(9_900) - usdc(1_000), "55 NVDAon at $180, less what the treasury holds");
  const rich = plan(localRound({ needs: new Map([[NVDA.copy, 10n * E18]]), treasury: { usdc: usdc(30_000), allowance: 0n } }));
  assert.deepEqual(kinds(rich), ["order"], "no repayment of the USDC the order may take, above twice the target though it is");
  assert.equal(
    plan(localRound({ treasury: { usdc: usdc(30_000), allowance: 0n } })).actions.at(-1).kind,
    "repay",
    "with no order the surplus goes back",
  );
});

test("a local coin's order is no larger than the treasury may spend, and fundings get only what it leaves", () => {
  const r = plan(localRound({ needs: new Map([[NVDA.copy, 200n * E18]]), treasury: { usdc: 0n, allowance: usdc(1_000) } }));
  assert.deepEqual(kinds(r), [], "39,600 USD of USDC is more than the 1,000 it may draw");
  assert.match(r.notes.join("\n"), /NVDAON: the treasury's USDC and its allowance on the executor are too small for its UniswapX order/);

  // An order and a funding in one round: the funding is planned from what the order leaves.
  const both = plan(
    localRound({
      coins: [NVDA, AERO.symbol === "AERO" ? coinsOf(["AVAX"])[0] : AERO],
      needs: new Map([
        [NVDA.copy, 50n * E18],
        [coinsOf(["AVAX"])[0].copy, 100n * E18],
      ]),
      home: { coins: new Map(), floats: new Map([["avalanche", 0n]]), gas: new Map([["avalanche", E18]]), funding: new Map() },
      prices: new Map([
        ["NVDAON", 180],
        ["AVAX", 20],
      ]),
      restockAllowance: new Map([
        [NVDA.copy, 10n ** 30n],
        [coinsOf(["AVAX"])[0].copy, 10n ** 30n],
      ]),
      treasury: { usdc: 0n, allowance: usdc(10_000) },
    }),
  );
  assert.deepEqual(kinds(both), ["draw", "order"], "the order's 9,900 leaves 100 USDC, too little for AVAX's funding");
  assert.match(both.notes.join("\n"), /avalanche: the treasury's USDC and its allowance on the executor are too small/);
});

test("what the treasury holds of a local coin goes into the executor, credited within the restock allowance", () => {
  // 4 NVDAon held of a need of 10: deposited, and the order buys only what they leave short.
  const r = plan(localRound({ needs: new Map([[NVDA.copy, 10n * E18]]), home: { coins: new Map([["NVDAON", 4n * E18]]), floats: new Map(), gas: new Map(), funding: new Map() } }));
  assert.deepEqual(kinds(r), ["deposit", "order"]);
  assert.equal(r.actions[0].amount, 4n * E18, "all of it");
  assert.equal(r.actions[1].amountOut, 7n * E18, "11 wanted, 4 coming in");
  // Covered, with nothing needed: what it holds still goes in when worth RESTOCK_MIN_USD, and a sliver waits.
  const spare = plan(localRound({ home: { coins: new Map([["NVDAON", E18]]), floats: new Map(), gas: new Map(), funding: new Map() } }));
  assert.deepEqual(kinds(spare), ["deposit"], "a hot wallet is no place to keep it");
  const sliver = plan(localRound({ home: { coins: new Map([["NVDAON", E18 / 1000n]]), floats: new Map(), gas: new Map(), funding: new Map() } }));
  assert.deepEqual(kinds(sliver), [], "18 cents of it waits for the next need");
});

test("a local coin is never sold or sent away, whatever the executor holds beyond its need", () => {
  const stock = new Map([[NVDA.copy, { balance: 1_000n * E18, allowance: 1_000n * E18 }]]);
  assert.deepEqual(kinds(plan(localRound({ stock }))), [], "no bridge out, no sale: it waits in the executor");
  assert.deepEqual(kinds(plan(localRound({ stock, needs: new Map([[NVDA.copy, 10n * E18]]) }))), []);
});

test("RS-1: a local coin is bought only within what is left of its restock allowance", () => {
  const needs = new Map([[NVDA.copy, 10n * E18]]);
  const none = plan(localRound({ needs, restockAllowance: new Map([[NVDA.copy, 0n]]) }));
  assert.deepEqual(kinds(none), []);
  assert.match(none.notes.join("\n"), new RegExp(`NVDAON: short 1980 USD, but its restock allowance on the executor has 0 USD left, below RESTOCK_MIN_USD: the owner must raise it with setRestockAllowance\\(${NVDA.copy}`));
  const some = plan(localRound({ needs, restockAllowance: new Map([[NVDA.copy, 3n * E18]]) }));
  assert.deepEqual(kinds(some), ["order"]);
  assert.equal(some.actions[0].amountOut, 3n * E18, "cut to the 3 NVDAon left of it");
  const held = plan(localRound({ needs, restockAllowance: new Map([[NVDA.copy, 25n * 10n ** 17n]]), home: { coins: new Map([["NVDAON", 2n * E18]]), floats: new Map(), gas: new Map(), funding: new Map() } }));
  assert.deepEqual(kinds(held), ["deposit"], "the 2 held take 2 of the 2.5; the 90 USD left is below RESTOCK_MIN_USD");
  assert.match(held.notes.join("\n"), /has 90 USD left, below RESTOCK_MIN_USD/);
});

test("a local coin's order waits while the treasury has a move to settle, an open order among them, and keeps to the day's budget", () => {
  const needs = new Map([[NVDA.copy, 10n * E18]]);
  const busy = plan(localRound({ needs, busy: new Set(["treasury"]) }));
  assert.deepEqual(kinds(busy), []);
  assert.match(busy.notes.join("\n"), /NVDAON: its UniswapX order waits for the treasury's move to settle/);
  const held = plan(localRound({ needs, busy: new Set(["treasury"]), home: { coins: new Map([["NVDAON", 4n * E18]]), floats: new Map(), gas: new Map(), funding: new Map() } }));
  assert.deepEqual(kinds(held), ["deposit"], "a deposit is the coin's own move, not the treasury's");
  assert.deepEqual(kinds(plan(localRound({ needs, busy: new Set(["NVDAON"]) }))), [], "nor while the coin's own move settles");
  const late = plan(localRound({ needs, spentUsd: 50_000 - 50 }));
  assert.deepEqual(kinds(late), []);
  assert.match(late.notes.join("\n"), /NVDAON: short 1980 USD, past RESTOCK_DAILY_USD for the day/);
  const cut = plan(localRound({ needs, spentUsd: 50_000 - 900 }));
  assert.equal(cut.actions[0].usd, 900, "cut to the 900 USD left of the budget: an exact spend costs its worth");
});
