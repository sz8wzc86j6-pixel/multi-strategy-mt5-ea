//+------------------------------------------------------------------+
//|                                          MultiConfluenceEA.mq5   |
//|                        Multi-Confluence Strategy EA               |
//|                                                                   |
//|  STRATEGY LOGIC (from TradingView chart analysis):                |
//|  ─────────────────────────────────────────────────                 |
//|  PRIMARY SIGNAL:  SuperTrend (DBHF ST variant)                    |
//|  CONFLUENCE #1:   Triple HMA ribbon (trend direction)             |
//|  CONFLUENCE #2:   WaveTrend oscillator (momentum/OB-OS)           |
//|  CONFLUENCE #3:   MACD histogram (momentum confirmation)          |
//|  FILTER:          Session time + Spread filter                    |
//|                                                                   |
//|  RISK MGMT:       ATR-based SL, dual TP, SuperTrend trail        |
//|                                                                   |
//|  Markets: Forex, Crypto, Indices                                  |
//|  Timeframes: M15, H1, H4                                         |
//+------------------------------------------------------------------+
#property copyright "MultiConfluence Strategy"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| Enums                                                             |
//+------------------------------------------------------------------+
enum ENUM_MARKET_TYPE
{
   MARKET_FOREX  = 0,  // Forex
   MARKET_CRYPTO = 1,  // Crypto
   MARKET_INDEX  = 2   // Index
};

enum ENUM_ENTRY_MODE
{
   MODE_CONSERVATIVE = 0, // Conservative (all 4 confluence)
   MODE_MODERATE     = 1, // Moderate (3 of 4 confluence)
   MODE_AGGRESSIVE   = 2  // Aggressive (2 of 4 confluence)
};

enum ENUM_SIGNAL_TYPE
{
   SIGNAL_SUPERTREND = 0, // SuperTrend flip (best for Forex/Index)
   SIGNAL_UT_BOT     = 1, // UT Bot flip (best for Crypto)
   SIGNAL_HMA        = 2, // HMA trend change
   SIGNAL_AUTO       = 3  // Auto-detect from symbol
};

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+
// ── Strategy Mode ──
input group "═══ STRATEGY MODE ═══"
input ENUM_MARKET_TYPE InpMarketType      = MARKET_FOREX;      // Market Type
input ENUM_ENTRY_MODE  InpEntryMode       = MODE_MODERATE;     // Entry Mode
input ENUM_SIGNAL_TYPE InpSignalType      = SIGNAL_AUTO;       // Signal Type (AUTO recommended)
input int              InpMagicNumber     = 202603;            // Magic Number

// ── SuperTrend (Primary Signal) ──
input group "═══ SUPERTREND (PRIMARY) ═══"
input int              InpST_ATRPeriod    = 14;                // ATR Period
input double           InpST_Multiplier   = 1.7;              // ATR Multiplier
input bool             InpST_UseClose     = true;              // Use Close (vs HL2)

// ── UT Bot (Alt Primary Signal for Crypto) ──
input group "═══ UT BOT (CRYPTO SIGNAL) ═══"
input double           InpUT_KeyValue    = 1.5;               // Key Value (Sensitivity)
input int              InpUT_ATRPeriod   = 10;                // UT Bot ATR Period

// ── Triple HMA (Confluence #1 - Trend) ──
input group "═══ TRIPLE HMA (TREND FILTER) ═══"
input int              InpHMA_Period      = 10;                // HMA Period
input ENUM_APPLIED_PRICE InpHMA_Price     = PRICE_CLOSE;      // Applied Price

// ── WaveTrend (Confluence #2 - Momentum) ──
input group "═══ WAVETREND (MOMENTUM) ═══"
input int              InpWT_Channel      = 6;                 // Channel Length
input int              InpWT_Average      = 13;                // Average Length
input int              InpWT_OB           = 53;                // Overbought Level
input int              InpWT_OS           = -53;               // Oversold Level

// ── MACD (Confluence #3 - Confirmation) ──
input group "═══ MACD (CONFIRMATION) ═══"
input int              InpMACD_Fast       = 14;                // Fast Period
input int              InpMACD_Slow       = 28;                // Slow Period
input int              InpMACD_Signal     = 11;                // Signal Period

