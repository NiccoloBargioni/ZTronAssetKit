# Scratch: S3-R12 rule-1 load reading of the TSan run (1-min load sampled every 5 s, from 60 s after start to the end).
import re, sys
log, samples = sys.argv[1], sys.argv[2]
text = open(log).read()
start = int(re.search(r'^start .* epoch (\d+)', text, re.M).group(1))
m = re.search(r'^exit (\d+) end .* epoch (\d+)', text, re.M)
end = int(m.group(2)) if m else None
vals = []
for line in open(samples):
    parts = line.replace('{', ' ').replace('}', ' ').split()
    if len(parts) < 2:
        continue
    t, one = int(parts[0]), float(parts[1].replace(',', '.'))
    if t >= start + 60 and (end is None or t <= end):
        vals.append(one)
if vals:
    print(f"rule-1 samples {len(vals)} mean {sum(vals)/len(vals):.2f} min {min(vals):.2f} max {max(vals):.2f} window {start+60}..{end} ({(end or 0)-start} s run)")
else:
    print("no samples in window")
