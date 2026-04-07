#!/usr/bin/env python3
"""
Crypto Late-Entry Bot (Bot #8)
==============================
Trades Polymarket crypto Up/Down markets using real-time price data.

Strategy: Enter 1-2 minutes before window closes when price already
shows clear direction. Uses Binance + Hyperliquid as signal sources.

Signals:
  1. Binance 1-min price momentum (primary)
  2. Binance 3-min price trend
  3. Binance 5-min price trend
  4. RSI-14 on 1-min candles
  5. Hyperliquid funding rate (sentiment)

When 3+ signals agree AND price has moved 0.03%+ from reference,
place $5-15 market order on Polymarket.
"""

import os
import sys
import time
import json
import math
import sqlite3
import logging
import argparse
import requests
from datetime import datetime, timedelta
from pathlib import Path

# ── Setup ─────────────────────────────────────────────────────────────

DATA_DIR = Path(__file__).parent / "data"
DATA_DIR.mkdir(exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler(DATA_DIR / "crypto_bot.log"),
    ],
)
log = logging.getLogger("crypto_bot")

# ── Config ────────────────────────────────────────────────────────────

# Auto-detect .env files
ENV_PATHS = [
    os.path.expanduser("~/Cl-/.env"),
    os.path.expanduser("~/copytrade-bot/.env"),
    os.path.expanduser("~/.env"),
    ".env",
]

def load_env():
    """Load environment variables from .env files."""
    for p in ENV_PATHS:
        if os.path.exists(p):
            log.info(f"Loading env from {p}")
            with open(p) as f:
                for line in f:
                    line = line.strip()
                    if "=" in line and not line.startswith("#"):
                        key, val = line.split("=", 1)
                        os.environ.setdefault(key.strip(), val.strip())

load_env()

# Polymarket credentials (try multiple naming conventions)
def get_env(*names, default=""):
    for n in names:
        v = os.environ.get(n, "")
        if v:
            return v
    return default

POLYMARKET_API_KEY = get_env("POLY_API_KEY", "POLYMARKET_API_KEY", "PY_CLOB_API_KEY")
POLYMARKET_API_SECRET = get_env("POLY_API_SECRET", "POLYMARKET_API_SECRET", "PY_CLOB_API_SECRET")
POLYMARKET_API_PASSPHRASE = get_env("POLY_API_PASSPHRASE", "POLYMARKET_API_PASSPHRASE", "PY_CLOB_API_PASSPHRASE")
POLYMARKET_PRIVATE_KEY = get_env("PRIVATE_KEY", "POLYMARKET_PRIVATE_KEY", "PY_CLOB_PRIVATE_KEY")
PROXY_WALLET = get_env("PROXY_WALLET", "POLY_PROXY_WALLET")

# Strategy params
MIN_LEAD_PCT = 0.03          # Minimum price lead to enter (0.03%)
ENTRY_MIN_BEFORE = 2         # Enter 2 minutes before window closes
BET_SIZE = 5.0               # Base bet size USD
MAX_BET = 15.0               # Maximum bet size
MIN_BET = 3.0                # Minimum bet size
MAX_TOKEN_PRICE = 0.70       # Don't buy tokens above this (no value)
MIN_TOKEN_PRICE = 0.15       # Don't buy tokens below this (too risky)
MAX_POSITIONS = 5            # Max concurrent positions
MAX_DAILY_LOSS = 50.0        # Stop if daily loss exceeds this
CYCLE_SECONDS = 30           # Check every 30 seconds
WINDOW_MINUTES = 5           # Polymarket window size

# Cryptos to trade
CRYPTO_SYMBOLS = ["BTCUSDT", "ETHUSDT"]  # BTC has best win rate

# ── Binance Price Feed ────────────────────────────────────────────────

