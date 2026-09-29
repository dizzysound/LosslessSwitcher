import csv, glob, sys, statistics as st
W=4.0; TH=20e-6
files=sorted(set(glob.glob('/Users/chrisgillespie/Developer/music-tap-spike/.claude/worktrees/*/vdev/data/*.clock.csv')))
worst_fail=0
for f in files:
    rows=[r for r in csv.DictReader(open(f))]
    segs=[];cur=[]
    for r in rows:
        t=float(r['t']);rb=float(r['dacScalarHAL']);e=float(r['err'])
        if (e==0.0 and cur) or (cur and t-cur[-1][0]>2): segs.append(cur);cur=[]
        cur.append((t,rb,int(float(r['rate']))))
    if cur: segs.append(cur)
    out=[]
    for s in segs:
        if len(s)<9: continue
        t0=s[0][0]; first=None; fails=0; wins=0; maxd=0
        for i in range(len(s)):
            w=[x for x in s[:i+1] if s[i][0]-x[0]<=W]
            if s[i][0]-w[0][0] < W-0.75: continue
            mid=w[0][0]+(s[i][0]-w[0][0])/2
            a=[x[1] for x in w if x[0]<mid]; b=[x[1] for x in w if x[0]>=mid]
            d=abs(st.mean(a)-st.mean(b))
            ok=d<TH
            if ok and first is None: first=s[i][0]-t0
            if s[i][0]-t0>15: wins+=1; fails+= (not ok); maxd=max(maxd,d)
        jit=st.pstdev([x[1] for x in s if x[0]-t0>15]) if len(s)>40 else float('nan')
        out.append(f"{s[0][2]}:pass@{first}s fail{fails}/{wins} maxd{maxd*1e6:.0f} sd{jit*1e6:.1f} rb0={s[0][1]:.6f}")
    print(f.split('/')[-4][:8], f.split('/')[-1], '; '.join(out))
