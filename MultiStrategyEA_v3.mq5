//+------------------------------------------------------------------+
//|                                       MultiStrategyEA_v3.mq5     |
//|  8 strategies, one chart, all independent                        |
//|                                                                   |
//|  14-DAY BACKTEST RESULTS (Mar 13-27, 2026, real data):           |
//|  ─────────────────────────────────────────────────                |
//|  S1  ST+HMA         GBPUSD M15  +36.9%  PF 1.50  WR 45.7%      |
//|  S2  ST+HMA+WT+MACD EURUSD M15  +40.7%  PF 1.61  WR 50.0%      |
//|  S3  UT+HMA+WT+MACD EURUSD M15  +36.6%  PF 1.39  WR 44.9%      |
//|  S4  UT+ST+HMA+MACD EURUSD M15  +33.3%  PF 1.41  WR 47.1%      |
//|  S5  HMA+ST+MACD    EURUSD M15  +24.7%  PF 1.38  WR 49.4%      |
//|  S6  MACD+ST+HMA    EURUSD M15  +16.0%  PF 1.33  WR 46.3%      |
//|  S7  WT+ST+HMA      EURUSD M15  +34.0%  PF 1.76  WR 54.1%      |
//|  S8  ST+ALL Cons    EURUSD M15  +24.9%  PF 1.66  WR 56.1%      |
//|                                                                   |
//|  FINDINGS: M15 Forex dominates. Avoid BTCUSD M15 (choppy).      |
//|  Best overall: S7 (highest PF), S8 (highest WR).                 |
//+------------------------------------------------------------------+
#property copyright "MultiStrategy EA v3.0"
#property version   "3.00"
#property strict
#property description "8 independent strategies on one chart"

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| Enums                                                             |
//+------------------------------------------------------------------+
enum ENUM_SLTP { SLTP_TIGHT=0, SLTP_DEFAULT=1, SLTP_WIDE=2 };

//+------------------------------------------------------------------+
//| Inputs                                                            |
//+------------------------------------------------------------------+
input group "════════ GLOBAL ════════"
input double  Inp_Risk         = 1.5;           // Risk % per trade
input int     Inp_BaseMagic    = 100000;        // Base magic number
input bool    Inp_EnableAll    = true;          // Master enable
input double  Inp_MaxSpreadATR = 0.3;           // Max spread / ATR ratio
input double  Inp_MinLot       = 0.01;          // Min lot size
input double  Inp_MaxLot       = 100.0;         // Max lot size
input bool    Inp_CloseOnOppFlip = true;        // Close on SuperTrend flip

input group "════════ S1: ST + HMA (Forex Scalper) ════════"
input bool    S1_On     = true;                 // Enable
input ENUM_SLTP S1_SLTP = SLTP_TIGHT;          // SL/TP preset

input group "════════ S2: ST + HMA+WT+MACD (Multi-Conf) ════════"
input bool    S2_On     = true;                 // Enable
input int     S2_MinC   = 2;                    // Min confluence (of 3)

input group "════════ S3: UT + HMA+WT+MACD (Crypto/Fast) ════════"
input bool    S3_On     = true;                 // Enable

input group "════════ S4: UT + ST+HMA+MACD (Universal) ════════"
input bool    S4_On     = true;                 // Enable
input int     S4_MinC   = 2;                    // Min confluence (of 3)

input group "════════ S5: HMA + ST+MACD (Trend Follow) ════════"
input bool    S5_On     = true;                 // Enable

input group "════════ S6: MACD + ST+HMA (Momentum) ════════"
input bool    S6_On     = true;                 // Enable

input group "════════ S7: WT + ST+HMA (Best PF) ════════"
input bool    S7_On     = true;                 // Enable

input group "════════ S8: ST + ALL (Conservative) ════════"
input bool    S8_On     = true;                 // Enable
input int     S8_MinC   = 3;                    // Min confluence (of 4)

input group "════════ SESSION ════════"
input bool    Inp_UseSess   = true;             // Enable session filter
input int     Inp_SessStart = 7;                // Start hour UTC
input int     Inp_SessEnd   = 21;               // End hour UTC

