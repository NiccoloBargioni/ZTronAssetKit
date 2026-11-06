# Cycle 22 step 3's kills (S3-R27 item 1; MUT_EXTRA for .build-s3f/c22/tools/mut22s.py, MUT_SNAP the step's commit):
# a1's compound `if` (both flips of `replaced`, dropping `isProgress`) by T-A-1; publishAll's hand-off `if let` by T-A-2;
# `coalesced ? 1 : 0` by T-A-3 (both orders); c3's `allBound` forced true by T-ORDER (swept first).
SQ = E + 'SubscriberQueue.swift'
TA1 = 'terminalPublishReportsAMoveAndMovesToTheTail'
TA2 = 'publishAllMatchesOnePublishPerEvent'
TA3 = 'commitBatchReachesAWaitingAndAStalledSubscriber'
TORDER = 'commitAnnouncesItsBoundIDsInAscendingOrder'
M = [
 ('a1-replaced-false', SQ, '        return (nil, replaced)\n', '        return (nil, false)\n', TA1),
 ('a1-replaced-true', SQ, '        return (nil, replaced)\n', '        return (nil, true)\n', TA1),
 ('a1-no-isprogress', SQ, '        if slot.isProgress, var live = self.slots[slot], !self.finished,', '        if var live = self.slots[slot], !self.finished,', TA1),
 ('a3-no-handoff', SQ, """            if let continuation = published.handOff {
                handOff = (continuation, event)
            }""", '            _ = published.handOff', TA2),
 ('a3-coalesced-never', SQ, '            coalesced += published.coalesced ? 1 : 0', '            coalesced += published.coalesced ? 0 : 0', TA3),
 ('a3-coalesced-always', SQ, '            coalesced += published.coalesced ? 1 : 0', '            coalesced += published.coalesced ? 1 : 1', TA3),
 ('a3-coalesced-flipped', SQ, '            coalesced += published.coalesced ? 1 : 0', '            coalesced += published.coalesced ? 0 : 1', TA3),
 ('c3-allbound-true', JO, '            let allBound = locations.count == ascending.count', '            let allBound = true', TORDER),
]
