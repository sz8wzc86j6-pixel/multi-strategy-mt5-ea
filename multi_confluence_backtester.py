#!/usr/bin/env python3
"""
Multi-Confluence Strategy Backtester
=====================================
Tests ALL combinations of indicators from the TradingView chart:
  - SuperTrend (DBHF ST variant)
  - Triple HMA (trend ribbon)
  - WaveTrend oscillator
  - MACD
  - UT Bot Alerts
  - EMA trend filter

Tests across:
  - Forex: GBPUSD, EURUSD, USDJPY
  - Crypto: BTCUSD
  - Indices: US30 (DJI)
  - Timeframes: M15, H1, H4

Finds optimal combination by: profit factor, win rate, max drawdown, total return.
"""

import numpy as np
import pandas as pd
import itertools
import warnings
import os
from datetime import datetime, timedelta
from dataclasses import dataclass, field
from typing import List, Dict, Tuple, Optional
import json

warnings.filterwarnings('ignore')

# Try to import yfinance for data, fallback to synthetic
try:
    import yfinance as yf
    HAS_YFINANCE = True
except ImportError:
    HAS_YFINANCE = False
    print("yfinance not installed. Will use synthetic data. Install with: pip install yfinance")


# ═══════════════════════════════════════════════════════════════
#  INDICATOR IMPLEMENTATIONS
# ═══════════════════════════════════════════════════════════════

def calculate_atr(high: np.ndarray, low: np.ndarray, close: np.ndarray, period: int = 14) -> np.ndarray:
    """Average True Range"""
    n = len(close)
    tr = np.zeros(n)
    tr[0] = high[0] - low[0]
    for i in range(1, n):
        tr[i] = max(high[i] - low[i],
                     abs(high[i] - close[i-1]),
                     abs(low[i] - close[i-1]))
    atr = np.zeros(n)
    atr[:period] = np.nan
    atr[period-1] = np.mean(tr[:period])
    multiplier = 2.0 / (period + 1)
    for i in range(period, n):
        atr[i] = tr[i] * multiplier + atr[i-1] * (1 - multiplier)
    return atr


def calculate_supertrend(high: np.ndarray, low: np.ndarray, close: np.ndarray,
                          atr_period: int = 14, multiplier: float = 1.7) -> Tuple[np.ndarray, np.ndarray]:
    """
    SuperTrend indicator (DBHF ST variant).
    Returns: (supertrend_line, direction) where direction: 1=bullish, -1=bearish
    """
    n = len(close)
    atr = calculate_atr(high, low, close, atr_period)

    upper_band = np.zeros(n)
    lower_band = np.zeros(n)
    supertrend = np.zeros(n)
    direction = np.zeros(n, dtype=int)

    src = close  # Use close price (matching chart settings)

    for i in range(n):
        basic_upper = src[i] + multiplier * atr[i] if not np.isnan(atr[i]) else src[i]
        basic_lower = src[i] - multiplier * atr[i] if not np.isnan(atr[i]) else src[i]

        if i == 0:
            upper_band[i] = basic_upper
            lower_band[i] = basic_lower
            direction[i] = 1
        else:
            # Lower band can only go up
            lower_band[i] = basic_lower if (basic_lower > lower_band[i-1] or close[i-1] < lower_band[i-1]) else lower_band[i-1]

            # Upper band can only go down
            upper_band[i] = basic_upper if (basic_upper < upper_band[i-1] or close[i-1] > upper_band[i-1]) else upper_band[i-1]

            # Direction
            if direction[i-1] == -1 and close[i] > upper_band[i]:
                direction[i] = 1
            elif direction[i-1] == 1 and close[i] < lower_band[i]:
                direction[i] = -1
            else:
                direction[i] = direction[i-1]

        supertrend[i] = lower_band[i] if direction[i] == 1 else upper_band[i]

    return supertrend, direction


def calculate_hma(close: np.ndarray, period: int = 10) -> Tuple[np.ndarray, np.ndarray]:
    """
    Hull Moving Average with trend direction.
    Returns: (hma, trend) where trend: 1=rising, -1=falling
    """
    n = len(close)
    half_period = max(int(period / 2), 1)
    sqrt_period = max(int(np.sqrt(period)), 1)

    def wma(data, p):
        result = np.full(len(data), np.nan)
        weights = np.arange(1, p + 1, dtype=float)
        w_sum = weights.sum()
        for i in range(p - 1, len(data)):
            result[i] = np.sum(data[i - p + 1:i + 1] * weights) / w_sum
        return result

    wma_half = wma(close, half_period)
    wma_full = wma(close, period)

    hull_src = 2 * wma_half - wma_full
    hma = wma(hull_src, sqrt_period)

    trend = np.zeros(n, dtype=int)
    for i in range(1, n):
        if not np.isnan(hma[i]) and not np.isnan(hma[i-1]):
            trend[i] = 1 if hma[i] > hma[i-1] else -1
        else:
            trend[i] = 0

    return hma, trend


def calculate_wavetrend(high: np.ndarray, low: np.ndarray, close: np.ndarray,
                         channel: int = 6, average: int = 13) -> Tuple[np.ndarray, np.ndarray]:
    """
    WaveTrend Oscillator (LazyBear variant).
    Returns: (wt1, wt2)
    """
    n = len(close)
    hlc3 = (high + low + close) / 3.0

    def ema(data, period):
        result = np.zeros(n)
        mult = 2.0 / (period + 1)
        result[0] = data[0]
        for i in range(1, n):
            result[i] = data[i] * mult + result[i-1] * (1 - mult)
        return result

    ema_hlc3 = ema(hlc3, channel)
    diff = hlc3 - ema_hlc3
    abs_diff = np.abs(diff)

    ema_diff = ema(diff, channel)
    ema_abs_diff = ema(abs_diff, channel)

    ci = np.zeros(n)
    for i in range(n):
        denom = 0.015 * ema_abs_diff[i]
        ci[i] = ema_diff[i] / denom if denom != 0 else 0

    wt1 = ema(ci, average)
    wt2 = np.zeros(n)
    for i in range(3, n):
        wt2[i] = np.mean(wt1[i-3:i+1])

    return wt1, wt2


