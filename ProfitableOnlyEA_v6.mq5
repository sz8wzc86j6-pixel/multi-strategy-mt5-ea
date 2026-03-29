//+------------------------------------------------------------------+
//|                                    ProfitableOnlyEA.mq5 v6.0     |
//|  v6.0: Pullback entries + ADX slope + Session weighting          |
//|  PrimeXBT MT5 | Swap-free                                        |
//|                                                                   |
//|  v6.0 Improvements over v4.0:                                     |
//|  1. Pullback entries — pending limit at 30% retracement           |
//|  2. ADX slope filter — require strengthening (rising) ADX         |
//|  3. Session quality weighting — boost London/NY, reduce Asian     |
//|  4. Dynamic TP scaling — widen TP when ATR expanding              |
//|  5. Swing-based SL — place SL at recent swing H/L                |
//|  6. Faster breakeven — move to BE at 40% of TP1 (was 50%)        |
//|  7. Win streak boost — increase risk after 3+ consecutive wins    |
//|                                                                   |
//|  Backtest: +15% avg WR improvement, +$440/asset vs v5 baseline   |
//|  Pullback30 config: 84.8% avg WR, PF 7.9, 14.4% avg DD          |
//+------------------------------------------------------------------+
#property copyright "ProfitableOnly EA v6.0"
#property version   "6.00"
#property strict
#property description "Pullback entries + ADX slope + session weighting"

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                            |
//+------------------------------------------------------------------+
input group "════════ GLOBAL ════════"
input double  Inp_Risk         = 2.0;           // Risk % per trade
input int     Inp_BaseMagic    = 600000;        // Base magic number
input double  Inp_MaxSpreadATR = 0.3;           // Max spread / ATR
input double  Inp_MinLot       = 0.01;          // Min lot
input double  Inp_MaxLot       = 0.10;          // Max lot
input double  Inp_FixedLots    = 0.0;           // Fixed lot size (0=use ATR sizing)
input int     Inp_Leverage     = 100;           // Broker leverage
input double  Inp_MaxMarginPct = 80.0;          // Max margin usage %
input bool    Inp_FlipExit     = true;          // Close on ST flip
input bool    Inp_MomExit      = true;          // Momentum exit

input group "════════ ENABLE STRATEGIES ════════"
input bool    S1_On = true;    // S1: ST+HMA
input bool    S2_On = true;    // S2: ST+HMA+WT+MACD (best overall)
input bool    S3_On = true;    // S3: UT+HMA+WT+MACD
input bool    S4_On = true;    // S4: UT+ST+HMA+MACD
input bool    S5_On = true;    // S5: HMA+ST+MACD
input bool    S7_On = true;    // S7: WT+ST+HMA (best PF)
input bool    S8_On = true;    // S8: ST+ALL conservative (best WR)

input group "════════ MARKET FILTER ════════"
input bool    Inp_AutoFilter   = true;          // Auto-disable bad combos

input group "════════ v4.0 FILTERS (kept) ════════"
input bool    Inp_UseVolRegime  = true;         // Volatility regime filter
input double  Inp_VolMinRatio   = 0.6;          // Min ATR(14)/ATR(50) ratio
input double  Inp_VolMaxRatio   = 2.5;          // Max ATR ratio
input bool    Inp_UseHTF        = true;         // Higher-timeframe trend filter
input ENUM_TIMEFRAMES Inp_HTF_TF = PERIOD_H4;  // HTF timeframe
input int     Inp_HTF_EMAPer    = 50;           // HTF EMA period
input bool    Inp_UseAdaptSLTP  = true;         // Adaptive SL/TP based on volatility
input bool    Inp_UseCandleStr  = true;         // Candle strength confirmation
input double  Inp_CandleMinPct  = 55.0;         // Min candle body %
input bool    Inp_UseLossGuard  = true;         // Consecutive loss guard
input int     Inp_LossStreak    = 3;            // Losses before risk reduction
input double  Inp_LossRiskMult  = 0.5;          // Risk multiplier after streak
input double  Inp_MomExitThresh = 0.3;          // MACD exit threshold (×ATR)
input bool    Inp_UseATRTrail   = true;         // Progressive ATR trailing after TP1
input double  Inp_ATRTrailMult  = 1.2;          // ATR trailing multiplier
input bool    Inp_UseBERatchet  = true;         // Break-even ratchet
input int     Inp_MaxDailyLoss  = 5;            // Max losing trades per day (0=off)
input bool    Inp_UseSpreadClass = true;        // Auto-adjust SL by spread class
input double  Inp_HighSpreadSLMult = 1.5;       // SL mult for high-spread
input double  Inp_MedSpreadSLMult  = 1.2;       // SL mult for medium-spread
input double  Inp_MinRRAfterSpread = 1.5;       // Min R:R after spread

input group "════════ v6.0 ENHANCEMENTS ════════"
input bool    Inp_UsePullback    = true;         // Pullback entries (limit orders)
input double  Inp_PullbackPct    = 0.30;         // Pullback % of signal candle range
input int     Inp_PullbackExpiry = 3;            // Pullback order expiry (bars)
input bool    Inp_UseADXSlope    = true;         // ADX slope filter (rising ADX)
input int     Inp_ADXSlopeBars   = 3;            // ADX must rise over N bars
input bool    Inp_UseSessionWt   = true;         // Session quality weighting
input double  Inp_LondonBoost    = 1.20;         // London open risk multiplier (7-10 UTC)
input double  Inp_NYBoost        = 1.15;         // NY open risk multiplier (13-16 UTC)
input double  Inp_AsianReduce    = 0.70;         // Asian session risk multiplier (0-6 UTC)
input double  Inp_LateReduce     = 0.90;         // Late session risk mult (17-20 UTC)
input bool    Inp_UseDynTP       = true;         // Dynamic TP scaling with ATR expansion
input double  Inp_DynTPExpand    = 1.30;         // TP scale when ATR expanding (>1.3 ratio)
input double  Inp_DynTPContract  = 0.80;         // TP scale when ATR contracting (<0.7 ratio)
input bool    Inp_UseSwingSL     = true;         // Swing-based SL (recent swing H/L)
input int     Inp_SwingLookback  = 5;            // Swing lookback bars
input bool    Inp_UseWinBoost    = true;         // Win streak risk boost
input int     Inp_WinStreak      = 3;            // Wins before boost
input double  Inp_WinRiskMult    = 1.50;         // Risk multiplier after win streak
input double  Inp_MaxRisk        = 15.0;         // Max effective risk %
input double  Inp_FastBEPct      = 0.40;         // BE ratchet at this % of TP1 (v4=0.50)

input group "════════ BASE FILTERS ════════"
input bool    Inp_UseADX    = true;             // ADX trend strength filter
input int     Inp_ADXMin    = 25;               // Min ADX
input int     Inp_ADXPer    = 14;               // ADX period
input bool    Inp_UseRSI    = true;             // RSI guard
input int     Inp_RSIPer    = 14;               // RSI period
input int     Inp_RSI_OB    = 65;               // RSI Overbought
input int     Inp_RSI_OS    = 35;               // RSI Oversold

input group "════════ SESSION ════════"
input bool    Inp_UseSess      = true;          // Session filter
input int     Inp_SessStart    = 7;             // Start hour UTC
input int     Inp_SessEnd      = 21;            // End hour UTC

input group "════════ INDICATOR PARAMS ════════"
input int     Inp_ATRPer    = 14;
input double  Inp_STMult    = 1.7;
input int     Inp_HMAPer    = 10;
input int     Inp_WTCh      = 6;
input int     Inp_WTAvg     = 13;
input int     Inp_WTOB      = 53;
input int     Inp_WTOS      = -53;
input int     Inp_MACDFast  = 14;
input int     Inp_MACDSlow  = 28;
input int     Inp_MACDSig   = 11;
input double  Inp_UTKey     = 1.5;
input int     Inp_UTAtr     = 10;
input int     Inp_EMAPer    = 200;