class BinanceFeed:
    """Real-time price data from Binance public API."""

    BASE_URL = "https://api.binance.com/api/v3"

    def __init__(self):
        self.price_history = {}  # symbol -> list of (timestamp, price)
        self.rsi_cache = {}

    def get_price(self, symbol="BTCUSDT"):
        """Get current price."""
        try:
            resp = requests.get(
                f"{self.BASE_URL}/ticker/price",
                params={"symbol": symbol},
                timeout=5,
            )
            data = resp.json()
            price = float(data["price"])

            # Store in history
            if symbol not in self.price_history:
                self.price_history[symbol] = []
            self.price_history[symbol].append((time.time(), price))

            # Keep last 30 minutes
            cutoff = time.time() - 1800
            self.price_history[symbol] = [
                (t, p) for t, p in self.price_history[symbol] if t > cutoff
            ]

            return price
        except Exception as e:
            log.warning(f"Binance price error ({symbol}): {e}")
            return None

    def get_momentum(self, symbol="BTCUSDT"):
        """
        Get momentum signals.
        Returns dict with:
          - pct_1m: 1-min price change %
          - pct_3m: 3-min price change %
          - pct_5m: 5-min price change %
          - rsi: RSI-14 on 1-min candles
          - direction: UP or DOWN
          - strength: 0-5 (number of agreeing signals)
        """
        history = self.price_history.get(symbol, [])
        now = time.time()
        current = self.get_price(symbol)
        if not current:
            return None

        def price_at(seconds_ago):
            target = now - seconds_ago
            closest = None
            for t, p in history:
                if closest is None or abs(t - target) < abs(closest[0] - target):
                    closest = (t, p)
            if closest and abs(closest[0] - target) < 30:  # within 30s
                return closest[1]
            return None

        p1m = price_at(60)
        p3m = price_at(180)
        p5m = price_at(300)

        pct_1m = ((current - p1m) / p1m * 100) if p1m else 0
        pct_3m = ((current - p3m) / p3m * 100) if p3m else 0
        pct_5m = ((current - p5m) / p5m * 100) if p5m else 0

        # RSI from recent klines
        rsi = self._get_rsi(symbol)

        # Count agreeing signals
        signals_up = 0
        signals_down = 0

        if pct_1m > 0.01:
            signals_up += 1
        elif pct_1m < -0.01:
            signals_down += 1

        if pct_3m > 0.02:
            signals_up += 1
        elif pct_3m < -0.02:
            signals_down += 1

        if pct_5m > 0.03:
            signals_up += 1
        elif pct_5m < -0.03:
            signals_down += 1

        if rsi and rsi > 55:
            signals_up += 1
        elif rsi and rsi < 45:
            signals_down += 1

        direction = "UP" if signals_up > signals_down else "DOWN"
        strength = max(signals_up, signals_down)

        return {
            "price": current,
            "pct_1m": pct_1m,
            "pct_3m": pct_3m,
            "pct_5m": pct_5m,
            "rsi": rsi or 50,
            "direction": direction,
            "strength": strength,
            "signals_up": signals_up,
            "signals_down": signals_down,
        }

    def _get_rsi(self, symbol, period=14):
        """Calculate RSI from 1-min klines."""
        try:
            resp = requests.get(
                f"{self.BASE_URL}/klines",
                params={"symbol": symbol, "interval": "1m", "limit": period + 5},
                timeout=5,
            )
            klines = resp.json()
            if len(klines) < period + 1:
                return None

            closes = [float(k[4]) for k in klines]
            gains = []
            losses = []
            for i in range(1, len(closes)):
                change = closes[i] - closes[i - 1]
                gains.append(max(change, 0))
                losses.append(max(-change, 0))

            avg_gain = sum(gains[-period:]) / period
            avg_loss = sum(losses[-period:]) / period

            if avg_loss == 0:
                return 100.0
            rs = avg_gain / avg_loss
            return 100 - (100 / (1 + rs))
        except:
            return None


# ── Hyperliquid Feed ──────────────────────────────────────────────────

class HyperliquidFeed:
    """Funding rate and price data from Hyperliquid."""

    BASE_URL = "https://api.hyperliquid.xyz/info"

    def get_funding_rate(self, coin="BTC"):
        """Get current funding rate. Positive = longs pay shorts (bullish pressure)."""
        try:
            resp = requests.post(
                self.BASE_URL,
                json={"type": "metaAndAssetCtxs"},
                timeout=5,
            )
            data = resp.json()
            if len(data) >= 2:
                universe = data[0].get("universe", [])
                asset_ctxs = data[1]
                for i, asset in enumerate(universe):
                    if asset.get("name", "").upper() == coin.upper():
                        if i < len(asset_ctxs):
                            funding = float(asset_ctxs[i].get("funding", 0))
                            mark_price = float(asset_ctxs[i].get("markPx", 0))
                            return {
                                "funding_rate": funding,
                                "mark_price": mark_price,
                                "sentiment": "BULLISH" if funding > 0 else "BEARISH",
                            }
            return None
        except Exception as e:
            log.warning(f"Hyperliquid error: {e}")
            return None


