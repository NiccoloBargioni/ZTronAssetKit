"""Symbolicate turn samples' frames to source lines with atos -i (dSYM), and annotate each frame with file:line.
usage: symb.py turn.pkl out.pkl"""
import sys, pickle, subprocess, os, re, collections
P = '/Users/admin/Documents/ZTronAssetKit/.build-prof40'
DW = P + '/spm/release/ZTronAssetKitBenchmarks.xctest.dSYM/Contents/Resources/DWARF/ZTronAssetKitBenchmarks'
turn = pickle.load(open(sys.argv[1], 'rb'))
addrs = collections.OrderedDict()
load = None
for x in turn:
    for f in x[4]:
        if f[2].endswith('/ZTronAssetKitBenchmarks'):
            addrs[f[1]] = 1
            load = f[3]
addrs = list(addrs)
chains = {}
B = 500
for i in range(0, len(addrs), B):
    chunk = addrs[i:i+B]
    out = subprocess.run(['atos', '-i', '-o', DW, '-l', load] + chunk, capture_output=True, text=True).stdout
    blocks = out.strip('\n').split('\n\n')
    if len(blocks) != len(chunk):
        # fall back one by one
        for a in chunk:
            o = subprocess.run(['atos', '-i', '-o', DW, '-l', load, a], capture_output=True, text=True).stdout
            chains[a] = o.strip('\n').split('\n')
    else:
        for a, b in zip(chunk, blocks):
            chains[a] = b.split('\n')
rx = re.compile(r'^(.*) \(in ZTronAssetKitBenchmarks\) \((.*)\)$')
def parse(lines):
    r = []
    for l in lines:
        m = rx.match(l)
        r.append((m.group(1), m.group(2)) if m else (l, '?'))
    return r
pchains = {a: parse(c) for a, c in chains.items()}
ann = []
for x in turn:
    fr = []
    # frames sharing an addr are an inline chain in the same order as atos's
    i = 0
    frames = x[4]
    while i < len(frames):
        a = frames[i][1]
        j = i
        while j < len(frames) and frames[j][1] == a:
            j += 1
        group = frames[i:j]
        ch = pchains.get(a)
        for k, f in enumerate(group):
            loc = '?'
            if ch is not None:
                # match by name, else by position
                cands = [c for c in ch if c[0] == f[0]]
                loc = cands[0][1] if cands else (ch[k][1] if k < len(ch) else '?')
            fr.append((f[0], loc))
        i = j
    ann.append((x[0], x[1], x[2], x[3], tuple(fr)))
pickle.dump(ann, open(sys.argv[2], 'wb'))
print('annotated', len(ann), 'unique addrs', len(addrs))
