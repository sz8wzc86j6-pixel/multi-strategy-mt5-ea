#!/usr/bin/env python3
"""
Strategy Optimizer — Test enhancements to increase WR and profit.
Tests: ADX filter, volatility filter, WT zone entries, momentum exit,
       hour filter, tighter confluence, optimized SL/TP ratios.
"""

import numpy as np, pandas as pd, warnings, itertools
from datetime import datetime, timedelta
warnings.filterwarnings('ignore')
import yfinance as yf

# ═══════════════════════════════════════════════════════════════
# INDICATORS
# ═══════════════════════════════════════════════════════════════
def calc_atr(h,l,c,p=14):
    n=len(c);tr=np.zeros(n);tr[0]=h[0]-l[0]
    for i in range(1,n):tr[i]=max(h[i]-l[i],abs(h[i]-c[i-1]),abs(l[i]-c[i-1]))
    a=np.full(n,np.nan);
    if n<p:return a
    a[p-1]=np.mean(tr[:p]);m=2.0/(p+1)
    for i in range(p,n):a[i]=tr[i]*m+a[i-1]*(1-m)
    return a

def calc_supertrend(h,l,c,ap=14,mult=1.7):
    n=len(c);atr=calc_atr(h,l,c,ap)
    u=np.zeros(n);lo=np.zeros(n);st=np.zeros(n);d=np.zeros(n,dtype=int)
    for i in range(n):
        a=atr[i] if not np.isnan(atr[i]) else 0
        ub=c[i]+mult*a;lb=c[i]-mult*a
        if i==0:u[i]=ub;lo[i]=lb;d[i]=1
        else:
            lo[i]=lb if(lb>lo[i-1]or c[i-1]<lo[i-1])else lo[i-1]
            u[i]=ub if(ub<u[i-1]or c[i-1]>u[i-1])else u[i-1]
            if d[i-1]==-1 and c[i]>u[i]:d[i]=1
            elif d[i-1]==1 and c[i]<lo[i]:d[i]=-1
            else:d[i]=d[i-1]
        st[i]=lo[i] if d[i]==1 else u[i]
    return st,d

def calc_hma(c,p=10):
    n=len(c);hp=max(int(p/2),1);sp=max(int(np.sqrt(p)),1)
    wh=np.full(n,np.nan);wf=np.full(n,np.nan)
    for i in range(hp-1,n):
        w=np.arange(1,hp+1,dtype=float);wh[i]=np.sum(c[i-hp+1:i+1]*w)/w.sum()
    for i in range(p-1,n):
        w=np.arange(1,p+1,dtype=float);wf[i]=np.sum(c[i-p+1:i+1]*w)/w.sum()
    hs=np.full(n,np.nan)
    for i in range(p-1,n):
        if not np.isnan(wh[i])and not np.isnan(wf[i]):hs[i]=2*wh[i]-wf[i]
    hma=np.full(n,np.nan)
    for i in range(p+sp-2,n):
        v=hs[i-sp+1:i+1]
        if not np.any(np.isnan(v)):
            w=np.arange(1,sp+1,dtype=float);hma[i]=np.sum(v*w)/w.sum()
    tr=np.zeros(n,dtype=int)
    for i in range(1,n):
        if not np.isnan(hma[i])and not np.isnan(hma[i-1]):tr[i]=1 if hma[i]>hma[i-1] else -1
    return hma,tr

def calc_wavetrend(h,l,c,ch=6,avg=13):
    n=len(c);hlc3=(h+l+c)/3.0
    def ema(d,p):
        r=np.zeros(n);m=2.0/(p+1);r[0]=d[0]
        for i in range(1,n):r[i]=d[i]*m+r[i-1]*(1-m)
        return r
    e=ema(hlc3,ch);df=hlc3-e;ad=np.abs(df)
    ed=ema(df,ch);ead=ema(ad,ch)
    ci=np.zeros(n)
    for i in range(n):dn=0.015*ead[i];ci[i]=ed[i]/dn if dn!=0 else 0
    wt1=ema(ci,avg);wt2=np.zeros(n)
    for i in range(3,n):wt2[i]=np.mean(wt1[i-3:i+1])
    return wt1,wt2

