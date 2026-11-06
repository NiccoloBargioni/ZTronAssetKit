"""Wait until a branch gains a commit whose subject starts with PUT-BACK, or a workflow journal records more agent
results than `seen`; print what arrived and exit (ruling S3-R28 item 8, fail fast).

Usage: python3 watch_putback.py <worktree> <since-commit> <journal.jsonl> <seen>
"""
import json
import subprocess
import sys
import time

worktree, since, journal, seen = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])


def results():
    count = 0
    try:
        with open(journal) as f:
            for line in f:
                try:
                    if json.loads(line).get('type') == 'result':
                        count += 1
                except ValueError:
                    continue
    except FileNotFoundError:
        pass
    return count


while True:
    log = subprocess.run(['git', '-C', worktree, 'log', '--format=%h %s', since + '..HEAD'],
                         capture_output=True, text=True).stdout
    hits = [line for line in log.splitlines() if line.split(' ', 1)[-1].startswith('PUT-BACK')]
    if hits:
        print('put-back:\n' + '\n'.join(hits))
        sys.exit(0)
    count = results()
    if count > seen:
        print('journal: %d results (was %d)' % (count, seen))
        sys.exit(0)
    time.sleep(60)