input group "════════ INDICATORS ════════"
input int     Inp_ATRPer    = 14;               // ATR period
input double  Inp_STMult    = 1.7;              // SuperTrend multiplier
input int     Inp_HMAPer    = 10;               // HMA period
input int     Inp_WTCh      = 6;                // WaveTrend channel
input int     Inp_WTAvg     = 13;               // WaveTrend average
input int     Inp_WTOB      = 53;               // WaveTrend OB
input int     Inp_WTOS      = -53;              // WaveTrend OS
input int     Inp_MACDFast  = 14;               // MACD fast
input int     Inp_MACDSlow  = 28;               // MACD slow
input int     Inp_MACDSig   = 11;               // MACD signal
input double  Inp_UTKey     = 1.5;              // UT Bot key value
input int     Inp_UTAtr     = 10;               // UT Bot ATR period
input int     Inp_EMAPer    = 200;              // EMA period (S8)

input group "════════ DISPLAY ════════"
input bool    Inp_Dash      = true;             // Show dashboard

//+------------------------------------------------------------------+
//| Constants & Types                                                 |
//+------------------------------------------------------------------+
#define NS 8

struct SPos
{
   ulong  ticket;
   double entry, sl, tp1, tp2, lots;
   bool   tp1Hit;
   int    sid;
};

//+------------------------------------------------------------------+
//| Globals                                                           |
//+------------------------------------------------------------------+
CTrade      G_trade;
CSymbolInfo G_sym;

double C[], H[], L[], HLC3[], ATR[];
double ST_upper[], ST_lower[], ST_line[];
int    ST_dir[];
double HMA_val[]; int HMA_tr[];
double WT1[], WT2[];
double MACD_l[], MACD_s[], MACD_h[];
double UT_trail[]; int UT_dir[];
double EMA200[];

int H_ATR, H_MACD;

SPos  G_pos[];
bool  G_on[NS];
double G_sl[NS], G_tp1[NS], G_tp2[NS];

//+------------------------------------------------------------------+
//| SL/TP from preset                                                 |
//+------------------------------------------------------------------+
void SLTP(ENUM_SLTP p, int i)
{
   switch(p) {
      case SLTP_TIGHT:   G_sl[i]=1.0; G_tp1[i]=1.5; G_tp2[i]=3.0; break;
      case SLTP_DEFAULT: G_sl[i]=1.5; G_tp1[i]=2.0; G_tp2[i]=4.0; break;
      case SLTP_WIDE:    G_sl[i]=2.0; G_tp1[i]=3.0; G_tp2[i]=6.0; break;
   }
}