// ── Risk Management ──
input group "═══ RISK MANAGEMENT ═══"
input double           InpRiskPercent     = 1.5;               // Risk % per Trade
input double           InpSL_ATR_Multi    = 1.5;               // SL ATR Multiplier
input double           InpTP1_ATR_Multi   = 2.0;               // TP1 ATR Multiplier
input double           InpTP2_ATR_Multi   = 4.0;               // TP2 ATR Multiplier
input double           InpTP1_ClosePercent= 50.0;              // TP1 Close % of Position
input bool             InpUseTrailingStop = true;              // Use SuperTrend Trailing Stop
input int              InpMaxPositions    = 3;                 // Max Concurrent Positions
input double           InpMaxSpreadATR    = 0.3;               // Max Spread (ATR ratio)
input double           InpMinLotSize      = 0.01;              // Minimum Lot Size
input double           InpMaxLotSize      = 100.0;             // Maximum Lot Size

// ── Session Filter ──
input group "═══ SESSION FILTER ═══"
input bool             InpUseSession      = true;              // Enable Session Filter
input int              InpSessionStartH   = 7;                 // Session Start Hour (UTC)
input int              InpSessionEndH     = 21;                // Session End Hour (UTC)
input int              InpBestStartH      = 13;                // Best Hours Start (UTC)
input int              InpBestEndH        = 16;                // Best Hours End (UTC)
input bool             InpBestHoursOnly   = false;             // Trade Only Best Hours

// ── Display ──
input group "═══ DISPLAY ═══"
input bool             InpShowDashboard   = true;              // Show Dashboard Panel
input bool             InpShowSignals     = true;              // Show Signal Arrows
input color            InpBuyColor        = clrLime;           // Buy Signal Color
input color            InpSellColor       = clrRed;            // Sell Signal Color

//+------------------------------------------------------------------+
//| Global Variables                                                  |
//+------------------------------------------------------------------+
CTrade         trade;
CPositionInfo  posInfo;
CSymbolInfo    symInfo;

// SuperTrend state
double g_stUpperBand[];
double g_stLowerBand[];
double g_stLine[];
int    g_stDirection[];     // 1 = bullish, -1 = bearish

// HMA state
double g_hma[];
int    g_hmaTrend[];        // 1 = rising, -1 = falling

// WaveTrend state
double g_wt1[];
double g_wt2[];

// UT Bot state
double g_utTrail[];
int    g_utDir[];

// Active signal type (resolved from AUTO)
ENUM_SIGNAL_TYPE g_activeSignal;

// MACD
int    g_hMACD;
double g_macdLine[];
double g_macdSignal[];
double g_macdHist[];

// ATR
int    g_hATR;
double g_atr[];

// Buffers
double g_close[];
double g_high[];
double g_low[];
double g_hlc3[];

// Position tracking
struct PositionData
{
   ulong  ticket;
   double entryPrice;
   double stopLoss;
   double tp1;
   double tp2;
   bool   tp1Hit;
   double originalLots;
};
PositionData g_positions[];