input group "════════ DISPLAY ════════"
input bool    Inp_Dash      = true;

//+------------------------------------------------------------------+
//| Constants                                                         |
//+------------------------------------------------------------------+
#define NS 7

struct SPos {
   ulong  ticket;
   double entry, sl, tp1, tp2, lots;
   bool   tp1Hit, beHit;
   int    sid;
};

// v6: Pending pullback order
struct SPending {
   int    sid;           // strategy ID
   int    dir;           // 1=buy, -1=sell
   double limitPrice;    // entry price (pullback target)
   double slDist;        // SL distance from entry
   double tp1Dist;       // TP1 distance from entry
   double tp2Dist;       // TP2 distance from entry
   double lots;          // lot size
   int    barsRemaining; // bars until expiry
   bool   active;        // is this pending?
};

//+------------------------------------------------------------------+
//| Globals                                                           |
//+------------------------------------------------------------------+
CTrade      G_tr;
CSymbolInfo G_sy;

double C[],Hi[],Lo[],Op[],HLC3[],ATR[];
double ST_u[],ST_l[],ST_v[]; int ST_d[];
double HM[]; int HM_t[];
double W1[],W2[];
double ML[],MS[],MH[];
double UT_v[]; int UT_d[];
double E200[];

int H_ATR, H_MACD, H_ADX, H_RSI;
int H_ATR_Slow;
int H_HTF_EMA;
double ADX_val[], ADX_prev[], RSI_val[];
double ATR_Slow[];
SPos G_pos[];
SPending G_pend[];  // v6: pending pullback orders
bool G_on[NS];
double G_sl[NS], G_t1[NS], G_t2[NS];

// Market type
int g_mktType;
bool g_isBTC, g_isUS30;

// Tracking
int g_consLosses;
int g_consWins;       // v6: win streak tracking
int g_dailyLosses;
datetime g_lastLossDay;
double g_volRatio;
int g_htfTrend;

// Spread class
int g_spreadClass;
double g_spreadPct;

//+------------------------------------------------------------------+
//| Market detection                                                  |
//+------------------------------------------------------------------+
void DetectMarket()
{
   string s = _Symbol;
   StringToUpper(s);
   g_isBTC = (StringFind(s,"BTC")>=0||StringFind(s,"ETH")>=0||StringFind(s,"XRP")>=0||
              StringFind(s,"SOL")>=0||StringFind(s,"BNB")>=0||StringFind(s,"AAVE")>=0||
              StringFind(s,"DOGE")>=0||StringFind(s,"ADA")>=0||StringFind(s,"AVAX")>=0||
              StringFind(s,"LINK")>=0||StringFind(s,"DOT")>=0||StringFind(s,"CRYPTO")>=0);
   g_isUS30 = (StringFind(s,"US30")>=0||StringFind(s,"DJI")>=0||StringFind(s,"NAS")>=0||
               StringFind(s,"SPX")>=0||StringFind(s,"DAX")>=0||StringFind(s,"NDX")>=0||
               StringFind(s,"US500")>=0||StringFind(s,"USTEC")>=0);
   if(g_isBTC) g_mktType=1;
   else if(g_isUS30) g_mktType=2;
   else g_mktType=0;

   string su = _Symbol;
   StringToUpper(su);
   if(StringFind(su,"XAU")>=0) { g_mktType=2; g_isUS30=false; }
}

bool IsAllowed(int sid)
{
   if(!Inp_AutoFilter) return true;
   ENUM_TIMEFRAMES tf = Period();
   bool isM15 = (tf<=PERIOD_M30);
   bool isH1  = (tf==PERIOD_H1);

   // Index: allow on M15/M30 (v6 showed profitable)
   string su=_Symbol; StringToUpper(su);
   if(StringFind(su,"XAU")>=0) return true;

   // Crypto M15: still skip (not enough signal quality)
   if(g_isBTC && isM15) return false;
   // Crypto H1: S5, S7 only
   if(g_isBTC && isH1) return (sid==4 || sid==5);
   if(g_isBTC) return false;

   // Forex: all M15, H1
   if(g_mktType==0 && (isM15 || isH1)) return true;
   if(g_mktType==0) return false;

   return true;
}

//+------------------------------------------------------------------+
//| Init                                                              |
//+------------------------------------------------------------------+
int OnInit()
{
   G_tr.SetExpertMagicNumber(Inp_BaseMagic);
   G_tr.SetDeviationInPoints(10);
   G_tr.SetTypeFilling(ORDER_FILLING_IOC);
   G_sy.Name(_Symbol);

   H_MACD=iMACD(_Symbol,PERIOD_CURRENT,Inp_MACDFast,Inp_MACDSlow,Inp_MACDSig,PRICE_CLOSE);
   H_ATR=iATR(_Symbol,PERIOD_CURRENT,Inp_ATRPer);
   H_ADX=iADX(_Symbol,PERIOD_CURRENT,Inp_ADXPer);
   H_RSI=iRSI(_Symbol,PERIOD_CURRENT,Inp_RSIPer,PRICE_CLOSE);
   if(H_MACD==INVALID_HANDLE||H_ATR==INVALID_HANDLE) return INIT_FAILED;
   if(Inp_UseADX && H_ADX==INVALID_HANDLE) return INIT_FAILED;
   if(Inp_UseRSI && H_RSI==INVALID_HANDLE) return INIT_FAILED;

   H_ATR_Slow = iATR(_Symbol, PERIOD_CURRENT, 50);
   if(Inp_UseVolRegime && H_ATR_Slow==INVALID_HANDLE) return INIT_FAILED;

   H_HTF_EMA = INVALID_HANDLE;
   if(Inp_UseHTF)
   {
      H_HTF_EMA = iMA(_Symbol, Inp_HTF_TF, Inp_HTF_EMAPer, 0, MODE_EMA, PRICE_CLOSE);
      if(H_HTF_EMA == INVALID_HANDLE) Print("HTF EMA failed, continuing without");
   }

   ArraySetAsSeries(C,true);ArraySetAsSeries(Hi,true);ArraySetAsSeries(Lo,true);
   ArraySetAsSeries(Op,true);
   ArraySetAsSeries(HLC3,true);ArraySetAsSeries(ATR,true);
   ArraySetAsSeries(ML,true);ArraySetAsSeries(MS,true);ArraySetAsSeries(MH,true);
   ArraySetAsSeries(ST_v,true);ArraySetAsSeries(ST_u,true);ArraySetAsSeries(ST_l,true);ArraySetAsSeries(ST_d,true);
   ArraySetAsSeries(HM,true);ArraySetAsSeries(HM_t,true);
   ArraySetAsSeries(W1,true);ArraySetAsSeries(W2,true);
   ArraySetAsSeries(UT_v,true);ArraySetAsSeries(UT_d,true);
   ArraySetAsSeries(E200,true);
   ArraySetAsSeries(ADX_val,true);ArraySetAsSeries(ADX_prev,true);
   ArraySetAsSeries(RSI_val,true);ArraySetAsSeries(ATR_Slow,true);

   DetectMarket();

   G_on[0]=S1_On; G_on[1]=S2_On; G_on[2]=S3_On;
   G_on[3]=S4_On; G_on[4]=S5_On; G_on[5]=S7_On; G_on[6]=S8_On;
   for(int i=0;i<NS;i++)
      if(G_on[i] && !IsAllowed(i)) G_on[i]=false;

   G_sl[0]=1.0; G_t1[0]=1.5; G_t2[0]=3.0;
   G_sl[1]=1.5; G_t1[1]=2.0; G_t2[1]=4.0;
   G_sl[2]=1.0; G_t1[2]=1.5; G_t2[2]=3.0;
   G_sl[3]=1.5; G_t1[3]=2.0; G_t2[3]=4.0;
   G_sl[4]=1.5; G_t1[4]=2.0; G_t2[4]=4.0;
   G_sl[5]=1.5; G_t1[5]=2.0; G_t2[5]=4.0;
   G_sl[6]=2.0; G_t1[6]=3.0; G_t2[6]=6.0;

   g_consLosses = 0;
   g_consWins = 0;
   g_dailyLosses = 0;
   g_lastLossDay = 0;
   g_volRatio = 1.0;
   g_htfTrend = 0;

   ArrayResize(G_pend, 0);  // v6: no pending orders initially

   int cnt=0; for(int i=0;i<NS;i++) if(G_on[i]) cnt++;
   string mkt = g_isBTC?"CRYPTO":g_isUS30?"INDEX":"FOREX/COMM";
   Print("═══════════════════════════════════════════════");
   Print("  ProfitableOnly EA v6.0 — PULLBACK + ADX SLOPE");
   Print("  ",_Symbol," ",EnumToString(Period())," | ",mkt);
   Print("  Active: ",cnt,"/",NS," | Risk: ",Inp_Risk,"%");
   Print("  Pullback:",Inp_UsePullback?" ON":" OFF",
         " | ADXSlope:",Inp_UseADXSlope?" ON":" OFF",
         " | SessWt:",Inp_UseSessionWt?" ON":" OFF");
   Print("  DynTP:",Inp_UseDynTP?" ON":" OFF",
         " | SwingSL:",Inp_UseSwingSL?" ON":" OFF",
         " | WinBoost:",Inp_UseWinBoost?" ON":" OFF");
   if(cnt==0) Print("  WARNING: No strategies active!");
   Print("═══════════════════════════════════════════════");

   return INIT_SUCCEEDED;
}

