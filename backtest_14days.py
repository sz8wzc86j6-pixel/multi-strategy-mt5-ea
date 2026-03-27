#!/usr/bin/env python3
"""
14-Day Backtest — All 8 strategies independently
Matches MultiStrategyEA.mq5 logic exactly.
Period: Last 14 days
Data: Yahoo Finance (real market data)
"""

import numpy as np
import pandas as pd
import warnings
from datetime import datetime, timedelta
from dataclasses import dataclass, field
from typing import List, Optional, Tuple
import json

warnings.filterwarnings('ignore')

try:
    import yfinance as yf
except ImportError:
    print("ERROR: pip3 install yfinance")
    exit(1)

# ═══════════════════════════════════════════════════════════════
#  INDICATORS (identical to EA)
# ═══════════════════════════════════════════════════════════════

def calc_atr(high, low, close, period=14):
    n = len(close)
    tr = np.zeros(n)
    tr[0] = high[0] - low[0]
    for i in range(1, n):
        tr[i] = max(high[i]-low[i], abs(high[i]-close[i-1]), abs(low[i]-close[i-1]))
    atr = np.full(n, np.nan)
    if n < period: return atr
    atr[period-1] = np.mean(tr[:period])
    m = 2.0/(period+1)
    for i in range(period, n):
        atr[i] = tr[i]*m + atr[i-1]*(1-m)
    return atr

def calc_supertrend(high, low, close, atr_period=14, mult=1.7):
    n = len(close)
    atr = calc_atr(high, low, close, atr_period)
    upper = np.zeros(n); lower = np.zeros(n)
    st = np.zeros(n); direction = np.zeros(n, dtype=int)
    for i in range(n):
        a = atr[i] if not np.isnan(atr[i]) else 0
        u = close[i] + mult*a; l = close[i] - mult*a
        if i == 0:
            upper[i]=u; lower[i]=l; direction[i]=1
        else:
            lower[i] = l if (l > lower[i-1] or close[i-1] < lower[i-1]) else lower[i-1]
            upper[i] = u if (u < upper[i-1] or close[i-1] > upper[i-1]) else upper[i-1]
            if direction[i-1]==-1 and close[i]>upper[i]: direction[i]=1
            elif direction[i-1]==1 and close[i]<lower[i]: direction[i]=-1
            else: direction[i]=direction[i-1]
        st[i] = lower[i] if direction[i]==1 else upper[i]
    return st, direction

def calc_hma(close, period=10):
    n = len(close)
    hp = max(int(period/2),1); sp = max(int(np.sqrt(period)),1)
    def wma(d, s, p):
        w = np.arange(1,p+1,dtype=float); ws = w.sum()
        if s+p > len(d): return 0
        return np.sum(d[s:s+p]*w)/ws
    hma = np.full(n, np.nan); trend = np.zeros(n, dtype=int)
    hsrc = np.full(n, np.nan)
    for i in range(n-period):
        hsrc[i] = 2*wma(close,i,hp) - wma(close,i,period)
    for i in range(n-period-sp):
        hma[i] = wma(hsrc,i,sp)
    for i in range(1, n):
        if not np.isnan(hma[i]) and not np.isnan(hma[i-1]) and i < n-period-sp:
            # Note: arrays are series (0=newest) when used, but here 0=oldest
            pass
    # Recalculate with proper indexing for non-series
    hma2 = np.full(n, np.nan); trend2 = np.zeros(n, dtype=int)
    # Forward pass
    wma_half = np.full(n, np.nan); wma_full = np.full(n, np.nan)
    for i in range(hp-1, n):
        w = np.arange(1, hp+1, dtype=float)
        wma_half[i] = np.sum(close[i-hp+1:i+1]*w)/w.sum()
    for i in range(period-1, n):
        w = np.arange(1, period+1, dtype=float)
        wma_full[i] = np.sum(close[i-period+1:i+1]*w)/w.sum()
    hull_src = np.full(n, np.nan)
    for i in range(period-1, n):
        if not np.isnan(wma_half[i]) and not np.isnan(wma_full[i]):
            hull_src[i] = 2*wma_half[i] - wma_full[i]
    for i in range(period+sp-2, n):
        valid = hull_src[i-sp+1:i+1]
        if not np.any(np.isnan(valid)):
            w = np.arange(1, sp+1, dtype=float)
            hma2[i] = np.sum(valid*w)/w.sum()
    for i in range(1, n):
        if not np.isnan(hma2[i]) and not np.isnan(hma2[i-1]):
            trend2[i] = 1 if hma2[i] > hma2[i-1] else -1
    return hma2, trend2

