#!/usr/bin/env python3
"""
Crypto Late-Entry Strategy Backtest v2
======================================
Tests the "late entry" approach on Polymarket crypto Up/Down markets:
- Fetch real 1-min candle data from Binance (last 7 days)
- Simulate 5-minute Up/Down windows (like Polymarket)
- Enter 1-2 minutes before window closes when price already shows direction
- Test multiple thresholds, bet sizes, and crypto pairs

Strategy: Don't predict — react to what's already happening.
When BTC is already +0.05% above reference with 2 min left,
"Up" token is almost certain to win. Buy it cheap.
"""

import requests
import time
import json
from datetime import datetime, timedelta

# ── Binance Data ──────────────────────────────────────────────────────

def fetch_binance_klines(symbol="BTCUSDT", interval="1m", days=7):
    """Fetch 1-minute candles from Binance for the last N days."""
    all_candles = []
    end_time = int(time.time() * 1000)
    start_time = end_time - (days * 24 * 60 * 60 * 1000)

    print(f"  Fetching {symbol} {interval} candles for {days} days...")

    current = start_time
    while current < end_time:
        try:
            resp = requests.get(
                "https://api.binance.com/api/v3/klines",
                params={
                    "symbol": symbol,
                    "interval": interval,
                    "startTime": current,
                    "limit": 1000,
                },
                timeout=10,
            )
            data = resp.json()
            if not data or not isinstance(data, list):
                break
            all_candles.extend(data)
            current = data[-1][0] + 1  # next candle after last
            time.sleep(0.1)  # rate limit
        except Exception as e:
            print(f"    Error: {e}")
            time.sleep(1)
            continue

    # Parse into list of dicts
    candles = []
    for c in all_candles:
        candles.append({
            "open_time": c[0],
            "open": float(c[1]),
            "high": float(c[2]),
            "low": float(c[3]),
            "close": float(c[4]),
            "volume": float(c[5]),
            "close_time": c[6],
        })

    print(f"    Got {len(candles)} candles for {symbol}")
    return candles


def simulate_polymarket_windows(candles, window_minutes=5):
    """
    Simulate Polymarket-style Up/Down windows.
    Each window: reference_price = open of first candle in window.
    Outcome: UP if close of last candle > reference_price, else DOWN.
    """
    windows = []
    i = 0
    while i + window_minutes <= len(candles):
        window_candles = candles[i : i + window_minutes]
        reference_price = window_candles[0]["open"]
        final_price = window_candles[-1]["close"]

        # Price at each minute within the window
        minute_prices = [c["close"] for c in window_candles]

        outcome = "UP" if final_price > reference_price else "DOWN"
        pct_change = (final_price - reference_price) / reference_price * 100

        windows.append({
            "reference_price": reference_price,
            "final_price": final_price,
            "minute_prices": minute_prices,
            "outcome": outcome,
            "pct_change": pct_change,
            "open_time": window_candles[0]["open_time"],
        })

        i += window_minutes  # non-overlapping windows

    return windows


def estimate_token_price(current_price, reference_price, minutes_left, window_minutes=5):
    """
    Estimate what the Polymarket token price would be.
    When price is clearly above/below reference with little time left,
    the token price moves toward $1 or $0.

    This is a conservative estimate — real Polymarket tokens may lag more.
    """
    pct_lead = (current_price - reference_price) / reference_price * 100
    time_factor = 1.0 - (minutes_left / window_minutes)  # 0 at start, 1 at end

    # Base probability from price lead
    if abs(pct_lead) < 0.01:
        base_prob = 0.50
    else:
        # Sigmoid-like mapping: bigger lead = higher probability
        import math
        # Scale: 0.1% lead ≈ 60% prob, 0.3% lead ≈ 80% prob, 0.5% lead ≈ 90% prob
        z = pct_lead * 15  # scaling factor
        base_prob = 1 / (1 + math.exp(-z))

    # Time decay: closer to end = price more certain
    # With 1 min left and clear lead, token should be 0.70-0.90
    # With 2 min left and clear lead, token should be 0.55-0.75
    adjusted_prob = 0.50 + (base_prob - 0.50) * (0.5 + 0.5 * time_factor)

    # Add market inefficiency (Polymarket tokens lag real price by ~5-15%)
    inefficiency = 0.10  # 10% lag
    if adjusted_prob > 0.50:
        token_price = adjusted_prob - inefficiency * (adjusted_prob - 0.50)
    else:
        token_price = adjusted_prob + inefficiency * (0.50 - adjusted_prob)

    return max(0.05, min(0.95, token_price))


# ── Strategy ──────────────────────────────────────────────────────────