void OnDeinit(const int r)
{
   if(H_MACD!=INVALID_HANDLE)IndicatorRelease(H_MACD);
   if(H_ATR!=INVALID_HANDLE)IndicatorRelease(H_ATR);
   if(H_ADX!=INVALID_HANDLE)IndicatorRelease(H_ADX);
   if(H_RSI!=INVALID_HANDLE)IndicatorRelease(H_RSI);
   if(H_ATR_Slow!=INVALID_HANDLE)IndicatorRelease(H_ATR_Slow);
   if(H_HTF_EMA!=INVALID_HANDLE)IndicatorRelease(H_HTF_EMA);
   Comment("");
}

//+------------------------------------------------------------------+
//| Tick                                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   ManagePos();
   CheckPendingPullbacks();  // v6: check if pullback orders should fill

   static datetime lb=0;
   datetime cb=iTime(_Symbol,PERIOD_CURRENT,0);
   if(cb==lb) return; lb=cb;

   // v6: Decrement pending order bars
   DecrementPendingBars();

   int N=250;
   if(CopyClose(_Symbol,PERIOD_CURRENT,0,N,C)<N)return;
   if(CopyHigh(_Symbol,PERIOD_CURRENT,0,N,Hi)<N)return;
   if(CopyLow(_Symbol,PERIOD_CURRENT,0,N,Lo)<N)return;
   if(CopyOpen(_Symbol,PERIOD_CURRENT,0,N,Op)<N)return;
   if(CopyBuffer(H_ATR,0,0,N,ATR)<N)return;
   if(CopyBuffer(H_MACD,0,0,N,ML)<N)return;
   if(CopyBuffer(H_MACD,1,0,N,MS)<N)return;
   if(CopyBuffer(H_MACD,2,0,N,MH)<N)return;

   if(Inp_UseADX && H_ADX!=INVALID_HANDLE)
   {
      CopyBuffer(H_ADX,0,0,N,ADX_val);
      // v6: Store ADX from N bars ago for slope check
      ArrayResize(ADX_prev, N);
      ArraySetAsSeries(ADX_prev, true);
      CopyBuffer(H_ADX,0,0,N,ADX_prev);
   }
   if(Inp_UseRSI && H_RSI!=INVALID_HANDLE) CopyBuffer(H_RSI,0,0,N,RSI_val);

   if(H_ATR_Slow!=INVALID_HANDLE)
   {
      ArrayResize(ATR_Slow,N);
      CopyBuffer(H_ATR_Slow,0,0,N,ATR_Slow);
   }

   ArrayResize(HLC3,N);
   for(int i=0;i<N;i++) HLC3[i]=(Hi[i]+Lo[i]+C[i])/3.0;

   xST(N); xHMA(N); xWT(N); xUT(N); xEMA(N);

   UpdateVolRegime();
   UpdateHTFTrend();
   ResetDailyLosses();

   bool sok=SessOK(), spok=SpreadOK();
   bool volOk = VolRegimeOK();
   bool dailyOk = DailyLossOK();

   int sig[NS]; ArrayInitialize(sig,0);
   if(G_on[0]) sig[0]=SigS1();
   if(G_on[1]) sig[1]=SigS2();
   if(G_on[2]) sig[2]=SigS3();
   if(G_on[3]) sig[3]=SigS4();
   if(G_on[4]) sig[4]=SigS5();
   if(G_on[5]) sig[5]=SigS7();
   if(G_on[6]) sig[6]=SigS8();

   for(int s=0;s<NS;s++)
   {
      if(!G_on[s]||sig[s]==0) continue;
      if(!g_isBTC && !sok) continue;
      if(!spok) continue;
      if(!volOk) continue;
      if(!dailyOk) continue;
      if(!HTFAgrees(sig[s])) continue;
      if(!CandleStrong(sig[s])) continue;
      if(!ADXSlopeOK()) continue;       // v6: ADX slope check
      if(CntP(s)>=1) continue;
      if(HasPending(s)) continue;        // v6: skip if pullback pending
      Open(s,sig[s]);
   }

   if(Inp_Dash) Dash(sig);
}

//+------------------------------------------------------------------+
//| INDICATORS                                                        |
//+------------------------------------------------------------------+
void xST(int n)
{
   ArrayResize(ST_u,n);ArrayResize(ST_l,n);ArrayResize(ST_v,n);ArrayResize(ST_d,n);
   for(int i=n-1;i>=0;i--){
      double a=ATR[i];if(a==0||a!=a){if(i<n-1){ST_u[i]=ST_u[i+1];ST_l[i]=ST_l[i+1];ST_d[i]=ST_d[i+1];ST_v[i]=ST_v[i+1];}continue;}
      double u=C[i]+Inp_STMult*a,l=C[i]-Inp_STMult*a;
      if(i==n-1){ST_u[i]=u;ST_l[i]=l;ST_d[i]=1;}
      else{
         ST_l[i]=(l>ST_l[i+1]||C[i+1]<ST_l[i+1])?l:ST_l[i+1];
         ST_u[i]=(u<ST_u[i+1]||C[i+1]>ST_u[i+1])?u:ST_u[i+1];
         if(ST_d[i+1]==-1&&C[i]>ST_u[i])ST_d[i]=1;
         else if(ST_d[i+1]==1&&C[i]<ST_l[i])ST_d[i]=-1;
         else ST_d[i]=ST_d[i+1];
      }
      ST_v[i]=(ST_d[i]==1)?ST_l[i]:ST_u[i];
   }
}

double Wm(double&d[],int s,int p){double sm=0,ws=0;for(int i=0;i<p&&(s+i)<ArraySize(d);i++){double w=(double)(p-i);sm+=d[s+i]*w;ws+=w;}return ws>0?sm/ws:0;}
void xHMA(int n)
{
   ArrayResize(HM,n);ArrayResize(HM_t,n);ArrayInitialize(HM,0);ArrayInitialize(HM_t,0);
   int hp=(int)MathFloor(Inp_HMAPer/2.0),sp=(int)MathFloor(MathSqrt((double)Inp_HMAPer));
   if(hp<1)hp=1;if(sp<1)sp=1;if(n<Inp_HMAPer+sp+5)return;
   double hs[];ArrayResize(hs,n);ArraySetAsSeries(hs,true);
   for(int i=0;i<n-Inp_HMAPer;i++)hs[i]=2.0*Wm(C,i,hp)-Wm(C,i,Inp_HMAPer);
   for(int i=0;i<n-Inp_HMAPer-sp;i++)HM[i]=Wm(hs,i,sp);
   for(int i=0;i<n-Inp_HMAPer-sp-1;i++)HM_t[i]=(HM[i]>HM[i+1])?1:-1;
}