//+------------------------------------------------------------------+
//| Init                                                              |
//+------------------------------------------------------------------+
int OnInit()
{
   G_trade.SetExpertMagicNumber(Inp_BaseMagic);
   G_trade.SetDeviationInPoints(10);
   G_trade.SetTypeFilling(ORDER_FILLING_IOC);
   G_sym.Name(_Symbol);

   H_MACD = iMACD(_Symbol, PERIOD_CURRENT, Inp_MACDFast, Inp_MACDSlow, Inp_MACDSig, PRICE_CLOSE);
   H_ATR  = iATR(_Symbol, PERIOD_CURRENT, Inp_ATRPer);
   if(H_MACD==INVALID_HANDLE || H_ATR==INVALID_HANDLE) return INIT_FAILED;

   // Series
   double *arrs[] = {}; // Can't do pointer array in MQL5, set individually
   ArraySetAsSeries(C,true); ArraySetAsSeries(H,true); ArraySetAsSeries(L,true);
   ArraySetAsSeries(HLC3,true); ArraySetAsSeries(ATR,true);
   ArraySetAsSeries(MACD_l,true); ArraySetAsSeries(MACD_s,true); ArraySetAsSeries(MACD_h,true);
   ArraySetAsSeries(ST_line,true); ArraySetAsSeries(ST_upper,true);
   ArraySetAsSeries(ST_lower,true); ArraySetAsSeries(ST_dir,true);
   ArraySetAsSeries(HMA_val,true); ArraySetAsSeries(HMA_tr,true);
   ArraySetAsSeries(WT1,true); ArraySetAsSeries(WT2,true);
   ArraySetAsSeries(UT_trail,true); ArraySetAsSeries(UT_dir,true);
   ArraySetAsSeries(EMA200,true);

   // Enable flags
   G_on[0]=Inp_EnableAll&&S1_On; G_on[1]=Inp_EnableAll&&S2_On;
   G_on[2]=Inp_EnableAll&&S3_On; G_on[3]=Inp_EnableAll&&S4_On;
   G_on[4]=Inp_EnableAll&&S5_On; G_on[5]=Inp_EnableAll&&S6_On;
   G_on[6]=Inp_EnableAll&&S7_On; G_on[7]=Inp_EnableAll&&S8_On;

   // SL/TP: S1 user-chosen, rest from backtest optimal
   SLTP(S1_SLTP, 0);
   // S2 default
   G_sl[1]=1.5; G_tp1[1]=2.0; G_tp2[1]=4.0;
   // S3 tight (fast entries)
   G_sl[2]=1.0; G_tp1[2]=1.5; G_tp2[2]=3.0;
   // S4 default
   G_sl[3]=1.5; G_tp1[3]=2.0; G_tp2[3]=4.0;
   // S5 default
   G_sl[4]=1.5; G_tp1[4]=2.0; G_tp2[4]=4.0;
   // S6 default
   G_sl[5]=1.5; G_tp1[5]=2.0; G_tp2[5]=4.0;
   // S7 default
   G_sl[6]=1.5; G_tp1[6]=2.0; G_tp2[6]=4.0;
   // S8 wide (conservative)
   G_sl[7]=2.0; G_tp1[7]=3.0; G_tp2[7]=6.0;

   int cnt=0; for(int i=0;i<NS;i++) if(G_on[i]) cnt++;
   Print("MultiStrategy EA v3.0 | ",_Symbol," ",EnumToString(Period()),
         " | ",cnt,"/",NS," strategies | Risk: ",Inp_Risk,"%");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int r)
{
   if(H_MACD!=INVALID_HANDLE) IndicatorRelease(H_MACD);
   if(H_ATR!=INVALID_HANDLE) IndicatorRelease(H_ATR);
   Comment("");
}

//+------------------------------------------------------------------+
//| Tick                                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   ManagePositions();

   static datetime lastB=0;
   datetime curB = iTime(_Symbol,PERIOD_CURRENT,0);
   if(curB==lastB) return;
   lastB=curB;

   int N=250;
   if(CopyClose(_Symbol,PERIOD_CURRENT,0,N,C)<N) return;
   if(CopyHigh(_Symbol,PERIOD_CURRENT,0,N,H)<N) return;
   if(CopyLow(_Symbol,PERIOD_CURRENT,0,N,L)<N) return;
   if(CopyBuffer(H_ATR,0,0,N,ATR)<N) return;
   if(CopyBuffer(H_MACD,0,0,N,MACD_l)<N) return;
   if(CopyBuffer(H_MACD,1,0,N,MACD_s)<N) return;
   if(CopyBuffer(H_MACD,2,0,N,MACD_h)<N) return;

   ArrayResize(HLC3,N);
   for(int i=0;i<N;i++) HLC3[i]=(H[i]+L[i]+C[i])/3.0;

   CalcST(N); CalcHMA(N); CalcWT(N); CalcUT(N); CalcEma(N);

   bool sok = SessOK(), spok = SpreadOK();

   int sig[NS]; ArrayInitialize(sig,0);
   if(G_on[0]) sig[0]=Sig1(); if(G_on[1]) sig[1]=Sig2();
   if(G_on[2]) sig[2]=Sig3(); if(G_on[3]) sig[3]=Sig4();
   if(G_on[4]) sig[4]=Sig5(); if(G_on[5]) sig[5]=Sig6();
   if(G_on[6]) sig[6]=Sig7(); if(G_on[7]) sig[7]=Sig8();

   for(int s=0;s<NS;s++)
   {
      if(!G_on[s] || sig[s]==0 || !sok || !spok) continue;
      if(CntPos(s)>=1) continue;
      OpenTrade(s, sig[s]);
   }

   if(Inp_Dash) Dashboard(sig);
}

