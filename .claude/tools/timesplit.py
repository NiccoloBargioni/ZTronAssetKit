"""Split workflow agents' wall time into model time and tool time (builds, tests, simulator, probes).

Usage: python3 .claude/tools/timesplit.py <run dir> [<run dir> ...]
A run dir is ~/.claude/projects/-Users-admin-Documents-ZTronAssetKit/<session>/subagents/workflows/<run id>.
Agents labelled usage:* (the haiku usage probes) are skipped. Gaps over 3 h (sleep, outages) are ignored.
"""
import collections, datetime, glob, json, os, sys

agg = collections.defaultdict(lambda: [0.0, 0.0, 0, 0.0])
for run in sys.argv[1:]:
    for meta in glob.glob(os.path.join(run, '*.meta.json')):
        label = json.load(open(meta)).get('description', '?')
        if label.startswith('usage'):
            continue
        role = label.split(':')[0]
        rows = []
        for line in open(meta.replace('.meta.json', '.jsonl')):
            try:
                o = json.loads(line)
            except ValueError:
                continue
            t, kind = o.get('timestamp'), o.get('type')
            if not t or kind not in ('assistant', 'user', 'attachment'):
                continue
            rows.append((datetime.datetime.fromisoformat(t.replace('Z', '+00:00')), 'assistant' if kind == 'assistant' else 'user'))
        rows.sort()
        model = tool = 0.0
        for (t0, a), (t1, b) in zip(rows, rows[1:]):
            dt = (t1 - t0).total_seconds()
            if dt < 0 or dt > 3 * 3600:
                continue
            if b == 'assistant':
                model += dt
            elif a == 'assistant':
                tool += dt
        g = agg[role]
        g[0] += model; g[1] += tool; g[2] += 1
        g[3] += (rows[-1][0] - rows[0][0]).total_seconds() if rows else 0
for role, (m, t, n, span) in sorted(agg.items()):
    total = (m + t) or 1
    print(f'{role:8s} agents {n:3d}  wall {span/3600:6.1f} h  model {m/3600:5.1f} h ({100*m/total:.0f}%)  tools {t/3600:5.1f} h ({100*t/total:.0f}%)')