def calc_wavetrend(high, low, close, ch=6, avg=13):
    n = len(close)
    hlc3 = (high+low+close)/3.0
    def ema(d, p):
        r = np.zeros(n); m = 2.0/(p+1); r[0]=d[0]
        for i in range(1,n): r[i]=d[i]*m+r[i-1]*(1-m)
        return r
    e = ema(hlc3, ch)
    diff = hlc3-e; ad = np.abs(diff)
    ed = ema(diff, ch); ead = ema(ad, ch)
    ci = np.zeros(n)
    for i in range(n):
        dn = 0.015*ead[i]
        ci[i] = ed[i]/dn if dn != 0 else 0
    wt1 = ema(ci, avg)
    wt2 = np.zeros(n)
    for i in range(3, n):
        wt2[i] = np.mean(wt1[i-3:i+1])
    return wt1, wt2

def calc_macd(close, fast=14, slow=28, sig=11):
    n = len(close)
    def ema(d, p):
        r = np.zeros(n); m = 2.0/(p+1); r[0]=d[0]
        for i in range(1,n): r[i]=d[i]*m+r[i-1]*(1-m)
        return r
    ml = ema(close, fast) - ema(close, slow)
    sl = ema(ml, sig)
    return ml, sl, ml-sl

def calc_utbot(close, high, low, key=1.5, atr_period=10):
    n = len(close)
    atr = calc_atr(high, low, close, atr_period)
    trail = np.zeros(n); direction = np.zeros(n, dtype=int)
    for i in range(1, n):
        nL = key*atr[i] if not np.isnan(atr[i]) else 0
        if close[i]>trail[i-1] and close[i-1]>trail[i-1]:
            trail[i] = max(trail[i-1], close[i]-nL)
        elif close[i]<trail[i-1] and close[i-1]<trail[i-1]:
            trail[i] = min(trail[i-1], close[i]+nL)
        elif close[i]>trail[i-1]:
            trail[i] = close[i]-nL
        else:
            trail[i] = close[i]+nL
        if close[i]>trail[i] and close[i-1]<=trail[i-1]: direction[i]=1
        elif close[i]<trail[i] and close[i-1]>=trail[i-1]: direction[i]=-1
        else: direction[i]=direction[i-1]
    return trail, direction

def calc_ema(close, period=200):
    n = len(close); r = np.zeros(n); m = 2.0/(period+1); r[0]=close[0]
    for i in range(1,n): r[i]=close[i]*m+r[i-1]*(1-m)
    return r

# ═══════════════════════════════════════════════════════════════
#  BACKTESTER
# ═══════════════════════════════════════════════════════════════

@dataclass
class Trade:
    strategy: str = ""
    strat_id: int = 0
    entry_time: object = None
    exit_time: object = None
    direction: int = 0
    entry_price: float = 0
    exit_price: float = 0
    sl: float = 0
    tp1: float = 0
    tp2: float = 0
    tp1_hit: bool = False
    pnl: float = 0
    pnl_pct: float = 0
    exit_reason: str = ""