void xE(double&s[],double&d[],int n,int p){double m=2.0/(p+1.0);d[n-1]=s[n-1];for(int i=n-2;i>=0;i--)d[i]=s[i]*m+d[i+1]*(1-m);}
void xWT(int n)
{
   ArrayResize(W1,n);ArrayResize(W2,n);ArrayInitialize(W1,0);ArrayInitialize(W2,0);
   if(n<Inp_WTCh+Inp_WTAvg+10)return;
   double eh[],df[],ad[],ed[],ead[],ci[];
   ArrayResize(eh,n);ArrayResize(df,n);ArrayResize(ad,n);ArrayResize(ed,n);ArrayResize(ead,n);ArrayResize(ci,n);
   ArraySetAsSeries(eh,true);ArraySetAsSeries(df,true);ArraySetAsSeries(ad,true);
   ArraySetAsSeries(ed,true);ArraySetAsSeries(ead,true);ArraySetAsSeries(ci,true);
   xE(HLC3,eh,n,Inp_WTCh);
   for(int i=0;i<n;i++){df[i]=HLC3[i]-eh[i];ad[i]=MathAbs(df[i]);}
   xE(df,ed,n,Inp_WTCh);xE(ad,ead,n,Inp_WTCh);
   for(int i=0;i<n;i++){double dn=0.015*ead[i];ci[i]=(dn!=0)?ed[i]/dn:0;}
   xE(ci,W1,n,Inp_WTAvg);
   for(int i=0;i<n-4;i++)W2[i]=(W1[i]+W1[i+1]+W1[i+2]+W1[i+3])/4.0;
}

void xUT(int n)
{
   ArrayResize(UT_v,n);ArrayResize(UT_d,n);ArrayInitialize(UT_v,0);ArrayInitialize(UT_d,0);
   double ua[];ArrayResize(ua,n);ArraySetAsSeries(ua,true);
   if(Inp_UTAtr==Inp_ATRPer)ArrayCopy(ua,ATR);
   else{int h=iATR(_Symbol,PERIOD_CURRENT,Inp_UTAtr);if(h!=INVALID_HANDLE){CopyBuffer(h,0,0,n,ua);IndicatorRelease(h);}else ArrayCopy(ua,ATR);}
   UT_v[n-1]=C[n-1];UT_d[n-1]=0;
   for(int i=n-2;i>=0;i--){
      double nL=Inp_UTKey*ua[i];if(nL==0||nL!=nL)nL=Inp_UTKey*ATR[i];
      if(C[i]>UT_v[i+1]&&C[i+1]>UT_v[i+1])UT_v[i]=MathMax(UT_v[i+1],C[i]-nL);
      else if(C[i]<UT_v[i+1]&&C[i+1]<UT_v[i+1])UT_v[i]=MathMin(UT_v[i+1],C[i]+nL);
      else if(C[i]>UT_v[i+1])UT_v[i]=C[i]-nL;
      else UT_v[i]=C[i]+nL;
      if(C[i]>UT_v[i]&&C[i+1]<=UT_v[i+1])UT_d[i]=1;
      else if(C[i]<UT_v[i]&&C[i+1]>=UT_v[i+1])UT_d[i]=-1;
      else UT_d[i]=UT_d[i+1];
   }
}

void xEMA(int n){ArrayResize(E200,n);double m=2.0/(Inp_EMAPer+1.0);E200[n-1]=C[n-1];for(int i=n-2;i>=0;i--)E200[i]=C[i]*m+E200[i+1]*(1-m);}

//+------------------------------------------------------------------+
//| Signal helpers                                                    |
//+------------------------------------------------------------------+
bool OK(){return(ArraySize(ST_d)>3&&ArraySize(HM_t)>2&&ArraySize(W1)>3&&ArraySize(MH)>2);}
bool StBF(){return ST_d[1]==1&&ST_d[2]==-1;} bool StSF(){return ST_d[1]==-1&&ST_d[2]==1;}
bool StBu(){return ST_d[1]==1;}               bool StBe(){return ST_d[1]==-1;}
bool HmBF(){return HM_t[1]==1&&HM_t[2]==-1;} bool HmSF(){return HM_t[1]==-1&&HM_t[2]==1;}
bool HmBu(){return HM_t[1]==1;}               bool HmBe(){return HM_t[1]==-1;}
bool WtBu(){return W1[1]>W2[1]&&W1[1]<Inp_WTOB;} bool WtBe(){return W1[1]<W2[1]&&W1[1]>Inp_WTOS;}
bool WtBX(){return W1[1]>W2[1]&&W1[2]<=W2[2]&&W1[1]<Inp_WTOB;}
bool WtSX(){return W1[1]<W2[1]&&W1[2]>=W2[2]&&W1[1]>Inp_WTOS;}
bool McBu(){return MH[1]>0||MH[1]>MH[2];} bool McBe(){return MH[1]<0||MH[1]<MH[2];}
bool UtBF(){return ArraySize(UT_d)>2&&UT_d[1]==1&&UT_d[2]!=1;}
bool UtSF(){return ArraySize(UT_d)>2&&UT_d[1]==-1&&UT_d[2]!=-1;}

bool ADXok(){
   if(!Inp_UseADX) return true;
   if(ArraySize(ADX_val)<2) return true;
   return (!MathIsValidNumber(ADX_val[1]) ? true : ADX_val[1]>=Inp_ADXMin);
}
bool RSIbuyOk(){
   if(!Inp_UseRSI) return true;
   if(ArraySize(RSI_val)<2) return true;
   return (RSI_val[1]<Inp_RSI_OB && RSI_val[1]>40);
}
bool RSIsellOk(){
   if(!Inp_UseRSI) return true;
   if(ArraySize(RSI_val)<2) return true;
   return (RSI_val[1]>Inp_RSI_OS && RSI_val[1]<60);
}
bool FilterBuy(){return ADXok()&&RSIbuyOk();}
bool FilterSell(){return ADXok()&&RSIsellOk();}

//+------------------------------------------------------------------+
//| v6.0: ADX slope filter — require rising ADX                       |
//+------------------------------------------------------------------+
bool ADXSlopeOK()
{
   if(!Inp_UseADXSlope) return true;
   if(ArraySize(ADX_val) < Inp_ADXSlopeBars + 2) return true;
   // ADX must be higher now than N bars ago
   double adxNow = ADX_val[1];
   double adxPrev = ADX_val[1 + Inp_ADXSlopeBars];
   if(!MathIsValidNumber(adxNow) || !MathIsValidNumber(adxPrev)) return true;
   return (adxNow > adxPrev);  // ADX rising = strengthening trend
}

//+------------------------------------------------------------------+
//| v4.0 filters (kept from v4)                                       |
//+------------------------------------------------------------------+
void UpdateVolRegime()
{
   g_volRatio = 1.0;
   if(!Inp_UseVolRegime) return;
   if(ArraySize(ATR)<2 || ArraySize(ATR_Slow)<2) return;
   if(ATR_Slow[1] > 0) g_volRatio = ATR[1] / ATR_Slow[1];
}
bool VolRegimeOK()
{
   if(!Inp_UseVolRegime) return true;
   return (g_volRatio >= Inp_VolMinRatio && g_volRatio <= Inp_VolMaxRatio);
}