// Dashboard
string g_dashName = "MCDash";

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   // Setup trade object
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   // Initialize MACD handle
   g_hMACD = iMACD(_Symbol, PERIOD_CURRENT, InpMACD_Fast, InpMACD_Slow, InpMACD_Signal, PRICE_CLOSE);
   if(g_hMACD == INVALID_HANDLE)
   {
      Print("Failed to create MACD handle");
      return INIT_FAILED;
   }

   // Initialize ATR handle
   g_hATR = iATR(_Symbol, PERIOD_CURRENT, InpST_ATRPeriod);
   if(g_hATR == INVALID_HANDLE)
   {
      Print("Failed to create ATR handle");
      return INIT_FAILED;
   }

   // Set series arrays
   ArraySetAsSeries(g_close, true);
   ArraySetAsSeries(g_high, true);
   ArraySetAsSeries(g_low, true);
   ArraySetAsSeries(g_hlc3, true);
   ArraySetAsSeries(g_atr, true);
   ArraySetAsSeries(g_macdLine, true);
   ArraySetAsSeries(g_macdSignal, true);
   ArraySetAsSeries(g_macdHist, true);
   ArraySetAsSeries(g_stLine, true);
   ArraySetAsSeries(g_stUpperBand, true);
   ArraySetAsSeries(g_stLowerBand, true);
   ArraySetAsSeries(g_stDirection, true);
   ArraySetAsSeries(g_hma, true);
   ArraySetAsSeries(g_hmaTrend, true);
   ArraySetAsSeries(g_wt1, true);
   ArraySetAsSeries(g_wt2, true);

   symInfo.Name(_Symbol);

   // Resolve AUTO signal type based on symbol
   g_activeSignal = InpSignalType;
   if(InpSignalType == SIGNAL_AUTO)
   {
      string sym = _Symbol;
      StringToUpper(sym);
      // Crypto: use UT Bot (backtested best: +134% on BTCUSD H1)
      if(StringFind(sym, "BTC") >= 0 || StringFind(sym, "ETH") >= 0 ||
         StringFind(sym, "XRP") >= 0 || StringFind(sym, "SOL") >= 0 ||
         StringFind(sym, "CRYPTO") >= 0)
      {
         g_activeSignal = SIGNAL_UT_BOT;
         Print("AUTO: Crypto detected - using UT Bot signal (best for crypto)");
      }
      // Index: use HMA (backtested best: PF 1.88 on US30 H4)
      else if(StringFind(sym, "US30") >= 0 || StringFind(sym, "NAS") >= 0 ||
              StringFind(sym, "SPX") >= 0 || StringFind(sym, "DAX") >= 0 ||
              StringFind(sym, "DJI") >= 0 || StringFind(sym, "NDX") >= 0)
      {
         g_activeSignal = SIGNAL_HMA;
         Print("AUTO: Index detected - using HMA signal (best for indices)");
      }
      // Default Forex: SuperTrend (best overall: +121% GBPUSD M15)
      else
      {
         g_activeSignal = SIGNAL_SUPERTREND;
         Print("AUTO: Forex detected - using SuperTrend signal (best for forex)");
      }
   }

   Print("MultiConfluence EA v2.0 initialized on ", _Symbol, " ", EnumToString(Period()));
   Print("Signal: ", EnumToString(g_activeSignal), " | Mode: ", EnumToString(InpEntryMode));

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_hMACD != INVALID_HANDLE) IndicatorRelease(g_hMACD);
   if(g_hATR  != INVALID_HANDLE) IndicatorRelease(g_hATR);
   ObjectsDeleteAll(0, g_dashName);
   ObjectsDeleteAll(0, "MCSignal_");
   Comment("");
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   // Only process on new bar
   static datetime lastBar = 0;
   datetime currentBar = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currentBar == lastBar)
   {
      // Still manage positions on every tick
      ManageOpenPositions();
      return;
   }
   lastBar = currentBar;

   // Load price data
   int bars = 200;
   if(CopyClose(_Symbol, PERIOD_CURRENT, 0, bars, g_close) < bars) return;
   if(CopyHigh(_Symbol, PERIOD_CURRENT, 0, bars, g_high)   < bars) return;
   if(CopyLow(_Symbol, PERIOD_CURRENT, 0, bars, g_low)     < bars) return;

   // Calculate HLC3
   ArrayResize(g_hlc3, bars);
   for(int i = 0; i < bars; i++)
      g_hlc3[i] = (g_high[i] + g_low[i] + g_close[i]) / 3.0;

   // Copy indicator data
   if(CopyBuffer(g_hATR, 0, 0, bars, g_atr) < bars) return;
   if(CopyBuffer(g_hMACD, 0, 0, bars, g_macdLine)   < bars) return;
   if(CopyBuffer(g_hMACD, 1, 0, bars, g_macdSignal)  < bars) return;
   if(CopyBuffer(g_hMACD, 2, 0, bars, g_macdHist)    < bars) return;

   // Calculate custom indicators
   CalculateSuperTrend(bars);
   CalculateHMA(bars);
   CalculateWaveTrend(bars);
   CalculateUTBot(bars);

   // Check for signals
   int signal = CheckEntrySignal();

   // Session filter
   if(!IsSessionAllowed()) signal = 0;

   // Spread filter
   if(!CheckSpread()) signal = 0;

   // Execute trades
   if(signal != 0 && CountPositions() < InpMaxPositions)
   {
      ExecuteTrade(signal);
   }

   // Manage existing positions
   ManageOpenPositions();

   // Update dashboard
   if(InpShowDashboard)
      UpdateDashboard(signal);

   // Draw signal arrow
   if(InpShowSignals && signal != 0)
      DrawSignalArrow(signal);
}

//+------------------------------------------------------------------+
//| SuperTrend Calculation (DBHF ST variant)                         |
//+------------------------------------------------------------------+
void CalculateSuperTrend(int bars)
{
   ArrayResize(g_stUpperBand, bars);
   ArrayResize(g_stLowerBand, bars);
   ArrayResize(g_stLine, bars);
   ArrayResize(g_stDirection, bars);

   for(int i = bars - 1; i >= 0; i--)
   {
      double src = InpST_UseClose ? g_close[i] : (g_high[i] + g_low[i]) / 2.0;
      double atrVal = g_atr[i];

      double upperBand = src + InpST_Multiplier * atrVal;
      double lowerBand = src - InpST_Multiplier * atrVal;

      // Carry forward logic
      if(i < bars - 1)
      {
         // Lower band can only go up
         if(lowerBand > g_stLowerBand[i + 1] || g_close[i + 1] < g_stLowerBand[i + 1])
            g_stLowerBand[i] = lowerBand;
         else
            g_stLowerBand[i] = g_stLowerBand[i + 1];

         // Upper band can only go down
         if(upperBand < g_stUpperBand[i + 1] || g_close[i + 1] > g_stUpperBand[i + 1])
            g_stUpperBand[i] = upperBand;
         else
            g_stUpperBand[i] = g_stUpperBand[i + 1];

         // Direction
         int prevDir = g_stDirection[i + 1];
         if(prevDir == -1 && g_close[i] > g_stUpperBand[i])
            g_stDirection[i] = 1;
         else if(prevDir == 1 && g_close[i] < g_stLowerBand[i])
            g_stDirection[i] = -1;
         else
            g_stDirection[i] = prevDir;
      }
      else
      {
         g_stUpperBand[i] = upperBand;
         g_stLowerBand[i] = lowerBand;
         g_stDirection[i] = 1;
      }

      // SuperTrend line
      g_stLine[i] = (g_stDirection[i] == 1) ? g_stLowerBand[i] : g_stUpperBand[i];
   }
}