def run_strategy(windows, config, starting_capital=250.0):
    """Run the late-entry strategy on simulated windows."""
    capital = starting_capital
    trades = []
    wins = 0
    losses = 0

    min_lead_pct = config["min_lead_pct"]
    entry_minutes_before_close = config["entry_min_before"]
    bet_size = config["bet_size"]
    symbols = config.get("symbols", ["BTCUSDT"])
    max_token_price = config.get("max_token_price", 0.75)
    min_token_price = config.get("min_token_price", 0.20)

    for w in windows:
        if capital < bet_size:
            break

        # Check price at entry point (e.g., 2 minutes before close)
        entry_idx = 5 - entry_minutes_before_close  # e.g., minute 3 for 2-min-before
        if entry_idx < 0 or entry_idx >= len(w["minute_prices"]):
            continue

        entry_price = w["minute_prices"][entry_idx]
        reference = w["reference_price"]
        lead_pct = abs((entry_price - reference) / reference * 100)

        # Only enter if price has a clear lead
        if lead_pct < min_lead_pct:
            continue

        # Determine direction
        direction = "UP" if entry_price > reference else "DOWN"

        # Estimate token price (what we'd pay on Polymarket)
        token_price = estimate_token_price(
            entry_price, reference,
            entry_minutes_before_close, 5
        )

        # For DOWN direction, we buy the DOWN token
        if direction == "DOWN":
            token_price = 1.0 - token_price  # DOWN token price

        # Skip if token price is too high (no value) or too low (too risky)
        if token_price > max_token_price or token_price < min_token_price:
            continue

        # Calculate shares
        shares = bet_size / token_price
        cost = bet_size

        # Check outcome
        if direction == w["outcome"]:
            # Win: shares * $1.00
            payout = shares * 1.0
            pnl = payout - cost
            wins += 1
            result = "WIN"
        else:
            # Lose: shares * $0.00
            pnl = -cost
            losses += 1
            result = "LOSE"

        capital += pnl

        trades.append({
            "direction": direction,
            "outcome": w["outcome"],
            "lead_pct": lead_pct,
            "token_price": token_price,
            "cost": cost,
            "pnl": pnl,
            "result": result,
            "capital": capital,
        })

    total_trades = wins + losses
    win_rate = wins / total_trades * 100 if total_trades > 0 else 0
    total_pnl = capital - starting_capital
    roi = total_pnl / starting_capital * 100

    # Profit factor
    gross_profit = sum(t["pnl"] for t in trades if t["pnl"] > 0)
    gross_loss = abs(sum(t["pnl"] for t in trades if t["pnl"] < 0))
    profit_factor = gross_profit / gross_loss if gross_loss > 0 else float("inf")

    # Max drawdown
    peak = starting_capital
    max_dd = 0
    for t in trades:
        peak = max(peak, t["capital"])
        dd = (peak - t["capital"]) / peak * 100
        max_dd = max(max_dd, dd)

    return {
        "trades": total_trades,
        "wins": wins,
        "losses": losses,
        "win_rate": win_rate,
        "total_pnl": total_pnl,
        "roi": roi,
        "profit_factor": profit_factor,
        "max_drawdown": max_dd,
        "final_capital": capital,
        "avg_pnl": total_pnl / total_trades if total_trades > 0 else 0,
        "trade_log": trades,
    }


# ── Main ──────────────────────────────────────────────────────────────