def calculate_macd(close: np.ndarray, fast: int = 14, slow: int = 28,
                    signal: int = 11) -> Tuple[np.ndarray, np.ndarray, np.ndarray]:
    """MACD with custom parameters. Returns: (macd_line, signal_line, histogram)"""
    n = len(close)

    def ema(data, period):
        result = np.zeros(n)
        mult = 2.0 / (period + 1)
        result[0] = data[0]
        for i in range(1, n):
            result[i] = data[i] * mult + result[i-1] * (1 - mult)
        return result

    ema_fast = ema(close, fast)
    ema_slow = ema(close, slow)
    macd_line = ema_fast - ema_slow
    signal_line = ema(macd_line, signal)
    histogram = macd_line - signal_line

    return macd_line, signal_line, histogram


def calculate_ut_bot(close: np.ndarray, high: np.ndarray, low: np.ndarray,
                      key_value: float = 1.5, atr_period: int = 10) -> Tuple[np.ndarray, np.ndarray]:
    """
    UT Bot Alerts. ATR trailing stop flip signals.
    Returns: (trailing_stop, direction) where direction: 1=buy, -1=sell
    """
    n = len(close)
    atr = calculate_atr(high, low, close, atr_period)

    xATRTrailingStop = np.zeros(n)
    direction = np.zeros(n, dtype=int)

    for i in range(1, n):
        nLoss = key_value * atr[i] if not np.isnan(atr[i]) else 0

        if close[i] > xATRTrailingStop[i-1] and close[i-1] > xATRTrailingStop[i-1]:
            xATRTrailingStop[i] = max(xATRTrailingStop[i-1], close[i] - nLoss)
        elif close[i] < xATRTrailingStop[i-1] and close[i-1] < xATRTrailingStop[i-1]:
            xATRTrailingStop[i] = min(xATRTrailingStop[i-1], close[i] + nLoss)
        elif close[i] > xATRTrailingStop[i-1]:
            xATRTrailingStop[i] = close[i] - nLoss
        else:
            xATRTrailingStop[i] = close[i] + nLoss

        # Direction detection
        if close[i] > xATRTrailingStop[i] and close[i-1] <= xATRTrailingStop[i-1]:
            direction[i] = 1  # Buy flip
        elif close[i] < xATRTrailingStop[i] and close[i-1] >= xATRTrailingStop[i-1]:
            direction[i] = -1  # Sell flip
        else:
            direction[i] = direction[i-1] if i > 0 else 0

    return xATRTrailingStop, direction


def calculate_ema(close: np.ndarray, period: int = 200) -> np.ndarray:
    """Exponential Moving Average"""
    n = len(close)
    result = np.zeros(n)
    mult = 2.0 / (period + 1)
    result[0] = close[0]
    for i in range(1, n):
        result[i] = close[i] * mult + result[i-1] * (1 - mult)
    return result


# ═══════════════════════════════════════════════════════════════
#  DATA LOADING
# ═══════════════════════════════════════════════════════════════

def generate_synthetic_data(symbol: str, timeframe: str, bars: int = 5000) -> pd.DataFrame:
    """Generate realistic synthetic OHLCV data for backtesting when yfinance unavailable."""
    np.random.seed(hash(symbol + timeframe) % 2**31)

    # Base prices by symbol
    base_prices = {
        'GBPUSD': 1.30, 'EURUSD': 1.08, 'USDJPY': 150.0,
        'BTCUSD': 45000, 'US30': 38000
    }
    base = base_prices.get(symbol, 1.30)

    # Volatility by symbol
    vols = {
        'GBPUSD': 0.003, 'EURUSD': 0.003, 'USDJPY': 0.004,
        'BTCUSD': 0.02, 'US30': 0.005
    }
    vol = vols.get(symbol, 0.003)

    # Timeframe multiplier for volatility
    tf_mult = {'M15': 0.5, 'H1': 1.0, 'H4': 2.0}
    vol *= tf_mult.get(timeframe, 1.0)

    # Generate returns with trend + mean reversion + regime changes
    returns = np.random.normal(0, vol, bars)

    # Add trend regimes
    regime_len = bars // 5
    for i in range(0, bars, regime_len):
        trend = np.random.uniform(-0.0005, 0.0005)
        end = min(i + regime_len, bars)
        returns[i:end] += trend

    # Build price series
    close = np.zeros(bars)
    close[0] = base
    for i in range(1, bars):
        close[i] = close[i-1] * (1 + returns[i])

    # Generate OHLC from close
    high = close * (1 + np.abs(np.random.normal(0, vol * 0.5, bars)))
    low = close * (1 - np.abs(np.random.normal(0, vol * 0.5, bars)))
    open_price = np.roll(close, 1)
    open_price[0] = close[0]
    volume = np.random.randint(100, 10000, bars).astype(float)

    # Ensure OHLC consistency
    high = np.maximum(high, np.maximum(open_price, close))
    low = np.minimum(low, np.minimum(open_price, close))

    # Generate dates
    tf_minutes = {'M15': 15, 'H1': 60, 'H4': 240}
    minutes = tf_minutes.get(timeframe, 60)
    dates = pd.date_range(end=datetime.now(), periods=bars, freq=f'{minutes}min')

    df = pd.DataFrame({
        'Open': open_price, 'High': high, 'Low': low,
        'Close': close, 'Volume': volume
    }, index=dates)

    return df


