"""Weight-floor and staging figures for the v4 design (section 2), from the 29 Sep 2026 snapshot.

Run from anywhere: `python3 design/analysis/floor.py`. Needs numpy. Reads data/ (CoinPaprika tickers and DefiLlama daily
prices, see the design's appendix) through backtest.py, which builds the benchmark: the top 100 by market cap without
stablecoins, gold and wrapped or staked copies, and its one-year daily return series with supplies held constant.
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
os.chdir(os.path.join(HERE, "data"))
exec(open(os.path.join(HERE, "backtest.py")).read().split("print(f\"\\nbenchmark")[0])

# Script-only chains: out of scope (Bitcoin enters as WBTC and is re-added below).
T3 = {'btc-bitcoin', 'xrp-xrp', 'zec-zcash', 'doge-dogecoin', 'xmr-monero', 'bch-bitcoin-cash', 'ltc-litecoin',
      'kas-kaspa', 'dash-dash'}
# Assets whose home or custody could not be classified on 29 Sep 2026.
UNK = {'rain-rain-protocol', 'cc-canton-network', 'pi2-pi-network', 'agix-singularitynet'}
# Tier 1: native to Ethereum.
T1 = {'eth-ethereum', 'link-chainlink', 'uni-uniswap', 'aave-new', 'sky-sky', 'shib-shiba-inu', 'pepe-pepe',
      'leo-leo-token', 'wbt-whitebit', 'qnt-quant', 'ena-ethena', 'okb-okb', 'ondo-ondo', 'wld-worldcoin',
      'wlfi-official-world-liberty-financial', 'arb-arbitrum', 'pol-polygon-ecosystem-token', 'gt-gatechain-token',
      'bgb-bitget-token', 'kcs-kucoin-token', 'ethfi-etherfi', 'mnt-mantle', 'btw-bitway', 'lit-lighter'}
# Tier 2: the chain whose vault would hold each coin.
CHAIN = {'bnb-binance-coin': 'BNB Chain', 'cake-pancakeswap': 'BNB Chain', 'aster-aster': 'BNB Chain',
         'sol-solana': 'Solana', 'jup-jupiter-exchange-token': 'Solana', 'pump-pumpfun': 'Solana',
         'rndr-render-token': 'Solana', 'trx-tron': 'Tron', 'jst-just': 'Tron', 'hype-hyperliquid': 'HyperEVM',
         'ada-cardano': 'Cardano', 'xlm-stellar': 'Stellar', 'near-near-protocol': 'NEAR',
         'hbar-hedera-hashgraph': 'Hedera', 'avax-avalanche': 'Avalanche', 'sui-sui': 'Sui',
         'toncoin-the-open-network': 'TON', 'cro-cryptocom-chain': 'Cronos', 'tao-bittensor': 'Bittensor',
         'm-memecore': 'MemeCore', 'icp-internet-computer': 'ICP', 'etc-ethereum-classic': 'Ethereum Classic',
         'vvv-venice-token': 'Base', 'aero-aerodrome-finance': 'Base', 'algo-algorand': 'Algorand',
         'fil-filecoin': 'Filecoin', 'vet-vechain': 'VeChain', 'inj-injective-protocol': 'Injective',
         'apt-aptos': 'Aptos'}
STAGE_B = ['bnb-binance-coin', 'sol-solana', 'trx-tron', 'hype-hyperliquid']
SCREEN = 0.001  # listing policy: daily volume at least 0.1% of market cap
WBTC_VOLUME = 201e6  # WBTC's own 24h volume on 29 Sep 2026 (Ethereum DEXs and CEXs), design section 9.3

cap = lambda i: tick[i]['quotes']['USD']['market_cap']
vol = lambda i: tick[i]['quotes']['USD']['volume_24h']
universe = [i for i in ids if i not in T3 | UNK] + ['btc-bitcoin']
total = sum(cap(i) for i in universe)


def te(sel):
    d = cw(sel) - rB
    return d.std(ddof=1) * 365 ** 0.5


def row(name, sel):
    s = sum(cap(i) for i in sel)
    vault = sum(cap(i) for i in sel if i in CHAIN) / s
    bnb = cap('bnb-binance-coin') / s if 'bnb-binance-coin' in sel else 0.0
    print(f"  {name:<26} {len(sel):>2} tokens  coverage {s / M:5.1%}  tracking error {te(sel):4.1%}/yr  "
          f"WBTC {cap('btc-bitcoin') / s:5.1%}  vault share {vault:5.1%}  BNB {bnb:4.2%}")


print("\nWeight floors (share of the holdable universe):")
for floor in (0.0, 0.001, 0.002, 0.005):
    sel = [i for i in universe if cap(i) / total >= floor]
    chains = sorted({CHAIN[i] for i in sel if i in CHAIN})
    print(f"  floor {floor:.1%}: {len(sel):>2} tokens, coverage {sum(cap(i) for i in sel) / M:5.1%}, "
          f"tracking error {te(sel):4.1%}/yr, vault chains {len(chains)}: {', '.join(chains)}")

floor_list = [i for i in universe if cap(i) / total >= 0.002]
fs = sum(cap(i) for i in floor_list)
print("\nThe 0.2% floor list (weight in the index, rank, home, daily volume / market cap):")
for i in sorted(floor_list, key=lambda i: -cap(i)):
    flag = "  FAILS SCREEN" if vol(i) / cap(i) < SCREEN else ""
    print(f"  {i:<24} {cap(i) / fs:6.2%}  rank {tick[i]['rank']:>3}  {CHAIN.get(i, 'Ethereum'):<10} "
          f"{vol(i) / cap(i):7.3%}{flag}")

for label, lst in (("floor only", floor_list), ("floor + screen", [i for i in floor_list if vol(i) / cap(i) >= SCREEN])):
    eth = [i for i in lst if i not in CHAIN]
    b = eth + [i for i in STAGE_B if i in lst]
    print(f"\nStages, {label}:")
    row("A (Ethereum only)", eth)
    row("B (+ BNB, SOL, TRX, HYPE)", b)
    row("C (all)", lst)
    s = sum(cap(i) for i in lst)
    binding = sorted((vol(i) / cap(i), i) for i in lst if i != 'btc-bitcoin')[0]
    print(f"  capacity at 1% participation: {binding[1]} binds at ${0.01 * s * binding[0] / 1e6:,.0f}M/day; "
          f"WBTC's own volume binds at ${0.01 * WBTC_VOLUME * s / cap('btc-bitcoin') / 1e6:,.2f}M/day; "
          f"smallest coin in a $250k mint ${250e3 * min(cap(i) for i in lst) / s:,.0f}")
