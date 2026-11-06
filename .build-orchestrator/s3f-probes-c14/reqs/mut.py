import sys, subprocess, os, json
R = sys.argv[1]
SRC = os.path.join(R, 'mutsrc')
E = os.path.join(SRC, 'Sources/ZTronAssetSync/Engine')
c13 = open(os.path.join(R, 'probes/c13-followedLane.txt')).read()
c14 = open(os.path.join(R, 'probes/c14-followedLane.txt')).read()
MUTANTS = [
  ('M1-stampBreakerRefusal', 'EngineDispatch.swift',
   'if let stamp = self.state.placeStamps[transfer], let until = OriginGate.inForce(self.state.worldHistory[stamp.view].throttle, at: stamp.at) {\n            return .block(.throttled(until: until))\n        }',
   'if let stamp = self.state.placeStamps[transfer] {\n            let view = self.state.worldHistory[stamp.view]\n            if let until = OriginGate.inForce(view.throttle, at: stamp.at) {\n                return .block(.throttled(until: until))\n            }\n            if case .reject(let cause, _)? = view.breaker?.admission(of: transfer, at: stamp.at) {\n                return .block(.circuitOpen(cause))\n            }\n        }',
   'barrierStartsAVisitsPlaceOnceTheBreakerCloses'),
  ('M7-purgeJoinsKept', 'EngineCommands.swift',
   '        self.withdrawPurgedJoins(isPurged)\n', '',
   'barrierPurgeWithdrawsAWaitingGroupJoin|barrierPurgeForgetsAWaitingHeal'),
  ('M8-stampWithoutSlot', 'EngineJobs.swift',
   'if let stamp = self.state.reading, stamp.freeSlots.admit(job.lane) {',
   'if let stamp = self.state.reading {',
   'barrierGatesAPlaceWithoutASlotOnTheLiveThrottle|barrierRefusesAUserPlaceInAReservedSlotOnItsThrottle'),
  ('M9-cycle13FollowedLane', 'EngineFailures.swift', c14, c13,
   'barrierDecidesA429OnTheLane'),
  ('M2-verdictVisitDropped', 'EngineFollow.swift',
   'if job.passedPublishing != .publishingAtApply, self.holdsIDListedElsewhere(job) {\n            _ = self.visit(transfer, at: nil)',
   'if job.passedPublishing != .publishingAtApply, self.holdsIDListedElsewhere(job) {\n            _ = 0',
   'barrierAnswersAPassedJobsFailureAfterItsVisit'),
]
only = sys.argv[2:] 
env = dict(os.environ)
for name, f, old, new, filt in MUTANTS:
    if only and name not in only:
        continue
    path = os.path.join(E, f)
    s = open(path).read()
    n = s.count(old)
    print(f'== {name}: {f} count={n}', flush=True)
    if n != 1:
        continue
    open(path, 'w').write(s.replace(old, new))
    try:
        b = subprocess.run(['swift', 'build', '--build-tests', '--scratch-path', os.path.join(R, 'mutbuild')], cwd=SRC, capture_output=True, text=True, env=env)
        open(os.path.join(R, f'mut-{name}-build.log'), 'w').write(b.stdout + b.stderr)
        print(f'   build exit {b.returncode}', flush=True)
        if b.returncode == 0:
            for i in (1, 2):
                t = subprocess.run(['swift', 'test', '--skip-build', '--scratch-path', os.path.join(R, 'mutbuild'), '--filter', filt], cwd=SRC, capture_output=True, text=True, env=env)
                log = t.stdout + t.stderr
                open(os.path.join(R, f'mut-{name}-run{i}.log'), 'w').write(log)
                lines = [l for l in log.split('\n') if ('recorded an issue' in l or 'Test run with' in l)]
                print(f'   run {i} exit {t.returncode}', flush=True)
                for l in lines[:8]:
                    print('     ' + l[:230], flush=True)
    finally:
        open(path, 'w').write(s)
d = subprocess.run(['diff', '-r', os.path.join(SRC, 'Sources'), os.path.join(R, '..', 'Sources')], capture_output=True, text=True)
print('revert diff:', 'none' if d.returncode == 0 else d.stdout[:500])