//+------------------------------------------------------------------+
//| Hull Moving Average (Triple HMA) Calculation                     |
//+------------------------------------------------------------------+
void CalculateHMA(int bars)
{
   ArrayResize(g_hma, bars);
   ArrayResize(g_hmaTrend, bars);

   int period = InpHMA_Period;
   int halfPeriod = (int)MathFloor(period / 2.0);
   int sqrtPeriod = (int)MathFloor(MathSqrt(period));

   // Need enough bars
   if(bars < period + sqrtPeriod + 5) return;

   // Step 1: WMA(close, period/2) * 2 - WMA(close, period)
   double hullSrc[];
   ArrayResize(hullSrc, bars);
   ArraySetAsSeries(hullSrc, true);

   for(int i = 0; i < bars - period; i++)
   {
      double wmaHalf = CalculateWMA(g_close, i, halfPeriod);
      double wmaFull = CalculateWMA(g_close, i, period);
      hullSrc[i] = 2.0 * wmaHalf - wmaFull;
   }

   // Step 2: WMA(hullSrc, sqrt(period))
   for(int i = 0; i < bars - period - sqrtPeriod; i++)
   {
      g_hma[i] = CalculateWMA(hullSrc, i, sqrtPeriod);
   }

   // Determine trend (slope)
   for(int i = 0; i < bars - period - sqrtPeriod - 1; i++)
   {
      g_hmaTrend[i] = (g_hma[i] > g_hma[i + 1]) ? 1 : -1;
   }
}

//+------------------------------------------------------------------+
//| WMA helper                                                        |
//+------------------------------------------------------------------+
double CalculateWMA(double &data[], int start, int period)
{
   double sum = 0;
   double weightSum = 0;
   for(int i = 0; i < period; i++)
   {
      double weight = (double)(period - i);
      sum += data[start + i] * weight;
      weightSum += weight;
   }
   return (weightSum > 0) ? sum / weightSum : 0;
}

//+------------------------------------------------------------------+
//| WaveTrend Oscillator Calculation                                  |
//+------------------------------------------------------------------+
void CalculateWaveTrend(int bars)
{
   ArrayResize(g_wt1, bars);
   ArrayResize(g_wt2, bars);

   int ch = InpWT_Channel;
   int avg = InpWT_Average;

   if(bars < ch + avg + 10) return;

   // Step 1: EMA of HLC3
   double emaHLC3[];
   ArrayResize(emaHLC3, bars);
   ArraySetAsSeries(emaHLC3, true);
   CalculateEMA(g_hlc3, emaHLC3, bars, ch);

   // Step 2: |HLC3 - EMA(HLC3)|
   double diff[];
   double absDiff[];
   ArrayResize(diff, bars);
   ArrayResize(absDiff, bars);
   ArraySetAsSeries(diff, true);
   ArraySetAsSeries(absDiff, true);

   for(int i = 0; i < bars; i++)
   {
      diff[i] = g_hlc3[i] - emaHLC3[i];
      absDiff[i] = MathAbs(diff[i]);
   }

   // Step 3: EMA of diff and EMA of |diff|
   double emaDiff[];
   double emaAbsDiff[];
   ArrayResize(emaDiff, bars);
   ArrayResize(emaAbsDiff, bars);
   ArraySetAsSeries(emaDiff, true);
   ArraySetAsSeries(emaAbsDiff, true);
   CalculateEMA(diff, emaDiff, bars, ch);
   CalculateEMA(absDiff, emaAbsDiff, bars, ch);

   // Step 4: CI = diff / (0.015 * EMA(|diff|))
   double ci[];
   ArrayResize(ci, bars);
   ArraySetAsSeries(ci, true);

   for(int i = 0; i < bars; i++)
   {
      double denom = 0.015 * emaAbsDiff[i];
      ci[i] = (denom != 0) ? emaDiff[i] / denom : 0;
   }

   // Step 5: WT1 = EMA(CI, avg), WT2 = SMA(WT1, 4)
   CalculateEMA(ci, g_wt1, bars, avg);

   for(int i = 0; i < bars - 4; i++)
   {
      g_wt2[i] = (g_wt1[i] + g_wt1[i + 1] + g_wt1[i + 2] + g_wt1[i + 3]) / 4.0;
   }
}