def load_data(symbol: str, timeframe: str, bars: int = 5000) -> pd.DataFrame:
    """Load OHLCV data. Uses yfinance if available, otherwise synthetic."""
    if HAS_YFINANCE:
        yf_map = {
            'GBPUSD': 'GBPUSD=X', 'EURUSD': 'EURUSD=X', 'USDJPY': 'USDJPY=X',
            'BTCUSD': 'BTC-USD', 'US30': '^DJI'
        }
        tf_map = {'M15': '15m', 'H1': '1h', 'H4': '4h'}

        yf_symbol = yf_map.get(symbol, symbol)
        yf_tf = tf_map.get(timeframe, '1h')

        # yfinance limits: 15m=60d, 1h=730d, 4h=730d (via 1h aggregate)
        if timeframe == 'M15':
            period = '60d'
        else:
            period = '2y'

        try:
            df = yf.download(yf_symbol, period=period, interval=yf_tf, progress=False)
            # Flatten MultiIndex columns if present
            if isinstance(df.columns, pd.MultiIndex):
                df.columns = df.columns.get_level_values(0)
            # Drop any duplicate column names
            df = df.loc[:, ~df.columns.duplicated()]
            if len(df) > 100:
                print(f"  Loaded {len(df)} bars from Yahoo Finance for {symbol} {timeframe}")
                return df
        except Exception as e:
            print(f"  yfinance failed for {symbol}: {e}")

    print(f"  Using synthetic data for {symbol} {timeframe} ({bars} bars)")
    return generate_synthetic_data(symbol, timeframe, bars)


# ═══════════════════════════════════════════════════════════════
#  BACKTESTER
# ═══════════════════════════════════════════════════════════════

@dataclass
class Trade:
    entry_time: datetime
    exit_time: Optional[datetime] = None
    direction: int = 0       # 1=long, -1=short
    entry_price: float = 0
    exit_price: float = 0
    sl: float = 0
    tp1: float = 0
    tp2: float = 0
    lots: float = 1.0
    pnl: float = 0
    pnl_pct: float = 0
    tp1_hit: bool = False
    closed: bool = False


@dataclass
class StrategyConfig:
    """Defines which indicators to use and their parameters."""
    name: str = ""

    # Which indicator triggers entry signal
    signal_type: str = "supertrend"   # supertrend, ut_bot, hma, wavetrend

    # Which indicators to use as confluence (list of indicator names)
    confluence: List[str] = field(default_factory=list)

    # Minimum confluence count required
    min_confluence: int = 2

    # SuperTrend params
    st_atr_period: int = 14
    st_multiplier: float = 1.7

    # HMA params
    hma_period: int = 10

    # WaveTrend params
    wt_channel: int = 6
    wt_average: int = 13
    wt_ob: int = 53
    wt_os: int = -53

    # MACD params
    macd_fast: int = 14
    macd_slow: int = 28
    macd_signal: int = 11

    # UT Bot params
    ut_key: float = 1.5
    ut_atr: int = 10

    # EMA params
    ema_period: int = 200

    # Risk management
    sl_atr_mult: float = 1.5
    tp1_atr_mult: float = 2.0
    tp2_atr_mult: float = 4.0
    tp1_close_pct: float = 50.0
    risk_pct: float = 1.5


@dataclass
class BacktestResult:
    strategy_name: str
    symbol: str
    timeframe: str
    total_trades: int = 0
    winning_trades: int = 0
    losing_trades: int = 0
    win_rate: float = 0
    total_pnl_pct: float = 0
    max_drawdown_pct: float = 0
    profit_factor: float = 0
    avg_win_pct: float = 0
    avg_loss_pct: float = 0
    sharpe_ratio: float = 0
    max_consecutive_wins: int = 0
    max_consecutive_losses: int = 0
    score: float = 0  # composite ranking score


