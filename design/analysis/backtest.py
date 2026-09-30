import json, numpy as np
tick={x['id']:x for x in json.load(open('paprika_tickers.json')) if x.get('rank',0)>0}
top=sorted(tick.values(), key=lambda x:x['rank'])[:100]
hist=json.load(open('hist.json'))
STABLE={'usdt-tether','usdc-usd-coin','usds-usds','dai-dai','susds-susds','usd1-usd1','usde-ethena-usde','usdg-global-dollar','pyusd-paypal-usd',
 'usdf-falcon-finance','bfusd-bfusd','susde-ethena-staked-usde','usdd-usdd','syrupusdc-syrupusdc','paxg-pax-gold','xaut-tether-gold',
 'jlp-jupiter-perpetuals-liquidity-provider-token'}
DUP={'steth-lido-staked-ether','wsteth-wrapped-liquid-staked-ether-20','wbtc-wrapped-bitcoin','cbbtc-coinbase-wrapped-btc','weeth-wrapped-eeth',
 'weth-weth','eth-ethereum-token','jitosol-jito-staked-sol','reth-rocket-pool-eth','rseth-rseth','khype-kinetiq-staked-hype','wbnb-wrapped-bnb',
 'meth-meth','lbtc-lombard-staked-btc','bnsol-binance-staked-sol','lseth-liquid-staked-ethereum','jupsol-jupiter-staked-sol'}
bench=[x for x in top if x['id'] not in STABLE|DUP]
tot100=sum(x['quotes']['USD']['market_cap'] for x in top)
print(f"top-100 total ${tot100/1e9:,.0f}B; stables/gold/LP ${sum(x['quotes']['USD']['market_cap'] for x in top if x['id'] in STABLE)/1e9:,.0f}B; "
      f"duplicates ${sum(x['quotes']['USD']['market_cap'] for x in top if x['id'] in DUP)/1e9:,.0f}B; benchmark {len(bench)} assets")
# sanity: history's last price vs today's price
drop=[]
for x in bench:
    h=hist.get(x['id']) or []
    if not h: drop.append((x['id'],'no data')); continue
    r=h[-1][1]/x['quotes']['USD']['price']
    if not 0.8<r<1.25: drop.append((x['id'],f'last hist/now = {r:.2f}'))