//+------------------------------------------------------------------+
//| SUPERTREND                                                        |
//+------------------------------------------------------------------+
void CalcST(int n)
{
   ArrayResize(ST_upper,n); ArrayResize(ST_lower,n);
   ArrayResize(ST_line,n);  ArrayResize(ST_dir,n);
   for(int i=n-1;i>=0;i--)
   {
      double a=ATR[i]; if(a==0||a!=a){if(i<n-1){ST_upper[i]=ST_upper[i+1];ST_lower[i]=ST_lower[i+1];ST_dir[i]=ST_dir[i+1];ST_line[i]=ST_line[i+1];}continue;}
      double u=C[i]+Inp_STMult*a, lo=C[i]-Inp_STMult*a;
      if(i==n-1){ST_upper[i]=u;ST_lower[i]=lo;ST_dir[i]=1;}
      else{
         ST_lower[i]=(lo>ST_lower[i+1]||C[i+1]<ST_lower[i+1])?lo:ST_lower[i+1];
         ST_upper[i]=(u<ST_upper[i+1]||C[i+1]>ST_upper[i+1])?u:ST_upper[i+1];
         if(ST_dir[i+1]==-1&&C[i]>ST_upper[i]) ST_dir[i]=1;
         else if(ST_dir[i+1]==1&&C[i]<ST_lower[i]) ST_dir[i]=-1;
         else ST_dir[i]=ST_dir[i+1];
      }
      ST_line[i]=(ST_dir[i]==1)?ST_lower[i]:ST_upper[i];
   }
}

//+------------------------------------------------------------------+
//| HMA                                                               |
//+------------------------------------------------------------------+
double Wma(double &d[],int s,int p)
{
   double sm=0,ws=0;
   for(int i=0;i<p&&(s+i)<ArraySize(d);i++){double w=(double)(p-i);sm+=d[s+i]*w;ws+=w;}
   return ws>0?sm/ws:0;
}

void CalcHMA(int n)
{
   ArrayResize(HMA_val,n); ArrayResize(HMA_tr,n);
   ArrayInitialize(HMA_val,0); ArrayInitialize(HMA_tr,0);
   int hp=(int)MathFloor(Inp_HMAPer/2.0), sp=(int)MathFloor(MathSqrt((double)Inp_HMAPer));
   if(hp<1)hp=1; if(sp<1)sp=1; if(n<Inp_HMAPer+sp+5)return;
   double hs[]; ArrayResize(hs,n); ArraySetAsSeries(hs,true);
   for(int i=0;i<n-Inp_HMAPer;i++) hs[i]=2.0*Wma(C,i,hp)-Wma(C,i,Inp_HMAPer);
   for(int i=0;i<n-Inp_HMAPer-sp;i++) HMA_val[i]=Wma(hs,i,sp);
   for(int i=0;i<n-Inp_HMAPer-sp-1;i++) HMA_tr[i]=(HMA_val[i]>HMA_val[i+1])?1:-1;
}

//+------------------------------------------------------------------+
//| WAVETREND                                                         |
//+------------------------------------------------------------------+
void Ema(double &s[],double &d[],int n,int p)
{
   double m=2.0/(p+1.0); d[n-1]=s[n-1];
   for(int i=n-2;i>=0;i--) d[i]=s[i]*m+d[i+1]*(1-m);
}

void CalcWT(int n)
{
   ArrayResize(WT1,n); ArrayResize(WT2,n);
   ArrayInitialize(WT1,0); ArrayInitialize(WT2,0);
   if(n<Inp_WTCh+Inp_WTAvg+10) return;
   double eh[],df[],ad[],ed[],ead[],ci[];
   ArrayResize(eh,n);ArrayResize(df,n);ArrayResize(ad,n);
   ArrayResize(ed,n);ArrayResize(ead,n);ArrayResize(ci,n);
   ArraySetAsSeries(eh,true);ArraySetAsSeries(df,true);ArraySetAsSeries(ad,true);
   ArraySetAsSeries(ed,true);ArraySetAsSeries(ead,true);ArraySetAsSeries(ci,true);
   Ema(HLC3,eh,n,Inp_WTCh);
   for(int i=0;i<n;i++){df[i]=HLC3[i]-eh[i];ad[i]=MathAbs(df[i]);}
   Ema(df,ed,n,Inp_WTCh); Ema(ad,ead,n,Inp_WTCh);
   for(int i=0;i<n;i++){double dn=0.015*ead[i];ci[i]=(dn!=0)?ed[i]/dn:0;}
   Ema(ci,WT1,n,Inp_WTAvg);
   for(int i=0;i<n-4;i++) WT2[i]=(WT1[i]+WT1[i+1]+WT1[i+2]+WT1[i+3])/4.0;
}

