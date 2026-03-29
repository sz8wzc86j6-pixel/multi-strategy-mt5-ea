//+------------------------------------------------------------------+
//|  v6 EA — ETHUSDT — Optimized for PrimeXBT MT5                    |
//|  Timeframe: 1h | Config: vol_confirm | Filter: minimal              |
//|  Backtest (14d): 4 trades | 100% WR | PF 999.0             |
//|  Profit: $+5,006 (+1,545%) | DD: 0%                      |
//+------------------------------------------------------------------+
#property copyright "v6 EA — ETHUSDT"
#property version   "6.00"
#property strict
#property description "ETHUSDT 1h | vol_confirm | 4T 100%WR PF:999.0 | $+5,006 (+1,545%)"

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| Inputs — Pre-optimized for ETHUSDT                                |
//+------------------------------------------------------------------+
input group "════ RISK ════"
input double  Inp_Risk         = 25.0;    // Risk % per trade
input double  Inp_MinLot       = 0.01;
input double  Inp_MaxLot       = 0.10;
input double  Inp_FixedLots    = 0.0;           // 0 = ATR sizing
input int     Inp_Leverage     = 100;
input double  Inp_MaxMarginPct = 80.0;
input int     Inp_BaseMagic    = 631309;

input group "════ SL / TP (ATR multiples) ════"
input double  Inp_SL           = 1.0;      // Stop loss × ATR
input double  Inp_TP1          = 1.5;     // Take profit 1 × ATR
input double  Inp_TP2          = 5.0;     // Take profit 2 × ATR
input double  Inp_TP3          = 8.0;     // Take profit 3 × ATR (final)

input group "════ FILTERS ════"
input double  Inp_VolMin       = 0.3;  // Min vol ratio (ATR14/ATR50)
input double  Inp_VolMax       = 4.0;  // Max vol ratio
input int     Inp_ADXMin       = 15;      // Min ADX
input double  Inp_CandleMinPct = 30;   // Min candle body %
input bool    Inp_UseHTF       = false;  // HTF trend filter
input double  Inp_MinRR        = 1.0;   // Min R:R after spread
input double  Inp_MaxSpreadATR = 0.3;
input int     Inp_RSI_OB       = 65;
input int     Inp_RSI_OS       = 35;

input group "════ v6 FEATURES ════"
input bool    Inp_UsePullback   = false;    // Pullback entry
input double  Inp_PullbackPct   = 0.30;          // Retrace % of signal candle
input int     Inp_PullbackExp   = 3;             // Expiry bars
input bool    Inp_UseADXSlope   = false;  // ADX slope (rising)
input bool    Inp_UseSessionWt  = false;  // Session weighting
input bool    Inp_UseDynTP      = false; // Dynamic TP scaling
input bool    Inp_UseSwingSL    = false; // Swing-based SL
input bool    Inp_UseFastBE     = false;   // Fast breakeven (40%)
input bool    Inp_UseWinBoost   = true;           // Win streak boost
input bool    Inp_UseLossGuard  = true;           // Loss streak guard

input group "════ SESSION ════"
input int     Inp_SessStart    = 0;
input int     Inp_SessEnd      = 23;

input group "════ INDICATORS ════"
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

input group "════ DISPLAY ════"
input bool    Inp_Dash      = true;

//+------------------------------------------------------------------+
//| Structs                                                           |
//+------------------------------------------------------------------+
struct SPos {
   ulong  ticket;
   double entry, sl, tp1, tp2, lots;
   bool   tp1Hit, beHit;
};

struct SPend {
   int    dir;
   double limitPrice, slDist, tp1Dist, tp2Dist, lots;
   int    barsLeft;
   bool   active;
};

//+------------------------------------------------------------------+
//| Globals                                                           |
//+------------------------------------------------------------------+
CTrade      G_tr;
CSymbolInfo G_sy;

double C[],Hi[],Lo[],Op[],HLC3[],ATR[],ATR_Slow[];
double ST_u[],ST_l[],ST_v[]; int ST_d[];
double HM[]; int HM_t[];
double W1[],W2[];
double ML[],MS[],MH[];
double UT_v[]; int UT_d[];
double E200[];
double ADX_val[],RSI_val[];