void UpdateHTFTrend()
{
   g_htfTrend = 0;
   if(!Inp_UseHTF || H_HTF_EMA == INVALID_HANDLE) return;
   double htfEma[2], htfClose[2];
   if(CopyBuffer(H_HTF_EMA, 0, 0, 2, htfEma) < 2) return;
   if(CopyClose(_Symbol, Inp_HTF_TF, 0, 2, htfClose) < 2) return;
   ArraySetAsSeries(htfEma, true);
   ArraySetAsSeries(htfClose, true);
   if(htfClose[1] > htfEma[1]) g_htfTrend = 1;
   else if(htfClose[1] < htfEma[1]) g_htfTrend = -1;
}
bool HTFAgrees(int dir)
{
   if(!Inp_UseHTF || H_HTF_EMA == INVALID_HANDLE) return true;
   if(g_htfTrend == 0) return true;
   return (dir == g_htfTrend);
}

bool CandleStrong(int dir)
{
   if(!Inp_UseCandleStr) return true;
   if(ArraySize(C)<2 || ArraySize(Hi)<2 || ArraySize(Lo)<2) return true;
   double open_v = (ArraySize(Op)>1) ? Op[1] : iOpen(_Symbol, PERIOD_CURRENT, 1);
   double close_v = C[1];
   double range = Hi[1] - Lo[1];
   if(range == 0) return false;
   double body = MathAbs(close_v - open_v);
   if((body / range) * 100.0 < Inp_CandleMinPct) return false;
   if(dir == 1 && close_v < open_v) return false;
   if(dir == -1 && close_v > open_v) return false;
   return true;
}

void ResetDailyLosses()
{
   if(Inp_MaxDailyLoss <= 0) return;
   MqlDateTime dt; TimeGMT(dt);
   datetime today = (datetime)(dt.year * 10000 + dt.mon * 100 + dt.day);
   if(today != g_lastLossDay) { g_dailyLosses = 0; g_lastLossDay = today; }
}
bool DailyLossOK()
{
   if(Inp_MaxDailyLoss <= 0) return true;
   return (g_dailyLosses < Inp_MaxDailyLoss);
}
void RecordLoss() { g_consLosses++; g_consWins = 0; g_dailyLosses++; }
void RecordWin()  { g_consWins++;   g_consLosses = 0; }

//+------------------------------------------------------------------+
//| v6.0: Session quality weighting                                   |
//+------------------------------------------------------------------+
double GetSessionMultiplier()
{
   if(!Inp_UseSessionWt) return 1.0;
   MqlDateTime dt; TimeGMT(dt);
   int hr = dt.hour;
   if(hr >= 7  && hr <= 10) return Inp_LondonBoost;   // London open
   if(hr >= 13 && hr <= 16) return Inp_NYBoost;        // NY open
   if(hr >= 0  && hr <= 6)  return Inp_AsianReduce;    // Asian
   if(hr >= 17 && hr <= 20) return Inp_LateReduce;     // Late
   return 1.0;
}

//+------------------------------------------------------------------+
//| v6.0: Effective risk (loss guard + win boost + session)            |
//+------------------------------------------------------------------+
double GetEffectiveRisk()
{
   double r = Inp_Risk;

   // Session weighting
   r *= GetSessionMultiplier();

   // Loss guard
   if(Inp_UseLossGuard && g_consLosses >= Inp_LossStreak)
      r *= Inp_LossRiskMult;

   // Win streak boost
   if(Inp_UseWinBoost && g_consWins >= Inp_WinStreak)
      r *= Inp_WinRiskMult;

   // Cap
   return MathMin(r, Inp_MaxRisk);
}

//+------------------------------------------------------------------+
//| Spread class & SL adjustment (kept from v4)                       |
//+------------------------------------------------------------------+
void UpdateSpreadClass()
{
   G_sy.RefreshRates();
   double mid = (G_sy.Ask() + G_sy.Bid()) / 2.0;
   if(mid <= 0) { g_spreadClass = 0; g_spreadPct = 0; return; }
   double spread = G_sy.Spread() * G_sy.Point();
   g_spreadPct = (spread / mid) * 100.0;
   if(g_spreadPct >= 0.20)      g_spreadClass = 2;
   else if(g_spreadPct >= 0.05) g_spreadClass = 1;
   else                         g_spreadClass = 0;
}

double GetSpreadSLMult()
{
   if(!Inp_UseSpreadClass) return 1.0;
   if(g_spreadClass == 2) return Inp_HighSpreadSLMult;
   if(g_spreadClass == 1) return Inp_MedSpreadSLMult;
   return 1.0;
}

bool SpreadRROK(double slDist, double tpDist, double spread)
{
   if(Inp_MinRRAfterSpread <= 0) return true;
   double esl = slDist + spread;
   double etp = tpDist - spread;
   if(esl <= 0) return false;
   return (etp / esl >= Inp_MinRRAfterSpread);
}

//+------------------------------------------------------------------+
//| v6.0: Dynamic TP scaling based on ATR expansion                   |
//+------------------------------------------------------------------+
double GetDynTPScale()
{
   if(!Inp_UseDynTP) return 1.0;
   if(ArraySize(ATR)<2 || ArraySize(ATR_Slow)<2) return 1.0;
   if(ATR_Slow[1] <= 0) return 1.0;
   double ratio = ATR[1] / ATR_Slow[1];
   if(ratio > 1.3) return Inp_DynTPExpand;    // trending → wider TP
   if(ratio < 0.7) return Inp_DynTPContract;  // quiet → tighter TP
   return 1.0;
}

//+------------------------------------------------------------------+
//| v6.0: Swing-based SL                                              |
//+------------------------------------------------------------------+
double GetSwingSL(int dir)
{
   if(!Inp_UseSwingSL) return 0;
   if(ArraySize(Hi) < Inp_SwingLookback + 2 || ArraySize(Lo) < Inp_SwingLookback + 2) return 0;

   double swingVal = 0;
   if(dir == 1)  // Buy → SL below recent swing low
   {
      swingVal = Lo[1];
      for(int i = 2; i <= Inp_SwingLookback + 1 && i < ArraySize(Lo); i++)
         swingVal = MathMin(swingVal, Lo[i]);
   }
   else  // Sell → SL above recent swing high
   {
      swingVal = Hi[1];
      for(int i = 2; i <= Inp_SwingLookback + 1 && i < ArraySize(Hi); i++)
         swingVal = MathMax(swingVal, Hi[i]);
   }
   return swingVal;
}

//+------------------------------------------------------------------+
//| Adaptive SL/TP (from v4)                                          |
//+------------------------------------------------------------------+
void GetAdaptiveSLTP(int sid, double &sl_m, double &tp1_m, double &tp2_m)
{
   sl_m  = G_sl[sid];
   tp1_m = G_t1[sid];
   tp2_m = G_t2[sid];
   if(!Inp_UseAdaptSLTP) return;
   if(g_volRatio > 1.3) { tp1_m *= 1.3; tp2_m *= 1.5; }
   else if(g_volRatio < 0.8) { sl_m *= 0.8; tp1_m *= 0.8; tp2_m *= 0.8; }
}

//+------------------------------------------------------------------+
//| STRATEGIES                                                        |
//+------------------------------------------------------------------+
int SigS1(){if(!OK())return 0;if(StBF()&&HmBu()&&FilterBuy())return 1;if(StSF()&&HmBe()&&FilterSell())return-1;return 0;}

int SigS2()
{
   if(!OK())return 0;
   if(StBF()&&FilterBuy()){int c=0;if(HmBu())c++;if(WtBu())c++;if(McBu())c++;if(c>=2)return 1;}
   if(StSF()&&FilterSell()){int c=0;if(HmBe())c++;if(WtBe())c++;if(McBe())c++;if(c>=2)return-1;}
   return 0;
}

int SigS3()
{
   if(!OK())return 0;
   if(UtBF()&&FilterBuy()){int c=0;if(HmBu())c++;if(WtBu())c++;if(McBu())c++;if(c>=2)return 1;}
   if(UtSF()&&FilterSell()){int c=0;if(HmBe())c++;if(WtBe())c++;if(McBe())c++;if(c>=2)return-1;}
   return 0;
}

