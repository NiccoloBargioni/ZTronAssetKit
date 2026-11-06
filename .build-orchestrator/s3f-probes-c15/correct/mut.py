import sys, pathlib
root = pathlib.Path('/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/.build-verify-s3f-c15-correct/probe/Sources/ZTronAssetSync/Engine')
orig = pathlib.Path('/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/Sources/ZTronAssetSync/Engine')
M = {
  'targetIgnored': ('EngineFailures.swift',
      'guard let target, SyncEngine.sameTransfer(target, job.entry), self.stillWants(join) else {',
      'guard let _ = target, self.stillWants(join) else {'),
  'stillWantsIgnored': ('EngineFailures.swift',
      'guard let target, SyncEngine.sameTransfer(target, job.entry), self.stillWants(join) else {',
      'guard let target, SyncEngine.sameTransfer(target, job.entry) else {'),
}
cmd, name = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else None)
if cmd == 'apply':
    f, old, new = M[name]
    t = (root / f).read_text()
    assert t.count(old) == 1, (name, t.count(old))
    (root / f).write_text(t.replace(old, new))
    print('applied', name)
elif cmd == 'revert':
    for f in {m[0] for m in M.values()}:
        (root / f).write_text((orig / f).read_text())
    print('reverted')
