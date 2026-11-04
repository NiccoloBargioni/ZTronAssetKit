import Foundation
import ZTronAssetModel

/// One interest of a holder in one id it moves (`MoveProgress`), ordered by id and then token. Hashable for the pairs a
/// batch of owed re-routes holds (`RerouteBatch`, read by `invariantViolations()`).
struct MoveItem: Comparable, Hashable, Sendable {
    /// The id.
    let asset: AssetID
    /// The interest's token.
    let token: InterestToken

    static func < (lhs: MoveItem, rhs: MoveItem) -> Bool {
        (lhs.asset, lhs.token) < (rhs.asset, rhs.token)
    }
}

/// A binary min-heap: a turn takes its next elements in order without the whole set sorted up front (a sort of 10,000
/// is milliseconds, the heap's first pass a fraction of one). A move's interests wait in one (`MoveProgress`), and so do
/// a batch of owed re-routes (`RerouteBatch`).
struct MinHeap<Element: Comparable & Sendable>: Sendable {
    /// The elements, in heap order.
    private(set) var elements: [Element]

    /// A heap of `elements`, built in place in O(n).
    init(_ elements: [Element]) {
        self.elements = elements
        self.heapify()
    }

    /// Whether no element is left.
    var isEmpty: Bool {
        self.elements.isEmpty
    }

    /// The elements left.
    var count: Int {
        self.elements.count
    }

    /// The least element, without taking it.
    var first: Element? {
        self.elements.first
    }

    /// Takes the least element.
    mutating func popFirst() -> Element? {
        guard let first = self.elements.first else {
            return nil
        }
        let last = self.elements.removeLast()
        if !self.elements.isEmpty {
            self.elements[0] = last
            self.siftDown(from: 0)
        }
        return first
    }

    /// Drops every element.
    mutating func removeAll() {
        self.elements.removeAll()
    }

    /// Takes out every element `shouldRemove` matches, in heap order, and keeps the rest a heap: one pass and, when it
    /// took any, one heapify, O(n) (a purge's withdrawals from an owed batch, `withdrawPurgedJoins`).
    mutating func removeAll(where shouldRemove: (Element) -> Bool) -> [Element] {
        var removed: [Element] = []
        self.elements.removeAll { element in
            guard shouldRemove(element) else {
                return false
            }
            removed.append(element)
            return true
        }
        if !removed.isEmpty {
            self.heapify()
        }
        return removed
    }

    private mutating func heapify() {
        var index = self.elements.count / 2
        while index > 0 {
            index -= 1
            self.siftDown(from: index)
        }
    }

    private mutating func siftDown(from start: Int) {
        var parent = start
        let count = self.elements.count
        while true {
            let left = 2 * parent + 1
            guard left < count else {
                return
            }
            var child = left
            if left + 1 < count, self.elements[left + 1] < self.elements[left] {
                child = left + 1
            }
            guard self.elements[child] < self.elements[parent] else {
                return
            }
            self.elements.swapAt(child, parent)
            parent = child
        }
    }
}

/// The moves left of one visit, or of one owed move, that carries more ids than a turn moves (C2; Stage 3 close-out
/// cycle 19, ruling S3-R22 item 1): its holder's interests in the ids it moves, taken by id and then token over the
/// follow's turns (`SyncEngine.continueMove`), from a heap (`MinHeap`).
struct MoveProgress {
    /// The interests left.
    private(set) var heap: MinHeap<MoveItem>
    /// Whether every id leaves a job that is not publishing: as `SyncEngine.move` supersedes it, its running attempt was
    /// abandoned at the first turn, and the job is removed once its last interest leaves (`SyncEngine.startMove`).
    let supersedes: Bool
    /// The holder's lane when the move began: a superseded holder an id rejoined meanwhile is re-laned from it at the
    /// end.
    let lane: AssetPriority

    init(_ items: [MoveItem], supersedes: Bool, lane: AssetPriority) {
        self.heap = MinHeap(items)
        self.supersedes = supersedes
        self.lane = lane
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
        self.heap.popFirst()
    }

    /// Drops every interest left: the holder is gone.
    mutating func removeAll() {
        self.heap.removeAll()
    }
}

