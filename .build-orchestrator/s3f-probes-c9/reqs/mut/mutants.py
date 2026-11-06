# name: (file, old, new, test-filter regex)
E = "Sources/ZTronAssetSync/Engine/"
M = {
 "sweepNoBarrier": (E+"EngineJobs.swift", "        if self.followBarrier {\n            self.advanceFollowForSpaceSweep()", "        if false && self.followBarrier {\n            self.advanceFollowForSpaceSweep()",
   "sweepJudgesADroppedHolderAtItsFollowedPlace|spaceSweepJudgesAJobRaisedFromAHolderInFlightAtItsUserPlace|barrierSweepsWithoutTheBytesTheOwedVisitAbandons|barrierSweepsARequestMadeDuringTheOwedFollow"),
 "pumpOwedOnly": (E+"EngineDispatch.swift", "if self.followBarrier || self.state.drainingAfterFollow {", "if self.followOwed {", "barrierAdmitsNothingBetweenDrainTurns"),
 "pumpNoBarrier": (E+"EngineDispatch.swift", "if self.followBarrier || self.state.drainingAfterFollow {", "if false && (self.followBarrier || self.state.drainingAfterFollow) {",
   "barrierGivesAFreedSlotToTheJobTheOwedVisitPromotes|barrierGivesTheOnlySlotToTheJobTheOwedVisitPromotes|barrierGivesAFreedSlotToTheJobTheOwedVisitCreates|barrierGivesAFreedSlotToTheUserWorkBehindAnEndedHead|barrierGatesARequestOnTheRoomTheOwedVisitFrees"),
 "dropFront": (E+"EngineFollow.swift", "self.enqueue(transfer, front: front, askedBefore: true)", "self.enqueue(transfer, front: false, askedBefore: true)", "barrierKeepsAPausedTransfersFrontPlace"),
 "dropAskedBefore": (E+"EngineFollow.swift", "self.enqueue(transfer, front: front, askedBefore: true)", "self.enqueue(transfer, front: front, askedBefore: false)", "barrierKeepsAPausedTransfersFrontPlace"),
 "resortOwed": (E+"EngineFollow.swift", "self.state.followOrder = Array(owed) + self.state.unfollowed.subtracting(owedSet).sorted()", "self.state.followOrder = self.state.unfollowed.sorted(); _ = owedSet", "barrierKeepsTheOwedVisitsOrderAcrossASecondFollow"),
 "visitForward": (E+"EngineFollow.swift", "        guard self.defersToFollow, let job = self.state.jobs[transfer], self.holdsMovedID(job) else {\n            return false\n        }\n", "        guard self.defersToFollow, let job = self.state.jobs[transfer], self.holdsMovedID(job) else {\n            return false\n        }\n        if job.epoch >= 0 { _ = self.visit(transfer); return self.state.jobs[transfer]?.epoch != job.epoch }\n",
   "barrierReroutesAFailedHoldersInterestInTheFollowsOrder|barrierCreatesAFailedHoldersNewContentInTheFollowsOrder"),
 "joinNoDefer": (E+"EngineJobs.swift", "if self.defersToFollow, job.state == .blocked(.insufficientSpace) {", "if self.defersToFollow, job.state == .blocked(.insufficientSpace), job.epoch == UInt64.max {", "barrierRechecksAJoinOnTheRoomTheOwedVisitFrees"),
 "enospcNoDefer": (E+"EngineFailures.swift", "        if self.defersToFollow {\n            // The verdict reads", "        if self.defersToFollow, epoch == UInt64.max {\n            // The verdict reads", "barrierDecidesAnENOSPCOnTheFollowedState"),
 "enqueueNoDefer": (E+"EngineJobs.swift", "        if self.defersToFollow {\n            self.state.jobs[transfer] = job\n", "        if self.defersToFollow, transfer.description.isEmpty {\n            self.state.jobs[transfer] = job\n", "barrierQueuesARequestAfterTheJobTheOwedVisitCreates"),
}
