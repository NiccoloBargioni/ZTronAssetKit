import re, sys, os
root=sys.argv[1]
start=re.compile(r'CorePoll\.until|\bwhile\b|\brepeat\s*\{')
calls=re.compile(r'\bstep\(|holdPlacement|untilPurgeReturnsOrWaits|releaseAll|CleanupSteps\.run|\.run\(|advance|settle|drive|pump|EngineReaperOverlap')
for dp,dn,fns in os.walk(root):
    for f in sorted(fns):
        if not f.endswith('.swift'): continue
        p=os.path.join(dp,f); lines=open(p).read().split('\n')
        for i,line in enumerate(lines):
            code=re.sub(r'//.*','',line)
            if start.search(code) and '{' in code:
                depth=0; j=i; started=False; body=[]
                while j<len(lines):
                    c=re.sub(r'//.*','',lines[j]); c=re.sub(r'"(?:\\.|[^"\\])*"','""',c)
                    for ch in c:
                        if ch=='{': depth+=1; started=True
                        elif ch=='}': depth-=1
                    body.append(c)
                    if started and depth<=0: break
                    j+=1
                hits=[b.strip() for b in body[1:] if calls.search(b)]
                if hits: print(f"{p}:{i+1}: {lines[i].strip()[:70]} -> {hits[:3]}")