int H_ATR,H_MACD,H_ADX,H_RSI,H_ATR_Slow,H_HTF_EMA;
SPos G_pos[];
SPend G_pend[];
int g_consLoss=0, g_consWin=0, g_dailyLoss=0;
datetime g_lastDay=0;
double g_volRatio=1.0;
int g_htfTrend=0;

//+------------------------------------------------------------------+
//| Init                                                              |
//+------------------------------------------------------------------+
int OnInit()
{
   G_tr.SetExpertMagicNumber(Inp_BaseMagic);
   G_tr.SetDeviationInPoints(10);
   G_tr.SetTypeFilling(ORDER_FILLING_IOC);
   G_sy.Name(_Symbol);

   H_ATR=iATR(_Symbol,PERIOD_CURRENT,Inp_ATRPer);
   H_MACD=iMACD(_Symbol,PERIOD_CURRENT,Inp_MACDFast,Inp_MACDSlow,Inp_MACDSig,PRICE_CLOSE);
   H_ADX=iADX(_Symbol,PERIOD_CURRENT,14);
   H_RSI=iRSI(_Symbol,PERIOD_CURRENT,14,PRICE_CLOSE);
   H_ATR_Slow=iATR(_Symbol,PERIOD_CURRENT,50);
   H_HTF_EMA=INVALID_HANDLE;
   if(Inp_UseHTF)
      H_HTF_EMA=iMA(_Symbol,PERIOD_H4,50,0,MODE_EMA,PRICE_CLOSE);

   if(H_ATR==INVALID_HANDLE||H_MACD==INVALID_HANDLE) return INIT_FAILED;

   ArraySetAsSeries(C,true);ArraySetAsSeries(Hi,true);ArraySetAsSeries(Lo,true);ArraySetAsSeries(Op,true);
   ArraySetAsSeries(HLC3,true);ArraySetAsSeries(ATR,true);ArraySetAsSeries(ATR_Slow,true);
   ArraySetAsSeries(ML,true);ArraySetAsSeries(MS,true);ArraySetAsSeries(MH,true);
   ArraySetAsSeries(ST_u,true);ArraySetAsSeries(ST_l,true);ArraySetAsSeries(ST_v,true);ArraySetAsSeries(ST_d,true);
   ArraySetAsSeries(HM,true);ArraySetAsSeries(HM_t,true);
   ArraySetAsSeries(W1,true);ArraySetAsSeries(W2,true);
   ArraySetAsSeries(UT_v,true);ArraySetAsSeries(UT_d,true);
   ArraySetAsSeries(E200,true);
   ArraySetAsSeries(ADX_val,true);ArraySetAsSeries(RSI_val,true);

   ArrayResize(G_pend,0);

   Print("═════════════════════════════════════════");
   Print("  v6 EA — ETHUSDT 1h | vol_confirm");
   Print("  R:25% SL:1.0 TP:1.5/5.0/8.0 | minimal");
   Print("  Backtest: 4 trades | 100%WR | PF:999.0");
   Print("  Profit: $+5,006 (+1,545%) | DD:0%");
   Print("═════════════════════════════════════════");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int r)
{
   if(H_ATR!=INVALID_HANDLE)IndicatorRelease(H_ATR);
   if(H_MACD!=INVALID_HANDLE)IndicatorRelease(H_MACD);
   if(H_ADX!=INVALID_HANDLE)IndicatorRelease(H_ADX);
   if(H_RSI!=INVALID_HANDLE)IndicatorRelease(H_RSI);
   if(H_ATR_Slow!=INVALID_HANDLE)IndicatorRelease(H_ATR_Slow);
   if(H_HTF_EMA!=INVALID_HANDLE)IndicatorRelease(H_HTF_EMA);
   Comment("");
}

//+------------------------------------------------------------------+
//| Indicators                                                        |
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

void xEMA(int n){ArrayResize(E200,n);double m=2.0/(200+1.0);E200[n-1]=C[n-1];for(int i=n-2;i>=0;i--)E200[i]=C[i]*m+E200[i+1]*(1-m);}

//+------------------------------------------------------------------+
//| Helpers                                                           |
//+------------------------------------------------------------------+
bool OK(){return(ArraySize(ST_d)>3&&ArraySize(HM_t)>2&&ArraySize(W1)>3&&ArraySize(MH)>2);}
bool SessOK(){MqlDateTime dt;TimeGMT(dt);return(dt.hour>=Inp_SessStart&&dt.hour<Inp_SessEnd);}
bool SpreadOK(){if(ArraySize(ATR)<2||ATR[1]==0)return true;G_sy.RefreshRates();return(G_sy.Spread()*G_sy.Point()<=ATR[1]*Inp_MaxSpreadATR);}

