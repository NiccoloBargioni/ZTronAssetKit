"""Select the measured turn's samples and print self/inclusive tops.
usage: turn.py pkl clusterpat minN rootpat [rootpat...]
Turn samples: on the cluster's thread, within the cluster's [first,last] time, whose backtrace contains any rootpat."""
import sys, pickle, collections
s = pickle.load(open(sys.argv[1], 'rb'))
clpat, minn, roots = sys.argv[2], int(sys.argv[3]), sys.argv[4:]
s.sort(key=lambda x: x[0])
hits = [x for x in s if any(clpat in f[0] for f in x[4])]
cl = []
for h in hits:
    if cl and h[0] - cl[-1][-1][0] < 30e6 and h[1] == cl[-1][-1][1]:
        cl[-1].append(h)
    else:
        cl.append([h])
print('cluster sizes', [len(c) for c in cl])
cl = [c for c in cl if len(c) >= minn]
import os
EXT = float(os.environ.get('EXTEND_MS', '0')) * 1e6
turn = []
other = collections.Counter()
for c in cl:
    t0, t1, tid = c[0][0], c[-1][0], c[0][1]
    if EXT:
        same = [x for x in s if x[1] == tid and any(any(r in f[0] for f in x[4]) for r in roots)]
        times = sorted(x[0] for x in same)
        import bisect
        i = bisect.bisect_left(times, t0)
        while i > 0 and t0 - times[i-1] <= EXT:
            i -= 1
            t0 = times[i]
        j = bisect.bisect_right(times, t1)
        while j < len(times) and times[j] - t1 <= EXT:
            t1 = times[j]
            j += 1
    for x in s:
        if t0 <= x[0] <= t1 and x[1] == tid:
            if any(any(r in f[0] for f in x[4]) for r in roots):
                turn.append(x)
            else:
                other[x[4][0][0] if x[4] else '?'] += 1
print('clusters', len(cl), 'turn samples', len(turn), 'same-thread non-root samples in window', sum(other.values()), other.most_common(5))
pickle.dump(turn, open(sys.argv[1].replace('.pkl', '.turn.pkl'), 'wb'))
selfc = collections.Counter(x[4][0][0] for x in turn)
incl = collections.Counter()
for x in turn:
    for f in set(g[0] for g in x[4]):
        incl[f] += 1
N = len(turn)
print('--- self top 40')
for f, n in selfc.most_common(40):
    print('%5d %5.1f%% %s' % (n, 100*n/N, f[:150]))
print('--- inclusive top 60')
for f, n in incl.most_common(60):
    print('%5d %5.1f%% %s' % (n, 100*n/N, f[:150]))