//+------------------------------------------------------------------+
//| EMA Calculation Helper                                            |
//+------------------------------------------------------------------+
void CalculateEMA(double &src[], double &dest[], int bars, int period)
{
   double multiplier = 2.0 / (period + 1.0);

   // Initialize: use SMA for first value
   dest[bars - 1] = src[bars - 1];
   for(int i = bars - 2; i >= 0; i--)
   {
      dest[i] = src[i] * multiplier + dest[i + 1] * (1.0 - multiplier);
   }
}

//+------------------------------------------------------------------+
//| UT Bot Calculation (ATR Trailing Stop)                            |
//+------------------------------------------------------------------+
void CalculateUTBot(int bars)
{
   ArrayResize(g_utTrail, bars);
   ArrayResize(g_utDir, bars);

   int utATRHandle = iATR(_Symbol, PERIOD_CURRENT, InpUT_ATRPeriod);
   double utATR[];
   ArraySetAsSeries(utATR, true);
   if(CopyBuffer(utATRHandle, 0, 0, bars, utATR) < bars)
   {
      IndicatorRelease(utATRHandle);
      return;
   }
   IndicatorRelease(utATRHandle);

   g_utTrail[bars - 1] = g_close[bars - 1];
   g_utDir[bars - 1] = 0;

   for(int i = bars - 2; i >= 0; i--)
   {
      double nLoss = InpUT_KeyValue * utATR[i];

      if(g_close[i] > g_utTrail[i + 1] && g_close[i + 1] > g_utTrail[i + 1])
         g_utTrail[i] = MathMax(g_utTrail[i + 1], g_close[i] - nLoss);
      else if(g_close[i] < g_utTrail[i + 1] && g_close[i + 1] < g_utTrail[i + 1])
         g_utTrail[i] = MathMin(g_utTrail[i + 1], g_close[i] + nLoss);
      else if(g_close[i] > g_utTrail[i + 1])
         g_utTrail[i] = g_close[i] - nLoss;
      else
         g_utTrail[i] = g_close[i] + nLoss;

      // Direction: 1=bullish, -1=bearish
      if(g_close[i] > g_utTrail[i] && g_close[i + 1] <= g_utTrail[i + 1])
         g_utDir[i] = 1;
      else if(g_close[i] < g_utTrail[i] && g_close[i + 1] >= g_utTrail[i + 1])
         g_utDir[i] = -1;
      else
         g_utDir[i] = g_utDir[i + 1];
   }
}