bool ADXSlopeOK()
{
   if(!Inp_UseADXSlope) return true;
   if(ArraySize(ADX_val)<5) return true;
   return (ADX_val[1]>ADX_val[4]);
}

double SessionMult()
{
   if(!Inp_UseSessionWt) return 1.0;
   MqlDateTime dt;TimeGMT(dt);int hr=dt.hour;
   if(hr>=7&&hr<=10) return 1.20;
   if(hr>=13&&hr<=16) return 1.15;
   if(hr>=0&&hr<=6) return 0.70;
   if(hr>=17&&hr<=20) return 0.90;
   return 1.0;
}

double EffRisk()
{
   double r=Inp_Risk*SessionMult();
   if(Inp_UseLossGuard&&g_consLoss>=3) r*=0.5;
   if(Inp_UseWinBoost&&g_consWin>=3) r*=1.5;
   return MathMin(r,15.0);
}

double DynTPScale()
{
   if(!Inp_UseDynTP||ArraySize(ATR)<2||ArraySize(ATR_Slow)<2||ATR_Slow[1]<=0) return 1.0;
   double ratio=ATR[1]/ATR_Slow[1];
   if(ratio>1.3) return 1.30;
   if(ratio<0.7) return 0.80;
   return 1.0;
}

double SwingSL(int dir)
{
   if(!Inp_UseSwingSL||ArraySize(Hi)<7||ArraySize(Lo)<7) return 0;
   double v;
   if(dir==1){v=Lo[1];for(int i=2;i<=6;i++)v=MathMin(v,Lo[i]);}
   else{v=Hi[1];for(int i=2;i<=6;i++)v=MathMax(v,Hi[i]);}
   return v;
}

void RecLoss(){g_consLoss++;g_consWin=0;g_dailyLoss++;}
void RecWin(){g_consWin++;g_consLoss=0;}
int CntP(){int c=0;for(int i=PositionsTotal()-1;i>=0;i--)if(PositionGetSymbol(i)==_Symbol&&PositionGetInteger(POSITION_MAGIC)==Inp_BaseMagic)c++;return c;}

//+------------------------------------------------------------------+
//| Signal — UT Bot + 2+ confluence                                   |
//+------------------------------------------------------------------+
int GetSignal()
{
   if(!OK()) return 0;
   if(ArraySize(UT_d)<3||ArraySize(ADX_val)<2||ArraySize(RSI_val)<2) return 0;

   bool ut_buy  = UT_d[1]==1 && UT_d[2]!=1;
   bool ut_sell = UT_d[1]==-1 && UT_d[2]!=-1;
   if(!ut_buy && !ut_sell) return 0;

   // ADX filter
   if(ADX_val[1]<Inp_ADXMin) return 0;

   // RSI filter
   double rv=RSI_val[1];

   // Confluence
   bool hbu=HM_t[1]==1, hbe=HM_t[1]==-1;
   bool wbu=W1[1]>W2[1]&&W1[1]<Inp_WTOB, wbe=W1[1]<W2[1]&&W1[1]>Inp_WTOS;
   bool mbu=MH[1]>0||MH[1]>MH[2], mbe=MH[1]<0||MH[1]<MH[2];

   int sig=0;
   if(ut_buy && rv<Inp_RSI_OB && rv>40)
   {
      int c=0;if(hbu)c++;if(wbu)c++;if(mbu)c++;
      if(c>=2) sig=1;
   }
   if(sig==0 && ut_sell && rv>Inp_RSI_OS && rv<60)
   {
      int c=0;if(hbe)c++;if(wbe)c++;if(mbe)c++;
      if(c>=2) sig=-1;
   }

   if(sig==0) return 0;

   // Vol regime
   if(ArraySize(ATR_Slow)>1 && ATR_Slow[1]>0)
   {
      double vr=ATR[1]/ATR_Slow[1];
      if(vr<Inp_VolMin||vr>Inp_VolMax) return 0;
   }

   // HTF trend
   if(Inp_UseHTF && H_HTF_EMA!=INVALID_HANDLE)
   {
      double htfE[2],htfC[2];
      if(CopyBuffer(H_HTF_EMA,0,0,2,htfE)>=2 && CopyClose(_Symbol,PERIOD_H4,0,2,htfC)>=2)
      {
         ArraySetAsSeries(htfE,true);ArraySetAsSeries(htfC,true);
         int htfDir=(htfC[1]>htfE[1])?1:-1;
         if(sig!=htfDir) return 0;
      }
   }

   // Candle strength
   if(Inp_CandleMinPct>0 && ArraySize(Op)>1)
   {
      double rng=Hi[1]-Lo[1];
      if(rng>0)
      {
         double bd=MathAbs(C[1]-Op[1]);
         if((bd/rng)*100<Inp_CandleMinPct) return 0;
         if(sig==1 && C[1]<Op[1]) return 0;
         if(sig==-1 && C[1]>Op[1]) return 0;
      }
   }

   // ADX slope
   if(!ADXSlopeOK()) return 0;

   // R:R check
   double a=ATR[1],sp=G_sy.Spread()*G_sy.Point();
   double rrEff=(Inp_TP3*a-sp)/(Inp_SL*a*1.2+sp);
   if(rrEff<Inp_MinRR) return 0;

   return sig;
}

