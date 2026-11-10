"""Details for a turn: top self, formatting call sites, sort call sites, inclusive shares of named functions."""
import sys, pickle, collections, os
ann = pickle.load(open(sys.argv[1], 'rb'))
base = float(sys.argv[2])
N = len(ann)
def pct(n): return '%d (%.1f %%, %.2f ms)' % (n, 100*n/N, base*n/N)
selfc = collections.Counter(x[4][0][0] for x in ann)
print('--- top 15 self')
for n, k in [(v, k) for k, v in selfc.most_common(15)]:
    print('|', k[:110], '|', pct(n), '|')
def site_of(x, pred):
    fr = x[4]
    for i, (n, l) in enumerate(fr):
        if pred(n):
            for m, ml in fr[i+1:]:
                if ml.split(':')[0].startswith('Engine') and not ml.endswith(':0'):
                    return ml + ' ' + m[:40]
            return '?'
    return None
for title, pred in [('formatting call sites', lambda n: 'ManifestEntry.transferID.getter' in n or 'ContentHash.hex.getter' in n),
                    ('sort call sites', lambda n: 'sorted(' in n or '.sort(by:)' in n)]:
    c = collections.Counter()
    for x in ann:
        s = site_of(x, pred)
        if s: c[s] += 1
    print('---', title, 'total', pct(sum(c.values())))
    for k, v in c.most_common(12):
        print('|', k, '|', pct(v), '|')
print('--- inclusive shares')
for f in sys.argv[3:]:
    n = sum(1 for x in ann if any(f in g[0] for g in x[4]))
    print('|', f, '|', pct(n), '|')