def main():
    print("=" * 70)
    print("CRYPTO LATE-ENTRY STRATEGY BACKTEST v2")
    print("=" * 70)
    print(f"Period: Last 7 days")
    print(f"Strategy: Enter when price already shows direction, 1-2 min before close")
    print()

    # Fetch data for multiple symbols
    symbols = ["BTCUSDT", "ETHUSDT", "XRPUSDT", "SOLUSDT", "DOGEUSDT"]
    all_windows = {}

    print("Fetching Binance data...")
    for sym in symbols:
        try:
            candles = fetch_binance_klines(sym, "1m", 7)
            if candles:
                windows = simulate_polymarket_windows(candles, 5)
                all_windows[sym] = windows
                up_count = sum(1 for w in windows if w["outcome"] == "UP")
                print(f"    {sym}: {len(windows)} windows ({up_count} UP, {len(windows)-up_count} DOWN)")
        except Exception as e:
            print(f"    {sym}: Error - {e}")

    print()

    # Test configurations
    configs = [
        # Ultra-aggressive: tiny lead, enter early
        {"name": "Ultra-Aggr (0.02%, 2min, $5)", "min_lead_pct": 0.02, "entry_min_before": 2, "bet_size": 5, "max_token_price": 0.70},
        {"name": "Ultra-Aggr (0.02%, 2min, $10)", "min_lead_pct": 0.02, "entry_min_before": 2, "bet_size": 10, "max_token_price": 0.70},
        {"name": "Ultra-Aggr (0.02%, 2min, $15)", "min_lead_pct": 0.02, "entry_min_before": 2, "bet_size": 15, "max_token_price": 0.70},

        # Aggressive: small lead
        {"name": "Aggressive (0.03%, 2min, $5)", "min_lead_pct": 0.03, "entry_min_before": 2, "bet_size": 5, "max_token_price": 0.70},
        {"name": "Aggressive (0.03%, 2min, $10)", "min_lead_pct": 0.03, "entry_min_before": 2, "bet_size": 10, "max_token_price": 0.70},
        {"name": "Aggressive (0.03%, 1min, $10)", "min_lead_pct": 0.03, "entry_min_before": 1, "bet_size": 10, "max_token_price": 0.80},

        # Moderate
        {"name": "Moderate (0.05%, 2min, $5)", "min_lead_pct": 0.05, "entry_min_before": 2, "bet_size": 5, "max_token_price": 0.70},
        {"name": "Moderate (0.05%, 2min, $10)", "min_lead_pct": 0.05, "entry_min_before": 2, "bet_size": 10, "max_token_price": 0.70},
        {"name": "Moderate (0.05%, 1min, $10)", "min_lead_pct": 0.05, "entry_min_before": 1, "bet_size": 10, "max_token_price": 0.80},

        # Conservative
        {"name": "Conservative (0.10%, 2min, $10)", "min_lead_pct": 0.10, "entry_min_before": 2, "bet_size": 10, "max_token_price": 0.65},
        {"name": "Conservative (0.10%, 1min, $15)", "min_lead_pct": 0.10, "entry_min_before": 1, "bet_size": 15, "max_token_price": 0.75},

        # Late entry (1 min before)
        {"name": "Late Entry (0.05%, 1min, $15)", "min_lead_pct": 0.05, "entry_min_before": 1, "bet_size": 15, "max_token_price": 0.80},
    ]

    print("=" * 70)
    print(f"{'Config':<42} {'Trades':>6} {'WinR%':>6} {'PnL':>10} {'ROI%':>8} {'PF':>6} {'MaxDD':>6}")
    print("-" * 70)

    best_config = None
    best_score = -999

    for config in configs:
        # Combine all symbol windows
        combined_windows = []
        for sym in all_windows:
            combined_windows.extend(all_windows[sym])

        # Sort by time
        combined_windows.sort(key=lambda w: w["open_time"])

        result = run_strategy(combined_windows, config)

        # Score: balance win rate, PnL, and trade count
        score = (result["win_rate"] * 0.4) + (result["roi"] * 0.3) + (min(result["trades"], 50) * 0.3)

        status = "***" if result["win_rate"] >= 65 and result["roi"] > 0 else "   "

        print(f"{config['name']:<42} {result['trades']:>6} {result['win_rate']:>5.1f}% "
              f"${result['total_pnl']:>+8.2f} {result['roi']:>+7.1f}% "
              f"{result['profit_factor']:>5.2f} {result['max_drawdown']:>5.1f}% {status}")

        if score > best_score:
            best_score = score
            best_config = config
            best_result = result

    print("=" * 70)
    print()

    # Show best config details
    if best_config:
        print(f"BEST CONFIG: {best_config['name']}")
        print(f"  Trades: {best_result['trades']}")
        print(f"  Win Rate: {best_result['win_rate']:.1f}%")
        print(f"  Total PnL: ${best_result['total_pnl']:+.2f}")
        print(f"  ROI: {best_result['roi']:+.1f}%")
        print(f"  Profit Factor: {best_result['profit_factor']:.2f}")
        print(f"  Max Drawdown: {best_result['max_drawdown']:.1f}%")
        print(f"  Final Capital: ${best_result['final_capital']:.2f}")
        print()

        # Show per-symbol breakdown for best config
        print("  Per-Symbol Breakdown:")
        for sym in all_windows:
            sym_result = run_strategy(all_windows[sym], best_config)
            if sym_result["trades"] > 0:
                print(f"    {sym:>10}: {sym_result['trades']:>4} trades, "
                      f"{sym_result['win_rate']:>5.1f}% WR, "
                      f"${sym_result['total_pnl']:>+8.2f}")

        print()

        # Show sample trades
        if best_result["trade_log"]:
            print("  Sample Trades (first 15):")
            for i, t in enumerate(best_result["trade_log"][:15]):
                print(f"    #{i+1:>3}: {t['direction']:>4} lead={t['lead_pct']:.3f}% "
                      f"token=${t['token_price']:.3f} cost=${t['cost']:.2f} "
                      f"pnl=${t['pnl']:>+7.2f} [{t['result']}] bal=${t['capital']:.2f}")

    print()
    print("=" * 70)
    print("RECOMMENDATION:")
    if best_result and best_result["win_rate"] >= 60 and best_result["roi"] > 0:
        print(f"  Deploy crypto bot with: {best_config['name']}")
        print(f"  Expected: {best_result['trades']//7} trades/day, "
              f"{best_result['win_rate']:.0f}% WR, "
              f"${best_result['total_pnl']/7:.2f}/day")
    elif best_result and best_result["win_rate"] >= 55:
        print(f"  Marginal edge. Deploy with small bets ($3-5) to validate.")
    else:
        print(f"  Strategy needs more tuning. Do not deploy yet.")
    print("=" * 70)


if __name__ == "__main__":
    main()