STRATEGIES = [
    {"id": 0, "name": "S1_ST+HMA",          "sl": 1.0, "tp1": 1.5, "tp2": 3.0},
    {"id": 1, "name": "S2_ST+HMA+WT+MACD",  "sl": 1.5, "tp1": 2.0, "tp2": 4.0},
    {"id": 2, "name": "S3_UT+HMA+WT+MACD",  "sl": 1.0, "tp1": 1.5, "tp2": 3.0},
    {"id": 3, "name": "S4_UT+ST+HMA+MACD",  "sl": 1.5, "tp1": 2.0, "tp2": 4.0},
    {"id": 4, "name": "S5_HMA+ST+MACD",     "sl": 1.5, "tp1": 2.0, "tp2": 4.0},
    {"id": 5, "name": "S6_MACD+ST+HMA",     "sl": 1.5, "tp1": 2.0, "tp2": 4.0},
    {"id": 6, "name": "S7_WT+ST+HMA",       "sl": 1.5, "tp1": 2.0, "tp2": 4.0},
    {"id": 7, "name": "S8_ST+ALL_Cons",      "sl": 2.0, "tp1": 3.0, "tp2": 6.0},
]

WT_OB = 53
WT_OS = -53

def check_signals(i, st_dir, hma_trend, wt1, wt2, macd_hist, ut_dir, ema200, close):
    """Check all 8 strategies, return dict of strat_id -> signal (1/-1/0)"""
    signals = {}

    # Helpers
    st_buy  = (st_dir[i]==1 and st_dir[i-1]==-1)
    st_sell = (st_dir[i]==-1 and st_dir[i-1]==1)
    st_bull = (st_dir[i]==1)
    st_bear = (st_dir[i]==-1)
    hma_buy  = (hma_trend[i]==1 and hma_trend[i-1]==-1)
    hma_sell = (hma_trend[i]==-1 and hma_trend[i-1]==1)
    hma_bull = (hma_trend[i]==1)
    hma_bear = (hma_trend[i]==-1)
    wt_bull = (wt1[i]>wt2[i] and wt1[i]<WT_OB)
    wt_bear = (wt1[i]<wt2[i] and wt1[i]>WT_OS)
    wt_buy_x  = (wt1[i]>wt2[i] and wt1[i-1]<=wt2[i-1] and wt1[i]<WT_OB)
    wt_sell_x = (wt1[i]<wt2[i] and wt1[i-1]>=wt2[i-1] and wt1[i]>WT_OS)
    macd_bull = (macd_hist[i]>0 or macd_hist[i]>macd_hist[i-1])
    macd_bear = (macd_hist[i]<0 or macd_hist[i]<macd_hist[i-1])
    macd_buy  = (macd_hist[i]>0 and macd_hist[i-1]<=0)
    macd_sell = (macd_hist[i]<0 and macd_hist[i-1]>=0)
    ut_buy  = (ut_dir[i]==1 and ut_dir[i-1]!=1)
    ut_sell = (ut_dir[i]==-1 and ut_dir[i-1]!=-1)

    # S1: ST flip + HMA trend
    if st_buy and hma_bull: signals[0] = 1
    elif st_sell and hma_bear: signals[0] = -1
    else: signals[0] = 0

    # S2: ST flip + 2/3 of (HMA, WT, MACD)
    s2 = 0
    if st_buy:
        c = int(hma_bull)+int(wt_bull)+int(macd_bull)
        s2 = 1 if c >= 2 else 0
    elif st_sell:
        c = int(hma_bear)+int(wt_bear)+int(macd_bear)
        s2 = -1 if c >= 2 else 0
    signals[1] = s2

    # S3: UT flip + 2/3 of (HMA, WT, MACD)
    s3 = 0
    if ut_buy:
        c = int(hma_bull)+int(wt_bull)+int(macd_bull)
        s3 = 1 if c >= 2 else 0
    elif ut_sell:
        c = int(hma_bear)+int(wt_bear)+int(macd_bear)
        s3 = -1 if c >= 2 else 0
    signals[2] = s3

    # S4: UT flip + 2/3 of (ST, HMA, MACD)
    s4 = 0
    if ut_buy:
        c = int(st_bull)+int(hma_bull)+int(macd_bull)
        s4 = 1 if c >= 2 else 0
    elif ut_sell:
        c = int(st_bear)+int(hma_bear)+int(macd_bear)
        s4 = -1 if c >= 2 else 0
    signals[3] = s4

    # S5: HMA flip + ST + MACD
    if hma_buy and st_bull and macd_bull: signals[4] = 1
    elif hma_sell and st_bear and macd_bear: signals[4] = -1
    else: signals[4] = 0

    # S6: MACD flip + ST + HMA
    if macd_buy and st_bull and hma_bull: signals[5] = 1
    elif macd_sell and st_bear and hma_bear: signals[5] = -1
    else: signals[5] = 0

    # S7: WT cross + ST + HMA
    if wt_buy_x and st_bull and hma_bull: signals[6] = 1
    elif wt_sell_x and st_bear and hma_bear: signals[6] = -1
    else: signals[6] = 0

    # S8: ST flip + 3/4 of (HMA, WT, MACD, EMA200)
    s8 = 0
    if st_buy:
        c = int(hma_bull)+int(wt_bull)+int(macd_bull)+int(close[i]>ema200[i])
        s8 = 1 if c >= 3 else 0
    elif st_sell:
        c = int(hma_bear)+int(wt_bear)+int(macd_bear)+int(close[i]<ema200[i])
        s8 = -1 if c >= 3 else 0
    signals[7] = s8

    return signals


