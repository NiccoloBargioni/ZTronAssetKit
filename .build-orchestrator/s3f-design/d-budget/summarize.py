import re, sys
# Summarize Swift Testing output: per test, pass/fail and failing arguments with first issue location.
for path in sys.argv[1:]:
    print("==", path)
    fails = {}
    for line in open(path, errors='replace'):
        line = line.rstrip()
        m = re.match(r'✘ Test "([^"]+)" recorded an issue with 1 argument (\S+ → \S+) at (\S+): (.*)', line)
        if m:
            fails.setdefault(m.group(1), []).append(f"{m.group(2)} @ {m.group(3)} {m.group(4)[:110]}")
            continue
        m = re.match(r'✘ Test "([^"]+)" recorded an issue at (\S+): (.*)', line)
        if m:
            fails.setdefault(m.group(1), []).append(f"@ {m.group(2)} {m.group(3)[:110]}")
            continue
        m = re.match(r'([✔✘]) Test "([^"]+)" (with \d+ test cases )?(passed|failed).*', line)
        if m:
            name = m.group(2)
            print(f"  {m.group(1)} {name[:90]}")
            for f in fails.get(name, []):
                print(f"      {f}")
        if 'Test run with' in line or 'error:' in line:
            print("  " + line[:200])