def calc_macd(c,f=14,s=28,sg=11):
    n=len(c)
    def ema(d,p):
        r=np.zeros(n);m=2.0/(p+1);r[0]=d[0]
        for i in range(1,n):r[i]=d[i]*m+r[i-1]*(1-m)
        return r
    ml=ema(c,f)-ema(c,s);sl=ema(ml,sg);return ml,sl,ml-sl

def calc_utbot(c,h,l,key=1.5,ap=10):
    n=len(c);atr=calc_atr(h,l,c,ap)
    tr=np.zeros(n);d=np.zeros(n,dtype=int)
    for i in range(1,n):
        nL=key*atr[i] if not np.isnan(atr[i]) else 0
        if c[i]>tr[i-1]and c[i-1]>tr[i-1]:tr[i]=max(tr[i-1],c[i]-nL)
        elif c[i]<tr[i-1]and c[i-1]<tr[i-1]:tr[i]=min(tr[i-1],c[i]+nL)
        elif c[i]>tr[i-1]:tr[i]=c[i]-nL
        else:tr[i]=c[i]+nL
        if c[i]>tr[i]and c[i-1]<=tr[i-1]:d[i]=1
        elif c[i]<tr[i]and c[i-1]>=tr[i-1]:d[i]=-1
        else:d[i]=d[i-1]
    return tr,d

def calc_ema(c,p=200):
    n=len(c);r=np.zeros(n);m=2.0/(p+1);r[0]=c[0]
    for i in range(1,n):r[i]=c[i]*m+r[i-1]*(1-m)
    return r

def calc_adx(h,l,c,p=14):
    """ADX indicator — trend strength"""
    n=len(c);adx=np.full(n,np.nan)
    if n<2*p:return adx
    pdi=np.zeros(n);mdi=np.zeros(n);tr=np.zeros(n)
    for i in range(1,n):
        up=h[i]-h[i-1];dn=l[i-1]-l[i]
        pdi[i]=up if up>dn and up>0 else 0
        mdi[i]=dn if dn>up and dn>0 else 0
        tr[i]=max(h[i]-l[i],abs(h[i]-c[i-1]),abs(l[i]-c[i-1]))
    # Smoothed
    atr=np.zeros(n);spdi=np.zeros(n);smdi=np.zeros(n)
    atr[p]=np.sum(tr[1:p+1]);spdi[p]=np.sum(pdi[1:p+1]);smdi[p]=np.sum(mdi[1:p+1])
    for i in range(p+1,n):
        atr[i]=atr[i-1]-atr[i-1]/p+tr[i]
        spdi[i]=spdi[i-1]-spdi[i-1]/p+pdi[i]
        smdi[i]=smdi[i-1]-smdi[i-1]/p+mdi[i]
    dpdi=np.zeros(n);dmdi=np.zeros(n);dx=np.zeros(n)
    for i in range(p,n):
        if atr[i]>0:dpdi[i]=100*spdi[i]/atr[i];dmdi[i]=100*smdi[i]/atr[i]
        s=dpdi[i]+dmdi[i]
        dx[i]=100*abs(dpdi[i]-dmdi[i])/s if s>0 else 0
    # ADX = EMA of DX
    if n>2*p:
        adx[2*p-1]=np.mean(dx[p:2*p])
        for i in range(2*p,n):adx[i]=(adx[i-1]*(p-1)+dx[i])/p
    return adx

