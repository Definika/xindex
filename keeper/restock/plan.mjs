// What the restock service does next, decided from what it can see: the needs the keeper reported, the executor's
// stock, what is crossing a bridge, the home wallets' balances, the treasury's USDC and Pyth's prices. A pure function,
// recomputed every round from fresh readings, so a round that fails or a restart loses nothing: whatever was done
// shows in the next round's balances, and whatever is in flight in the journal. No dependencies.

import { CHAINS } from "./coins.mjs";

/// The bridge carries eight decimals; below them an amount stays with its sender.
export function bridgeable(amount, decimals) {
  if (decimals <= 8) return amount;
  const unit = 10n ** BigInt(decimals - 8);
  return amount - (amount % unit);
}

const usdOf = (units, decimals, price) => (Number(units) / 10 ** decimals) * price;
const unitsOf = (usd, decimals, price) => BigInt(Math.floor((usd / price) * 10 ** decimals));
const withBps = (x, bps) => x + (x * BigInt(bps)) / 10_000n;

/// The round's actions, in the order to run them, and a note for every coin or chain left alone and why.
///
/// - `coins`: the coins served (`coins.mjs`).
/// - `needs`: Map of copy address (lowercased) to the whole of it the keeper's fills need (`needs.mjs`), or null when
///   the keeper's board is missing, unreadable or stale: then no coin is bought, sold or bridged (RS-8).
/// - `stock`: Map of copy address to `{balance, allowance}` in the executor.
/// - `inflight`: Map of copy address to `{in, out}`, amounts crossing the bridge now (the journal's).
/// - `home`: `{coins: Map symbol -> balance in the home wallet, the gas reserve left out; floats: Map chain -> the
///   float's balance; gas: Map chain -> the gas coin's balance; funding: Map chain -> float on its way there}`.
/// - `treasury`: `{usdc, allowance}`: the treasury's USDC on Ethereum and what it may still draw from the executor.
/// - `prices`: Map symbol -> USD, from Pyth; a coin without one is left alone.
/// - `spentUsd`: what buys cost over the last day.
/// - `restockAllowance`: Map of copy address to how much more of it arriving through the bridge may earn stock
///   allowance (the executor's `restockAllowance`, which only its owner sets, RS-1); a coin missing from it has none.
/// - `busy`: Set of coin symbols, chains and "treasury" with a move of the journal's still to settle, left alone until
///   it does, so no round acts twice on the same balance.
/// - `cfg`: `{bufferBps, minUsd, dailyUsd, keepUsd, maxTransferUsd, floatTargetUsd, treasuryTargetUsd, maxLossBps,
///   gasMin: Map chain -> units}`.
export function plan({ coins, needs, stock, inflight, home, treasury, prices, spentUsd, restockAllowance = new Map(), busy = new Set(), cfg }) {
  const actions = [];
  const notes = [];
  const float = new Map(home.floats);
  const fundWanted = new Map(); // chain -> float to send there
  let budget = cfg.dailyUsd - spentUsd;

  const active = [...new Set(coins.map((c) => c.chain))];
  const noGas = new Set();
  for (const chain of active) {
    if ((home.gas.get(chain) ?? 0n) < (cfg.gasMin.get(chain) ?? 0n)) {
      noGas.add(chain);
      notes.push(`${chain}: gas below its minimum: top up ${CHAINS[chain].gas.symbol}`);
    }
  }

  // Needs that are unknown are not none: with the keeper down, every coin would look spare and go home (RS-8).
  if (needs === null) {
    notes.push("needs: the keeper's NEEDS_FILE is missing, unreadable or stale: no coin is bought, sold or bridged until it writes it again");
  }
  for (const c of needs === null ? [] : coins) {
    if (busy.has(c.symbol)) continue;
    const price = prices.get(c.symbol);
    if (!price) {
      notes.push(`${c.symbol}: no Pyth price, left alone`);
      continue;
    }
    const need = needs.get(c.copy) ?? 0n;
    const { balance = 0n, allowance = 0n } = stock.get(c.copy) ?? {};
    const usable = balance < allowance ? balance : allowance;
    const coming = inflight.get(c.copy)?.in ?? 0n;
    const going = inflight.get(c.copy)?.out ?? 0n;
    // What arrives earns stock allowance only within the owner's restock allowance (RS-1): the transfers on their way
    // count only as far as it goes, and nothing is brought in or bought beyond what is left of it.
    const room = restockAllowance.get(c.copy) ?? 0n;
    const credited = coming < room ? coming : room;
    const open = room - credited;
    const atHome = home.coins.get(c.symbol) ?? 0n;
    const want = need === 0n ? 0n : withBps(need, cfg.bufferBps);
    const blocked = noGas.has(c.chain);

    if (usable + credited < need) {
      const short = want - usable - credited;
      if (open === 0n) {
        notes.push(
          `${c.symbol}: short ${usdOf(short, c.decimals, price).toFixed(0)} USD, but its restock allowance on the executor is spent: the owner must call setRestockAllowance(${c.copy}, <amount>)`,
        );
        continue;
      }
      // Short: bring in what the home wallet holds, then buy the rest, up to the need and its buffer, so a need that
      // grows a little before the coins land does not start another round of buys.
      const gap = short < open ? short : open;
      const fromHome = atHome < gap ? atHome : gap;
      const bring = bridgeable(fromHome, c.decimals);
      if (bring > 0n && !blocked) {
        const capped = bridgeable(capUnits(bring, c, price, cfg.maxTransferUsd), c.decimals);
        actions.push({ kind: "bridgeIn", coin: c.symbol, copy: c.copy, chain: c.chain, amount: capped, usd: usdOf(capped, c.decimals, price) });
      }
      const rest = gap - fromHome;
      if (rest <= 0n) continue;
      // The buy, counted in the coin's units so that it lands on what is missing to the wei (RS-3): at least
      // RESTOCK_MIN_USD of the coin, so fees do not eat a small one, unless the home wallet's coins already cover the
      // need, when what only the buffer still lacks waits; at most RESTOCK_MAX_TRANSFER_USD, the restock allowance and
      // what is left of the day's budget, to which a larger one is cut rather than dropped (RS-7).
      const minUnits = unitsOf(cfg.minUsd, c.decimals, price);
      if (rest < minUnits && usable + credited + fromHome >= need) continue;
      const roomLeft = open - fromHome;
      if (roomLeft < minUnits) {
        notes.push(
          `${c.symbol}: its restock allowance on the executor has ${usdOf(roomLeft, c.decimals, price).toFixed(0)} USD left, below RESTOCK_MIN_USD: the owner must raise it with setRestockAllowance(${c.copy}, <amount>)`,
        );
        continue;
      }
      const budgetLeft = budget > 0 ? unitsOf(budget, c.decimals, price) : 0n;
      if (budgetLeft < minUnits) {
        notes.push(`${c.symbol}: short ${usdOf(rest, c.decimals, price).toFixed(0)} USD, past RESTOCK_DAILY_USD for the day`);
        continue;
      }
      let amountOut = capUnits(rest > minUnits ? rest : minUnits, c, price, cfg.maxTransferUsd);
      if (amountOut > roomLeft) amountOut = roomLeft;
      if (amountOut > budgetLeft) amountOut = budgetLeft;
      const usd = usdOf(amountOut, c.decimals, price);
      if (blocked) continue;
      // `usd` of the coin, at most `maxIn` of the float for it: an exact-output venue buys `amountOut` for at most
      // `maxIn`, an exact-input one spends `amountIn` for at least `minOut`; either way within the loss bound at Pyth.
      const fl = CHAINS[c.chain].float;
      const amountIn = unitsOf(usd, fl.decimals, 1);
      const maxIn = withBps(amountIn, cfg.maxLossBps);
      const have = float.get(c.chain) ?? 0n;
      if (have < maxIn) {
        fundWanted.set(c.chain, (fundWanted.get(c.chain) ?? 0n) + maxIn - have);
        float.set(c.chain, 0n);
        notes.push(`${c.symbol}: waiting for ${fl.symbol} on ${c.chain}`);
        continue;
      }
      float.set(c.chain, have - maxIn);
      budget -= usd;
      const minOut = unitsOf(usd * (1 - cfg.maxLossBps / 10_000), c.decimals, price);
      actions.push({ kind: "buy", coin: c.symbol, copy: c.copy, chain: c.chain, usd, amountIn, maxIn, amountOut, minOut });
      continue;
    }

    // Covered: the coins at home first bring the stock up to the need and its buffer, as far as the restock allowance
    // goes and when worth RESTOCK_MIN_USD, so a need that grows a little finds them there; only the rest is sold (RS-10).
    const lacking = want > usable + credited ? want - usable - credited : 0n;
    let topUp = lacking < open ? lacking : open;
    if (topUp > atHome) topUp = atHome;
    const bringTop = bridgeable(capUnits(topUp, c, price, cfg.maxTransferUsd), c.decimals);
    if (bringTop > 0n && !blocked && usdOf(bringTop, c.decimals, price) >= cfg.minUsd) {
      actions.push({ kind: "bridgeIn", coin: c.symbol, copy: c.copy, chain: c.chain, amount: bringTop, usd: usdOf(bringTop, c.decimals, price) });
    }
    const surplus = atHome - topUp;
    if (surplus > 0n && !blocked && usdOf(surplus, c.decimals, price) >= cfg.minUsd) {
      const amount = capUnits(surplus, c, price, cfg.maxTransferUsd);
      actions.push({ kind: "sell", coin: c.symbol, copy: c.copy, chain: c.chain, amount, minOut: unitsOf(usdOf(amount, c.decimals, price) * (1 - cfg.maxLossBps / 10_000), CHAINS[c.chain].float.decimals, 1) });
    }
    // Executor stock beyond what the needs want and the keep goes home: what it holds now, not what is on its way,
    // which goes home in its turn once it lands, if still spare (RS-9).
    const spare = balance > want ? balance - want : 0n;
    const keep = unitsOf(cfg.keepUsd, c.decimals, price);
    if (going === 0n && spare > keep && usdOf(spare - keep, c.decimals, price) >= cfg.minUsd) {
      const amount = bridgeable(capUnits(spare - keep, c, price, cfg.maxTransferUsd), c.decimals);
      if (amount > 0n) actions.push({ kind: "bridgeOut", coin: c.symbol, copy: c.copy, chain: c.chain, amount, usd: usdOf(amount, c.decimals, price) });
    }
  }

  // Floats: send what the buys wait for where CCTP runs, flag the rest, and bring back what sits idle.
  let fundTotal = 0n;
  for (const chain of active) {
    const ch = CHAINS[chain];
    if (busy.has(chain)) continue;
    const wanted = fundWanted.get(chain) ?? 0n;
    const onItsWay = home.funding?.get(chain) ?? 0n;
    if (wanted > 0n) {
      if (ch.cctpDomain === null) {
        notes.push(`${chain}: top up its ${ch.float.symbol} float by hand (no CCTP)`);
      } else if (busy.has("treasury")) {
        notes.push(`${chain}: funding waits for the treasury's move to settle`);
      } else if (noGas.has(chain)) {
        notes.push(`${chain}: no float sent while it has no gas to receive it`);
      } else if (onItsWay === 0n) {
        // CCTP moves USDC in six decimals; top up to the target on top of what the buys wait for.
        const amount = toUsdc(wanted, ch.float.decimals) + BigInt(Math.round(cfg.floatTargetUsd * 1e6));
        const capped = amount < BigInt(Math.round(cfg.maxTransferUsd * 1e6)) ? amount : BigInt(Math.round(cfg.maxTransferUsd * 1e6));
        actions.push({ kind: "fund", chain, amount: capped });
        fundTotal += capped;
      }
      continue;
    }
    // Above twice the target, the float goes back down to the target: what the round's buys leave of it, since they
    // run first (RS-4), at most RESTOCK_MAX_TRANSFER_USD at a time (RS-11).
    const held = float.get(chain) ?? 0n;
    const targetUnits = unitsOf(cfg.floatTargetUsd, ch.float.decimals, 1);
    if (ch.cctpDomain !== null && !noGas.has(chain) && held > 2n * targetUnits && usdOf(held - targetUnits, ch.float.decimals, 1) >= cfg.minUsd) {
      const most = unitsOf(cfg.maxTransferUsd, ch.float.decimals, 1);
      actions.push({ kind: "sweep", chain, amount: held - targetUnits < most ? held - targetUnits : most });
    }
  }

  // The treasury: draw from the executor what the funding needs, and repay what it holds beyond its target.
  const target = BigInt(Math.round(cfg.treasuryTargetUsd * 1e6));
  if (busy.has("treasury")) return { actions, notes };
  if (fundTotal > treasury.usdc) {
    const short = fundTotal - treasury.usdc;
    if (short > treasury.allowance) notes.push("treasury: its USDC allowance on the executor is too small for the funding");
    else actions.unshift({ kind: "draw", amount: short });
  } else if (fundTotal === 0n && treasury.usdc > target + target) {
    actions.push({ kind: "repay", amount: treasury.usdc - target });
  }
  return { actions, notes };
}

/// `amount` of coin `c`, cut to at most `maxUsd` at `price`.
function capUnits(amount, c, price, maxUsd) {
  const cap = unitsOf(maxUsd, c.decimals, price);
  return amount < cap ? amount : cap;
}

/// A float amount in six-decimal USDC, rounded up.
function toUsdc(amount, decimals) {
  if (decimals === 6) return amount;
  if (decimals > 6) {
    const unit = 10n ** BigInt(decimals - 6);
    return (amount + unit - 1n) / unit;
  }
  return amount * 10n ** BigInt(6 - decimals);
}