//+------------------------------------------------------------------+
//| Tick                                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   ManagePos();
   CheckPending();

   static datetime lb=0;
   datetime cb=iTime(_Symbol,PERIOD_CURRENT,0);
   if(cb==lb) return; lb=cb;

   DecrPending();

   int N=250;
   if(CopyClose(_Symbol,PERIOD_CURRENT,0,N,C)<N) return;
   if(CopyHigh(_Symbol,PERIOD_CURRENT,0,N,Hi)<N) return;
   if(CopyLow(_Symbol,PERIOD_CURRENT,0,N,Lo)<N) return;
   if(CopyOpen(_Symbol,PERIOD_CURRENT,0,N,Op)<N) return;
   if(CopyBuffer(H_ATR,0,0,N,ATR)<N) return;
   if(CopyBuffer(H_MACD,0,0,N,ML)<N) return;
   if(CopyBuffer(H_MACD,1,0,N,MS)<N) return;
   if(CopyBuffer(H_MACD,2,0,N,MH)<N) return;
   if(H_ADX!=INVALID_HANDLE) CopyBuffer(H_ADX,0,0,N,ADX_val);
   if(H_RSI!=INVALID_HANDLE) CopyBuffer(H_RSI,0,0,N,RSI_val);
   ArrayResize(ATR_Slow,N);
   if(H_ATR_Slow!=INVALID_HANDLE) CopyBuffer(H_ATR_Slow,0,0,N,ATR_Slow);

   ArrayResize(HLC3,N);
   for(int i=0;i<N;i++) HLC3[i]=(Hi[i]+Lo[i]+C[i])/3.0;
   xST(N);xHMA(N);xWT(N);xUT(N);xEMA(N);

   // Daily loss reset
   MqlDateTime dt;TimeGMT(dt);
   datetime today=(datetime)(dt.year*10000+dt.mon*100+dt.day);
   if(today!=g_lastDay){g_dailyLoss=0;g_lastDay=today;}

   if(!SessOK()||!SpreadOK()||g_dailyLoss>=5) return;
   if(CntP()>=1||HasPending()) return;

   int sig=GetSignal();
   if(sig==0) return;

   OpenTrade(sig);

   if(Inp_Dash) Dash(sig);
}