def backtest_strategy(df: pd.DataFrame, config: StrategyConfig,
                       symbol: str, timeframe: str) -> BacktestResult:
    """Run a single backtest with the given strategy configuration."""

    close = df['Close'].values.flatten().astype(float)
    high = df['High'].values.flatten().astype(float)
    low = df['Low'].values.flatten().astype(float)
    n = len(close)

    if n < 200:
        return BacktestResult(config.name, symbol, timeframe)

    # ── Calculate all indicators ──
    atr = calculate_atr(high, low, close, config.st_atr_period)
    st_line, st_dir = calculate_supertrend(high, low, close, config.st_atr_period, config.st_multiplier)
    hma_line, hma_trend = calculate_hma(close, config.hma_period)
    wt1, wt2 = calculate_wavetrend(high, low, close, config.wt_channel, config.wt_average)
    macd_line, macd_signal, macd_hist = calculate_macd(close, config.macd_fast, config.macd_slow, config.macd_signal)
    ut_trail, ut_dir = calculate_ut_bot(close, high, low, config.ut_key, config.ut_atr)
    ema200 = calculate_ema(close, config.ema_period)

    # ── Generate signals ──
    trades: List[Trade] = []
    equity_curve = [10000.0]  # Start with $10k
    current_equity = 10000.0
    position: Optional[Trade] = None
    risk_pct = config.risk_pct  # 1.5% default

    warmup = max(config.st_atr_period, config.hma_period, config.macd_slow,
                 config.wt_channel + config.wt_average, config.ema_period) + 10

    for i in range(warmup, n - 1):
        if np.isnan(atr[i]) or atr[i] == 0:
            equity_curve.append(current_equity)
            continue

        # ── Check exit for open position ──
        if position is not None and not position.closed:
            if position.direction == 1:  # Long
                # Check SL
                if low[i] <= position.sl:
                    position.exit_price = position.sl
                    position.exit_time = df.index[i]
                    position.closed = True
                # Check TP1 (partial)
                elif not position.tp1_hit and high[i] >= position.tp1:
                    position.tp1_hit = True
                    # Move SL to breakeven
                    position.sl = position.entry_price
                # Check TP2
                elif high[i] >= position.tp2:
                    position.exit_price = position.tp2
                    position.exit_time = df.index[i]
                    position.closed = True
                # SuperTrend flip exit
                elif st_dir[i] == -1 and st_dir[i-1] == 1:
                    position.exit_price = close[i]
                    position.exit_time = df.index[i]
                    position.closed = True

                # Trailing stop with SuperTrend
                if not position.closed and position.tp1_hit:
                    if st_line[i] > position.sl and st_dir[i] == 1:
                        position.sl = st_line[i]

            else:  # Short
                # Check SL
                if high[i] >= position.sl:
                    position.exit_price = position.sl
                    position.exit_time = df.index[i]
                    position.closed = True
                # Check TP1 (partial)
                elif not position.tp1_hit and low[i] <= position.tp1:
                    position.tp1_hit = True
                    position.sl = position.entry_price
                # Check TP2
                elif low[i] <= position.tp2:
                    position.exit_price = position.tp2
                    position.exit_time = df.index[i]
                    position.closed = True
                # SuperTrend flip exit
                elif st_dir[i] == 1 and st_dir[i-1] == -1:
                    position.exit_price = close[i]
                    position.exit_time = df.index[i]
                    position.closed = True

                # Trailing stop
                if not position.closed and position.tp1_hit:
                    if st_line[i] < position.sl and st_dir[i] == -1:
                        position.sl = st_line[i]

            # Calculate PnL if closed — proper position sizing with compounding
            if position.closed:
                sl_distance = abs(position.entry_price - (position.entry_price - config.sl_atr_mult * atr[i] if position.direction == 1 else position.entry_price + config.sl_atr_mult * atr[i]))
                if sl_distance == 0:
                    sl_distance = atr[i] * config.sl_atr_mult

                # Risk amount = risk_pct of current equity
                risk_amount = current_equity * risk_pct / 100.0

                # Position size in units (how many "lots" based on risk)
                pos_size = risk_amount / sl_distance if sl_distance > 0 else 0

                if position.tp1_hit:
                    # 50% closed at TP1, 50% at exit
                    pnl_tp1 = (position.tp1 - position.entry_price) * position.direction * pos_size * 0.5
                    pnl_rest = (position.exit_price - position.entry_price) * position.direction * pos_size * 0.5
                    raw_pnl = pnl_tp1 + pnl_rest
                else:
                    raw_pnl = (position.exit_price - position.entry_price) * position.direction * pos_size

                position.pnl = raw_pnl
                position.pnl_pct = (raw_pnl / current_equity) * 100
                current_equity += raw_pnl
                current_equity = max(current_equity, 100)  # Floor at $100
                trades.append(position)
                position = None

        # ── Check for new entry (only if no position) ──
        if position is None:
            # Determine primary signal
            buy_signal = False
            sell_signal = False

            if config.signal_type == "supertrend":
                buy_signal = (st_dir[i] == 1 and st_dir[i-1] == -1)
                sell_signal = (st_dir[i] == -1 and st_dir[i-1] == 1)
            elif config.signal_type == "ut_bot":
                buy_signal = (ut_dir[i] == 1 and ut_dir[i-1] != 1)
                sell_signal = (ut_dir[i] == -1 and ut_dir[i-1] != -1)
            elif config.signal_type == "hma":
                buy_signal = (hma_trend[i] == 1 and hma_trend[i-1] == -1)
                sell_signal = (hma_trend[i] == -1 and hma_trend[i-1] == 1)
            elif config.signal_type == "wavetrend":
                buy_signal = (wt1[i] > wt2[i] and wt1[i-1] <= wt2[i-1])
                sell_signal = (wt1[i] < wt2[i] and wt1[i-1] >= wt2[i-1])
            elif config.signal_type == "macd":
                buy_signal = (macd_hist[i] > 0 and macd_hist[i-1] <= 0)
                sell_signal = (macd_hist[i] < 0 and macd_hist[i-1] >= 0)

            if buy_signal or sell_signal:
                # Count confluence
                confluence_count = 0

                for conf in config.confluence:
                    if conf == "supertrend":
                        if buy_signal and st_dir[i] == 1: confluence_count += 1
                        if sell_signal and st_dir[i] == -1: confluence_count += 1
                    elif conf == "hma":
                        if buy_signal and hma_trend[i] == 1: confluence_count += 1
                        if sell_signal and hma_trend[i] == -1: confluence_count += 1
                    elif conf == "wavetrend":
                        if buy_signal and wt1[i] < config.wt_ob and wt1[i] > wt2[i]: confluence_count += 1
                        if sell_signal and wt1[i] > config.wt_os and wt1[i] < wt2[i]: confluence_count += 1
                    elif conf == "macd":
                        if buy_signal and (macd_hist[i] > 0 or macd_hist[i] > macd_hist[i-1]): confluence_count += 1
                        if sell_signal and (macd_hist[i] < 0 or macd_hist[i] < macd_hist[i-1]): confluence_count += 1
                    elif conf == "ut_bot":
                        if buy_signal and ut_dir[i] == 1: confluence_count += 1
                        if sell_signal and ut_dir[i] == -1: confluence_count += 1
                    elif conf == "ema200":
                        if buy_signal and close[i] > ema200[i]: confluence_count += 1
                        if sell_signal and close[i] < ema200[i]: confluence_count += 1

                # Check if enough confluence
                if confluence_count >= config.min_confluence:
                    direction = 1 if buy_signal else -1
                    entry_price = close[i]
                    atr_val = atr[i]

                    if direction == 1:
                        sl = entry_price - config.sl_atr_mult * atr_val
                        tp1 = entry_price + config.tp1_atr_mult * atr_val
                        tp2 = entry_price + config.tp2_atr_mult * atr_val
                    else:
                        sl = entry_price + config.sl_atr_mult * atr_val
                        tp1 = entry_price - config.tp1_atr_mult * atr_val
                        tp2 = entry_price - config.tp2_atr_mult * atr_val

                    position = Trade(
                        entry_time=df.index[i],
                        direction=direction,
                        entry_price=entry_price,
                        sl=sl, tp1=tp1, tp2=tp2
                    )

        equity_curve.append(current_equity)

    # ── Calculate results ──
    result = BacktestResult(config.name, symbol, timeframe)
    result.total_trades = len(trades)

    if len(trades) == 0:
        return result

    pnls = [t.pnl_pct for t in trades]
    wins = [p for p in pnls if p > 0]
    losses = [p for p in pnls if p <= 0]

    result.winning_trades = len(wins)
    result.losing_trades = len(losses)
    result.win_rate = len(wins) / len(trades) * 100 if trades else 0
    result.total_pnl_pct = ((current_equity - 10000) / 10000) * 100
    result.avg_win_pct = np.mean(wins) if wins else 0
    result.avg_loss_pct = np.mean(losses) if losses else 0

    # Profit factor
    gross_profit = sum(wins)
    gross_loss = abs(sum(losses)) if losses else 0.001
    result.profit_factor = gross_profit / gross_loss if gross_loss > 0 else gross_profit

    # Max drawdown
    equity = np.array(equity_curve)
    peak = np.maximum.accumulate(equity)
    drawdown = (peak - equity) / peak * 100
    result.max_drawdown_pct = np.max(drawdown) if len(drawdown) > 0 else 0

    # Sharpe ratio (annualized)
    if len(pnls) > 1:
        result.sharpe_ratio = np.mean(pnls) / np.std(pnls) * np.sqrt(252) if np.std(pnls) > 0 else 0
    else:
        result.sharpe_ratio = 0

    # Consecutive wins/losses
    max_consec_w = max_consec_l = consec_w = consec_l = 0
    for p in pnls:
        if p > 0:
            consec_w += 1
            consec_l = 0
            max_consec_w = max(max_consec_w, consec_w)
        else:
            consec_l += 1
            consec_w = 0
            max_consec_l = max(max_consec_l, consec_l)
    result.max_consecutive_wins = max_consec_w
    result.max_consecutive_losses = max_consec_l

    # Composite score: weighted ranking
    result.score = (
        result.win_rate * 0.25 +
        result.total_pnl_pct * 0.30 +
        result.profit_factor * 10 * 0.20 +
        result.sharpe_ratio * 5 * 0.15 -
        result.max_drawdown_pct * 0.10
    )

    return result