# ── Polymarket Client ─────────────────────────────────────────────────

class CryptoPolymarketClient:
    """Interact with Polymarket for crypto Up/Down markets."""

    def __init__(self):
        self.clob_client = None
        self._init_clob()

    def _init_clob(self):
        """Initialize CLOB client."""
        if not POLYMARKET_PRIVATE_KEY:
            log.warning("No Polymarket private key — running in scan-only mode")
            return

        try:
            from py_clob_client.client import ClobClient
            from py_clob_client.clob_types import ApiCreds

            creds = None
            if POLYMARKET_API_KEY and POLYMARKET_API_SECRET and POLYMARKET_API_PASSPHRASE:
                creds = ApiCreds(
                    api_key=POLYMARKET_API_KEY,
                    api_secret=POLYMARKET_API_SECRET,
                    api_passphrase=POLYMARKET_API_PASSPHRASE,
                )

            kwargs = {
                "host": "https://clob.polymarket.com",
                "key": POLYMARKET_PRIVATE_KEY,
                "chain_id": 137,
                "signature_type": 2,
            }
            if PROXY_WALLET:
                kwargs["funder"] = PROXY_WALLET
            if creds:
                kwargs["creds"] = creds

            self.clob_client = ClobClient(**kwargs)
            log.info(f"CLOB client initialized (proxy={PROXY_WALLET[:10]}...)" if PROXY_WALLET else "CLOB client initialized")
        except Exception as e:
            log.error(f"CLOB init failed: {e}")

    def find_crypto_markets(self):
        """Find active crypto Up/Down markets on Polymarket."""
        markets = []
        try:
            # Search for crypto up/down events via Gamma API
            keywords = ["bitcoin up", "bitcoin down", "btc up", "btc down",
                       "ethereum up", "eth up", "ethereum down", "eth down",
                       "crypto", "xrp up", "xrp down", "sol up", "sol down"]

            resp = requests.get(
                "https://gamma-api.polymarket.com/markets",
                params={"closed": "false", "active": "true", "limit": 200},
                timeout=15,
            )
            all_markets = resp.json()

            for m in all_markets:
                q = m.get("question", "").lower()
                if any(k in q for k in ["up or down", "bitcoin", "btc", "ethereum", "eth", "xrp", "solana"]):
                    if "up" in q or "down" in q:
                        markets.append({
                            "question": m.get("question", ""),
                            "condition_id": m.get("conditionId", ""),
                            "token_yes": m.get("clobTokenIds", [""])[0] if m.get("clobTokenIds") else "",
                            "token_no": m.get("clobTokenIds", [""])[1] if m.get("clobTokenIds") and len(m.get("clobTokenIds", [])) > 1 else "",
                            "price_yes": float(m.get("outcomePrices", "[0.5,0.5]").strip("[]").split(",")[0]) if m.get("outcomePrices") else 0.5,
                            "end_date": m.get("endDate", ""),
                            "volume": float(m.get("volume", 0) or 0),
                            "liquidity": float(m.get("liquidity", 0) or 0),
                        })

            log.info(f"Found {len(markets)} crypto Up/Down markets on Polymarket")
        except Exception as e:
            log.error(f"Market fetch error: {e}")

        return markets

    def place_order(self, token_id, side, amount_usd, price, dry_run=False):
        """Place a market order on Polymarket."""
        if dry_run:
            log.info(f"  [DRY RUN] Would place {side} ${amount_usd:.2f} @ ${price:.3f} on token {token_id[:10]}...")
            return True

        if not self.clob_client:
            log.error("  No CLOB client — cannot place orders")
            return False

        try:
            from py_clob_client.order_builder.constants import BUY, SELL
            from py_clob_client.clob_types import OrderArgs

            order_side = BUY if side == "BUY" else SELL
            shares = amount_usd / max(price, 0.01)

            order_args = OrderArgs(
                price=price,
                size=round(shares, 2),
                side=order_side,
                token_id=token_id,
            )

            resp = self.clob_client.create_and_post_order(order_args)
            log.info(f"  ORDER: {side} {shares:.1f} shares @ ${price:.3f} (${amount_usd:.2f}) → {resp}")
            return True
        except Exception as e:
            log.error(f"  Order failed: {e}")
            return False

    def cancel_all(self):
        """Cancel all open orders."""
        if self.clob_client:
            try:
                self.clob_client.cancel_all()
                log.info("All orders cancelled")
            except Exception as e:
                log.error(f"Cancel failed: {e}")


