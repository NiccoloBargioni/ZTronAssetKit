# Item B's, B8's and variant Y's mutants (MUT_EXTRA for mut21s.py): replaces M.
PR = E + 'EnginePresence.swift'
IDX = 'EngineIDTokensTests'
ORACLE = 'invariantsReportAMisindexedJob'
T2 = 'barrierReroutesAMovesInterestsByToken'
T3 = 'barrierReroutesEveryHolderOfAMovedID'
T4 = 'barrierTakesABoundedMovesUnheldIDsOffTheHolder'
T6 = 'barrierBoundsOneIDMovesOffAHolderPerTurn|barrierBoundsAnOwedMovesTurnAcrossHolders'
Q1 = 'barrierKeepsARestsIDWhileAJoinedInterestHoldsIt|barrierMovesARejoinedIDOffItsFailedHolder|barrierAnswersARestsIDOnItsPublishingHolderAsVisitedFirst'
VY = 'barrierAnswersARestsIDOnItsPublishingHolderAsVisitedFirst'
M = [
 ('nb1-add-first', ST, '        if token != self.first {\n            self.others.insert(token)\n        }', '        self.others.insert(token)', IDX),
 ('nb2-remove-other', ST, '        if token != self.first {\n            self.others.remove(token)\n            return true\n        }', '        if token != self.first {\n            return true\n        }', IDX),
 ('nb3-no-promote', ST, '        guard let next = self.others.popFirst() else {\n            return false\n        }\n        self.first = next\n        return true', '        return false', IDX + '|' + T3),
 ('nb3-skip-promotion', ST, '        self.first = next\n        return true', '        _ = next\n        return true', IDX + '|' + T3),
 ('nb4-keep-empty-entry', ST, '        if self.tokensByID[asset]?.remove(token) == false {\n            self.tokensByID[asset] = nil\n        }', '        _ = self.tokensByID[asset]?.remove(token)', IDX),
 ('nb5-insert-always', ST, '        if self.interests[token]?.assets.insert(asset).inserted == true {\n            self.index(asset, token)\n        }', '        self.interests[token]?.assets.insert(asset)\n        self.index(asset, token)', IDX),
 ('nb6-set-no-release', ST, '        for asset in old where !new.contains(asset) {\n            self.release(asset, token)\n        }', '', IDX),
 ('nb6-set-no-index', ST, '        for asset in new where !old.contains(asset) {\n            self.index(asset, token)\n        }', '', IDX),
 ('nb6b-remove-no-release', ST, '        guard self.interests[token]?.assets.remove(asset) != nil else {\n            return false\n        }\n        self.release(asset, token)\n        return true', '        guard self.interests[token]?.assets.remove(asset) != nil else {\n            return false\n        }\n        return true', IDX),
 ('nb6c-subtract-no-release', ST, '        for asset in assets where self.interests[token]?.assets.remove(asset) != nil {\n            self.release(asset, token)\n        }', '        for asset in assets {\n            self.interests[token]?.assets.remove(asset)\n        }', IDX),
 ('nb6d-setassets-no-release', ST, '        for asset in old where !assets.contains(asset) {\n            self.release(asset, token)\n        }', '', IDX),
 ('nb6e-setassets-no-index', ST, '        for asset in assets where !old.contains(asset) {\n            self.index(asset, token)\n        }', '', IDX),
 ('nb7-keep-no-release', ST, '            for asset in interest.assets {\n                self.release(asset, token)\n            }\n            self.interests[token] = nil', '            self.interests[token] = nil', IDX),
 ('nb8-clear-no-index', ST, '        self.interestCounts = InterestCounts()\n        self.tokensByID.removeAll()', '        self.interestCounts = InterestCounts()', IDX),
 ('nb9-no-reinsert', MV, '            if self.state.jobs[holder]?.tokensByID[asset] != nil {\n                self.state.jobs[holder]?.assets.insert(asset)\n            }', '', Q1),
 ('nb9b-one-slot-many-ids', MV, '            while let item = progress.first, item.asset == asset {', '            while let item = progress.first {', T6 + '|' + Q1),
 ('nb10-no-unheld-subtract', MV, '        if !read.built.unheld.isEmpty {\n            self.state.jobs[transfer]?.assets.subtract(read.built.unheld)\n        }', '', T4),
 ('nb10b-no-unheld-append', ST, '                unheld.append(asset)\n', '', T4),
 ('nb11-no-sort', ST, '        pairs.sort { ($0.token, $0.asset) < ($1.token, $1.asset) }\n', '', T2),
 ('nb11b-sort-by-asset', ST, '        pairs.sort { ($0.token, $0.asset) < ($1.token, $1.asset) }', '        pairs.sort { ($0.asset, $0.token) < ($1.asset, $1.token) }', T2),
 ('nb12-holdings-first-only', ST, """            holders.forEach { token in
                if let interest = self.interests[token] {
                    pairs.append((token, asset, JobInterest(lane: interest.lane, kind: interest.kind, assets: [])))
                }
            }""", """            if let interest = self.interests[holders.first] {
                pairs.append((holders.first, asset, JobInterest(lane: interest.lane, kind: interest.kind, assets: [])))
            }""", T3),
 ('nb12b-items-first-only', ST, '            holders.forEach { items.append(MoveItem(asset: asset, token: $0)) }', '            items.append(MoveItem(asset: asset, token: holders.first))', T3),
 ('nb13-drop-i1', CO, '            if misindexed > 0 || doubled > 0 {', '            if misindexed > 0 || doubled > 0, misindexed < 0 {', ORACLE),
 ('nb13-drop-i2', CO, '            if outside > 0 {', '            if outside > 0, outside < 0 {', ORACLE),
 ('nb13-drop-i3', CO, "            if let empty = job.interests.filter({ $0.value.assets.isEmpty }).keys.min() {", "            if let empty = job.interests.filter({ $0.value.assets.isEmpty }).keys.min(), empty.rawValue == UInt64.max {", ORACLE),
 ('t6-no-budget-spend', FO, '                budget.ids -= made.spent\n', '', T6),
 ('vy-no-pass', MV, '                if let rerouting, !rerouting.contains(asset) {', '                if let rerouting, !rerouting.contains(asset), rerouting.isEmpty, !rerouting.isEmpty {', VY),
 ('vy-owed-moves-too', MV, '        let rerouting = listing == nil ? self.state', '        let rerouting = true ? self.state', T6 + '|' + Q1),
 ('vy-not-committing', MV, 'job.state == .verifying || job.state == .committing ? self.rerouteOnVisit(job) : nil', 'job.state == .verifying ? self.rerouteOnVisit(job) : nil', VY),
 ('b11-always-subtract', PR, '            if row.whole {', '            if row.whole, !row.whole {', FULL),
 ('b9-no-unfollowed', FO, '            if !passed.isEmpty {\n                self.state.unfollowed.insert(transfer)\n            }\n            moved.subtract(passed)\n        }\n        return (moved, reroute)', '            moved.subtract(passed)\n        }\n        return (moved, reroute)', FULL),
 ('b6-no-supersede', FO, '        if let superseded {', '        if let superseded, !superseded.downloading, superseded.downloading {', FULL),
]