# ═══════════════════════════════════════════════════════════════
#  STRATEGY COMBINATION GENERATOR
# ═══════════════════════════════════════════════════════════════

def generate_strategy_combinations() -> List[StrategyConfig]:
    """Generate all meaningful combinations of indicators and parameters."""
    strategies = []

    # Primary signal options
    signal_types = ["supertrend", "ut_bot", "hma", "wavetrend", "macd"]

    # Confluence options (each signal can use other indicators as confluence)
    all_confluences = ["supertrend", "hma", "wavetrend", "macd", "ut_bot", "ema200"]

    # Parameter variations
    st_params = [
        (14, 1.7),   # Default from chart
        (14, 2.0),   # Wider
        (10, 1.5),   # Faster, tighter
        (14, 3.0),   # Very wide (trend only)
    ]

    hma_params = [10, 15, 21]

    wt_params = [
        (6, 13, 53, -53),    # From chart
        (10, 21, 60, -60),   # Standard
    ]

    macd_params = [
        (14, 28, 11),   # From chart
        (12, 26, 9),    # Standard
    ]

    ut_params = [
        (1.5, 10),   # From chart
        (2.0, 14),   # Wider
        (1.0, 7),    # Faster
    ]

    sl_tp_params = [
        (1.5, 2.0, 4.0),   # Default
        (1.0, 1.5, 3.0),   # Tighter
        (2.0, 3.0, 6.0),   # Wider
    ]

    combo_id = 0

    for signal in signal_types:
        # Get available confluences (exclude the signal indicator itself)
        available_confs = [c for c in all_confluences if c != signal]

        # Test different confluence combinations (1 to 3 confluences)
        for conf_count in range(1, min(4, len(available_confs) + 1)):
            for conf_combo in itertools.combinations(available_confs, conf_count):
                conf_list = list(conf_combo)

                # Test with different parameter sets (limit combinations to keep manageable)
                for st_p in st_params[:2]:  # Top 2 ST params
                    for hma_p in hma_params[:2]:
                        for wt_p in wt_params[:1]:
                            for macd_p in macd_params[:1]:
                                for ut_p in ut_params[:2]:
                                    for sl_tp in sl_tp_params[:2]:
                                        combo_id += 1
                                        name = f"{signal}+{'_'.join(conf_list)}|ST{st_p[1]}|HMA{hma_p}|SL{sl_tp[0]}"

                                        config = StrategyConfig(
                                            name=name,
                                            signal_type=signal,
                                            confluence=conf_list,
                                            min_confluence=max(1, conf_count - 1),
                                            st_atr_period=st_p[0],
                                            st_multiplier=st_p[1],
                                            hma_period=hma_p,
                                            wt_channel=wt_p[0],
                                            wt_average=wt_p[1],
                                            wt_ob=wt_p[2],
                                            wt_os=wt_p[3],
                                            macd_fast=macd_p[0],
                                            macd_slow=macd_p[1],
                                            macd_signal=macd_p[2],
                                            ut_key=ut_p[0],
                                            ut_atr=ut_p[1],
                                            sl_atr_mult=sl_tp[0],
                                            tp1_atr_mult=sl_tp[1],
                                            tp2_atr_mult=sl_tp[2],
                                        )
                                        strategies.append(config)

    print(f"Generated {len(strategies)} strategy combinations")
    return strategies