/// One owed re-route (`RerouteBatch`): an interest's token in one id, with the lane and kind `reroute` reads of the
/// interest, ordered by id and then token as `MoveItem`. A token's interests carry its one lane and kind
/// (`invariantViolations()`), so the id and the token decide the rest, and the order is total over a batch's items.
struct RerouteItem: Comparable, Sendable {
    /// The id.
    let asset: AssetID
    /// The interest's token.
    let token: InterestToken
    /// The interest's lane.
    let lane: AssetPriority
    /// The interest's kind.
    let kind: InterestKind

    static func < (lhs: RerouteItem, rhs: RerouteItem) -> Bool {
        (lhs.asset, lhs.token) < (rhs.asset, rhs.token)
    }
}

/// The engine's copy one apply replaced while a batch of owed re-routes waited (`SyncEngine.adoptApplied`), and the
/// jobs then at an attempt's end, so the batch's ids follow the copy a visit-first engine's re-route at the owing
/// instant, and its visits at the applies since, followed (`SyncEngine.rerouteListing`).
struct RerouteLayer: Sendable {
    /// The copy the apply replaced.
    let outgoing: ValidatedManifest
    /// The applies followed before it (`EngineState.appliesFollowed`).
    let applies: UInt64
    /// The jobs at an attempt's end then, with their epochs: publishing, or failed with an exit verdict that waits behind
    /// the batch. A visit-first engine's interest that had joined one of them stayed there through the apply's visit,
    /// which passed the job, while the job is still at that end (`SyncEngine.waitingTarget`).
    let ends: [TransferID: UInt64]
}

/// Re-routes a site owes instead of making them in its own turn (C2; Stage 3 close-out cycle 21, ruling S3-R26 item
/// 1): its interests left their job at the owing instant, and the drain re-routes them at the batch's place in
/// `EngineState.eventsAfterFollow`, at most a drain turn's ids a turn, each id with all its tokens
/// (`SyncEngine.continueReroutes`).
struct RerouteBatch: Sendable {
    /// The job the interests left.
    let from: TransferID
    /// The engine's copy at the owing instant.
    let copy: ValidatedManifest
    /// `EngineState.copySerial` at the owing instant: the batch holds one layer for each copy adopted since
    /// (`invariantViolations()`).
    let serial: UInt64
    /// The re-routes left.
    var items: MinHeap<RerouteItem>
    /// The copies adopted since the owing instant, oldest first (`SyncEngine.adoptApplied`).
    var layers: [RerouteLayer]
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

    /// Moves `moved`, ids of `transfer`'s job the copy maps elsewhere, as `move` does, within `budget` ids: all of them at
    /// once when they fit, else `budget` of the job's interests in them, by id and token, and returns the rest for the
    /// follow's next turns (`continueMove`). A job whose every id leaves and that is not publishing is superseded as
    /// `move` supersedes it: its running attempt is abandoned now, as a visit-first engine's visit abandoned it (no 429,
    /// failure or bytes of it can arrive in the follow's later turns), and the job waits queued, behind the barrier, until
    /// its last interest leaves and it is removed. Returns whether an id moved, the ids spent and the moves left. Both
    /// callers pass a job the table holds in this turn (`follow`'s visit read it, `continueInbound` checks it), so the
    /// read has no branch of its own for a missing one: it would make no items, and `continueMove`'s guard, which a
    /// holder removed between a rest's turns reaches, would end the move having moved nothing (ruling S3-R19 item 3).
    ///
    /// The job is read once, before anything changes, and the items come from its index (`Job.moveItems`), so no copy of
    /// its ids or interests is alive across the moves (Stage 3 close-out cycle 21, ruling S3-R26 item 3). The moved ids no
    /// interest holds leave the job's ids at once, as `move` subtracts every moved id: no item takes them off, and the job
    /// kept, after its visit, ids the copy maps elsewhere (B-T4).
    func startMove(_ moved: Set<AssetID>, of transfer: TransferID, listing: ValidatedManifest?, budget: Int) -> (moved: Bool, spent: Int, rest: MoveProgress?) {
        guard moved.count > budget else {
            return (self.move(moved, of: transfer, listing: listing), moved.count, nil)
        }
        let read = self.state.jobs[transfer].map { job in
            (supersedes: moved.count == job.assets.count && job.state != .verifying && job.state != .committing, downloading: job.state == .downloading, active: job.active, lane: job.lane, built: job.moveItems(of: moved))
        }
        if let read, read.supersedes, read.downloading {
            if let active = read.active {
                self.abandon(transfer, active)
            }
            // The transfer ends without a verdict: a half-open probe returns to `halfOpen(probe: nil)` (§7.7).
            self.recordBreaker(.abandoned(transfer))
            if self.transition(transfer, to: .queued) {
                self.enqueue(transfer)
            }
        }
        if let unheld = read?.built.unheld, !unheld.isEmpty {
            self.state.jobs[transfer]?.assets.subtract(unheld)
        }
        var progress = MoveProgress(read?.built.items ?? [], supersedes: read?.supersedes == true, lane: read?.lane ?? .bulk)
        let made = self.continueMove(&progress, of: transfer, listing: listing, budget: budget)
        return (made.moved, made.spent, progress.isDone ? nil : progress)
    }

