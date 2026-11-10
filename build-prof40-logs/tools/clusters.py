import sys, pickle, collections
s = pickle.load(open(sys.argv[1], 'rb'))
pat = sys.argv[2]
hits = [x for x in s if any(pat in f for f in x[4])]
print('hits', len(hits), 'threads', collections.Counter(h[1] for h in hits).most_common(5))
hits.sort()
cl = []
for h in hits:
    if cl and h[0] - cl[-1][-1][0] < 30e6:
        cl[-1].append(h)
    else:
        cl.append([h])
for c in cl:
    print('cluster t=%.3fs n=%d span=%.2fms threads=%d' % (c[0][0]/1e9, len(c), (c[-1][0]-c[0][0])/1e6, len(set(x[1] for x in c))))
# sample interval on the busy thread