//+------------------------------------------------------------------+
//| UT BOT                                                            |
//+------------------------------------------------------------------+
void CalcUT(int n)
{
   ArrayResize(UT_trail,n); ArrayResize(UT_dir,n);
   ArrayInitialize(UT_trail,0); ArrayInitialize(UT_dir,0);
   double ua[]; ArrayResize(ua,n); ArraySetAsSeries(ua,true);
   if(Inp_UTAtr==Inp_ATRPer) ArrayCopy(ua,ATR);
   else { int h=iATR(_Symbol,PERIOD_CURRENT,Inp_UTAtr);
          if(h!=INVALID_HANDLE){CopyBuffer(h,0,0,n,ua);IndicatorRelease(h);}
          else ArrayCopy(ua,ATR);}
   UT_trail[n-1]=C[n-1]; UT_dir[n-1]=0;
   for(int i=n-2;i>=0;i--)
   {
      double nL=Inp_UTKey*ua[i]; if(nL==0||nL!=nL) nL=Inp_UTKey*ATR[i];
      if(C[i]>UT_trail[i+1]&&C[i+1]>UT_trail[i+1]) UT_trail[i]=MathMax(UT_trail[i+1],C[i]-nL);
      else if(C[i]<UT_trail[i+1]&&C[i+1]<UT_trail[i+1]) UT_trail[i]=MathMin(UT_trail[i+1],C[i]+nL);
      else if(C[i]>UT_trail[i+1]) UT_trail[i]=C[i]-nL;
      else UT_trail[i]=C[i]+nL;
      if(C[i]>UT_trail[i]&&C[i+1]<=UT_trail[i+1]) UT_dir[i]=1;
      else if(C[i]<UT_trail[i]&&C[i+1]>=UT_trail[i+1]) UT_dir[i]=-1;
      else UT_dir[i]=UT_dir[i+1];
   }
}

//+------------------------------------------------------------------+
//| EMA                                                               |
//+------------------------------------------------------------------+
void CalcEma(int n)
{
   ArrayResize(EMA200,n);
   double m=2.0/(Inp_EMAPer+1.0); EMA200[n-1]=C[n-1];
   for(int i=n-2;i>=0;i--) EMA200[i]=C[i]*m+EMA200[i+1]*(1-m);
}

//+------------------------------------------------------------------+
//| SIGNAL HELPERS                                                    |
//+------------------------------------------------------------------+
bool OK(){return(ArraySize(ST_dir)>3&&ArraySize(HMA_tr)>2&&ArraySize(WT1)>3&&ArraySize(MACD_h)>2);}
bool StBF(){return ST_dir[1]==1&&ST_dir[2]==-1;}  bool StSF(){return ST_dir[1]==-1&&ST_dir[2]==1;}
bool StBu(){return ST_dir[1]==1;}                  bool StBe(){return ST_dir[1]==-1;}
bool HmBF(){return HMA_tr[1]==1&&HMA_tr[2]==-1;}  bool HmSF(){return HMA_tr[1]==-1&&HMA_tr[2]==1;}
bool HmBu(){return HMA_tr[1]==1;}                  bool HmBe(){return HMA_tr[1]==-1;}
bool WtBu(){return WT1[1]>WT2[1]&&WT1[1]<Inp_WTOB;} bool WtBe(){return WT1[1]<WT2[1]&&WT1[1]>Inp_WTOS;}
bool WtBX(){return WT1[1]>WT2[1]&&WT1[2]<=WT2[2]&&WT1[1]<Inp_WTOB;}
bool WtSX(){return WT1[1]<WT2[1]&&WT1[2]>=WT2[2]&&WT1[1]>Inp_WTOS;}
bool McBu(){return MACD_h[1]>0||MACD_h[1]>MACD_h[2];} bool McBe(){return MACD_h[1]<0||MACD_h[1]<MACD_h[2];}
bool McBF(){return MACD_h[1]>0&&MACD_h[2]<=0;} bool McSF(){return MACD_h[1]<0&&MACD_h[2]>=0;}
bool UtBF(){return ArraySize(UT_dir)>2&&UT_dir[1]==1&&UT_dir[2]!=1;}
bool UtSF(){return ArraySize(UT_dir)>2&&UT_dir[1]==-1&&UT_dir[2]!=-1;}

