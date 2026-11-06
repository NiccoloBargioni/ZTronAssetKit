"""Wait until a workflow journal records more agent results than `seen`, then print them and exit.

Usage: python3 watch_journal.py <journal.jsonl> <seen>
One line per finished agent: label, then the fix's quick line or the verifier's blocking count.
"""
import json
import sys
import time

path, seen = sys.argv[1], int(sys.argv[2])
# Optional: wait until at least this many results exist (default: one more than `seen`).
target = int(sys.argv[3]) if len(sys.argv) > 3 else seen + 1


def read():
    labels, results = {}, []
    try:
        with open(path) as f:
            for line in f:
                try:
                    o = json.loads(line)
                except ValueError:
                    continue
                if o.get('type') == 'started':
                    labels[o.get('agentId')] = o.get('label')
                elif o.get('type') == 'result':
                    results.append(o)
                elif o.get('type') not in (None, 'launched'):
                    results.append(o)
    except FileNotFoundError:
        pass
    return labels, results


while True:
    labels, results = read()
    if len(results) >= target:
        for o in results[seen:]:
            lab = labels.get(o.get('agentId'), o.get('type'))
            r = o.get('result')
            if isinstance(r, dict) and 'issues' in r:
                b = sum(1 for i in r['issues'] if i.get('blocking'))
                note = '%d blocking / %d issues' % (b, len(r['issues']))
            elif isinstance(r, dict) and 'quick_line' in r:
                note = 'quick: %s | declined %d' % (r.get('quick_line', '')[:160], len(r.get('declined', [])))
            else:
                note = 'type=%s result=%s' % (o.get('type'), str(r)[:160])
            print('%s finished (%s): %s' % (lab, time.strftime('%H:%M'), note), flush=True)
        print('results now %d' % len(results), flush=True)
        break
    time.sleep(60)