print('dropped:', drop)
dropped={d for d,_ in drop}
B=[x for x in bench if x['id'] not in dropped]
M=sum(x['quotes']['USD']['market_cap'] for x in bench); Mb=sum(x['quotes']['USD']['market_cap'] for x in B)
print(f"benchmark mcap ${M/1e9:,.0f}B; with usable history {len(B)} assets = {Mb/M:.1%} of it")
# cumulative coverage by rank (all benchmark assets, ignoring investability)
caps=np.array(sorted([x['quotes']['USD']['market_cap'] for x in bench],reverse=True)); cum=np.cumsum(caps)/caps.sum()
for k in (1,2,5,10,20,30,50): print(f"  top {k:>2} of the benchmark cover {cum[k-1]:.1%}")
# price matrix on a daily grid
days=sorted({int(t//86400) for x in B for t,_ in hist[x['id']]})
day_ix={d:i for i,d in enumerate(days)}
P=np.full((len(days),len(B)),np.nan)
for j,x in enumerate(B):
    for t,p in hist[x['id']]: P[day_ix[int(t//86400)],j]=p
supply=np.array([x['quotes']['USD']['market_cap']/x['quotes']['USD']['price'] for x in B])
ids=[x['id'] for x in B]; col={i:j for j,i in enumerate(ids)}
R=P[1:]/P[:-1]-1; W=P[:-1]*supply            # returns and prior-day caps (constant supplies = uncapped Xindex)
def cw(sel):
    m=np.zeros(len(B),bool); m[[col[s] for s in sel]]=True
    ok=~np.isnan(R)&~np.isnan(W)&m
    w=np.where(ok,W,0); r=np.where(ok,R,0)
    return (w*r).sum(1)/w.sum(1)
rB=cw(ids)
def capped_weights(caps):
    o=np.argsort(-caps); c=caps[o]/caps.sum(); n=len(c)
    top=0.2+0.1*min(1.0,max(0.0,caps[o][0]/caps[o][1]-1)); ceil=np.full(n,0.2); ceil[0]=top
    w=c.copy(); fixed=np.zeros(n,bool)
    for _ in range(n):
        over=(w>ceil+1e-15)&~fixed
        if not over.any(): break
        fixed|=over; w[fixed]=ceil[fixed]; rest=~fixed
        w[rest]=c[rest]/c[rest].sum()*(1-w[fixed].sum())
    out=np.zeros(n); out[o]=w; return out
def capped_series(sel, every=30):
    j=[col[s] for s in sel]; r=np.nan_to_num(R[:,j]); out=[]
    for t in range(len(r)):
        if t%every==0: w=capped_weights(P[t,j]*supply[j])
        out.append((w*r[t]).sum()); w=w*(1+r[t]); w=w/w.sum()
    return np.array(out)
S7=['btc-bitcoin','eth-ethereum','sol-solana','link-chainlink','uni-uniswap','aave-new']
S8=S7+['sky-sky','tao-bittensor']
def stats(name, rS, sel=None):
    d=rS-rB; te=d.std(ddof=1)*np.sqrt(365); td=np.prod(1+rS)-np.prod(1+rB)
    cov='' if sel is None else f"coverage {sum(tick[s]['quotes']['USD']['market_cap'] for s in sel)/M:6.1%}  "
    print(f"{name:<34} {cov}tracking error {te:6.1%}/yr   1-yr return diff {td:+6.1%}")
print(f"\nbenchmark (cap-weighted, {len(B)} assets) 1-yr return {np.prod(1+rB)-1:+.1%}")
stats('BTC only', cw(['btc-bitcoin']), ['btc-bitcoin'])
stats('BTC + ETH', cw(['btc-bitcoin','eth-ethereum']), ['btc-bitcoin','eth-ethereum'])
stats('launch list (6 assets), uncapped', cw(S7), S7)
stats('8 listable assets, uncapped', cw(S8), S8)
stats('8 listable assets, capped 30/20', capped_series(S8), S8)
# gap check: TE ~ (1-c) * sd(R_S - R_E)
rE=cw([i for i in ids if i not in S8]); c=sum(tick[s]['quotes']['USD']['market_cap'] for s in S8)/Mb
print(f"\ncheck for the 8: (1-c) x sd(R_S-R_E) = {(1-c):.3f} x {(cw(S8)-rE).std(ddof=1)*np.sqrt(365):.1%} = {(1-c)*(cw(S8)-rE).std(ddof=1)*np.sqrt(365):.1%}/yr")
# min-tracking-error long-only static weights on the 8 (in-sample, projected gradient on the simplex)
j=[col[s] for s in S8]; X=np.nan_to_num(R[:,j]); y=rB
def proj(v):
    u=np.sort(v)[::-1]; css=np.cumsum(u); k=np.nonzero(u*np.arange(1,len(v)+1)>(css-1))[0][-1]; th=(css[k]-1)/(k+1); return np.maximum(v-th,0)
w=np.ones(len(j))/len(j); L=np.linalg.norm(X,2)**2
for _ in range(20000): w=proj(w-(X.T@(X@w-y))/L)
rO=X@w; print("\nmin-tracking-error weights on the 8 (in-sample):", {S8[k].split('-')[0].upper():round(float(w[k]),3) for k in range(len(j)) if w[k]>1e-3})
stats('8 listable assets, min-TE weights', rO, S8)
cm=np.array([tick[s]['quotes']['USD']['market_cap'] for s in S8]); print("cap weights of the 8:", {S8[k].split('-')[0].upper():round(float(cm[k]/cm.sum()),3) for k in range(len(j))})