def run_backtest(df, symbol, timeframe, risk_pct=1.5):
    """Run all 8 strategies on the data independently."""
    close = df['Close'].values.flatten().astype(float)
    high  = df['High'].values.flatten().astype(float)
    low   = df['Low'].values.flatten().astype(float)
    n = len(close)

    if n < 60:
        print(f"  {symbol} {timeframe}: Only {n} bars, skipping")
        return []

    # Indicators
    atr = calc_atr(high, low, close, 14)
    st_line, st_dir = calc_supertrend(high, low, close, 14, 1.7)
    hma_line, hma_trend = calc_hma(close, 10)
    wt1, wt2 = calc_wavetrend(high, low, close, 6, 13)
    macd_l, macd_s, macd_h = calc_macd(close, 14, 28, 11)
    ut_trail, ut_dir = calc_utbot(close, high, low, 1.5, 10)
    ema200 = calc_ema(close, 200)

    # Track positions per strategy
    positions = {s["id"]: None for s in STRATEGIES}
    all_trades = []
    equity = {s["id"]: 10000.0 for s in STRATEGIES}

    warmup = 50  # minimal warmup for 14 days

    for i in range(warmup, n):
        if np.isnan(atr[i]) or atr[i] == 0:
            continue

        # ── Manage open positions ──
        for s in STRATEGIES:
            sid = s["id"]
            pos = positions[sid]
            if pos is None: continue

            if pos.direction == 1:
                # SL hit
                if low[i] <= pos.sl:
                    pos.exit_price = pos.sl; pos.exit_time = df.index[i]
                    pos.exit_reason = "SL"
                # TP1
                elif not pos.tp1_hit and high[i] >= pos.tp1:
                    pos.tp1_hit = True; pos.sl = pos.entry_price
                # TP2
                elif high[i] >= pos.tp2:
                    pos.exit_price = pos.tp2; pos.exit_time = df.index[i]
                    pos.exit_reason = "TP2"
                # ST flip
                elif st_dir[i]==-1 and i>0 and st_dir[i-1]==1:
                    pos.exit_price = close[i]; pos.exit_time = df.index[i]
                    pos.exit_reason = "ST_FLIP"
                # Trail with ST
                if pos.exit_reason == "" and pos.tp1_hit and st_dir[i]==1:
                    if st_line[i] > pos.sl: pos.sl = st_line[i]
            else:
                if high[i] >= pos.sl:
                    pos.exit_price = pos.sl; pos.exit_time = df.index[i]
                    pos.exit_reason = "SL"
                elif not pos.tp1_hit and low[i] <= pos.tp1:
                    pos.tp1_hit = True; pos.sl = pos.entry_price
                elif low[i] <= pos.tp2:
                    pos.exit_price = pos.tp2; pos.exit_time = df.index[i]
                    pos.exit_reason = "TP2"
                elif st_dir[i]==1 and i>0 and st_dir[i-1]==-1:
                    pos.exit_price = close[i]; pos.exit_time = df.index[i]
                    pos.exit_reason = "ST_FLIP"
                if pos.exit_reason == "" and pos.tp1_hit and st_dir[i]==-1:
                    if st_line[i] < pos.sl: pos.sl = st_line[i]

            if pos.exit_reason != "":
                sl_dist = abs(pos.entry_price - (pos.entry_price - s["sl"]*atr[i])) if atr[i] > 0 else atr[i]*s["sl"]
                if sl_dist == 0: sl_dist = atr[i]*s["sl"]
                risk_amt = equity[sid] * risk_pct / 100.0
                pos_size = risk_amt / sl_dist if sl_dist > 0 else 0

                if pos.tp1_hit:
                    pnl = (pos.tp1-pos.entry_price)*pos.direction*pos_size*0.5 + \
                          (pos.exit_price-pos.entry_price)*pos.direction*pos_size*0.5
                else:
                    pnl = (pos.exit_price-pos.entry_price)*pos.direction*pos_size

                pos.pnl = pnl
                pos.pnl_pct = (pnl/equity[sid])*100
                equity[sid] += pnl
                equity[sid] = max(equity[sid], 500)
                all_trades.append(pos)
                positions[sid] = None

        # ── Check for new entries ──
        if i < 2: continue
        signals = check_signals(i, st_dir, hma_trend, wt1, wt2, macd_h, ut_dir, ema200, close)

        for s in STRATEGIES:
            sid = s["id"]
            if positions[sid] is not None: continue
            sig = signals.get(sid, 0)
            if sig == 0: continue

            entry = close[i]
            a = atr[i]
            if sig == 1:
                sl = entry - s["sl"]*a; tp1 = entry + s["tp1"]*a; tp2 = entry + s["tp2"]*a
            else:
                sl = entry + s["sl"]*a; tp1 = entry - s["tp1"]*a; tp2 = entry - s["tp2"]*a

            positions[sid] = Trade(
                strategy=s["name"], strat_id=sid,
                entry_time=df.index[i], direction=sig,
                entry_price=entry, sl=sl, tp1=tp1, tp2=tp2
            )

    # Close any remaining open positions at last close
    for s in STRATEGIES:
        sid = s["id"]
        pos = positions[sid]
        if pos is not None:
            pos.exit_price = close[-1]; pos.exit_time = df.index[-1]
            pos.exit_reason = "EOD"
            sl_dist = atr[-1]*s["sl"] if not np.isnan(atr[-1]) and atr[-1]>0 else 1
            risk_amt = equity[sid]*risk_pct/100.0
            pos_size = risk_amt/sl_dist if sl_dist>0 else 0
            if pos.tp1_hit:
                pnl = (pos.tp1-pos.entry_price)*pos.direction*pos_size*0.5 + \
                      (pos.exit_price-pos.entry_price)*pos.direction*pos_size*0.5
            else:
                pnl = (pos.exit_price-pos.entry_price)*pos.direction*pos_size
            pos.pnl = pnl; pos.pnl_pct = (pnl/equity[sid])*100
            equity[sid] += pnl
            all_trades.append(pos)

    # Tag symbol/tf
    for t in all_trades:
        t.exit_reason = f"{symbol}_{timeframe}_{t.exit_reason}"

    return all_trades, equity


