import Foundation
import ZTronAssetModel

/// One interest of a holder in one id it moves (`MoveProgress`), ordered by id and then token.
struct MoveItem: Comparable {
    /// The id.
    let asset: AssetID
    /// The interest's token.
    let token: InterestToken

    static func < (lhs: MoveItem, rhs: MoveItem) -> Bool {
        (lhs.asset, lhs.token) < (rhs.asset, rhs.token)
    }
}

/// The moves left of one visit, or of one owed move, that carries more ids than a turn moves (C2; Stage 3 close-out
/// cycle 19, ruling S3-R22 item 1): its holder's interests in the ids it moves, taken by id and then token over the
/// follow's turns (`SyncEngine.continueMove`). They wait in a binary heap, so a turn takes its next ones in that order
/// without the whole set sorted up front: a sort of 10,000 is milliseconds, the heap's first pass a fraction of one.
struct MoveProgress {
    /// The interests left, a min-heap.
    private(set) var heap: [MoveItem]
    /// Whether every id leaves a job that is not publishing: as `SyncEngine.move` supersedes it, its running attempt was
    /// abandoned at the first turn, and the job is removed once its last interest leaves (`SyncEngine.startMove`).
    let supersedes: Bool
    /// The holder's lane when the move began: a superseded holder an id rejoined meanwhile is re-laned from it at the
    /// end.
    let lane: AssetPriority

    init(_ items: [MoveItem], supersedes: Bool, lane: AssetPriority) {
        self.heap = items
        self.supersedes = supersedes
        self.lane = lane
        var index = items.count / 2
        while index > 0 {
            index -= 1
            self.siftDown(from: index)
        }
    }

    /// Whether every interest has been moved.
    var isDone: Bool {
        self.heap.isEmpty
    }

    /// The next interest, without taking it.
    var first: MoveItem? {
        self.heap.first
    }

    /// Takes the next interest.
    mutating func popFirst() -> MoveItem? {
        guard let first = self.heap.first else {
            return nil
        }
        let last = self.heap.removeLast()
        if !self.heap.isEmpty {
            self.heap[0] = last
            self.siftDown(from: 0)
        }
        return first
    }

    /// Drops every interest left: the holder is gone.
    mutating func removeAll() {
        self.heap.removeAll()
    }

    private mutating func siftDown(from start: Int) {
        var parent = start
        let count = self.heap.count
        while true {
            let left = 2 * parent + 1
            guard left < count else {
                return
            }
            var child = left
            if left + 1 < count, self.heap[left + 1] < self.heap[left] {
                child = left + 1
            }
            guard self.heap[child] < self.heap[parent] else {
                return
            }
            self.heap.swapAt(child, parent)
            parent = child
        }
    }
}

/// The rest of a visit that moves more ids than a turn moves (`EngineState.followMoving`).
struct VisitRemainder {
    /// The job the visit moves ids off.
    let holder: TransferID
    /// Its moves left.
    var moves: MoveProgress
    /// The decision instant the visit read under (`SyncEngine.withReading`): its apply's (`followStamps`), or the
    /// drain's for its visit after a verdict.
    let stamp: WorldStamp
    /// Whether it is the drain's visit after a verdict (`SyncEngine.followAfterVerdict`), whose joins are made as that
    /// visit makes them (`SyncEngine.joinWaitsForVerdict`).
    let afterVerdict: Bool
    /// Whether the visit passed the job (`SyncEngine.rerouteOnVisit`): it spends the job's re-route set once its last id
    /// moved, so a publication or a verdict that meets the job meanwhile still reads the ids it moves
    /// (`recordDeferredVerdict`, `findInbound`, `followedLane`).
    let spends: Bool
}

/// What a follow turn may still do (`SyncEngine.continueFollow`): visits and owed moves together, at most
/// `followsPerTurn`, and the ids they move together, at most `followIDsPerTurn` (C2).
struct FollowBudget {
    /// The visits and holders' moves left.
    var holders: Int
    /// The ids left.
    var ids: Int
}

/// Moves too large for one turn, continued over the follow's turns (C2; Stage 3 close-out cycle 19, ruling S3-R22 item 1).
extension SyncEngine {
    /// The ids a follow turn moves at most, the visits, owed moves and a visit's rest together (`followIDsPerTurn` in
    /// `EngineState` is the seam); an attempt's end or an apply moves half of them in its own turn (`inboundIDsNow`). A
    /// moved id costs a re-route and a join, about 5 µs in release, so 512 hold a turn near 3 ms. One visit that moved
    /// the 10,000 ids of a prefetch group sharing one content held the actor 54 to 56 ms (the cycle-18 verifiers'
    /// VERIFY-C18R-SHARED-CONVERGENCE, -SHARED-DIVERGENCE and -DIVERGENCE; `BenchSync.sharedApplyTurns`,
    /// `BenchSync.divergenceTurns`, `BenchSync.inboundHolderTurns`). A visit of one id each counts one, so the 256 visits
    /// of a turn of `followsPerTurn` fit.
    static let followIDsPerTurn = 512

