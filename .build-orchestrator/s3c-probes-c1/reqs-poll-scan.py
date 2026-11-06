import re, sys, os
root = sys.argv[1]
pat = re.compile(r'\.release\(|releaseNext\(|releaseAll\(|setHolding\(')
loopstart = re.compile(r'CorePoll\.(until|releasing)|\bwhile\b|\brepeat\s*\{|\bfor\b[^\n]*\bin\b|withTaskGroup|Task\s*\{|Task\.detached')
for dp, dn, fn in os.walk(root):
    for f in fn:
        if not f.endswith('.swift'): continue
        p = os.path.join(dp, f)
        src = open(p).read()
        lines = src.split('\n')
        # compute brace depth stack with opener line text
        stack = []  # (line_no, text)
        enclosing = {}
        for i, line in enumerate(lines):
            # strip strings/comments crude
            code = re.sub(r'//.*', '', line)
            code = re.sub(r'"(?:\\.|[^"\\])*"', '""', code)
            if pat.search(code):
                ctx = [ (ln+1, t.strip()[:90]) for ln,t in stack if loopstart.search(t)]
                if ctx:
                    print(f"{p}:{i+1}: {line.strip()[:80]}")
                    for c in ctx: print(f"      in {c[0]}: {c[1]}")
            for ch in code:
                if ch == '{': stack.append((i, line))
                elif ch == '}':
                    if stack: stack.pop()
