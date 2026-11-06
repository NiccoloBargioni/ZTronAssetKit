import sys, subprocess, os, shutil
root = os.path.dirname(os.path.abspath(__file__))
pkg = os.path.join(root, 'pkg')
src = os.path.join(pkg, 'Sources/ZTronAssetTransport/Background/BackgroundSupport.swift')
orig = open(src).read()
M = {
 'MA-noloop': ('''        while let newest = self.priorities[name], newest != written {
            written = newest
            // REENTRANCY: D-9 (proposed, amended at Stage 3) — as above: `priorities[name]` is re-read after it.
            await self.driver.setPriority(taskIdentifier: task.taskIdentifier, written)
        }''', ''),
 'MB-noserial': ('''        guard self.priorityRequests[name] == request else {
            // A later request for the name began meanwhile (or the name's terminal was processed): it decides.
            return
        }''', ''),
 'MC-finished-keeps-priority': ('''            self.priorities[name] = nil
            self.priorityRequests[name] = nil
            self.processed.set(true, for: name)''', '''            self.priorityRequests[name] = nil
            self.processed.set(true, for: name)'''),
 'MD-end-keeps-controls': ('''            self.continuation.finish()
            self.controls.finish()''', '''            self.continuation.finish()'''),
 'ME-relay-replaces': ('''        self.handlers[identifier, default: []].append(completionHandler)''', '''        self.handlers[identifier] = [completionHandler]'''),
 'MF-relay-newest': ('''        guard let waiting = self.handlers[identifier], let oldest = waiting.first else {
            return
        }
        let rest = waiting.dropFirst()''', '''        guard let waiting = self.handlers[identifier], let oldest = waiting.last else {
            return
        }
        let rest = waiting.dropLast()'''),
 'MI-stale-takes-serial': ('''        if let token, self.waiters[name]?.token != token {
            return
        }
        self.lastPriorityRequest += 1
        let request = self.lastPriorityRequest
        self.priorityRequests[name] = request''', '''        self.lastPriorityRequest += 1
        let request = self.lastPriorityRequest
        self.priorityRequests[name] = request
        if let token, self.waiters[name]?.token != token {
            return
        }'''),
 'MG-concurrent-delivery': ('''                case .priority(let priority):
                    await coordinator.setPriority(priority, of: name, token: token)''', '''                case .priority(let priority):
                    Task { await coordinator.setPriority(priority, of: name, token: token) }'''),
 'MK-deinit-noop': ('''        // Controls already made are still delivered; the control task ends after them.
        self.controls.finish()''', '''        // mutant'''),
}
names = sys.argv[1:] or list(M)
env = dict(os.environ)
for n in names:
    a, b = M[n]
    assert orig.count(a) == 1, n
    open(src, 'w').write(orig.replace(a, b))
    try:
        log = os.path.join(root, f'mut-{n}.log')
        r = subprocess.run(['swift', 'build', '--build-tests', '--package-path', pkg, '--scratch-path', os.path.join(root, 'probe-build')], capture_output=True, text=True)
        if r.returncode != 0:
            print(n, 'BUILD FAILED', r.stdout[-1500:], r.stderr[-1500:]); continue
        r = subprocess.run(['swift', 'test', '--skip-build', '--package-path', pkg, '--scratch-path', os.path.join(root, 'probe-build'), '--filter', 'ZTronAssetTransportTests\\.(S3DC2CorrectProbeTests|BackgroundInterleavingTests|BackgroundControlTaskTests|BackgroundCoordinatorTests)'], capture_output=True, text=True, timeout=1500)
        out = r.stdout + r.stderr
        open(log, 'w').write(out)
        fails = [l for l in out.splitlines() if ('✘' in l and 'recorded an issue' in l) or 'PROBE-FAIL' in l]
        summary = [l for l in out.splitlines() if 'Test run with' in l]
        print(f'== {n}: exit {r.returncode}; {summary[-1] if summary else "no summary"}')
        for l in fails[:6]:
            print('   ', l[:420])
    except subprocess.TimeoutExpired:
        print(n, 'TIMEOUT')
    finally:
        open(src, 'w').write(orig)