//+------------------------------------------------------------------+
//| Open trade (with pullback support)                                |
//+------------------------------------------------------------------+
void OpenTrade(int dir)
{
   G_sy.RefreshRates();
   double a=ATR[1];if(a==0||a!=a)return;
   double ask=G_sy.Ask(),bid=G_sy.Bid();
   int dg=G_sy.Digits();
   double spread=G_sy.Spread()*G_sy.Point();

   double sl_m=Inp_SL*1.2;  // spread-adjusted SL
   double tpScale=DynTPScale();
   double tp1_m=Inp_TP1*tpScale;
   double tp2_m=Inp_TP2*tpScale;
   double tp3_m=Inp_TP3*tpScale;

   double ep=(dir==1)?ask:bid;

   // SL distance
   double slDist;
   double swSL=SwingSL(dir);
   if(Inp_UseSwingSL && swSL>0)
   {
      double swDist=MathAbs(ep-swSL);
      double aDist=sl_m*a+spread;
      slDist=MathMin(swDist,aDist);
      slDist=MathMax(slDist,0.5*a+spread);
   }
   else slDist=sl_m*a+spread;

   if(slDist<=0) return;

   // Lot sizing
   double effR=EffRisk();
   double bal=AccountInfoDouble(ACCOUNT_BALANCE);
   double lots;
   if(Inp_FixedLots>0)
   {
      lots=Inp_FixedLots;
      if(Inp_UseLossGuard&&g_consLoss>=3) lots*=0.5;
   }
   else
   {
      double risk=bal*effR/100.0;
      double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
      double ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
      if(tv==0||ts==0) return;
      lots=NormalizeDouble(risk/(slDist/ts*tv),2);
   }

   double ls=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double mL=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double xL=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   lots=MathMax(mL,MathMin(xL,MathMax(Inp_MinLot,MathMin(Inp_MaxLot,lots))));
   lots=NormalizeDouble(MathFloor(lots/ls)*ls,2);
   if(lots<mL) return;

   // Margin check
   double reqMgn=lots*SymbolInfoDouble(_Symbol,SYMBOL_TRADE_CONTRACT_SIZE)*ep;
   if(Inp_Leverage>0) reqMgn/=Inp_Leverage;
   if(AccountInfoDouble(ACCOUNT_MARGIN)+reqMgn>bal*Inp_MaxMarginPct/100.0) return;

   // PULLBACK ENTRY
   if(Inp_UsePullback && ArraySize(Hi)>1)
   {
      double cr=Hi[1]-Lo[1];
      if(cr>0)
      {
         SPend p;
         p.dir=dir;p.lots=lots;p.slDist=slDist;
         p.tp1Dist=tp1_m*a;p.tp2Dist=tp3_m*a;
         p.barsLeft=Inp_PullbackExp;p.active=true;
         if(dir==1) p.limitPrice=NormalizeDouble(ep-cr*Inp_PullbackPct,dg);
         else p.limitPrice=NormalizeDouble(ep+cr*Inp_PullbackPct,dg);
         int sz=ArraySize(G_pend);ArrayResize(G_pend,sz+1);G_pend[sz]=p;
         Print(StringFormat("PULLBACK %s Limit:%.5f Lots:%.2f R:%.1f%%",(dir==1)?"BUY":"SELL",p.limitPrice,lots,effR));
         return;
      }
   }

   // Immediate entry
   double sl,t1,tp;
   ENUM_ORDER_TYPE ot;
   if(dir==1){sl=NormalizeDouble(ep-slDist,dg);t1=NormalizeDouble(ep+tp1_m*a,dg);tp=NormalizeDouble(ep+tp3_m*a,dg);ot=ORDER_TYPE_BUY;}
   else{sl=NormalizeDouble(ep+slDist,dg);t1=NormalizeDouble(ep-tp1_m*a,dg);tp=NormalizeDouble(ep-tp3_m*a,dg);ot=ORDER_TYPE_SELL;}

   G_tr.SetExpertMagicNumber(Inp_BaseMagic);
   if(G_tr.PositionOpen(_Symbol,ot,lots,ep,sl,tp,"ETHUSDT"))
   {
      SPos p;p.ticket=G_tr.ResultOrder();p.entry=ep;p.sl=sl;p.tp1=t1;p.tp2=tp;
      p.tp1Hit=false;p.beHit=false;p.lots=lots;
      int sz=ArraySize(G_pos);ArrayResize(G_pos,sz+1);G_pos[sz]=p;
   }
}

//+------------------------------------------------------------------+
//| Pending pullback management                                       |
//+------------------------------------------------------------------+
bool HasPending(){for(int i=0;i<ArraySize(G_pend);i++)if(G_pend[i].active)return true;return false;}

void DecrPending()
{
   for(int i=ArraySize(G_pend)-1;i>=0;i--)
   {
      if(!G_pend[i].active) continue;
      G_pend[i].barsLeft--;
      if(G_pend[i].barsLeft<=0)
      {
         G_pend[i].active=false;
         int last=ArraySize(G_pend)-1;if(i<last)G_pend[i]=G_pend[last];
         ArrayResize(G_pend,last);
      }
   }
}