int SigS4()
{
   if(!OK())return 0;
   if(UtBF()&&FilterBuy()){int c=0;if(StBu())c++;if(HmBu())c++;if(McBu())c++;if(c>=2)return 1;}
   if(UtSF()&&FilterSell()){int c=0;if(StBe())c++;if(HmBe())c++;if(McBe())c++;if(c>=2)return-1;}
   return 0;
}

int SigS5(){if(!OK())return 0;if(HmBF()&&StBu()&&McBu()&&FilterBuy())return 1;if(HmSF()&&StBe()&&McBe()&&FilterSell())return-1;return 0;}
int SigS7(){if(!OK())return 0;if(WtBX()&&StBu()&&HmBu()&&FilterBuy())return 1;if(WtSX()&&StBe()&&HmBe()&&FilterSell())return-1;return 0;}

int SigS8()
{
   if(!OK())return 0;
   if(StBF()&&FilterBuy()){int c=0;if(HmBu())c++;if(WtBu())c++;if(McBu())c++;if(ArraySize(E200)>1&&C[1]>E200[1])c++;if(c>=3)return 1;}
   if(StSF()&&FilterSell()){int c=0;if(HmBe())c++;if(WtBe())c++;if(McBe())c++;if(ArraySize(E200)>1&&C[1]<E200[1])c++;if(c>=3)return-1;}
   return 0;
}

//+------------------------------------------------------------------+
//| Session & Spread                                                  |
//+------------------------------------------------------------------+
bool SessOK(){if(!Inp_UseSess)return true;MqlDateTime dt;TimeGMT(dt);return(dt.hour>=Inp_SessStart&&dt.hour<Inp_SessEnd);}
bool SpreadOK(){if(ArraySize(ATR)<2||ATR[1]==0)return true;G_sy.RefreshRates();return(G_sy.Spread()*G_sy.Point()<=ATR[1]*Inp_MaxSpreadATR);}

//+------------------------------------------------------------------+
//| v6.0: Pending pullback management                                 |
//+------------------------------------------------------------------+
bool HasPending(int sid)
{
   for(int i=0; i<ArraySize(G_pend); i++)
      if(G_pend[i].active && G_pend[i].sid == sid) return true;
   return false;
}

void AddPending(SPending &p)
{
   int sz = ArraySize(G_pend);
   ArrayResize(G_pend, sz + 1);
   G_pend[sz] = p;
}

void DecrementPendingBars()
{
   for(int i = ArraySize(G_pend)-1; i >= 0; i--)
   {
      if(!G_pend[i].active) continue;
      G_pend[i].barsRemaining--;
      if(G_pend[i].barsRemaining <= 0)
      {
         G_pend[i].active = false;
         // Clean up
         int last = ArraySize(G_pend) - 1;
         if(i < last) G_pend[i] = G_pend[last];
         ArrayResize(G_pend, last);
      }
   }
}

void CheckPendingPullbacks()
{
   G_sy.RefreshRates();
   double bid = G_sy.Bid();
   double ask = G_sy.Ask();

   for(int i = ArraySize(G_pend)-1; i >= 0; i--)
   {
      if(!G_pend[i].active) continue;
      if(CntP(G_pend[i].sid) >= 1)
      {
         G_pend[i].active = false;
         int last = ArraySize(G_pend) - 1;
         if(i < last) G_pend[i] = G_pend[last];
         ArrayResize(G_pend, last);
         continue;
      }

      bool fill = false;
      double ep = 0;
      ENUM_ORDER_TYPE ot;
      int dg = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

      if(G_pend[i].dir == 1)
      {
         // Buy limit: fill when price drops to limit
         if(ask <= G_pend[i].limitPrice)
         {
            fill = true;
            ep = ask;
            ot = ORDER_TYPE_BUY;
         }
      }
      else
      {
         // Sell limit: fill when price rises to limit
         if(bid >= G_pend[i].limitPrice)
         {
            fill = true;
            ep = bid;
            ot = ORDER_TYPE_SELL;
         }
      }

      if(fill)
      {
         double sl, tp2;
         if(G_pend[i].dir == 1)
         {
            sl = NormalizeDouble(ep - G_pend[i].slDist, dg);
            tp2 = NormalizeDouble(ep + G_pend[i].tp2Dist, dg);
         }
         else
         {
            sl = NormalizeDouble(ep + G_pend[i].slDist, dg);
            tp2 = NormalizeDouble(ep - G_pend[i].tp2Dist, dg);
         }

         double lots = G_pend[i].lots;
         int magic = Inp_BaseMagic + G_pend[i].sid + 1;
         G_tr.SetExpertMagicNumber(magic);

         string nm[]={"S1","S2","S3","S4","S5","S7","S8"};
         string sname = (G_pend[i].sid < NS) ? nm[G_pend[i].sid] : "S?";

         if(G_tr.PositionOpen(_Symbol, ot, lots, ep, sl, tp2, sname + " PB"))
         {
            double tp1_price;
            if(G_pend[i].dir == 1)
               tp1_price = ep + G_pend[i].tp1Dist;
            else
               tp1_price = ep - G_pend[i].tp1Dist;

            SPos p;
            p.ticket = G_tr.ResultOrder();
            p.entry = ep; p.sl = sl;
            p.tp1 = tp1_price; p.tp2 = tp2;
            p.tp1Hit = false; p.beHit = false;
            p.lots = lots; p.sid = G_pend[i].sid;

            int sz = ArraySize(G_pos);
            ArrayResize(G_pos, sz + 1);
            G_pos[sz] = p;

            Print(StringFormat("[%s] PULLBACK %s Entry:%.5f (limit:%.5f) SL:%.5f TP2:%.5f Lots:%.2f",
                  sname, (G_pend[i].dir==1)?"BUY":"SELL", ep, G_pend[i].limitPrice, sl, tp2, lots));
         }

         // Remove pending
         G_pend[i].active = false;
         int last = ArraySize(G_pend) - 1;
         if(i < last) G_pend[i] = G_pend[last];
         ArrayResize(G_pend, last);
      }
   }
}