//+------------------------------------------------------------------+
//| Check Entry Signal - Multi Confluence                             |
//+------------------------------------------------------------------+
int CheckEntrySignal()
{
   // Need at least 2 bars of data
   if(ArraySize(g_stDirection) < 3) return 0;
   if(ArraySize(g_hmaTrend) < 2) return 0;
   if(ArraySize(g_wt1) < 3) return 0;
   if(ArraySize(g_macdHist) < 2) return 0;

   int confluenceBuy  = 0;
   int confluenceSell = 0;
   int required = 4; // default conservative

   switch(InpEntryMode)
   {
      case MODE_CONSERVATIVE: required = 4; break;
      case MODE_MODERATE:     required = 3; break;
      case MODE_AGGRESSIVE:   required = 2; break;
   }

   // ═══ PRIMARY SIGNAL (depends on signal type) ═══
   bool primaryBuy = false;
   bool primarySell = false;

   // SuperTrend signals (always calculated for confluence too)
   bool stBuyFlip  = (g_stDirection[1] == 1 && g_stDirection[2] == -1);
   bool stSellFlip = (g_stDirection[1] == -1 && g_stDirection[2] == 1);

   // UT Bot signals
   bool utBuyFlip  = (ArraySize(g_utDir) > 2 && g_utDir[1] == 1 && g_utDir[2] != 1);
   bool utSellFlip = (ArraySize(g_utDir) > 2 && g_utDir[1] == -1 && g_utDir[2] != -1);

   // HMA signals
   bool hmaBuyFlip  = (g_hmaTrend[1] == 1 && g_hmaTrend[2] == -1);
   bool hmaSellFlip = (g_hmaTrend[1] == -1 && g_hmaTrend[2] == 1);

   switch(g_activeSignal)
   {
      case SIGNAL_SUPERTREND:
         primaryBuy = stBuyFlip;
         primarySell = stSellFlip;
         break;
      case SIGNAL_UT_BOT:
         primaryBuy = utBuyFlip;
         primarySell = utSellFlip;
         break;
      case SIGNAL_HMA:
         primaryBuy = hmaBuyFlip;
         primarySell = hmaSellFlip;
         break;
      default:
         primaryBuy = stBuyFlip;
         primarySell = stSellFlip;
         break;
   }

   if(primaryBuy)  confluenceBuy++;
   if(primarySell) confluenceSell++;

   // ═══ CONFLUENCE 1: Triple HMA Trend ═══
   // (only counts as confluence if HMA is not the primary signal)
   if(g_activeSignal != SIGNAL_HMA)
   {
      if(g_hmaTrend[1] == 1)  confluenceBuy++;
      if(g_hmaTrend[1] == -1) confluenceSell++;
   }

   // ═══ CONFLUENCE: SuperTrend direction (when not primary) ═══
   if(g_activeSignal != SIGNAL_SUPERTREND)
   {
      if(g_stDirection[1] == 1)  confluenceBuy++;
      if(g_stDirection[1] == -1) confluenceSell++;
   }

   // ═══ CONFLUENCE 2: WaveTrend ═══
   // Buy: WT not overbought AND (crossing up OR momentum positive)
   bool wtCrossUp   = (g_wt1[1] > g_wt2[1] && g_wt1[2] <= g_wt2[2]);
   bool wtCrossDown = (g_wt1[1] < g_wt2[1] && g_wt1[2] >= g_wt2[2]);
   bool wtNotOB     = (g_wt1[1] < InpWT_OB);
   bool wtNotOS     = (g_wt1[1] > InpWT_OS);
   bool wtBullMom   = (g_wt1[1] > g_wt2[1]);
   bool wtBearMom   = (g_wt1[1] < g_wt2[1]);

   if((wtCrossUp || wtBullMom) && wtNotOB) confluenceBuy++;
   if((wtCrossDown || wtBearMom) && wtNotOS) confluenceSell++;

   // ═══ CONFLUENCE 3: MACD ═══
   bool macdBullish = (g_macdHist[1] > 0) || (g_macdHist[1] > g_macdHist[2]);
   bool macdBearish = (g_macdHist[1] < 0) || (g_macdHist[1] < g_macdHist[2]);

   if(macdBullish) confluenceBuy++;
   if(macdBearish) confluenceSell++;

   // ═══ FINAL DECISION ═══
   // Primary signal flip is REQUIRED for entry
   if(primaryBuy && confluenceBuy >= required)
      return 1;  // BUY

   if(primarySell && confluenceSell >= required)
      return -1; // SELL

   return 0; // No signal
}

//+------------------------------------------------------------------+
//| Session Filter                                                    |
//+------------------------------------------------------------------+
bool IsSessionAllowed()
{
   if(!InpUseSession) return true;

   // Crypto trades 24/7
   if(InpMarketType == MARKET_CRYPTO) return true;

   MqlDateTime dt;
   TimeGMT(dt);
   int hour = dt.hour;

   if(InpBestHoursOnly)
      return (hour >= InpBestStartH && hour < InpBestEndH);

   return (hour >= InpSessionStartH && hour < InpSessionEndH);
}

//+------------------------------------------------------------------+
//| Spread Filter                                                     |
//+------------------------------------------------------------------+
bool CheckSpread()
{
   if(ArraySize(g_atr) < 2 || g_atr[1] == 0) return true;

   symInfo.RefreshRates();
   double spread = symInfo.Spread() * symInfo.Point();
   double atrVal = g_atr[1];

   return (spread <= atrVal * InpMaxSpreadATR);
}

