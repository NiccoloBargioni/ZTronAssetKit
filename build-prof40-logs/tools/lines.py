"""Histogram of the innermost first-party source frame (file:line) per sample, with function names."""
import sys, pickle, collections, os
SRC = '/Users/admin/Documents/ZTronAssetKit/.build-prof40/src/Sources'
files = set()
for d, _, fs in os.walk(SRC):
    for f in fs:
        if f.endswith('.swift'): files.add(f)
ann = pickle.load(open(sys.argv[1], 'rb'))
mode = sys.argv[2] if len(sys.argv) > 2 else 'inner'
c = collections.Counter()
for x in ann:
    for name, loc in x[4]:
        fn = loc.split(':')[0]
        if fn in files:
            c[(loc, name[:70])] += 1
            if mode == 'inner':
                break
N = len(ann)
for (loc, name), n in c.most_common(int(sys.argv[3]) if len(sys.argv) > 3 else 70):
    print('%5d %5.1f%% %-28s %s' % (n, 100*n/N, loc, name))