def calc_rsi(c,p=14):
    n=len(c);rsi=np.full(n,50.0)
    if n<p+1:return rsi
    d=np.diff(c);g=np.where(d>0,d,0);lo=np.where(d<0,-d,0)
    ag=np.mean(g[:p]);al=np.mean(lo[:p])
    for i in range(p,n-1):
        ag=(ag*(p-1)+g[i])/p;al=(al*(p-1)+lo[i])/p
        rsi[i+1]=100-100/(1+ag/al) if al>0 else 100
    return rsi

# ═══════════════════════════════════════════════════════════════
# ENHANCED SIGNAL CHECKS
# ═══════════════════════════════════════════════════════════════
WT_OB=53;WT_OS=-53

def check_enhanced_signals(i,st_dir,hma_trend,wt1,wt2,macd_h,ut_dir,ema200,close,
                            adx,rsi,atr,
                            use_adx=False,adx_min=20,
                            use_rsi=False,rsi_ob=70,rsi_os=30,
                            use_wt_zone=False,
                            use_momentum_exit=False,
                            wt_ob=53,wt_os=-53):
    """Enhanced signal check with optional filters"""
    sigs={}

    # Base signals
    st_buy=(st_dir[i]==1 and st_dir[i-1]==-1)
    st_sell=(st_dir[i]==-1 and st_dir[i-1]==1)
    st_bull=(st_dir[i]==1);st_bear=(st_dir[i]==-1)
    hma_buy=(hma_trend[i]==1 and hma_trend[i-1]==-1)
    hma_sell=(hma_trend[i]==-1 and hma_trend[i-1]==1)
    hma_bull=(hma_trend[i]==1);hma_bear=(hma_trend[i]==-1)
    wt_bull=(wt1[i]>wt2[i] and wt1[i]<wt_ob)
    wt_bear=(wt1[i]<wt2[i] and wt1[i]>wt_os)
    wt_bx=(wt1[i]>wt2[i] and wt1[i-1]<=wt2[i-1] and wt1[i]<wt_ob)
    wt_sx=(wt1[i]<wt2[i] and wt1[i-1]>=wt2[i-1] and wt1[i]>wt_os)
    mc_bull=(macd_h[i]>0 or macd_h[i]>macd_h[i-1])
    mc_bear=(macd_h[i]<0 or macd_h[i]<macd_h[i-1])
    ut_buy=(ut_dir[i]==1 and ut_dir[i-1]!=1)
    ut_sell=(ut_dir[i]==-1 and ut_dir[i-1]!=-1)

    # WT zone: only enter when coming FROM oversold/overbought
    if use_wt_zone:
        # For buys: WT was recently below OS (last 5 bars)
        wt_from_os = any(wt1[max(0,i-5):i] < wt_os) if i>=5 else False
        wt_from_ob = any(wt1[max(0,i-5):i] > wt_ob) if i>=5 else False
        if not wt_from_os: wt_bull=False; wt_bx=False
        if not wt_from_ob: wt_bear=False; wt_sx=False

    # ADX filter
    adx_ok = (not use_adx) or (not np.isnan(adx[i]) and adx[i]>=adx_min)

    # RSI filter: don't buy overbought, don't sell oversold
    rsi_buy_ok = (not use_rsi) or (rsi[i]<rsi_ob and rsi[i]>40)
    rsi_sell_ok = (not use_rsi) or (rsi[i]>rsi_os and rsi[i]<60)

    # S1: ST+HMA
    if st_buy and hma_bull and adx_ok and rsi_buy_ok: sigs[0]=1
    elif st_sell and hma_bear and adx_ok and rsi_sell_ok: sigs[0]=-1
    else: sigs[0]=0

    # S2: ST+HMA+WT+MACD
    s2=0
    if st_buy and adx_ok and rsi_buy_ok:
        c=int(hma_bull)+int(wt_bull)+int(mc_bull)
        s2=1 if c>=2 else 0
    elif st_sell and adx_ok and rsi_sell_ok:
        c=int(hma_bear)+int(wt_bear)+int(mc_bear)
        s2=-1 if c>=2 else 0
    sigs[1]=s2

    # S3: UT+HMA+WT+MACD
    s3=0
    if ut_buy and adx_ok and rsi_buy_ok:
        c=int(hma_bull)+int(wt_bull)+int(mc_bull)
        s3=1 if c>=2 else 0
    elif ut_sell and adx_ok and rsi_sell_ok:
        c=int(hma_bear)+int(wt_bear)+int(mc_bear)
        s3=-1 if c>=2 else 0
    sigs[2]=s3

    # S4: UT+ST+HMA+MACD
    s4=0
    if ut_buy and adx_ok and rsi_buy_ok:
        c=int(st_bull)+int(hma_bull)+int(mc_bull)
        s4=1 if c>=2 else 0
    elif ut_sell and adx_ok and rsi_sell_ok:
        c=int(st_bear)+int(hma_bear)+int(mc_bear)
        s4=-1 if c>=2 else 0
    sigs[3]=s4

    # S5: HMA+ST+MACD
    if hma_buy and st_bull and mc_bull and adx_ok and rsi_buy_ok: sigs[4]=1
    elif hma_sell and st_bear and mc_bear and adx_ok and rsi_sell_ok: sigs[4]=-1
    else: sigs[4]=0

    # S7: WT+ST+HMA
    if wt_bx and st_bull and hma_bull and adx_ok and rsi_buy_ok: sigs[6]=1
    elif wt_sx and st_bear and hma_bear and adx_ok and rsi_sell_ok: sigs[6]=-1
    else: sigs[6]=0

    # S8: ST+ALL Cons
    s8=0
    if st_buy and adx_ok and rsi_buy_ok:
        c=int(hma_bull)+int(wt_bull)+int(mc_bull)+int(close[i]>ema200[i])
        s8=1 if c>=3 else 0
    elif st_sell and adx_ok and rsi_sell_ok:
        c=int(hma_bear)+int(wt_bear)+int(mc_bear)+int(close[i]<ema200[i])
        s8=-1 if c>=3 else 0
    sigs[7]=s8

    return sigs