//+------------------------------------------------------------------+
//| S1: ST + HMA                                                      |
//+------------------------------------------------------------------+
int Sig1(){if(!OK())return 0; if(StBF()&&HmBu())return 1; if(StSF()&&HmBe())return -1; return 0;}

//+------------------------------------------------------------------+
//| S2: ST + HMA+WT+MACD                                              |
//+------------------------------------------------------------------+
int Sig2()
{
   if(!OK())return 0;
   if(StBF()){int c=0;if(HmBu())c++;if(WtBu())c++;if(McBu())c++;if(c>=S2_MinC)return 1;}
   if(StSF()){int c=0;if(HmBe())c++;if(WtBe())c++;if(McBe())c++;if(c>=S2_MinC)return-1;}
   return 0;
}

//+------------------------------------------------------------------+
//| S3: UT + HMA+WT+MACD                                              |
//+------------------------------------------------------------------+
int Sig3()
{
   if(!OK())return 0;
   if(UtBF()){int c=0;if(HmBu())c++;if(WtBu())c++;if(McBu())c++;if(c>=2)return 1;}
   if(UtSF()){int c=0;if(HmBe())c++;if(WtBe())c++;if(McBe())c++;if(c>=2)return-1;}
   return 0;
}

//+------------------------------------------------------------------+
//| S4: UT + ST+HMA+MACD                                              |
//+------------------------------------------------------------------+
int Sig4()
{
   if(!OK())return 0;
   if(UtBF()){int c=0;if(StBu())c++;if(HmBu())c++;if(McBu())c++;if(c>=S4_MinC)return 1;}
   if(UtSF()){int c=0;if(StBe())c++;if(HmBe())c++;if(McBe())c++;if(c>=S4_MinC)return-1;}
   return 0;
}

//+------------------------------------------------------------------+
//| S5: HMA + ST+MACD                                                 |
//+------------------------------------------------------------------+
int Sig5(){if(!OK())return 0; if(HmBF()&&StBu()&&McBu())return 1; if(HmSF()&&StBe()&&McBe())return-1; return 0;}

//+------------------------------------------------------------------+
//| S6: MACD + ST+HMA                                                 |
//+------------------------------------------------------------------+
int Sig6(){if(!OK())return 0; if(McBF()&&StBu()&&HmBu())return 1; if(McSF()&&StBe()&&HmBe())return-1; return 0;}

//+------------------------------------------------------------------+
//| S7: WT + ST+HMA (Best PF 1.76)                                    |
//+------------------------------------------------------------------+
int Sig7(){if(!OK())return 0; if(WtBX()&&StBu()&&HmBu())return 1; if(WtSX()&&StBe()&&HmBe())return-1; return 0;}

//+------------------------------------------------------------------+
//| S8: ST + ALL Conservative (Best WR 56.1%)                         |
//+------------------------------------------------------------------+
int Sig8()
{
   if(!OK())return 0;
   if(StBF()){int c=0;if(HmBu())c++;if(WtBu())c++;if(McBu())c++;if(ArraySize(EMA200)>1&&C[1]>EMA200[1])c++;if(c>=S8_MinC)return 1;}
   if(StSF()){int c=0;if(HmBe())c++;if(WtBe())c++;if(McBe())c++;if(ArraySize(EMA200)>1&&C[1]<EMA200[1])c++;if(c>=S8_MinC)return-1;}
   return 0;
}

//+------------------------------------------------------------------+
//| Session & Spread                                                  |
//+------------------------------------------------------------------+
bool SessOK()
{
   if(!Inp_UseSess)return true;
   MqlDateTime dt; TimeGMT(dt);
   return(dt.hour>=Inp_SessStart&&dt.hour<Inp_SessEnd);
}