def generate_key_strategies() -> List[StrategyConfig]:
    """Generate a focused set of high-probability strategy combinations (faster)."""
    strategies = []

    # ── TOP COMBINATIONS based on chart analysis ──

    configs = [
        # SuperTrend as signal, different confluences
        ("ST+HMA+WT+MACD_default",      "supertrend", ["hma", "wavetrend", "macd"],   2, 14, 1.7, 10, 1.5, 2.0, 4.0),
        ("ST+HMA+WT+MACD_tight",        "supertrend", ["hma", "wavetrend", "macd"],   2, 14, 1.7, 10, 1.0, 1.5, 3.0),
        ("ST+HMA+WT+MACD_wide",         "supertrend", ["hma", "wavetrend", "macd"],   2, 14, 1.7, 10, 2.0, 3.0, 6.0),
        ("ST+HMA+WT_only",              "supertrend", ["hma", "wavetrend"],            1, 14, 1.7, 10, 1.5, 2.0, 4.0),
        ("ST+HMA+MACD_only",            "supertrend", ["hma", "macd"],                 1, 14, 1.7, 10, 1.5, 2.0, 4.0),
        ("ST+WT+MACD_only",             "supertrend", ["wavetrend", "macd"],           1, 14, 1.7, 10, 1.5, 2.0, 4.0),
        ("ST+EMA200+HMA",               "supertrend", ["ema200", "hma"],               1, 14, 1.7, 10, 1.5, 2.0, 4.0),
        ("ST+UT+HMA",                   "supertrend", ["ut_bot", "hma"],               1, 14, 1.7, 10, 1.5, 2.0, 4.0),

        # SuperTrend with different multipliers
        ("ST2.0+HMA+WT+MACD",           "supertrend", ["hma", "wavetrend", "macd"],   2, 14, 2.0, 10, 1.5, 2.0, 4.0),
        ("ST3.0+HMA+WT+MACD",           "supertrend", ["hma", "wavetrend", "macd"],   2, 14, 3.0, 10, 1.5, 2.0, 4.0),
        ("ST1.5+HMA+WT+MACD",           "supertrend", ["hma", "wavetrend", "macd"],   2, 14, 1.5, 10, 1.5, 2.0, 4.0),

        # UT Bot as signal
        ("UT+HMA+WT+MACD_default",      "ut_bot",     ["hma", "wavetrend", "macd"],   2, 14, 1.7, 10, 1.5, 2.0, 4.0),
        ("UT+ST+HMA+MACD",              "ut_bot",     ["supertrend", "hma", "macd"],   2, 14, 1.7, 10, 1.5, 2.0, 4.0),
        ("UT+ST+WT",                    "ut_bot",     ["supertrend", "wavetrend"],      1, 14, 1.7, 10, 1.5, 2.0, 4.0),
        ("UT+EMA200+MACD",              "ut_bot",     ["ema200", "macd"],               1, 14, 1.7, 10, 1.5, 2.0, 4.0),
        ("UT_fast+ST+HMA",              "ut_bot",     ["supertrend", "hma"],            1, 14, 1.7, 10, 1.0, 1.5, 3.0),

        # HMA as signal
        ("HMA+ST+WT+MACD",              "hma",        ["supertrend", "wavetrend", "macd"], 2, 14, 1.7, 10, 1.5, 2.0, 4.0),
        ("HMA+ST+MACD",                 "hma",        ["supertrend", "macd"],              1, 14, 1.7, 10, 1.5, 2.0, 4.0),
        ("HMA+UT+WT",                   "hma",        ["ut_bot", "wavetrend"],             1, 14, 1.7, 10, 1.5, 2.0, 4.0),
        ("HMA21+ST+WT+MACD",            "hma",        ["supertrend", "wavetrend", "macd"], 2, 14, 1.7, 21, 1.5, 2.0, 4.0),

        # WaveTrend as signal
        ("WT+ST+HMA+MACD",              "wavetrend",  ["supertrend", "hma", "macd"],   2, 14, 1.7, 10, 1.5, 2.0, 4.0),
        ("WT+ST+HMA",                   "wavetrend",  ["supertrend", "hma"],            1, 14, 1.7, 10, 1.5, 2.0, 4.0),
        ("WT+EMA200+MACD",              "wavetrend",  ["ema200", "macd"],               1, 14, 1.7, 10, 1.5, 2.0, 4.0),

        # MACD as signal
        ("MACD+ST+HMA+WT",              "macd",       ["supertrend", "hma", "wavetrend"], 2, 14, 1.7, 10, 1.5, 2.0, 4.0),
        ("MACD+ST+HMA",                 "macd",       ["supertrend", "hma"],              1, 14, 1.7, 10, 1.5, 2.0, 4.0),
        ("MACD+UT+WT",                  "macd",       ["ut_bot", "wavetrend"],             1, 14, 1.7, 10, 1.5, 2.0, 4.0),

        # Aggressive: fewer confluences, tighter TP
        ("ST_solo+HMA_tight",           "supertrend", ["hma"],                          1, 14, 1.7, 10, 1.0, 1.5, 3.0),
        ("UT_solo+ST_tight",            "ut_bot",     ["supertrend"],                    1, 14, 1.7, 10, 1.0, 1.5, 3.0),

        # Conservative: all confluences required
        ("ST+ALL_conservative",          "supertrend", ["hma", "wavetrend", "macd", "ema200"], 3, 14, 1.7, 10, 2.0, 3.0, 6.0),
        ("UT+ALL_conservative",          "ut_bot",     ["supertrend", "hma", "wavetrend", "macd"], 3, 14, 1.7, 10, 2.0, 3.0, 6.0),
    ]

    for cfg in configs:
        name, sig, confs, min_conf, atr_p, st_mult, hma_p, sl_m, tp1_m, tp2_m = cfg
        strategies.append(StrategyConfig(
            name=name,
            signal_type=sig,
            confluence=confs,
            min_confluence=min_conf,
            st_atr_period=atr_p,
            st_multiplier=st_mult,
            hma_period=hma_p,
            sl_atr_mult=sl_m,
            tp1_atr_mult=tp1_m,
            tp2_atr_mult=tp2_m,
        ))

    print(f"Generated {len(strategies)} key strategy combinations")
    return strategies