    /// Continues `progress`, the moves left off `holder`'s job, within `budget` ids; returns whether an id moved and the
    /// ids spent. An id is taken whole, all of its interests in one turn, so it leaves the job in one turn or stays: it
    /// leaves the job's ids (`Job.assets`) at its first interest, as `move` subtracts them before it re-routes, and comes
    /// back after its last one when an interest that joined meanwhile still holds it (the invariant check's I2), and each
    /// interest is re-routed as `move` re-routes it (`reroute`, under `listing`; a visit's under the copy as it stands at
    /// the turn) unless it left the job meanwhile, or, of a visit's rest whose holder began publishing meanwhile, its id
    /// is one the publication began with mapped to the job's content: such an interest is passed, as a visit passes it. An id that an apply made since maps to the job's content again rejoins
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
        // A visit's rest (no `listing`) whose holder publishes now passes the ids its publication began with, as the
        // visit of an apply that meets the job publishing passes them (`rerouteOnVisit`): a visit-first engine's visit at
        // the apply that mapped such an id back to this content had moved its interests onto the job before the
        // publication began, so a later apply's visit passed them and the publication's outcome answered them (Stage 3
        // close-out cycle 21, Q1's stage 3, variant Y). The ids the publication began with mapped elsewhere are
        // re-routed at their turn, as that visit re-routes them (`Job.rerouteOnPass`).
        let rerouting = listing == nil ? self.state.jobs[holder].flatMap { job in job.state == .verifying || job.state == .committing ? self.rerouteOnVisit(job) : nil } : nil
        var spent = 0
        var moved = false
        while let first = progress.first {
            let asset = first.asset
            guard spent < budget else {
                break
            }
            spent += 1
            self.state.jobs[holder]?.assets.remove(asset)
            while let item = progress.first, item.asset == asset {
                _ = progress.popFirst()
                if let rerouting, !rerouting.contains(asset) {
                    // Passed: the interest keeps the id, which comes back to the job's ids after its last item. The
                    // follow's own visit of the job passes it too, and leaves the job for the next follow (`unfollowed`).
                    continue
                }
                // The interest is read for its lane and kind, all `reroute` reads, and its id is removed in the table. A
                // copy of the interest held across the removal shares its ids' storage, so the removal copied them whole,
                // once per id moved: a turn of 512 off one interest of 10,000 ids held the actor about 20 ms (the
                // cycle-19 gate run's `BenchSync.sharedApplyTurns`, `divergenceTurns` and `inboundHolderTurns`).
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
            // An interest that joined the holder in the id after the rest's items were fixed (an owed move's join, made at
            // once) still holds it: the id stays in the job's ids, as a visit-first engine's join re-inserted it, so its
            // publication binds it and a later apply's visit moves it (Stage 3 close-out cycle 21, ruling S3-R26 item 7;
            // `analyse-state-cost.md` Q1, B-T5).
            if self.state.jobs[holder]?.tokensByID[asset] != nil {
                self.state.jobs[holder]?.assets.insert(asset)
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
