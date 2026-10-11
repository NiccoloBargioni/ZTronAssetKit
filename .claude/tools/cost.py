"""API-equivalent cost of workflow runs (Opus 5.5 prices: $4 in, $20 out, $0.20 cache read, $5 cache write per MTok;
max usage per message id). Usage: python3 .claude/tools/cost.py <run dir> [<run dir> ...]"""
import json, glob, sys, os
# Opus 5.5 API-equivalent: $4 in, $20 out, $0.20 cache read, $5 cache write per MTok; max usage per message id
def run_cost(d):
    tot = {'input':0,'output':0,'cr':0,'cw':0}
    n=0
    for f in glob.glob(os.path.join(d,'agent-*.jsonl')):
        n+=1
        best={}
        for line in open(f):
            try: o=json.loads(line)
            except: continue
            m=o.get('message') or {}
            u=m.get('usage'); mid=m.get('id')
            if not u or not mid: continue
            key=mid
            cur=(u.get('input_tokens',0),u.get('output_tokens',0),u.get('cache_read_input_tokens',0),u.get('cache_creation_input_tokens',0))
            prev=best.get(key)
            best[key]=tuple(max(a,b) for a,b in zip(prev,cur)) if prev else cur
        for i,o_,cr,cw in best.values():
            tot['input']+=i; tot['output']+=o_; tot['cr']+=cr; tot['cw']+=cw
    c = tot['input']*4e-6 + tot['output']*20e-6 + tot['cr']*0.2e-6 + tot['cw']*5e-6
    return n, tot, c
for d in sys.argv[1:]:
    n,t,c=run_cost(d)
    print(os.path.basename(d), 'agents',n, {k:f'{v/1e6:.1f}M' for k,v in t.items()}, f'${c:.0f}', f"cr {t['cr']*0.2e-6/c*100 if c else 0:.0f}% cw {t['cw']*5e-6/c*100 if c else 0:.0f}% out {t['output']*20e-6/c*100 if c else 0:.0f}%")