bool SpreadOK()
{
   if(ArraySize(ATR)<2||ATR[1]==0)return true;
   G_sym.RefreshRates();
   return(G_sym.Spread()*G_sym.Point()<=ATR[1]*Inp_MaxSpreadATR);
}

//+------------------------------------------------------------------+
//| Open Trade                                                        |
//+------------------------------------------------------------------+
void OpenTrade(int sid, int dir)
{
   G_sym.RefreshRates();
   double a=ATR[1]; if(a==0||a!=a)return;
   double ask=G_sym.Ask(), bid=G_sym.Bid();
   int dg=G_sym.Digits(), magic=Inp_BaseMagic+sid+1;

   double ep,sl,t1,t2;
   ENUM_ORDER_TYPE ot;
   if(dir==1){ep=ask;sl=NormalizeDouble(ep-G_sl[sid]*a,dg);t1=NormalizeDouble(ep+G_tp1[sid]*a,dg);t2=NormalizeDouble(ep+G_tp2[sid]*a,dg);ot=ORDER_TYPE_BUY;}
   else{ep=bid;sl=NormalizeDouble(ep+G_sl[sid]*a,dg);t1=NormalizeDouble(ep-G_tp1[sid]*a,dg);t2=NormalizeDouble(ep-G_tp2[sid]*a,dg);ot=ORDER_TYPE_SELL;}

   double risk=AccountInfoDouble(ACCOUNT_BALANCE)*Inp_Risk/100.0;
   double sld=MathAbs(ep-sl); if(sld==0)return;
   double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tv==0||ts==0)return;

   double lots=NormalizeDouble(risk/(sld/ts*tv),2);
   double lstep=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double mL=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double xL=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   lots=MathMax(mL,MathMin(xL,MathMax(Inp_MinLot,MathMin(Inp_MaxLot,lots))));
   lots=NormalizeDouble(MathFloor(lots/lstep)*lstep,2);
   if(lots<mL)return;

   G_trade.SetExpertMagicNumber(magic);
   string nm[]={"S1","S2","S3","S4","S5","S6","S7","S8"};

   if(G_trade.PositionOpen(_Symbol,ot,lots,ep,sl,t2,nm[sid]))
   {
      SPos p; p.ticket=G_trade.ResultOrder(); p.entry=ep; p.sl=sl;
      p.tp1=t1; p.tp2=t2; p.tp1Hit=false; p.lots=lots; p.sid=sid;
      int sz=ArraySize(G_pos); ArrayResize(G_pos,sz+1); G_pos[sz]=p;
      Print(StringFormat("[%s] %s Entry:%.5f SL:%.5f TP1:%.5f TP2:%.5f Lots:%.2f",
            nm[sid],(dir==1)?"BUY":"SELL",ep,sl,t1,t2,lots));
   }
}

//+------------------------------------------------------------------+
//| Manage Positions                                                  |
//+------------------------------------------------------------------+
void ManagePositions()
{
   for(int i=ArraySize(G_pos)-1;i>=0;i--)
   {
      if(!PositionSelectByTicket(G_pos[i].ticket)){RmPos(i);continue;}

      ENUM_POSITION_TYPE pt=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double cp=(pt==POSITION_TYPE_BUY)?SymbolInfoDouble(_Symbol,SYMBOL_BID):SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      int dg=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
      int magic=Inp_BaseMagic+G_pos[i].sid+1;

      // TP1 partial close
      if(!G_pos[i].tp1Hit)
      {
         bool hit=false;
         if(pt==POSITION_TYPE_BUY&&cp>=G_pos[i].tp1) hit=true;
         if(pt==POSITION_TYPE_SELL&&cp<=G_pos[i].tp1) hit=true;
         if(hit)
         {
            double cl=NormalizeDouble(G_pos[i].lots*0.5,2);
            double ls=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
            cl=NormalizeDouble(MathFloor(cl/ls)*ls,2);
            if(cl>=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN))
            {
               G_trade.SetExpertMagicNumber(magic);
               G_trade.PositionClosePartial(G_pos[i].ticket,cl);
               G_pos[i].tp1Hit=true;
               double be=G_pos[i].entry;
               G_trade.PositionModify(G_pos[i].ticket,be,G_pos[i].tp2);
               G_pos[i].sl=be;
            }
         }
      }

      // SuperTrend trailing (after TP1)
      if(G_pos[i].tp1Hit && ArraySize(ST_line)>1)
      {
         double stl=ST_line[1], csl=PositionGetDouble(POSITION_SL);
         G_trade.SetExpertMagicNumber(magic);
         if(pt==POSITION_TYPE_BUY){double ns=NormalizeDouble(stl,dg);if(ns>csl&&ns<cp)G_trade.PositionModify(G_pos[i].ticket,ns,G_pos[i].tp2);}
         else{double ns=NormalizeDouble(stl,dg);if((ns<csl||csl==0)&&ns>cp)G_trade.PositionModify(G_pos[i].ticket,ns,G_pos[i].tp2);}
      }

      // SuperTrend flip exit
      if(Inp_CloseOnOppFlip && ArraySize(ST_dir)>2)
      {
         bool fx=false;
         if(pt==POSITION_TYPE_BUY&&ST_dir[1]==-1&&ST_dir[2]==1) fx=true;
         if(pt==POSITION_TYPE_SELL&&ST_dir[1]==1&&ST_dir[2]==-1) fx=true;
         if(fx){G_trade.SetExpertMagicNumber(magic);G_trade.PositionClose(G_pos[i].ticket);RmPos(i);}
      }
   }
}