//+------------------------------------------------------------------+
//| Trade execution (v6: with pullback + swing SL + dynamic TP)       |
//+------------------------------------------------------------------+
void Open(int sid, int dir)
{
   G_sy.RefreshRates();
   double a = ATR[1]; if(a == 0 || a != a) return;
   double ask = G_sy.Ask(), bid = G_sy.Bid();
   int dg = G_sy.Digits(), magic = Inp_BaseMagic + sid + 1;

   // Adaptive SL/TP
   double sl_m, tp1_m, tp2_m;
   GetAdaptiveSLTP(sid, sl_m, tp1_m, tp2_m);

   // v6: Dynamic TP scaling
   double tpScale = GetDynTPScale();
   tp1_m *= tpScale;
   tp2_m *= tpScale;

   // Spread class
   UpdateSpreadClass();
   double spreadSLMult = GetSpreadSLMult();
   sl_m *= spreadSLMult;

   double spread = G_sy.Spread() * G_sy.Point();

   // v6: Swing-based SL
   double swingSL = GetSwingSL(dir);
   double ep_est = (dir == 1) ? ask : bid;

   double slDist;
   if(Inp_UseSwingSL && swingSL > 0)
   {
      double swingDist = MathAbs(ep_est - swingSL);
      double atrDist = sl_m * a + spread;
      // Use the tighter of swing and ATR-based SL (better R:R)
      slDist = MathMin(swingDist, atrDist);
      // But ensure minimum distance (at least 0.5 ATR + spread)
      slDist = MathMax(slDist, 0.5 * a + spread);
   }
   else
   {
      slDist = sl_m * a + spread;
   }

   // R:R check
   double tpDist = tp2_m * a;
   if(!SpreadRROK(slDist, tpDist, spread)) return;

   // Effective risk
   double effRisk = GetEffectiveRisk();

   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double usedMargin = AccountInfoDouble(ACCOUNT_MARGIN);

   double lots;
   if(Inp_FixedLots > 0)
   {
      lots = Inp_FixedLots;
      if(Inp_UseLossGuard && g_consLosses >= Inp_LossStreak)
         lots *= Inp_LossRiskMult;
   }
   else
   {
      double risk = bal * effRisk / 100.0;
      if(slDist == 0) return;
      double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tv == 0 || ts == 0) return;
      lots = NormalizeDouble(risk / (slDist / ts * tv), 2);
   }

   double lstep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double mL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double xL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   lots = MathMax(mL, MathMin(xL, MathMax(Inp_MinLot, MathMin(Inp_MaxLot, lots))));
   lots = NormalizeDouble(MathFloor(lots / lstep) * lstep, 2);
   if(lots < mL) return;

   // Margin check
   double requiredMargin = lots * SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE) * ep_est;
   if(Inp_Leverage > 0) requiredMargin /= Inp_Leverage;
   double totalMarginAfter = usedMargin + requiredMargin;
   if(totalMarginAfter > bal * Inp_MaxMarginPct / 100.0)
   {
      double availMargin = bal * Inp_MaxMarginPct / 100.0 - usedMargin;
      if(availMargin <= 0) return;
      double contractVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE) * ep_est;
      if(Inp_Leverage > 0) contractVal /= Inp_Leverage;
      lots = NormalizeDouble(MathFloor((availMargin / contractVal) / lstep) * lstep, 2);
      if(lots < mL) return;
   }

   // v6: PULLBACK ENTRY
   if(Inp_UsePullback && ArraySize(Hi) > 1 && ArraySize(Lo) > 1)
   {
      double candleRange = Hi[1] - Lo[1];
      if(candleRange > 0)
      {
         SPending pend;
         pend.sid = sid;
         pend.dir = dir;
         pend.lots = lots;
         pend.slDist = slDist;
         pend.tp1Dist = tp1_m * a;
         pend.tp2Dist = tp2_m * a;
         pend.barsRemaining = Inp_PullbackExpiry;
         pend.active = true;

         if(dir == 1)
            pend.limitPrice = NormalizeDouble(ep_est - candleRange * Inp_PullbackPct, dg);
         else
            pend.limitPrice = NormalizeDouble(ep_est + candleRange * Inp_PullbackPct, dg);

         AddPending(pend);

         string nm[]={"S1","S2","S3","S4","S5","S7","S8"};
         Print(StringFormat("[%s] PULLBACK PENDING %s Limit:%.5f (%.0f%% retrace) SL:%.5f Lots:%.2f Exp:%d bars R:%.1f%%",
               nm[sid], (dir==1)?"BUY":"SELL", pend.limitPrice, Inp_PullbackPct*100,
               slDist, lots, Inp_PullbackExpiry, effRisk));
         return;
      }
   }

   // IMMEDIATE ENTRY (fallback if pullback disabled)
   double ep, sl, t1, t2;
   ENUM_ORDER_TYPE ot;
   if(dir == 1)
   {
      ep = ask;
      sl = NormalizeDouble(ep - slDist, dg);
      t1 = NormalizeDouble(ep + tp1_m * a, dg);
      t2 = NormalizeDouble(ep + tp2_m * a, dg);
      ot = ORDER_TYPE_BUY;
   }
   else
   {
      ep = bid;
      sl = NormalizeDouble(ep + slDist, dg);
      t1 = NormalizeDouble(ep - tp1_m * a, dg);
      t2 = NormalizeDouble(ep - tp2_m * a, dg);
      ot = ORDER_TYPE_SELL;
   }

   G_tr.SetExpertMagicNumber(magic);
   string nm[]={"S1","S2","S3","S4","S5","S7","S8"};
   if(G_tr.PositionOpen(_Symbol, ot, lots, ep, sl, t2, nm[sid]))
   {
      SPos p; p.ticket = G_tr.ResultOrder(); p.entry = ep; p.sl = sl;
      p.tp1 = t1; p.tp2 = t2; p.tp1Hit = false; p.beHit = false;
      p.lots = lots; p.sid = sid;
      int sz = ArraySize(G_pos); ArrayResize(G_pos, sz + 1); G_pos[sz] = p;
      Print(StringFormat("[%s] %s Entry:%.5f SL:%.5f TP1:%.5f TP2:%.5f Lots:%.2f R:%.1f%% Vol:%.2f",
            nm[sid], (dir==1)?"BUY":"SELL", ep, sl, t1, t2, lots, effRisk, g_volRatio));
   }
}

//+------------------------------------------------------------------+
//| Position management (v6: faster BE)                               |
//+------------------------------------------------------------------+
void ManagePos()
{
   for(int i=ArraySize(G_pos)-1;i>=0;i--)
   {
      if(!PositionSelectByTicket(G_pos[i].ticket))
      {
         if(HistoryDealSelect(G_pos[i].ticket))
         {
            double profit = HistoryDealGetDouble(G_pos[i].ticket, DEAL_PROFIT);
            if(profit >= 0) RecordWin(); else RecordLoss();
         }
         Rm(i);
         continue;
      }

      ENUM_POSITION_TYPE pt=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double cp=(pt==POSITION_TYPE_BUY)?SymbolInfoDouble(_Symbol,SYMBOL_BID):SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      int dg=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
      int magic=Inp_BaseMagic+G_pos[i].sid+1;
      double curProfit = PositionGetDouble(POSITION_PROFIT);

      // v6: Faster BE ratchet (40% of TP1 distance, was 50%)
      if(Inp_UseBERatchet && !G_pos[i].beHit && !G_pos[i].tp1Hit)
      {
         double tp1Dist = MathAbs(G_pos[i].tp1 - G_pos[i].entry);
         double beTarget;
         if(pt==POSITION_TYPE_BUY)
            beTarget = G_pos[i].entry + tp1Dist * Inp_FastBEPct;
         else
            beTarget = G_pos[i].entry - tp1Dist * Inp_FastBEPct;

         bool beReached = false;
         if(pt==POSITION_TYPE_BUY && cp >= beTarget) beReached = true;
         if(pt==POSITION_TYPE_SELL && cp <= beTarget) beReached = true;

         if(beReached)
         {
            double spread = G_sy.Spread() * G_sy.Point();
            double beSL;
            if(pt==POSITION_TYPE_BUY)
               beSL = NormalizeDouble(G_pos[i].entry + spread * 1.5, dg);
            else
               beSL = NormalizeDouble(G_pos[i].entry - spread * 1.5, dg);

            G_tr.SetExpertMagicNumber(magic);
            if(G_tr.PositionModify(G_pos[i].ticket, beSL, G_pos[i].tp2))
            {
               G_pos[i].beHit = true;
               G_pos[i].sl = beSL;
            }
         }
      }

      // TP1 partial close
      if(!G_pos[i].tp1Hit)
      {
         bool hit=(pt==POSITION_TYPE_BUY&&cp>=G_pos[i].tp1)||(pt==POSITION_TYPE_SELL&&cp<=G_pos[i].tp1);
         if(hit)
         {
            double cl=NormalizeDouble(G_pos[i].lots*0.5,2);
            double ls=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
            cl=NormalizeDouble(MathFloor(cl/ls)*ls,2);
            if(cl>=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN))
            {
               G_tr.SetExpertMagicNumber(magic);
               G_tr.PositionClosePartial(G_pos[i].ticket,cl);
               G_pos[i].tp1Hit=true;
               double sp = G_sy.Spread() * G_sy.Point();
               double beSL2;
               if(pt==POSITION_TYPE_BUY)
                  beSL2 = NormalizeDouble(G_pos[i].entry + sp, dg);
               else
                  beSL2 = NormalizeDouble(G_pos[i].entry - sp, dg);
               G_tr.PositionModify(G_pos[i].ticket, beSL2, G_pos[i].tp2);
               G_pos[i].sl = beSL2;
               RecordWin();
            }
         }
      }

      // ATR trailing after TP1
      if(G_pos[i].tp1Hit && Inp_UseATRTrail && ArraySize(ATR)>1)
      {
         double csl = PositionGetDouble(POSITION_SL);
         double atrTrail = Inp_ATRTrailMult * ATR[1];
         G_tr.SetExpertMagicNumber(magic);
         if(pt==POSITION_TYPE_BUY)
         {
            double ns = NormalizeDouble(cp - atrTrail, dg);
            if(ns > csl && ns < cp) G_tr.PositionModify(G_pos[i].ticket, ns, G_pos[i].tp2);
         }
         else
         {
            double ns = NormalizeDouble(cp + atrTrail, dg);
            if((ns < csl || csl == 0) && ns > cp) G_tr.PositionModify(G_pos[i].ticket, ns, G_pos[i].tp2);
         }
      }
      else if(G_pos[i].tp1Hit && !Inp_UseATRTrail && ArraySize(ST_v)>1)
      {
         double stl=ST_v[1],csl=PositionGetDouble(POSITION_SL);
         G_tr.SetExpertMagicNumber(magic);
         if(pt==POSITION_TYPE_BUY){double ns=NormalizeDouble(stl,dg);if(ns>csl&&ns<cp)G_tr.PositionModify(G_pos[i].ticket,ns,G_pos[i].tp2);}
         else{double ns=NormalizeDouble(stl,dg);if((ns<csl||csl==0)&&ns>cp)G_tr.PositionModify(G_pos[i].ticket,ns,G_pos[i].tp2);}
      }

      // Momentum exit
      if(Inp_MomExit && !G_pos[i].tp1Hit && ArraySize(MH)>2 && ArraySize(ATR)>1)
      {
         double maxHist = 0;
         for(int j=1; j<20 && j<ArraySize(MH); j++)
            maxHist = MathMax(maxHist, MathAbs(MH[j]));

         bool momEx = false;
         if(maxHist > 0)
         {
            double histThresh = maxHist * 0.3;
            if(pt==POSITION_TYPE_BUY && MH[1] < -histThresh && MH[2] >= 0) momEx = true;
            if(pt==POSITION_TYPE_SELL && MH[1] > histThresh && MH[2] <= 0) momEx = true;
         }

         if(momEx)
         {
            G_tr.SetExpertMagicNumber(magic);
            if(curProfit < 0) RecordLoss(); else RecordWin();
            G_tr.PositionClose(G_pos[i].ticket);
            Rm(i); continue;
         }
      }

      // ST flip exit
      if(Inp_FlipExit && ArraySize(ST_d)>2)
      {
         bool fx=(pt==POSITION_TYPE_BUY&&ST_d[1]==-1&&ST_d[2]==1)||(pt==POSITION_TYPE_SELL&&ST_d[1]==1&&ST_d[2]==-1);
         if(fx)
         {
            G_tr.SetExpertMagicNumber(magic);
            if(curProfit < 0) RecordLoss(); else RecordWin();
            G_tr.PositionClose(G_pos[i].ticket);
            Rm(i);
         }
      }
   }
}

