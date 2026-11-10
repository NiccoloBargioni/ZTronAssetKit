"""Categorise turn samples (inclusive of callees). Leaf->root walk: the first frame matching a name rule decides; else the
first first-party frame with a known line decides; else 'other'. usage: cat.py ann.pkl baseline_ms [--residual]"""
import sys, pickle, collections, os
SRC = '/Users/admin/Documents/ZTronAssetKit/.build-prof40/src/Sources'
files = set(f for d, _, fs in os.walk(SRC) for f in fs if f.endswith('.swift'))
ann = pickle.load(open(sys.argv[1], 'rb'))
base = float(sys.argv[2])

FMT = 'transfer-id formatting'
JOBS = 'jobs-table access'
SORT = 'sorting'
SETS = 'other Set/Dictionary inserts, removals, lookups'
MAN = 'manifest lookups + ManifestEntry copies'
RET = 'retireProgress + removeJob'
EST = 'EngineState whole copy (decisionNow)'
OTH = 'everything else'

def name_rule(n):
    if any(k in n for k in ('ManifestEntry.transferID.getter', 'ContentHash.hex.getter', 'ContentHash.bytes.getter',
                            'TransferID.content(', 'TransferID.legacy(', 'TransferID.init(validated')):
        return FMT
    if 'of EngineState' in n or 'for EngineState' in n:
        return EST
    if any(k in n for k in ('AssetID.< infix', '.sort(by:)', '.sorted(', '_stableSortImpl', '_merge<', '_insertionSort',
                            'InterestToken.< infix', '_mergeTopRuns', '_finalizeRuns')):
        return SORT
    if 'retireProgress' in n or 'SyncEngine.removeJob(' in n:
        return RET
    if 'ValidatedManifest.entry(for:)' in n or 'ValidatedManifest.position(of:)' in n or 'of ManifestEntry' in n \
            or 'for ManifestEntry' in n or 'SyncEngine.sameTransfer' in n:
        return MAN
    if 'of Job' in n or 'for Job' in n:
        return JOBS
    if any(k in n for k in ('Set.insert(', '_NativeSet.insert', 'Set._Variant.insert', 'Set.remove(', '_NativeSet.remove',
                            'Set._Variant.remove', 'Job.insertAsset', 'Job.removeAsset', 'Job.setInterest', 'Set.filter',
                            'Set.subtracting', 'Set.intersection', '_NativeSet.filter', 'Set.subtract', 'Set._subtract')):
        return SETS
    return None

# (file, first, last) -> category, for the innermost first-party frame when no name rule matched.
LINES = [
    ('EngineJobs.swift', 109, 109, FMT),
    ('EngineJobs.swift', 125, 125, EST),
    ('EngineJobs.swift', 126, 126, MAN),
    ('EngineJobs.swift', 132, 135, JOBS),
    ('EngineJobs.swift', 136, 154, OTH),  # job creation (once)
    ('EngineJobs.swift', 156, 168, JOBS),
    ('EngineJobs.swift', 177, 177, JOBS),
    ('EngineJobs.swift', 179, 179, JOBS),
    ('EngineJobs.swift', 191, 191, MAN),
    ('EngineJobs.swift', 193, 195, SETS),
    ('EngineJobs.swift', 224, 247, JOBS),
    ('EngineJobs.swift', 263, 273, JOBS),
    ('EngineJobs.swift', 409, 448, RET),
    ('EngineDispatch.swift', 1121, 1121, MAN),
    ('EngineDispatch.swift', 1151, 1151, MAN),
    ('EngineDispatch.swift', 1164, 1164, SETS),   # isBound: boundContent[asset] == transfer
    ('EngineDispatch.swift', 1176, 1179, SETS),   # groups[token], pending[asset] = transfer
    ('EnginePresence.swift', 9, 11, SETS),
    # takeOffMovedBefore (EngineFollow.swift:551-568)
    ('EngineFollow.swift', 552, 552, SETS),   # job.assets.intersection(movedBefore)
    ('EngineFollow.swift', 557, 557, JOBS),   # jobs[...]?.assets.subtract(held): the table access (the subtract is SETS by name)
    ('EngineFollow.swift', 559, 559, SETS),   # held.contains(asset)
    ('EngineFollow.swift', 560, 560, JOBS),   # jobs[...]?.removeAsset: the table access (removeAsset is SETS by name)
    ('EngineFollow.swift', 563, 565, JOBS),
    ('EngineFollow.swift', 242, 242, EST),
]
def line_rule(loc):
    f, _, l = loc.partition(':')
    try:
        l = int(l)
    except ValueError:
        return None
    for ff, a, b, c in LINES:
        if f == ff and a <= l <= b:
            return c
    return None

ENGINE = set(f for f in files if f.startswith('Engine')) | {'SyncEngine.swift', 'JobState.swift'}
def ctx_rule(ctx, chain):
    leafy = ' '.join(chain)
    if ctx is None:
        return None
    if ('addInterest' in ctx or 'takeOffMovedBefore' in ctx) and 'Dictionary' in leafy:
        return JOBS
    if ('reroute' in ctx or 'committed' in ctx or 'supersede' in ctx) and 'Dictionary' in leafy:
        return SETS
    return None
bysite = collections.Counter()
cats = collections.Counter()
resid = collections.Counter()
for x in ann:
    c = None
    chain = []
    ctx = None
    for n, loc in x[4]:
        c = name_rule(n)
        if c:
            break
        fn = loc.split(':')[0]
        if fn in ENGINE:
            if loc.endswith(':0'):
                if ctx is None:
                    ctx = n
                chain.append(n)
                continue
            c = ctx_rule(ctx, chain) or line_rule(loc)
            if c:
                break
            resid[(loc, n[:50], ' < '.join(k[:35] for k in chain[-3:]))] += 1
            c = OTH
            break
        chain.append(n)
    if c is None:
        c = OTH
        resid[('(no engine line)', x[4][0][0][:50] if x[4] else '?', '')] += 1
    cats[c] += 1
    site = '?'
    for n, loc in x[4]:
        if loc.split(':')[0] in ENGINE and not loc.endswith(':0'):
            site = loc + ' ' + n.split('(')[0][-28:]
            break
    bysite[(c, site)] += 1
N = len(ann)
print('samples in turn: %d; baseline %.2f ms' % (N, base))
for c in (FMT, JOBS, SORT, SETS, MAN, RET, EST, OTH):
    n = cats[c]
    print('| %s | %d | %.1f %% | %.1f ms |' % (c, n, 100*n/N, base*n/N))
if '--residual' in sys.argv:
    print('--- everything-else items')
    for k, n in resid.most_common(30):
        print('%5d %5.1f%% %s' % (n, 100*n/N, k))

if '--bysite' in sys.argv:
    for c in (FMT, JOBS, SORT, SETS, MAN, RET, EST, OTH):
        print('---', c)
        for (cc, site), n in sorted(bysite.items(), key=lambda kv: -kv[1]):
            if cc == c and n >= max(3, N // 400):
                print('   %5d %5.1f%% %.2f ms %s' % (n, 100*n/N, base*n/N, site))
