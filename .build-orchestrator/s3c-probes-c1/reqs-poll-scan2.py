import re, sys, os
root = sys.argv[1]
start = re.compile(r'CorePoll\.until|\bwhile\b|\brepeat\s*\{')
for dp, dn, fn in os.walk(root):
    for f in sorted(fn):
        if not f.endswith('.swift'): continue
        p = os.path.join(dp, f)
        lines = open(p).read().split('\n')
        i = 0
        while i < len(lines):
            line = lines[i]
            code = re.sub(r'//.*', '', line)
            if start.search(code) and '{' in code:
                depth = 0; j = i; body=[]
                started=False
                while j < len(lines):
                    c = re.sub(r'//.*', '', lines[j]); c = re.sub(r'"(?:\\.|[^"\\])*"', '""', c)
                    for ch in c:
                        if ch=='{': depth+=1; started=True
                        elif ch=='}': depth-=1
                    body.append(lines[j])
                    if started and depth<=0: break
                    j+=1
                txt='\n'.join(body)
                if re.search(r'release|Release|setHolding|held', txt) and 'CorePoll+Release' not in p:
                    print(f"== {p}:{i+1}-{j+1}")
                    for b in body[:14]: print('   ', b.rstrip()[:130])
                i = i+1
            else:
                i+=1