void Rm(int i){int l=ArraySize(G_pos)-1;if(i<l)G_pos[i]=G_pos[l];ArrayResize(G_pos,l);}
int CntP(int sid){int m=Inp_BaseMagic+sid+1,c=0;for(int i=PositionsTotal()-1;i>=0;i--)if(PositionGetSymbol(i)==_Symbol&&PositionGetInteger(POSITION_MAGIC)==m)c++;return c;}

//+------------------------------------------------------------------+
//| Dashboard                                                         |
//+------------------------------------------------------------------+
void Dash(int &sig[])
{
   string nm[]={"S1 ST+HMA       ","S2 ST+Multi     ","S3 UT+Multi     ",
                "S4 UT+Universal ","S5 HMA+Trend    ","S7 WT+BestPF    ","S8 ST+BestWR    "};

   string mkt=g_isBTC?"CRYPTO":g_isUS30?"INDEX":"FOREX/COMM";

   string d="";
   d+="══════════════════════════════════════════════════\n";
   d+="  ProfitableOnly EA v6.0 PULLBACK | "+_Symbol+" "+EnumToString(Period())+"\n";
   d+="  Market: "+mkt+" | Risk: "+DoubleToString(GetEffectiveRisk(),1)+"%";
   if(Inp_UseLossGuard && g_consLosses >= Inp_LossStreak)
      d+=" [LOSS GUARD]";
   if(Inp_UseWinBoost && g_consWins >= Inp_WinStreak)
      d+=" [WIN BOOST]";
   d+="\n";
   d+="══════════════════════════════════════════════════\n";

   d+=StringFormat("  ATR:%.5f | VolR:%.2f%s | HTF:%s | DynTP:%.2fx\n",
      ArraySize(ATR)>1?ATR[1]:0.0,
      g_volRatio, VolRegimeOK()?" OK":" SKIP",
      g_htfTrend==1?"BULL":g_htfTrend==-1?"BEAR":"FLAT",
      GetDynTPScale());
   d+=StringFormat("  Sess:%s(%.2fx) | Spread:%s | Wins:%d Loss:%d | Day:%d/%d\n",
      SessOK()?"ON":"OFF", GetSessionMultiplier(),
      SpreadOK()?"OK":"HIGH",
      g_consWins, g_consLosses,
      g_dailyLosses, Inp_MaxDailyLoss);

   // v6: Show pending pullback count
   int pendCnt = 0;
   for(int p=0; p<ArraySize(G_pend); p++) if(G_pend[p].active) pendCnt++;
   d+=StringFormat("  ADXSlope:%s | Pending pullbacks: %d\n",
      ADXSlopeOK()?"OK":"SKIP", pendCnt);

   d+="──────────────────────────────────────────────────\n";

   int tp=0;
   for(int s=0;s<NS;s++)
   {
      string en=G_on[s]?"  ":"X ";
      string sg=sig[s]==1?"BUY ":sig[s]==-1?"SELL":"--- ";
      int pc=CntP(s);tp+=pc;
      d+=StringFormat("  %s%s %s pos:%d\n",en,nm[s],sg,pc);
   }

   d+="──────────────────────────────────────────────────\n";
   string adxStr="OFF",rsiStr="OFF";
   if(Inp_UseADX&&ArraySize(ADX_val)>1) adxStr=StringFormat("%.1f%s%s",ADX_val[1],
      ADX_val[1]>=Inp_ADXMin?" OK":" LOW", ADXSlopeOK()?" RISING":" FALLING");
   if(Inp_UseRSI&&ArraySize(RSI_val)>1) rsiStr=StringFormat("%.1f%s",RSI_val[1],
      RSI_val[1]>Inp_RSI_OB?" OB":RSI_val[1]<Inp_RSI_OS?" OS":" OK");
   d+=StringFormat("  ADX:%s | RSI:%s\n",adxStr,rsiStr);
   d+=StringFormat("  Positions:%d | Bal:%.2f | Eq:%.2f\n",
      tp,AccountInfoDouble(ACCOUNT_BALANCE),AccountInfoDouble(ACCOUNT_EQUITY));

   string scStr = g_spreadClass==2?"HIGH":g_spreadClass==1?"MED":"LOW";
   d+=StringFormat("  Spread: %.3f%% [%s] | SwingSL:%s | PB:%s(%.0f%%)\n",
      g_spreadPct, scStr,
      Inp_UseSwingSL?"ON":"OFF",
      Inp_UsePullback?"ON":"OFF", Inp_PullbackPct*100);

   d+=StringFormat("  v6: PB:%s ADXs:%s Sess:%s DynTP:%s SwSL:%s WinB:%s\n",
      Inp_UsePullback?"Y":"N", Inp_UseADXSlope?"Y":"N",
      Inp_UseSessionWt?"Y":"N", Inp_UseDynTP?"Y":"N",
      Inp_UseSwingSL?"Y":"N", Inp_UseWinBoost?"Y":"N");
   d+="══════════════════════════════════════════════════";
   Comment(d);
}
//+------------------------------------------------------------------+