void CheckPending()
{
   G_sy.RefreshRates();
   double bid=G_sy.Bid(),ask=G_sy.Ask();
   int dg=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);

   for(int i=ArraySize(G_pend)-1;i>=0;i--)
   {
      if(!G_pend[i].active) continue;
      if(CntP()>=1){G_pend[i].active=false;int last=ArraySize(G_pend)-1;if(i<last)G_pend[i]=G_pend[last];ArrayResize(G_pend,last);continue;}

      bool fill=false;double ep=0;ENUM_ORDER_TYPE ot;
      if(G_pend[i].dir==1 && ask<=G_pend[i].limitPrice){fill=true;ep=ask;ot=ORDER_TYPE_BUY;}
      if(G_pend[i].dir==-1 && bid>=G_pend[i].limitPrice){fill=true;ep=bid;ot=ORDER_TYPE_SELL;}

      if(fill)
      {
         double sl,tp;
         if(G_pend[i].dir==1){sl=NormalizeDouble(ep-G_pend[i].slDist,dg);tp=NormalizeDouble(ep+G_pend[i].tp2Dist,dg);}
         else{sl=NormalizeDouble(ep+G_pend[i].slDist,dg);tp=NormalizeDouble(ep-G_pend[i].tp2Dist,dg);}

         G_tr.SetExpertMagicNumber(Inp_BaseMagic);
         if(G_tr.PositionOpen(_Symbol,ot,G_pend[i].lots,ep,sl,tp,"ETHUSDT PB"))
         {
            double t1=(G_pend[i].dir==1)?ep+G_pend[i].tp1Dist:ep-G_pend[i].tp1Dist;
            SPos p;p.ticket=G_tr.ResultOrder();p.entry=ep;p.sl=sl;p.tp1=t1;p.tp2=tp;
            p.tp1Hit=false;p.beHit=false;p.lots=G_pend[i].lots;
            int sz=ArraySize(G_pos);ArrayResize(G_pos,sz+1);G_pos[sz]=p;
            Print(StringFormat("PULLBACK FILLED %s at %.5f",(G_pend[i].dir==1)?"BUY":"SELL",ep));
         }
         G_pend[i].active=false;int last=ArraySize(G_pend)-1;if(i<last)G_pend[i]=G_pend[last];ArrayResize(G_pend,last);
      }
   }
}