def backtest_enhanced(df, config, starting_capital=250.0):
    """Single enhanced backtest run"""
    c=df['Close'].values.flatten().astype(float)
    h=df['High'].values.flatten().astype(float)
    l=df['Low'].values.flatten().astype(float)
    n=len(c)
    if n<60: return None

    atr=calc_atr(h,l,c,14)
    st_line,st_dir=calc_supertrend(h,l,c,14,config['st_mult'])
    hma_line,hma_trend=calc_hma(c,config['hma_per'])
    wt1,wt2=calc_wavetrend(h,l,c,6,13)
    ml,ms,mh=calc_macd(c,14,28,11)
    ut_tr,ut_dir=calc_utbot(c,h,l,1.5,10)
    ema200=calc_ema(c,200)
    adx=calc_adx(h,l,c,14)
    rsi=calc_rsi(c,14)

    slm=config['sl'];t1m=config['tp1'];t2m=config['tp2']
    strat_ids=config['strats']
    risk_pct=config['risk']

    equity=starting_capital
    trades=[];pos_map={}

    for i in range(50,n):
        if np.isnan(atr[i])or atr[i]==0:continue

        # Manage positions
        for sid in list(pos_map.keys()):
            p=pos_map[sid]
            if p['dir']==1:
                if l[i]<=p['sl']:p['exit']=p['sl'];p['done']=True;p['reason']='SL'
                elif not p['tp1h'] and h[i]>=p['tp1']:p['tp1h']=True;p['sl']=p['entry']
                elif h[i]>=p['tp2']:p['exit']=p['tp2'];p['done']=True;p['reason']='TP2'
                elif st_dir[i]==-1 and i>0 and st_dir[i-1]==1:p['exit']=c[i];p['done']=True;p['reason']='FLIP'
                # Momentum exit: if MACD flips against us and no TP1 yet
                if config.get('mom_exit',False) and not p['tp1h'] and not p.get('done',False):
                    if mh[i]<0 and mh[i-1]>=0:p['exit']=c[i];p['done']=True;p['reason']='MOM'
                if not p.get('done',False) and p['tp1h'] and st_dir[i]==1 and st_line[i]>p['sl']:
                    p['sl']=st_line[i]
            else:
                if h[i]>=p['sl']:p['exit']=p['sl'];p['done']=True;p['reason']='SL'
                elif not p['tp1h'] and l[i]<=p['tp1']:p['tp1h']=True;p['sl']=p['entry']
                elif l[i]<=p['tp2']:p['exit']=p['tp2'];p['done']=True;p['reason']='TP2'
                elif st_dir[i]==1 and i>0 and st_dir[i-1]==-1:p['exit']=c[i];p['done']=True;p['reason']='FLIP'
                if config.get('mom_exit',False) and not p['tp1h'] and not p.get('done',False):
                    if mh[i]>0 and mh[i-1]<=0:p['exit']=c[i];p['done']=True;p['reason']='MOM'
                if not p.get('done',False) and p['tp1h'] and st_dir[i]==-1 and st_line[i]<p['sl']:
                    p['sl']=st_line[i]

            if p.get('done',False):
                sld=atr[i]*slm if atr[i]>0 else 1
                ra=equity*risk_pct/100.0;ps=ra/sld if sld>0 else 0
                if p['tp1h']:pnl=(p['tp1']-p['entry'])*p['dir']*ps*0.5+(p['exit']-p['entry'])*p['dir']*ps*0.5
                else:pnl=(p['exit']-p['entry'])*p['dir']*ps
                equity+=pnl;equity=max(equity,10)
                trades.append({'sid':sid,'pnl':pnl,'pnl_pct':(pnl/max(equity-pnl,10))*100,
                               'reason':p['reason'],'tp1h':p['tp1h']})
                del pos_map[sid]

        # New entries
        if i<2:continue
        sigs=check_enhanced_signals(i,st_dir,hma_trend,wt1,wt2,mh,ut_dir,ema200,c,
                                     adx,rsi,atr,
                                     use_adx=config.get('use_adx',False),adx_min=config.get('adx_min',20),
                                     use_rsi=config.get('use_rsi',False),rsi_ob=config.get('rsi_ob',70),rsi_os=config.get('rsi_os',30),
                                     use_wt_zone=config.get('use_wt_zone',False),
                                     wt_ob=config.get('wt_ob',53),wt_os=config.get('wt_os',-53))

        for sid in strat_ids:
            if sid in pos_map:continue
            sig=sigs.get(sid,0)
            if sig==0:continue
            a=atr[i]
            if sig==1:sl=c[i]-slm*a;tp1=c[i]+t1m*a;tp2=c[i]+t2m*a
            else:sl=c[i]+slm*a;tp1=c[i]-t1m*a;tp2=c[i]-t2m*a
            pos_map[sid]={'dir':sig,'entry':c[i],'sl':sl,'tp1':tp1,'tp2':tp2,'tp1h':False}

    # Close remaining
    for sid in list(pos_map.keys()):
        p=pos_map[sid]
        sld=atr[-1]*slm if not np.isnan(atr[-1])and atr[-1]>0 else 1
        ra=equity*risk_pct/100.0;ps=ra/sld if sld>0 else 0
        pnl=(c[-1]-p['entry'])*p['dir']*ps
        equity+=pnl
        trades.append({'sid':sid,'pnl':pnl,'pnl_pct':(pnl/max(equity-pnl,10))*100,'reason':'EOD','tp1h':p.get('tp1h',False)})

    if not trades:return None
    wins=[t for t in trades if t['pnl']>0]
    losses=[t for t in trades if t['pnl']<=0]
    wr=len(wins)/len(trades)*100
    ret=(equity-starting_capital)/starting_capital*100
    gp=sum(t['pnl'] for t in wins);gl=abs(sum(t['pnl'] for t in losses))
    pf=gp/gl if gl>0 else 99
    tp1_hits=sum(1 for t in trades if t['tp1h'])

    return {
        'trades':len(trades),'wins':len(wins),'wr':wr,'ret':ret,
        'equity':equity,'pf':pf,'tp1_rate':tp1_hits/len(trades)*100 if trades else 0,
        'avg_win':np.mean([t['pnl_pct'] for t in wins]) if wins else 0,
        'avg_loss':np.mean([t['pnl_pct'] for t in losses]) if losses else 0,
    }


