"""Write each finished agent's result of the RR-21 analysis run as Markdown under the output folder."""
import json, os, sys
journal, out = sys.argv[1], sys.argv[2]
run = os.path.basename(os.path.dirname(os.path.abspath(journal)))
os.makedirs(out, exist_ok=True)
labels, written = {}, []

def emit(v, depth=0):
    if isinstance(v, str):
        return v
    if isinstance(v, list):
        return '\n'.join('- ' + (x if isinstance(x, str) else json.dumps(x, indent=1)) for x in v)
    return json.dumps(v, indent=1)

for line in open(journal):
    try:
        o = json.loads(line)
    except ValueError:
        continue
    if o.get('type') == 'started':
        labels[o['agentId']] = o.get('label')
    elif o.get('type') == 'result':
        lab = labels.get(o['agentId'], o['agentId'])
        r = o.get('result')
        name = lab.replace(':', '-') + '.md'
        with open(os.path.join(out, name), 'w') as f:
            f.write('# %s\n\nRead-only analysis for ruling S3-R26 (workflow %s, on 8e1fb24). '
                    'UNCONFIRMED marks what the agent read but did not run.\n' % (lab, run))
            if isinstance(r, dict) and 'items' in r:
                for it in r['items']:
                    f.write('\n## %s\n' % it.get('item', ''))
                    for k, v in it.items():
                        if k != 'item':
                            f.write('\n### %s\n\n%s\n' % (k, emit(v)))
                for k, v in r.items():
                    if k != 'items':
                        f.write('\n## %s\n\n%s\n' % (k, emit(v)))
            elif isinstance(r, dict):
                for k, v in r.items():
                    f.write('\n## %s\n\n%s\n' % (k, emit(v)))
            else:
                f.write('\n%s\n' % r)
        written.append(name)
print('\n'.join(written))