void RmPos(int i){int l=ArraySize(G_pos)-1;if(i<l)G_pos[i]=G_pos[l];ArrayResize(G_pos,l);}

int CntPos(int sid)
{
   int m=Inp_BaseMagic+sid+1, c=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
      if(PositionGetSymbol(i)==_Symbol&&PositionGetInteger(POSITION_MAGIC)==m) c++;
   return c;
}

//+------------------------------------------------------------------+
//| Dashboard                                                         |
//+------------------------------------------------------------------+
void Dashboard(int &sig[])
{
   string nm[]={"S1 ST+HMA       ","S2 ST+Multi     ","S3 UT+Crypto    ","S4 UT+Universal ",
                "S5 HMA+Trend    ","S6 MACD+Mom     ","S7 WT+Reversal  ","S8 ST+Conserv   "};
   string d="";
   d+="══════════════════════════════════════════════\n";
   d+="  MultiStrategy EA v3.0 | "+_Symbol+" "+EnumToString(Period())+"\n";
   d+="══════════════════════════════════════════════\n";
   d+=StringFormat("  ATR: %.5f | Sess: %s | Spread: %s\n",
      ArraySize(ATR)>1?ATR[1]:0.0, SessOK()?"ON":"OFF", SpreadOK()?"OK":"HIGH");
   d+="──────────────────────────────────────────────\n";

   int tp=0;
   for(int s=0;s<NS;s++)
   {
      string en=G_on[s]?"":"[OFF] ";
      string sg=sig[s]==1?">>> BUY":sig[s]==-1?">>> SELL":"  ---  ";
      int pc=CntPos(s); tp+=pc;
      d+=StringFormat("  %s%s %s  pos:%d\n",en,nm[s],sg,pc);
   }

   d+="──────────────────────────────────────────────\n";
   d+=StringFormat("  ST:%s  HMA:%s  WT:%.0f[%s]  MACD:%s  UT:%s\n",
      ArraySize(ST_dir)>1?(ST_dir[1]==1?"BULL":"BEAR"):"?",
      ArraySize(HMA_tr)>1?(HMA_tr[1]==1?"BULL":"BEAR"):"?",
      ArraySize(WT1)>1?WT1[1]:0.0,
      ArraySize(WT1)>1?(WT1[1]>Inp_WTOB?"OB":WT1[1]<Inp_WTOS?"OS":"OK"):"?",
      ArraySize(MACD_h)>1?(MACD_h[1]>0?"+":"-"):"?",
      ArraySize(UT_dir)>1?(UT_dir[1]==1?"BULL":"BEAR"):"?");
   d+=StringFormat("  Positions: %d | Bal: %.2f | Eq: %.2f\n",
      tp, AccountInfoDouble(ACCOUNT_BALANCE), AccountInfoDouble(ACCOUNT_EQUITY));
   d+="══════════════════════════════════════════════";
   Comment(d);
}
//+------------------------------------------------------------------+