# ═══════════════════════════════════════════════════════════════
#  MAIN EXECUTION
# ═══════════════════════════════════════════════════════════════

def main():
    print("=" * 80)
    print("  MULTI-CONFLUENCE STRATEGY BACKTESTER")
    print("  Testing ALL indicator combinations from TradingView chart")
    print("=" * 80)

    # Markets and timeframes to test
    symbols = ['GBPUSD', 'EURUSD', 'USDJPY', 'BTCUSD', 'US30']
    timeframes = ['M15', 'H1', 'H4']

    # Generate strategies
    strategies = generate_key_strategies()

    # Load all data first
    print("\n── Loading Market Data ──")
    data_cache = {}
    for symbol in symbols:
        for tf in timeframes:
            key = f"{symbol}_{tf}"
            print(f"Loading {symbol} {tf}...")
            data_cache[key] = load_data(symbol, tf)

    # Run all backtests
    print("\n── Running Backtests ──")
    all_results: List[BacktestResult] = []
    total_tests = len(strategies) * len(symbols) * len(timeframes)
    test_num = 0

    for config in strategies:
        for symbol in symbols:
            for tf in timeframes:
                test_num += 1
                key = f"{symbol}_{tf}"
                df = data_cache[key]

                if len(df) < 200:
                    continue

                result = backtest_strategy(df, config, symbol, tf)
                all_results.append(result)

                if test_num % 100 == 0:
                    print(f"  Progress: {test_num}/{total_tests} ({test_num/total_tests*100:.0f}%)")

    print(f"\nCompleted {len(all_results)} backtests")

    # Filter results with trades
    results_with_trades = [r for r in all_results if r.total_trades >= 10]
    print(f"Results with 10+ trades: {len(results_with_trades)}")

    if not results_with_trades:
        print("No strategies produced enough trades. Try adjusting parameters.")
        return

    # ── RANK BY COMPOSITE SCORE ──
    results_with_trades.sort(key=lambda r: r.score, reverse=True)

    # ── REPORT: TOP 20 INDIVIDUAL RESULTS ──
    print("\n" + "=" * 120)
    print("  TOP 20 INDIVIDUAL BACKTEST RESULTS (sorted by composite score)")
    print("=" * 120)
    print(f"{'Rank':<5} {'Strategy':<40} {'Symbol':<8} {'TF':<5} {'Trades':<7} {'WinRate':<8} {'PnL%':<10} {'PF':<6} {'MaxDD%':<8} {'Sharpe':<8} {'Score':<8}")
    print("-" * 120)

    for i, r in enumerate(results_with_trades[:20]):
        print(f"{i+1:<5} {r.strategy_name[:39]:<40} {r.symbol:<8} {r.timeframe:<5} {r.total_trades:<7} "
              f"{r.win_rate:<7.1f}% {r.total_pnl_pct:<9.1f}% {r.profit_factor:<5.2f} "
              f"{r.max_drawdown_pct:<7.1f}% {r.sharpe_ratio:<7.2f} {r.score:<7.1f}")

    # ── AGGREGATE BY STRATEGY (across all symbols/timeframes) ──
    print("\n" + "=" * 120)
    print("  TOP 15 STRATEGIES AGGREGATED ACROSS ALL MARKETS & TIMEFRAMES")
    print("=" * 120)

    strategy_agg = {}
    for r in results_with_trades:
        if r.strategy_name not in strategy_agg:
            strategy_agg[r.strategy_name] = {
                'results': [],
                'avg_win_rate': 0,
                'avg_pnl': 0,
                'avg_pf': 0,
                'avg_dd': 0,
                'avg_sharpe': 0,
                'total_trades': 0,
                'markets_profitable': 0,
                'avg_score': 0,
            }
        strategy_agg[r.strategy_name]['results'].append(r)

    for name, data in strategy_agg.items():
        results = data['results']
        n = len(results)
        if n == 0:
            continue
        data['avg_win_rate'] = np.mean([r.win_rate for r in results])
        data['avg_pnl'] = np.mean([r.total_pnl_pct for r in results])
        data['avg_pf'] = np.mean([r.profit_factor for r in results])
        data['avg_dd'] = np.mean([r.max_drawdown_pct for r in results])
        data['avg_sharpe'] = np.mean([r.sharpe_ratio for r in results])
        data['total_trades'] = sum([r.total_trades for r in results])
        data['markets_profitable'] = sum([1 for r in results if r.total_pnl_pct > 0])
        data['avg_score'] = np.mean([r.score for r in results])

    # Sort by avg_score
    sorted_strats = sorted(strategy_agg.items(), key=lambda x: x[1]['avg_score'], reverse=True)

    print(f"{'Rank':<5} {'Strategy':<40} {'Tests':<6} {'Profitable':<11} {'AvgWR%':<8} {'AvgPnL%':<10} {'AvgPF':<7} {'AvgDD%':<8} {'AvgSharpe':<10} {'Score':<8}")
    print("-" * 120)

    for i, (name, data) in enumerate(sorted_strats[:15]):
        n = len(data['results'])
        print(f"{i+1:<5} {name[:39]:<40} {n:<6} {data['markets_profitable']}/{n:<8} "
              f"{data['avg_win_rate']:<7.1f}% {data['avg_pnl']:<9.1f}% {data['avg_pf']:<6.2f} "
              f"{data['avg_dd']:<7.1f}% {data['avg_sharpe']:<9.2f} {data['avg_score']:<7.1f}")

    # ── BEST PER MARKET ──
    print("\n" + "=" * 120)
    print("  BEST STRATEGY PER MARKET")
    print("=" * 120)

    for symbol in symbols:
        symbol_results = [r for r in results_with_trades if r.symbol == symbol]
        if symbol_results:
            best = max(symbol_results, key=lambda r: r.score)
            print(f"\n  {symbol}:")
            print(f"    Strategy:  {best.strategy_name}")
            print(f"    Timeframe: {best.timeframe}")
            print(f"    Win Rate:  {best.win_rate:.1f}%")
            print(f"    PnL:       {best.total_pnl_pct:.1f}%")
            print(f"    PF:        {best.profit_factor:.2f}")
            print(f"    Max DD:    {best.max_drawdown_pct:.1f}%")
            print(f"    Trades:    {best.total_trades}")

    # ── BEST PER TIMEFRAME ──
    print("\n" + "=" * 120)
    print("  BEST STRATEGY PER TIMEFRAME")
    print("=" * 120)

    for tf in timeframes:
        tf_results = [r for r in results_with_trades if r.timeframe == tf]
        if tf_results:
            best = max(tf_results, key=lambda r: r.score)
            print(f"\n  {tf}:")
            print(f"    Strategy:  {best.strategy_name}")
            print(f"    Symbol:    {best.symbol}")
            print(f"    Win Rate:  {best.win_rate:.1f}%")
            print(f"    PnL:       {best.total_pnl_pct:.1f}%")
            print(f"    PF:        {best.profit_factor:.2f}")

    # ── SAVE RESULTS TO CSV ──
    results_df = pd.DataFrame([{
        'Strategy': r.strategy_name,
        'Symbol': r.symbol,
        'Timeframe': r.timeframe,
        'Trades': r.total_trades,
        'Win_Rate': round(r.win_rate, 2),
        'PnL_Pct': round(r.total_pnl_pct, 2),
        'Profit_Factor': round(r.profit_factor, 2),
        'Max_Drawdown': round(r.max_drawdown_pct, 2),
        'Sharpe_Ratio': round(r.sharpe_ratio, 2),
        'Avg_Win': round(r.avg_win_pct, 2),
        'Avg_Loss': round(r.avg_loss_pct, 2),
        'Max_Consec_Wins': r.max_consecutive_wins,
        'Max_Consec_Losses': r.max_consecutive_losses,
        'Score': round(r.score, 2),
    } for r in results_with_trades])

    csv_path = os.path.join(os.path.dirname(__file__), 'strategy_backtest_results.csv')
    results_df.to_csv(csv_path, index=False)
    print(f"\n{'=' * 80}")
    print(f"  Results saved to: {csv_path}")
    print(f"  Total results: {len(results_df)}")

    # ── SAVE WINNING CONFIG AS JSON ──
    if sorted_strats:
        winner_name, winner_data = sorted_strats[0]
        # Find the config
        winner_config = None
        for s in strategies:
            if s.name == winner_name:
                winner_config = s
                break

        if winner_config:
            config_dict = {
                'strategy_name': winner_config.name,
                'signal_type': winner_config.signal_type,
                'confluence': winner_config.confluence,
                'min_confluence': winner_config.min_confluence,
                'supertrend_atr_period': winner_config.st_atr_period,
                'supertrend_multiplier': winner_config.st_multiplier,
                'hma_period': winner_config.hma_period,
                'wavetrend_channel': winner_config.wt_channel,
                'wavetrend_average': winner_config.wt_average,
                'wavetrend_ob': winner_config.wt_ob,
                'wavetrend_os': winner_config.wt_os,
                'macd_fast': winner_config.macd_fast,
                'macd_slow': winner_config.macd_slow,
                'macd_signal': winner_config.macd_signal,
                'ut_key_value': winner_config.ut_key,
                'ut_atr_period': winner_config.ut_atr,
                'sl_atr_multiplier': winner_config.sl_atr_mult,
                'tp1_atr_multiplier': winner_config.tp1_atr_mult,
                'tp2_atr_multiplier': winner_config.tp2_atr_mult,
                'performance': {
                    'avg_win_rate': round(winner_data['avg_win_rate'], 2),
                    'avg_pnl_pct': round(winner_data['avg_pnl'], 2),
                    'avg_profit_factor': round(winner_data['avg_pf'], 2),
                    'avg_max_drawdown': round(winner_data['avg_dd'], 2),
                    'avg_sharpe': round(winner_data['avg_sharpe'], 2),
                    'markets_profitable': winner_data['markets_profitable'],
                    'total_trades': winner_data['total_trades'],
                }
            }
            json_path = os.path.join(os.path.dirname(__file__), 'winning_strategy_config.json')
            with open(json_path, 'w') as f:
                json.dump(config_dict, f, indent=2)
            print(f"  Winning config saved to: {json_path}")

    print(f"\n{'=' * 80}")
    print(f"  WINNER: {sorted_strats[0][0] if sorted_strats else 'N/A'}")
    print(f"  Score: {sorted_strats[0][1]['avg_score']:.1f}" if sorted_strats else "")
    print(f"{'=' * 80}")


if __name__ == "__main__":
    main()
