"""For samples whose innermost first-party frame is at LOC, show leafward chains."""
import sys, pickle, collections, os
SRC = '/Users/admin/Documents/ZTronAssetKit/.build-prof40/src/Sources'
files = set(f for d, _, fs in os.walk(SRC) for f in fs if f.endswith('.swift'))
ann = pickle.load(open(sys.argv[1], 'rb'))
want = sys.argv[2]
c = collections.Counter()
for x in ann:
    chain = []
    for name, loc in x[4]:
        if loc.split(':')[0] in files:
            if loc == want or (want.endswith(':*') and loc.startswith(want[:-1])):
                c[(' < '.join(n[:45] for n in chain[-4:]), name[:40], ' > '.join(n[:40] for n, l in x[4][x[4].index((name, loc))+1:][:3]))] += 1
            break
        chain.append(name)
for k, n in c.most_common(int(sys.argv[3]) if len(sys.argv) > 3 else 12):
    print(n, k)