//+------------------------------------------------------------------+
//| Position management                                               |
//+------------------------------------------------------------------+
void ManagePos()
{
   for(int i=ArraySize(G_pos)-1;i>=0;i--)
   {
      if(!PositionSelectByTicket(G_pos[i].ticket))
      {
         if(HistoryDealSelect(G_pos[i].ticket))
         {if(HistoryDealGetDouble(G_pos[i].ticket,DEAL_PROFIT)>=0)RecWin();else RecLoss();}
         int l=ArraySize(G_pos)-1;if(i<l)G_pos[i]=G_pos[l];ArrayResize(G_pos,l);
         continue;
      }

      ENUM_POSITION_TYPE pt=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double cp=(pt==POSITION_TYPE_BUY)?SymbolInfoDouble(_Symbol,SYMBOL_BID):SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      int dg=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);

      // Fast BE at 40% of TP1 distance
      if(Inp_UseFastBE && !G_pos[i].beHit && !G_pos[i].tp1Hit)
      {
         double tp1D=MathAbs(G_pos[i].tp1-G_pos[i].entry);
         double beT=(pt==POSITION_TYPE_BUY)?G_pos[i].entry+tp1D*0.40:G_pos[i].entry-tp1D*0.40;
         if((pt==POSITION_TYPE_BUY&&cp>=beT)||(pt==POSITION_TYPE_SELL&&cp<=beT))
         {
            double sp=G_sy.Spread()*G_sy.Point();
            double beSL=(pt==POSITION_TYPE_BUY)?NormalizeDouble(G_pos[i].entry+sp*1.5,dg):NormalizeDouble(G_pos[i].entry-sp*1.5,dg);
            G_tr.SetExpertMagicNumber(Inp_BaseMagic);
            if(G_tr.PositionModify(G_pos[i].ticket,beSL,G_pos[i].tp2))
            {G_pos[i].beHit=true;G_pos[i].sl=beSL;}
         }
      }

      // TP1 partial close (50%)
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
               G_tr.SetExpertMagicNumber(Inp_BaseMagic);
               G_tr.PositionClosePartial(G_pos[i].ticket,cl);
               G_pos[i].tp1Hit=true;
               double sp=G_sy.Spread()*G_sy.Point();
               double beSL=(pt==POSITION_TYPE_BUY)?NormalizeDouble(G_pos[i].entry+sp,dg):NormalizeDouble(G_pos[i].entry-sp,dg);
               G_tr.PositionModify(G_pos[i].ticket,beSL,G_pos[i].tp2);
               G_pos[i].sl=beSL;
               RecWin();
            }
         }
      }

      // ATR trailing after TP1
      if(G_pos[i].tp1Hit && ArraySize(ATR)>1)
      {
         double csl=PositionGetDouble(POSITION_SL);
         double trail=1.2*ATR[1];
         G_tr.SetExpertMagicNumber(Inp_BaseMagic);
         if(pt==POSITION_TYPE_BUY){double ns=NormalizeDouble(cp-trail,dg);if(ns>csl&&ns<cp)G_tr.PositionModify(G_pos[i].ticket,ns,G_pos[i].tp2);}
         else{double ns=NormalizeDouble(cp+trail,dg);if((ns<csl||csl==0)&&ns>cp)G_tr.PositionModify(G_pos[i].ticket,ns,G_pos[i].tp2);}
      }

      // ST flip exit
      if(ArraySize(ST_d)>2)
      {
         bool fx=(pt==POSITION_TYPE_BUY&&ST_d[1]==-1&&ST_d[2]==1)||(pt==POSITION_TYPE_SELL&&ST_d[1]==1&&ST_d[2]==-1);
         if(fx)
         {
            G_tr.SetExpertMagicNumber(Inp_BaseMagic);
            if(PositionGetDouble(POSITION_PROFIT)<0)RecLoss();else RecWin();
            G_tr.PositionClose(G_pos[i].ticket);
            int l=ArraySize(G_pos)-1;if(i<l)G_pos[i]=G_pos[l];ArrayResize(G_pos,l);
            continue;
         }
      }

      // MACD momentum exit (before TP1)
      if(!G_pos[i].tp1Hit && ArraySize(MH)>2)
      {
         double maxH=0;for(int j=1;j<20&&j<ArraySize(MH);j++)maxH=MathMax(maxH,MathAbs(MH[j]));
         if(maxH>0)
         {
            double th=maxH*0.3;bool momEx=false;
            if(pt==POSITION_TYPE_BUY&&MH[1]<-th&&MH[2]>=0)momEx=true;
            if(pt==POSITION_TYPE_SELL&&MH[1]>th&&MH[2]<=0)momEx=true;
            if(momEx)
            {
               G_tr.SetExpertMagicNumber(Inp_BaseMagic);
               if(PositionGetDouble(POSITION_PROFIT)<0)RecLoss();else RecWin();
               G_tr.PositionClose(G_pos[i].ticket);
               int l=ArraySize(G_pos)-1;if(i<l)G_pos[i]=G_pos[l];ArrayResize(G_pos,l);
               continue;
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Dashboard                                                         |
//+------------------------------------------------------------------+
void Dash(int sig)
{
   string d="";
   double bal=AccountInfoDouble(ACCOUNT_BALANCE);
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   double startBal=324.0;
   double profitPct=(bal>0)?(bal-startBal)/startBal*100.0:0;
   d+="══════════════════════════════════════════\n";
   d+="  v6 — ETHUSDT 1h | vol_confirm\n";
   d+="  BT: 4T 100%WR PF:999.0 | $+5,006 (+1,545%)\n";
   d+=StringFormat("  R:%.1f%% | Wins:%d Loss:%d | Day:%d/5\n",EffRisk(),g_consWin,g_consLoss,g_dailyLoss);
   d+=StringFormat("  ATR:%.5f | TP scale:%.2fx\n",ArraySize(ATR)>1?ATR[1]:0.0,DynTPScale());
   d+=StringFormat("  Sig:%s | Pos:%d | Pend:%d\n",sig==1?"BUY":sig==-1?"SELL":"---",CntP(),ArraySize(G_pend));
   d+=StringFormat("  Bal:%.2f | Eq:%.2f\n",bal,eq);
   d+=StringFormat("  Live P/L: $%.2f (%.1f%%)\n",bal-startBal,profitPct);
   d+="══════════════════════════════════════════";
   Comment(d);
}
//+------------------------------------------------------------------+
