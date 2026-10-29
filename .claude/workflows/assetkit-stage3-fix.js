export const meta = {
  name: 'assetkit-stage3-fix',
  description: 'ZTronAssetKit Stage 3 fixes: one close-out (fix, then two-lens independent verification, until 0 blocking) per affected work package, at most two at once on separate simulator sets, under a weekly-usage stop',
  phases: [
    { title: 'Fix', detail: 'one fixer per close-out cycle, in the work package worktree' },
    { title: 'Verify', detail: 'requirements/tests and correctness/concurrency verifiers per cycle' },
  ],
}

// args:
//   base: 's3-base'
//   usageStop: 65
//   bar: 'strict'
//   maxCycle: 6                    per close-out; a work package still blocking after it stops and is reported
//   simSlots: [{fix, reqs, correct}, ...]   one simulator set per concurrent close-out (never the owner's iPhone 17)
//   wps: [{wp, name, target, testTarget, sections, coverageMin, rulingsFile, findingsFile, focus, fromCycle?, verifyFirst?}]
// Each close-out is .claude/workflows/assetkit-closeout.js run inline (worktree .worktrees/<wp>, branch wp/<wp>).
const A = args
const CLOSEOUT = { scriptPath: '/Users/admin/Documents/ZTronAssetKit/.claude/workflows/assetkit-closeout.js' }

// One simulator set per running close-out; a waiting close-out takes the next free set (FIFO).
const free = A.simSlots.map((_, i) => i)
const waiters = []
const acquire = () => new Promise(res => { if (free.length) res(free.shift()); else waiters.push(res) })
const release = (slot) => { const next = waiters.shift(); if (next) next(slot); else free.push(slot) }

const results = await Promise.all(A.wps.map(async (w) => {
  const slot = await acquire()
  log(w.wp + ': starting on simulator set ' + slot)
  try {
    const r = await workflow(CLOSEOUT, Object.assign({
      base: A.base, bar: A.bar || 'strict', maxCycle: A.maxCycle || 6, usageStop: A.usageStop,
      cleanScratch: true, sims: A.simSlots[slot],
    }, w))
    const last = r && r.cycles.length ? r.cycles[r.cycles.length - 1] : null
    const blocking = last && last.verify ? last.verify.issues.filter(i => i.blocking).length : null
    log(w.wp + ': ended after ' + (r ? r.cycles.length : 0) + ' cycle(s), last blocking ' + blocking + (r && r.stopped ? ', usage stop at ' + r.stopped.percent + '%' : ''))
    return { wp: w.wp, blocking, result: r }
  } catch (e) {
    log(w.wp + ': failed: ' + String(e))
    return { wp: w.wp, error: String(e) }
  } finally {
    release(slot)
  }
}))
return results