    /// The ids `makeInboundNow` moves in an attempt's end or an apply's turn, which also walks every job
    /// (`findInbound`): half a follow turn's.
    var inboundIDsNow: Int {
        max(1, self.state.followIDsPerTurn / 2)
    }

    /// Moves `moved`, ids of `job` the copy maps elsewhere, as `move` does, within `budget` ids: all of them at once when
    /// they fit, else `budget` of the job's interests in them, by id and token, and returns the rest for the follow's next
    /// turns (`continueMove`). A job whose every id leaves and that is not publishing is superseded as `move` supersedes
    /// it: its running attempt is abandoned now, as a visit-first engine's visit abandoned it (no 429, failure or bytes of
    /// it can arrive in the follow's later turns), and the job waits queued, behind the barrier, until its last interest
    /// leaves and it is removed. Returns whether an id moved, the ids spent and the moves left.
    func startMove(_ moved: Set<AssetID>, of job: Job, listing: ValidatedManifest?, budget: Int) -> (moved: Bool, spent: Int, rest: MoveProgress?) {
        guard moved.count > budget else {
            return (self.move(moved, of: job, listing: listing), moved.count, nil)
        }
        let transfer = job.transfer
        let supersedes = moved.count == job.assets.count && job.state != .verifying && job.state != .committing
        if supersedes, job.state == .downloading {
            if let active = job.active {
                self.abandon(transfer, active)
            }
            // The transfer ends without a verdict: a half-open probe returns to `halfOpen(probe: nil)` (§7.7).
            self.recordBreaker(.abandoned(transfer))
            if self.transition(transfer, to: .queued) {
                self.enqueue(transfer)
            }
        }
        var items: [MoveItem] = []
        items.reserveCapacity(moved.count)
        for (token, interest) in job.interests {
            for asset in interest.assets where moved.contains(asset) {
                items.append(MoveItem(asset: asset, token: token))
            }
        }
        var progress = MoveProgress(items, supersedes: supersedes, lane: job.lane)
        let made = self.continueMove(&progress, of: transfer, listing: listing, budget: budget)
        return (made.moved, made.spent, progress.isDone ? nil : progress)
    }

    /// Continues `progress`, the moves left off `holder`'s job, within `budget` ids; returns whether an id moved and the
    /// ids spent. An id is taken whole, all of its interests in one turn, so it leaves the job in one turn or stays: it
    /// leaves the job's ids (`Job.assets`) at its first interest, as `move` subtracts them before it re-routes, and each
    /// interest is re-routed as `move` re-routes it (`reroute`, under `listing`; a visit's under the copy as it stands at
    /// the turn) unless it left the job meanwhile. An id that an apply made since maps to the job's content again rejoins
    /// the job through `reroute`, as that apply's visit on a visit-first engine moved it back: behind the job's exit
    /// verdict when that waits (`addInterest`), since that visit met the job as the verdict left it. An interest left
    /// with no id is removed (`removeInterest`), or, of a job being superseded, dropped without a re-lane: that job is
    /// removed once none is left, as `supersede` removes it, or, an id having rejoined it, is re-laned once. A job
    /// removed meanwhile ends the moves: an owed move took its last ids onto a job whose attempt ended
    /// (`continueInbound`, which runs first), and re-routed them.
    func continueMove(_ progress: inout MoveProgress, of holder: TransferID, listing: ValidatedManifest?, budget: Int) -> (moved: Bool, spent: Int) {
        guard self.state.jobs[holder] != nil else {
            progress.removeAll()
            return (false, 0)
        }
        var spent = 0
        var moved = false
        var current: AssetID?
        while let item = progress.first {
            let asset = item.asset
            if asset != current {
                guard spent < budget else {
                    break
                }
                spent += 1
                current = asset
                self.state.jobs[holder]?.assets.remove(asset)
            }
            _ = progress.popFirst()
            // The interest is read for its lane and kind, all `reroute` reads, and its id is removed in the table. A copy
            // of the interest held across the removal shares its ids' storage, so the removal copied them whole, once per
            // id moved: a turn of 512 off one interest of 10,000 ids held the actor about 20 ms (the cycle-19 gate run's
            // `BenchSync.sharedApplyTurns`, `divergenceTurns` and `inboundHolderTurns`).
            guard let interest = self.state.jobs[holder]?.interests[item.token].map({ JobInterest(lane: $0.lane, kind: $0.kind, assets: []) }) else {
                continue
            }
            guard self.state.jobs[holder]?.removeAsset(asset, for: item.token) == true else {
                continue
            }
            self.reroute(item.token, interest: interest, asset: asset, from: holder, listing: listing)
            moved = true
            if self.state.jobs[holder]?.interests[item.token]?.assets.isEmpty == true {
                if progress.supersedes {
                    self.state.jobs[holder]?.setInterest(nil, for: item.token)
                } else {
                    self.removeInterest(item.token, from: holder)
                }
            }
        }
        if progress.isDone, progress.supersedes, self.state.jobs[holder] != nil {
            if self.state.jobs[holder]?.interests.isEmpty == true {
                self.removeJob(holder)
            } else {
                self.relane(holder, from: progress.lane)
            }
        }
        return (moved, spent)
    }
}
