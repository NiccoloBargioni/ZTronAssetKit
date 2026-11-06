import os, re, sys
root = 'Tests'
bodies = []
for d, _, fs in os.walk(root):
    for f in fs:
        if not f.endswith('.swift'):
            continue
        p = os.path.join(d, f)
        s = open(p).read()
        for m in re.finditer(r'awaitCondition\s*\{', s):
            i = m.end(); depth = 1
            while depth and i < len(s):
                c = s[i]
                if c == '{': depth += 1
                elif c == '}': depth -= 1
                i += 1
            bodies.append((p, s.count('\n', 0, m.start()) + 1, s[m.end():i - 1]))
print('closures', len(bodies))
direct = [(p, l) for p, l, b in bodies if 'violations' in b.lower()]
print('direct violations calls in closures:', direct)
# helpers called as Type.name( inside closures
helpers = set()
for p, l, b in bodies:
    for h in re.findall(r'\b([A-Z][A-Za-z0-9]*)\.([a-z][A-Za-z0-9]*)\(', b):
        helpers.add(h)
    for h in re.findall(r'\$0\.([a-z][A-Za-z0-9]*)\(', b) + re.findall(r'\be\.([a-z][A-Za-z0-9]*)\(', b):
        helpers.add(('engine', h))
print('helpers', sorted(helpers))