def main():
    print("="*90)
    print("  STRATEGY OPTIMIZER — Finding best enhancements")
    print("="*90)

    # Load EURUSD M15 (best performing market)
    end=datetime.now();start=end-timedelta(days=16)
    symbols = {
        'EURUSD': yf.download('EURUSD=X',start=start,end=end,interval='15m',progress=False),
        'GBPUSD': yf.download('GBPUSD=X',start=start,end=end,interval='15m',progress=False),
    }
    for k in symbols:
        df=symbols[k]
        if isinstance(df.columns,pd.MultiIndex):df.columns=df.columns.get_level_values(0)
        symbols[k]=df.loc[:,~df.columns.duplicated()]

    strat_ids = [0,1,2,3,4,6,7]  # S1-S5,S7,S8

    # ═══ TEST CONFIGURATIONS ═══
    configs = [
        # BASELINE (current)
        {"name":"BASELINE","strats":strat_ids,"sl":1.0,"tp1":1.5,"tp2":3.0,"risk":1.5,
         "st_mult":1.7,"hma_per":10},

        # ADX filter (only trade trending)
        {"name":"+ ADX>20","strats":strat_ids,"sl":1.0,"tp1":1.5,"tp2":3.0,"risk":1.5,
         "st_mult":1.7,"hma_per":10,"use_adx":True,"adx_min":20},
        {"name":"+ ADX>25","strats":strat_ids,"sl":1.0,"tp1":1.5,"tp2":3.0,"risk":1.5,
         "st_mult":1.7,"hma_per":10,"use_adx":True,"adx_min":25},
        {"name":"+ ADX>15","strats":strat_ids,"sl":1.0,"tp1":1.5,"tp2":3.0,"risk":1.5,
         "st_mult":1.7,"hma_per":10,"use_adx":True,"adx_min":15},

        # RSI filter
        {"name":"+ RSI guard","strats":strat_ids,"sl":1.0,"tp1":1.5,"tp2":3.0,"risk":1.5,
         "st_mult":1.7,"hma_per":10,"use_rsi":True,"rsi_ob":70,"rsi_os":30},
        {"name":"+ RSI tight","strats":strat_ids,"sl":1.0,"tp1":1.5,"tp2":3.0,"risk":1.5,
         "st_mult":1.7,"hma_per":10,"use_rsi":True,"rsi_ob":65,"rsi_os":35},

        # ADX + RSI combined
        {"name":"+ ADX20+RSI","strats":strat_ids,"sl":1.0,"tp1":1.5,"tp2":3.0,"risk":1.5,
         "st_mult":1.7,"hma_per":10,"use_adx":True,"adx_min":20,"use_rsi":True,"rsi_ob":70,"rsi_os":30},
        {"name":"+ ADX25+RSI65","strats":strat_ids,"sl":1.0,"tp1":1.5,"tp2":3.0,"risk":1.5,
         "st_mult":1.7,"hma_per":10,"use_adx":True,"adx_min":25,"use_rsi":True,"rsi_ob":65,"rsi_os":35},

        # WT zone entry (from OB/OS)
        {"name":"+ WT zone","strats":strat_ids,"sl":1.0,"tp1":1.5,"tp2":3.0,"risk":1.5,
         "st_mult":1.7,"hma_per":10,"use_wt_zone":True},

        # Momentum exit
        {"name":"+ Mom exit","strats":strat_ids,"sl":1.0,"tp1":1.5,"tp2":3.0,"risk":1.5,
         "st_mult":1.7,"hma_per":10,"mom_exit":True},

        # SL/TP optimization
        {"name":"SL0.8/TP1.2/2.5","strats":strat_ids,"sl":0.8,"tp1":1.2,"tp2":2.5,"risk":1.5,
         "st_mult":1.7,"hma_per":10},
        {"name":"SL1.2/TP2.0/4.0","strats":strat_ids,"sl":1.2,"tp1":2.0,"tp2":4.0,"risk":1.5,
         "st_mult":1.7,"hma_per":10},
        {"name":"SL1.0/TP2.0/5.0","strats":strat_ids,"sl":1.0,"tp1":2.0,"tp2":5.0,"risk":1.5,
         "st_mult":1.7,"hma_per":10},
        {"name":"SL0.7/TP1.0/2.0","strats":strat_ids,"sl":0.7,"tp1":1.0,"tp2":2.0,"risk":1.5,
         "st_mult":1.7,"hma_per":10},

        # Risk optimization
        {"name":"Risk 2.0%","strats":strat_ids,"sl":1.0,"tp1":1.5,"tp2":3.0,"risk":2.0,
         "st_mult":1.7,"hma_per":10},
        {"name":"Risk 2.5%","strats":strat_ids,"sl":1.0,"tp1":1.5,"tp2":3.0,"risk":2.5,
         "st_mult":1.7,"hma_per":10},
        {"name":"Risk 3.0%","strats":strat_ids,"sl":1.0,"tp1":1.5,"tp2":3.0,"risk":3.0,
         "st_mult":1.7,"hma_per":10},

        # Combined best
        {"name":"ADX20+RSI+R2%","strats":strat_ids,"sl":1.0,"tp1":1.5,"tp2":3.0,"risk":2.0,
         "st_mult":1.7,"hma_per":10,"use_adx":True,"adx_min":20,"use_rsi":True,"rsi_ob":70,"rsi_os":30},
        {"name":"ADX20+MomEx+R2%","strats":strat_ids,"sl":1.0,"tp1":1.5,"tp2":3.0,"risk":2.0,
         "st_mult":1.7,"hma_per":10,"use_adx":True,"adx_min":20,"mom_exit":True},
        {"name":"ADX20+RSI+SL0.8","strats":strat_ids,"sl":0.8,"tp1":1.2,"tp2":2.5,"risk":2.0,
         "st_mult":1.7,"hma_per":10,"use_adx":True,"adx_min":20,"use_rsi":True,"rsi_ob":70,"rsi_os":30},
        {"name":"ALL FILTERS+R2.5","strats":strat_ids,"sl":1.0,"tp1":1.5,"tp2":3.0,"risk":2.5,
         "st_mult":1.7,"hma_per":10,"use_adx":True,"adx_min":20,"use_rsi":True,"rsi_ob":70,"rsi_os":30,"mom_exit":True},
        {"name":"ALL+SL0.8+R2.5","strats":strat_ids,"sl":0.8,"tp1":1.2,"tp2":2.5,"risk":2.5,
         "st_mult":1.7,"hma_per":10,"use_adx":True,"adx_min":20,"use_rsi":True,"rsi_ob":70,"rsi_os":30,"mom_exit":True},

        # HMA period variations
        {"name":"HMA7+ADX20+R2%","strats":strat_ids,"sl":1.0,"tp1":1.5,"tp2":3.0,"risk":2.0,
         "st_mult":1.7,"hma_per":7,"use_adx":True,"adx_min":20},
        {"name":"HMA15+ADX20+R2%","strats":strat_ids,"sl":1.0,"tp1":1.5,"tp2":3.0,"risk":2.0,
         "st_mult":1.7,"hma_per":15,"use_adx":True,"adx_min":20},

        # ST multiplier variations
        {"name":"ST2.0+ADX20+R2%","strats":strat_ids,"sl":1.0,"tp1":1.5,"tp2":3.0,"risk":2.0,
         "st_mult":2.0,"hma_per":10,"use_adx":True,"adx_min":20},
        {"name":"ST1.5+ADX20+R2%","strats":strat_ids,"sl":1.0,"tp1":1.5,"tp2":3.0,"risk":2.0,
         "st_mult":1.5,"hma_per":10,"use_adx":True,"adx_min":20},
    ]

    # Run all configs on both symbols
    results = []
    for cfg in configs:
        for sym_name, df in symbols.items():
            r = backtest_enhanced(df, cfg, 250.0)
            if r:
                results.append({**r, 'config':cfg['name'], 'symbol':sym_name})

    # Aggregate by config
    print(f"\n{'Config':<25} {'AvgWR%':<8} {'AvgRet%':<10} {'AvgPF':<8} {'AvgTrades':<10} {'TP1Rate':<8} {'AvgWin':<8} {'AvgLoss':<9}")
    print("-"*90)

    agg = {}
    for r in results:
        k = r['config']
        if k not in agg: agg[k] = []
        agg[k].append(r)

    ranked = []
    for name, rs in agg.items():
        avg_wr = np.mean([r['wr'] for r in rs])
        avg_ret = np.mean([r['ret'] for r in rs])
        avg_pf = np.mean([r['pf'] for r in rs])
        avg_tr = np.mean([r['trades'] for r in rs])
        avg_tp1 = np.mean([r['tp1_rate'] for r in rs])
        avg_w = np.mean([r['avg_win'] for r in rs])
        avg_l = np.mean([r['avg_loss'] for r in rs])
        score = avg_wr*0.3 + avg_ret*0.3 + avg_pf*10*0.2 + avg_tp1*0.1 - abs(avg_l)*0.1
        ranked.append((name, avg_wr, avg_ret, avg_pf, avg_tr, avg_tp1, avg_w, avg_l, score))

    ranked.sort(key=lambda x: x[8], reverse=True)

    for i,(nm,wr,ret,pf,tr,tp1,aw,al,sc) in enumerate(ranked):
        marker = " <<<" if i==0 else (" <<" if i<3 else "")
        print(f"  {nm:<23} {wr:<7.1f}% {ret:+<9.1f}% {pf:<7.2f} {tr:<9.0f} {tp1:<7.1f}% {aw:+<7.2f}% {al:<+8.2f}%{marker}")

    # Show winner details
    winner = ranked[0]
    print(f"\n{'='*90}")
    print(f"  WINNER: {winner[0]}")
    print(f"  WR: {winner[1]:.1f}% | Return: {winner[2]:+.1f}% | PF: {winner[3]:.2f} | TP1 hit: {winner[5]:.1f}%")
    print(f"  vs BASELINE: WR {ranked[[r[0] for r in ranked].index('BASELINE')][1]:.1f}% | Ret {ranked[[r[0] for r in ranked].index('BASELINE')][2]:+.1f}%")

    # Show per-symbol for top 3
    print(f"\n  TOP 3 — Per symbol detail:")
    for nm,_,_,_,_,_,_,_,_ in ranked[:3]:
        print(f"\n  {nm}:")
        for r in agg[nm]:
            print(f"    {r['symbol']}: {r['trades']} trades | WR {r['wr']:.1f}% | Ret {r['ret']:+.1f}% | PF {r['pf']:.2f} | ${r['equity']:.2f}")

    print(f"\n{'='*90}")

    # Return winner config name for EA update
    return ranked[0][0]

if __name__=="__main__":
    main()