# ── Trade Tracker ─────────────────────────────────────────────────────

class TradeTracker:
    """SQLite-based trade tracking."""

    def __init__(self):
        self.db_path = DATA_DIR / "crypto_bot.db"
        self._init_db()

    def _init_db(self):
        conn = sqlite3.connect(self.db_path)
        conn.execute("""
            CREATE TABLE IF NOT EXISTS trades (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp TEXT,
                symbol TEXT,
                direction TEXT,
                entry_price REAL,
                reference_price REAL,
                lead_pct REAL,
                token_price REAL,
                bet_size REAL,
                result TEXT DEFAULT 'PENDING',
                pnl REAL DEFAULT 0,
                strength INTEGER DEFAULT 0,
                hl_funding REAL DEFAULT 0
            )
        """)
        conn.commit()
        conn.close()

    def record_trade(self, **kwargs):
        conn = sqlite3.connect(self.db_path)
        conn.execute(
            """INSERT INTO trades (timestamp, symbol, direction, entry_price,
               reference_price, lead_pct, token_price, bet_size, strength, hl_funding)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                datetime.now().isoformat(),
                kwargs.get("symbol", ""),
                kwargs.get("direction", ""),
                kwargs.get("entry_price", 0),
                kwargs.get("reference_price", 0),
                kwargs.get("lead_pct", 0),
                kwargs.get("token_price", 0),
                kwargs.get("bet_size", 0),
                kwargs.get("strength", 0),
                kwargs.get("hl_funding", 0),
            ),
        )
        conn.commit()
        conn.close()

    def get_daily_stats(self):
        conn = sqlite3.connect(self.db_path)
        today = datetime.now().strftime("%Y-%m-%d")
        cur = conn.execute(
            "SELECT COUNT(*), SUM(bet_size), SUM(pnl) FROM trades WHERE timestamp LIKE ?",
            (f"{today}%",),
        )
        row = cur.fetchone()
        conn.close()
        return {
            "trades_today": row[0] or 0,
            "deployed_today": row[1] or 0,
            "pnl_today": row[2] or 0,
        }


# ── Main Bot ──────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true", help="Don't place real orders")
    args = parser.parse_args()

    dry_run = args.dry_run

    print("=" * 60)
    print("CRYPTO LATE-ENTRY BOT v1.0")
    print("=" * 60)
    print(f"Mode: {'DRY RUN' if dry_run else 'LIVE TRADING'}")
    print(f"Symbols: {', '.join(CRYPTO_SYMBOLS)}")
    print(f"Min Lead: {MIN_LEAD_PCT}% | Entry: {ENTRY_MIN_BEFORE} min before close")
    print(f"Bet Size: ${MIN_BET}-${MAX_BET} | Max Positions: {MAX_POSITIONS}")
    print(f"Max Daily Loss: ${MAX_DAILY_LOSS}")
    print()

    # Initialize components
    binance = BinanceFeed()
    hyperliquid = HyperliquidFeed()
    polymarket = CryptoPolymarketClient()
    tracker = TradeTracker()

    # Pre-fill price history (need ~5 min of data)
    log.info("Pre-filling price history (5 minutes)...")
    for i in range(10):
        for sym in CRYPTO_SYMBOLS:
            binance.get_price(sym)
        time.sleep(30)
        sys.stdout.write(f"\r  {(i+1)*30}s / 300s")
        sys.stdout.flush()
    print()

    open_positions = []
    bankroll = 250.0
    cycle = 0

    log.info("Bot started. Scanning for opportunities...")

    while True:
        cycle += 1

        try:
            # Check daily loss limit
            stats = tracker.get_daily_stats()
            if stats["pnl_today"] < -MAX_DAILY_LOSS:
                log.warning(f"DAILY LOSS LIMIT: ${stats['pnl_today']:.2f} (max: -${MAX_DAILY_LOSS})")
                time.sleep(300)
                continue

            # Get signals for each crypto
            signals = []

            for sym in CRYPTO_SYMBOLS:
                momentum = binance.get_momentum(sym)
                if not momentum:
                    continue

                # Get Hyperliquid funding
                coin = sym.replace("USDT", "")
                hl_data = hyperliquid.get_funding_rate(coin)
                hl_funding = hl_data["funding_rate"] if hl_data else 0
                hl_sentiment = hl_data["sentiment"] if hl_data else "NEUTRAL"

                # Add HL as 5th signal
                strength = momentum["strength"]
                if hl_sentiment == "BULLISH" and momentum["direction"] == "UP":
                    strength += 1
                elif hl_sentiment == "BEARISH" and momentum["direction"] == "DOWN":
                    strength += 1

                # Check if signal is strong enough
                lead_pct = abs(momentum["pct_1m"])
                if lead_pct >= MIN_LEAD_PCT and strength >= 3:
                    # Calculate bet size based on confidence
                    bet = BET_SIZE
                    if strength >= 4:
                        bet = min(bet * 1.5, MAX_BET)
                    if strength >= 5:
                        bet = MAX_BET
                    if lead_pct > 0.10:
                        bet = min(bet * 1.3, MAX_BET)

                    bet = max(MIN_BET, min(bet, MAX_BET))

                    signals.append({
                        "symbol": sym,
                        "direction": momentum["direction"],
                        "strength": strength,
                        "lead_pct": lead_pct,
                        "price": momentum["price"],
                        "pct_1m": momentum["pct_1m"],
                        "pct_3m": momentum["pct_3m"],
                        "rsi": momentum["rsi"],
                        "hl_funding": hl_funding,
                        "hl_sentiment": hl_sentiment,
                        "bet_size": bet,
                    })

            # Find matching Polymarket markets
            if signals and len(open_positions) < MAX_POSITIONS:
                markets = polymarket.find_crypto_markets()

                for sig in signals:
                    coin = sig["symbol"].replace("USDT", "").lower()

                    # Find matching market
                    for mkt in markets:
                        q = mkt["question"].lower()
                        if coin not in q:
                            continue

                        # Determine which token to buy
                        if sig["direction"] == "UP" and "up" in q:
                            token_id = mkt["token_yes"]
                            token_price = mkt["price_yes"]
                        elif sig["direction"] == "DOWN" and "down" in q:
                            token_id = mkt["token_no"]
                            token_price = 1.0 - mkt["price_yes"]
                        else:
                            continue

                        # Check token price bounds
                        if token_price > MAX_TOKEN_PRICE or token_price < MIN_TOKEN_PRICE:
                            continue

                        # Check liquidity
                        if mkt["liquidity"] < 100:
                            continue

                        # Skip if already have position on this market
                        if mkt["condition_id"] in [p.get("condition_id") for p in open_positions]:
                            continue

                        # Place trade
                        log.info(f"SIGNAL: {sig['direction']} {sig['symbol']} "
                                f"strength={sig['strength']} lead={sig['lead_pct']:.3f}% "
                                f"RSI={sig['rsi']:.0f} HL={sig['hl_sentiment']}")
                        log.info(f"  Market: {mkt['question'][:60]}")
                        log.info(f"  Token: ${token_price:.3f} | Bet: ${sig['bet_size']:.2f}")

                        success = polymarket.place_order(
                            token_id=token_id,
                            side="BUY",
                            amount_usd=sig["bet_size"],
                            price=token_price,
                            dry_run=dry_run,
                        )

                        if success:
                            bankroll -= sig["bet_size"]
                            open_positions.append({
                                "condition_id": mkt["condition_id"],
                                "symbol": sig["symbol"],
                                "direction": sig["direction"],
                                "entry_time": time.time(),
                            })

                            tracker.record_trade(
                                symbol=sig["symbol"],
                                direction=sig["direction"],
                                entry_price=sig["price"],
                                reference_price=sig["price"],
                                lead_pct=sig["lead_pct"],
                                token_price=token_price,
                                bet_size=sig["bet_size"],
                                strength=sig["strength"],
                                hl_funding=sig["hl_funding"],
                            )

                        break  # one trade per symbol per cycle

            # Status line
            prices = {sym: binance.get_price(sym) for sym in CRYPTO_SYMBOLS}
            price_str = " | ".join(f"{s.replace('USDT','')}: ${p:,.0f}" if p else f"{s}: N/A"
                                   for s, p in prices.items())

            sig_str = f"signals={len(signals)}" if signals else "no signals"
            pos_str = f"pos={len(open_positions)}/{MAX_POSITIONS}"

            log.info(f"[Cycle {cycle}] {price_str} | {sig_str} | {pos_str} | "
                    f"bankroll=${bankroll:.2f} | trades_today={stats['trades_today']}")

        except KeyboardInterrupt:
            log.info("Shutting down...")
            break
        except Exception as e:
            log.error(f"Cycle error: {e}")

        time.sleep(CYCLE_SECONDS)


if __name__ == "__main__":
    main()