//+------------------------------------------------------------------+
//| Execute Trade                                                     |
//+------------------------------------------------------------------+
void ExecuteTrade(int signal)
{
   symInfo.RefreshRates();

   double atrVal = g_atr[1];
   if(atrVal == 0) return;

   double ask = symInfo.Ask();
   double bid = symInfo.Bid();
   double point = symInfo.Point();
   int digits = symInfo.Digits();

   double entryPrice, sl, tp1, tp2;
   ENUM_ORDER_TYPE orderType;

   if(signal == 1) // BUY
   {
      entryPrice = ask;
      sl  = NormalizeDouble(entryPrice - InpSL_ATR_Multi * atrVal, digits);
      tp1 = NormalizeDouble(entryPrice + InpTP1_ATR_Multi * atrVal, digits);
      tp2 = NormalizeDouble(entryPrice + InpTP2_ATR_Multi * atrVal, digits);
      orderType = ORDER_TYPE_BUY;
   }
   else // SELL
   {
      entryPrice = bid;
      sl  = NormalizeDouble(entryPrice + InpSL_ATR_Multi * atrVal, digits);
      tp1 = NormalizeDouble(entryPrice - InpTP1_ATR_Multi * atrVal, digits);
      tp2 = NormalizeDouble(entryPrice - InpTP2_ATR_Multi * atrVal, digits);
      orderType = ORDER_TYPE_SELL;
   }

   // Calculate lot size based on risk
   double riskAmount = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0;
   double slDistance = MathAbs(entryPrice - sl);
   if(slDistance == 0) return;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue == 0 || tickSize == 0) return;

   double lotSize = NormalizeDouble(riskAmount / (slDistance / tickSize * tickValue), 2);
   lotSize = MathMax(InpMinLotSize, MathMin(InpMaxLotSize, lotSize));

   // Ensure lot size meets symbol requirements
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   lotSize = MathMax(minLot, MathMin(maxLot, lotSize));
   lotSize = NormalizeDouble(MathFloor(lotSize / lotStep) * lotStep, 2);

   if(lotSize < minLot) return;

   // Place order — use TP2 as the order TP, manage TP1 manually
   string comment = StringFormat("MC_%s_%d", (signal == 1) ? "BUY" : "SELL", InpMagicNumber);

   if(trade.PositionOpen(_Symbol, orderType, lotSize, entryPrice, sl, tp2, comment))
   {
      // Track position for partial close management
      PositionData pd;
      pd.ticket       = trade.ResultOrder();
      pd.entryPrice   = entryPrice;
      pd.stopLoss     = sl;
      pd.tp1          = tp1;
      pd.tp2          = tp2;
      pd.tp1Hit       = false;
      pd.originalLots = lotSize;

      int size = ArraySize(g_positions);
      ArrayResize(g_positions, size + 1);
      g_positions[size] = pd;

      Print(StringFormat("TRADE OPENED: %s | Entry: %.5f | SL: %.5f | TP1: %.5f | TP2: %.5f | Lots: %.2f",
            (signal == 1) ? "BUY" : "SELL", entryPrice, sl, tp1, tp2, lotSize));
   }
   else
   {
      Print("Trade failed: ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Manage Open Positions (TP1 partial close + trailing stop)        |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   for(int i = ArraySize(g_positions) - 1; i >= 0; i--)
   {
      ulong ticket = g_positions[i].ticket;

      if(!PositionSelectByTicket(ticket))
      {
         // Position closed, remove from array
         RemovePosition(i);
         continue;
      }

      double currentPrice;
      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      if(posType == POSITION_TYPE_BUY)
         currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      else
         currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      // ── TP1 Partial Close ──
      if(!g_positions[i].tp1Hit)
      {
         bool tp1Reached = false;
         if(posType == POSITION_TYPE_BUY && currentPrice >= g_positions[i].tp1)
            tp1Reached = true;
         if(posType == POSITION_TYPE_SELL && currentPrice <= g_positions[i].tp1)
            tp1Reached = true;

         if(tp1Reached)
         {
            double closeLots = NormalizeDouble(g_positions[i].originalLots * InpTP1_ClosePercent / 100.0, 2);
            double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
            closeLots = NormalizeDouble(MathFloor(closeLots / lotStep) * lotStep, 2);
            double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

            if(closeLots >= minLot)
            {
               trade.PositionClosePartial(ticket, closeLots);
               g_positions[i].tp1Hit = true;

               // Move SL to breakeven
               double newSL = g_positions[i].entryPrice;
               trade.PositionModify(ticket, newSL, g_positions[i].tp2);
               g_positions[i].stopLoss = newSL;

               Print(StringFormat("TP1 HIT: Closed %.2f lots, moved SL to breakeven %.5f", closeLots, newSL));
            }
         }
      }

      // ── SuperTrend Trailing Stop (after TP1) ──
      if(InpUseTrailingStop && g_positions[i].tp1Hit && ArraySize(g_stLine) > 1)
      {
         double stLevel = g_stLine[1];
         double currentSL = PositionGetDouble(POSITION_SL);
         int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

         if(posType == POSITION_TYPE_BUY)
         {
            // Trail SL up with SuperTrend
            double newSL = NormalizeDouble(stLevel, digits);
            if(newSL > currentSL && newSL < currentPrice)
            {
               trade.PositionModify(ticket, newSL, g_positions[i].tp2);
               g_positions[i].stopLoss = newSL;
            }
         }
         else // SELL
         {
            double newSL = NormalizeDouble(stLevel, digits);
            if(newSL < currentSL && newSL > currentPrice)
            {
               trade.PositionModify(ticket, newSL, g_positions[i].tp2);
               g_positions[i].stopLoss = newSL;
            }
         }
      }

      // ── SuperTrend Flip Exit ──
      if(ArraySize(g_stDirection) > 2)
      {
         if(posType == POSITION_TYPE_BUY && g_stDirection[1] == -1 && g_stDirection[2] == 1)
         {
            trade.PositionClose(ticket);
            Print("EXIT: SuperTrend flipped BEARISH - closed BUY");
            RemovePosition(i);
         }
         else if(posType == POSITION_TYPE_SELL && g_stDirection[1] == 1 && g_stDirection[2] == -1)
         {
            trade.PositionClose(ticket);
            Print("EXIT: SuperTrend flipped BULLISH - closed SELL");
            RemovePosition(i);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Remove position from tracking array                               |
//+------------------------------------------------------------------+
void RemovePosition(int index)
{
   int last = ArraySize(g_positions) - 1;
   if(index < last)
      g_positions[index] = g_positions[last];
   ArrayResize(g_positions, last);
}

//+------------------------------------------------------------------+
//| Count positions with our magic number                             |
//+------------------------------------------------------------------+
int CountPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == _Symbol)
      {
         if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
            count++;
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Draw signal arrow on chart                                        |
//+------------------------------------------------------------------+
void DrawSignalArrow(int signal)
{
   string name = StringFormat("MCSignal_%d", (int)TimeCurrent());
   datetime time = iTime(_Symbol, PERIOD_CURRENT, 1);

   if(signal == 1)
   {
      ObjectCreate(0, name, OBJ_ARROW_UP, 0, time, g_low[1] - g_atr[1] * 0.5);
      ObjectSetInteger(0, name, OBJPROP_COLOR, InpBuyColor);
   }
   else
   {
      ObjectCreate(0, name, OBJ_ARROW_DOWN, 0, time, g_high[1] + g_atr[1] * 0.5);
      ObjectSetInteger(0, name, OBJPROP_COLOR, InpSellColor);
   }
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
}

//+------------------------------------------------------------------+
//| Update Dashboard                                                  |
//+------------------------------------------------------------------+
void UpdateDashboard(int signal)
{
   if(ArraySize(g_stDirection) < 2) return;
   if(ArraySize(g_hmaTrend) < 2) return;
   if(ArraySize(g_wt1) < 2) return;
   if(ArraySize(g_macdHist) < 2) return;

   string stDir   = (g_stDirection[1] == 1) ? "BULLISH" : "BEARISH";
   string hmaDir  = (g_hmaTrend[1] == 1) ? "BULLISH" : "BEARISH";
   string wtState = StringFormat("%.1f / %.1f", g_wt1[1], g_wt2[1]);
   string wtZone  = (g_wt1[1] > InpWT_OB) ? "OVERBOUGHT" : (g_wt1[1] < InpWT_OS) ? "OVERSOLD" : "NEUTRAL";
   string macdDir = (g_macdHist[1] > 0) ? "POSITIVE" : "NEGATIVE";
   string session = IsSessionAllowed() ? "ACTIVE" : "INACTIVE";
   string spread  = CheckSpread() ? "OK" : "TOO HIGH";
   string sigText = (signal == 1) ? ">>> BUY <<<" : (signal == -1) ? ">>> SELL <<<" : "---";

   string dashboard = StringFormat(
      "═══════════════════════════════\n"
      "   MULTI-CONFLUENCE EA v1.0\n"
      "═══════════════════════════════\n"
      " Symbol:     %s %s\n"
      " Mode:       %s\n"
      "───────────────────────────────\n"
      " SuperTrend: %s\n"
      " HMA Trend:  %s\n"
      " WaveTrend:  %s [%s]\n"
      " MACD Hist:  %s (%.5f)\n"
      "───────────────────────────────\n"
      " Session:    %s\n"
      " Spread:     %s\n"
      " Positions:  %d / %d\n"
      " ATR(14):    %.5f\n"
      "───────────────────────────────\n"
      " SIGNAL:     %s\n"
      "═══════════════════════════════",
      _Symbol, EnumToString(Period()),
      EnumToString(InpEntryMode),
      stDir,
      hmaDir,
      wtState, wtZone,
      macdDir, g_macdHist[1],
      session,
      spread,
      CountPositions(), InpMaxPositions,
      g_atr[1],
      sigText
   );

   Comment(dashboard);
}
//+------------------------------------------------------------------+