def main():
    print("=" * 90)
    print("  14-DAY BACKTEST — ALL 8 STRATEGIES INDEPENDENTLY")
    print("  Period: Last 14 days | Real Yahoo Finance data")
    print("=" * 90)

    symbols_map = {
        'GBPUSD': ('GBPUSD=X', 'Forex'),
        'EURUSD': ('EURUSD=X', 'Forex'),
        'USDJPY': ('USDJPY=X', 'Forex'),
        'BTCUSD': ('BTC-USD',  'Crypto'),
        'US30':   ('^DJI',     'Index'),
    }
    timeframes = {
        'M15': '15m',
        'H1':  '1h',
        'H4':  '4h',
    }

    end_date = datetime.now()
    start_date = end_date - timedelta(days=16)  # extra 2 days for warmup

    all_trades = []
    all_equity = {}  # (symbol, tf, strat_id) -> final equity

    for sym, (yf_sym, mkt) in symbols_map.items():
        for tf, yf_tf in timeframes.items():
            print(f"\n  Loading {sym} {tf}...")
            try:
                df = yf.download(yf_sym, start=start_date, end=end_date, interval=yf_tf, progress=False)
                if isinstance(df.columns, pd.MultiIndex):
                    df.columns = df.columns.get_level_values(0)
                df = df.loc[:, ~df.columns.duplicated()]
                if len(df) < 30:
                    print(f"    Only {len(df)} bars, skipping")
                    continue
                print(f"    {len(df)} bars loaded")
            except Exception as e:
                print(f"    Error: {e}")
                continue

            trades, equity = run_backtest(df, sym, tf)
            all_trades.extend(trades)
            for sid, eq in equity.items():
                all_equity[(sym, tf, sid)] = eq

    # ═══ RESULTS ═══
    print("\n" + "=" * 90)
    print("  RESULTS BY STRATEGY (aggregated across all symbols & timeframes)")
    print("=" * 90)

    for s in STRATEGIES:
        sid = s["id"]
        strades = [t for t in all_trades if t.strat_id == sid]
        if not strades:
            print(f"\n  {s['name']}: No trades")
            continue

        wins = [t for t in strades if t.pnl > 0]
        losses = [t for t in strades if t.pnl <= 0]
        wr = len(wins)/len(strades)*100 if strades else 0
        total_pnl = sum(t.pnl for t in strades)
        avg_win = np.mean([t.pnl_pct for t in wins]) if wins else 0
        avg_loss = np.mean([t.pnl_pct for t in losses]) if losses else 0
        gp = sum(t.pnl for t in wins)
        gl = abs(sum(t.pnl for t in losses))
        pf = gp/gl if gl > 0 else gp if gp > 0 else 0

        # Equity across all runs
        equities = [all_equity.get((sym, tf, sid), 10000) for sym in symbols_map for tf in timeframes]
        avg_ret = np.mean([(e-10000)/10000*100 for e in equities])

        print(f"\n  ┌─ {s['name']} ─────────────────────────────────────────")
        print(f"  │ Trades: {len(strades)}  |  Wins: {len(wins)}  |  Losses: {len(losses)}")
        print(f"  │ Win Rate: {wr:.1f}%  |  Profit Factor: {pf:.2f}")
        print(f"  │ Avg Win: {avg_win:+.2f}%  |  Avg Loss: {avg_loss:+.2f}%")
        print(f"  │ Total PnL: ${total_pnl:+.2f}  |  Avg Return: {avg_ret:+.1f}%")
        print(f"  └──────────────────────────────────────────────────────")

    # ═══ DETAILED RESULTS BY SYMBOL × TIMEFRAME × STRATEGY ═══
    print("\n" + "=" * 90)
    print("  DETAILED: STRATEGY × SYMBOL × TIMEFRAME")
    print("=" * 90)
    print(f"  {'Strategy':<22} {'Symbol':<8} {'TF':<5} {'Trades':<7} {'WR%':<7} {'PnL$':<12} {'PF':<7} {'Return%':<9}")
    print("  " + "-" * 80)

    rows = []
    for s in STRATEGIES:
        sid = s["id"]
        for sym in symbols_map:
            for tf in timeframes:
                strades = [t for t in all_trades if t.strat_id==sid and t.exit_reason.startswith(f"{sym}_{tf}")]
                if not strades: continue
                wins = [t for t in strades if t.pnl > 0]
                losses = [t for t in strades if t.pnl <= 0]
                wr = len(wins)/len(strades)*100
                pnl = sum(t.pnl for t in strades)
                gp = sum(t.pnl for t in wins); gl = abs(sum(t.pnl for t in losses))
                pf = gp/gl if gl > 0 else 99
                eq = all_equity.get((sym, tf, sid), 10000)
                ret = (eq-10000)/10000*100
                rows.append((s["name"], sym, tf, len(strades), wr, pnl, pf, ret))
                print(f"  {s['name']:<22} {sym:<8} {tf:<5} {len(strades):<7} {wr:<6.1f}% ${pnl:<10.2f} {pf:<6.2f} {ret:+.1f}%")

    # ═══ TOP 10 BEST COMBINATIONS ═══
    print("\n" + "=" * 90)
    print("  TOP 10 BEST COMBINATIONS (by return %)")
    print("=" * 90)

    rows.sort(key=lambda x: x[7], reverse=True)
    print(f"  {'#':<4} {'Strategy':<22} {'Symbol':<8} {'TF':<5} {'Trades':<7} {'WR%':<7} {'PnL$':<12} {'PF':<7} {'Return%':<9}")
    print("  " + "-" * 80)
    for i, r in enumerate(rows[:10]):
        print(f"  {i+1:<4} {r[0]:<22} {r[1]:<8} {r[2]:<5} {r[3]:<7} {r[4]:<6.1f}% ${r[5]:<10.2f} {r[6]:<6.2f} {r[7]:+.1f}%")

    # ═══ WORST 5 ═══
    print("\n  WORST 5:")
    print(f"  {'#':<4} {'Strategy':<22} {'Symbol':<8} {'TF':<5} {'Trades':<7} {'WR%':<7} {'PnL$':<12} {'Return%':<9}")
    print("  " + "-" * 80)
    for i, r in enumerate(rows[-5:]):
        print(f"  {i+1:<4} {r[0]:<22} {r[1]:<8} {r[2]:<5} {r[3]:<7} {r[4]:<6.1f}% ${r[5]:<10.2f} {r[7]:+.1f}%")

    # ═══ TRADE LOG (last 20 trades) ═══
    print("\n" + "=" * 90)
    print("  RECENT TRADE LOG (last 20)")
    print("=" * 90)

    sorted_trades = sorted(all_trades, key=lambda t: str(t.entry_time) if t.entry_time else "")
    for t in sorted_trades[-20:]:
        d = "LONG" if t.direction == 1 else "SHORT"
        tp1 = "TP1+" if t.tp1_hit else ""
        reason = t.exit_reason.split("_")[-1] if "_" in t.exit_reason else t.exit_reason
        print(f"  {str(t.entry_time)[:16]} {t.strategy:<22} {d:<6} "
              f"Entry:{t.entry_price:<10.5f} Exit:{t.exit_price:<10.5f} "
              f"{tp1}{reason:<8} PnL:{t.pnl_pct:+.2f}%")

    # ═══ SAVE CSV ═══
    if rows:
        df_out = pd.DataFrame(rows, columns=['Strategy','Symbol','TF','Trades','WinRate','PnL','PF','Return'])
        csv_path = '/Users/danielwrabel/untitled folder/backtest_14days_results.csv'
        df_out.to_csv(csv_path, index=False)
        print(f"\n  Results saved to: {csv_path}")

    # Summary
    total_t = len(all_trades)
    total_w = len([t for t in all_trades if t.pnl > 0])
    total_pnl = sum(t.pnl for t in all_trades)
    print(f"\n{'=' * 90}")
    print(f"  SUMMARY: {total_t} trades | {total_w} wins ({total_w/total_t*100:.1f}% WR) | Total PnL: ${total_pnl:+.2f}")
    print(f"{'=' * 90}")


if __name__ == "__main__":
    main()
