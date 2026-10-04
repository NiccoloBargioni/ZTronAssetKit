import Foundation
import Testing
import ZTronAssetModel

extension ModelSuites {
    /// R-MAN-4 over the shipped series and seeded manifests: every identifier classified exactly once, applying the
    /// diff reproduces the newer manifest, and a manifest diffs against itself as all unchanged.
    @Suite("Manifest diff")
    struct ManifestDiffTests {
        @Test("R-MAN-4: every shipped transition of both tiers classifies exactly as expectations.json lists")
        func shippedTransitionsClassify() throws {
            let expectations = try ManifestFixtures.expectations()
            var checked = 0
            for tierName in ManifestFixtures.tiers {
                let tier = try #require(expectations.tiers[tierName])
                for (name, transition) in (tier.transitions.merging(tier.extraTransitions) { first, _ in first }).sorted(by: { $0.key < $1.key }) {
                    let old = try ManifestFixtures.decode(transition.fromFile)
                    let new = try ManifestFixtures.decode(transition.toFile)
                    let diff = ManifestDiff.compute(from: old, to: new)
                    let label = "\(tierName) \(name)"
                    #expect(diff.added.sortedRaw == transition.added, "\(label)")
                    #expect(diff.removed.sortedRaw == transition.removed, "\(label)")
                    #expect(diff.contentChanged.sortedRaw == transition.contentChanged, "\(label)")
                    #expect(diff.metadataChanged.sortedRaw == transition.metadataChanged, "\(label)")
                    #expect(diff.unchanged.sortedRaw == transition.unchanged, "\(label)")
                    #expect(diff.applied(to: old) == new.entries, "\(label)")
                    checked += 1
                }
            }
            #expect(checked == 10)
        }

        @Test("R-MAN-4: seeded manifests diff against themselves as all unchanged")
        func selfDiffIsAllUnchanged() throws {
            let seed: UInt64 = 0x00D1_FF00_0004
            for round in 0..<200 {
                var random = SplitMix64(seed: KeyedRandom.next64(seed: seed, key: 4, counter: UInt64(round)))
                let manifest = try Self.randomManifest(count: Int(random.next() % 120), random: &random)
                let diff = ManifestDiff.compute(from: manifest, to: manifest)
                let label = "seed \(seed) round \(round)"
                #expect(diff.isEmpty, "\(label)")
                #expect(diff.unchanged == manifest.entries.map(\.identifier), "\(label)")
                #expect(diff.added.isEmpty && diff.removed.isEmpty && diff.contentChanged.isEmpty && diff.metadataChanged.isEmpty, "\(label)")
                #expect(diff.upserts.isEmpty, "\(label)")
                #expect(diff.applied(to: manifest) == manifest.entries, "\(label)")
                #expect(manifest.entries.allSatisfy { diff.change(of: $0.identifier) == .unchanged }, "\(label)")
            }
        }

        @Test("R-MAN-4: seeded manifest pairs partition every identifier and apply back to the newer manifest")
        func seededPairsPartitionAndApply() throws {
            let seed: UInt64 = 0x00D1_FF00_0044
            for round in 0..<300 {
                var random = SplitMix64(seed: KeyedRandom.next64(seed: seed, key: 44, counter: UInt64(round)))
                let old = try Self.randomManifest(count: Int(random.next() % 80), random: &random)
                let new = try Self.mutate(old, random: &random)
                let diff = ManifestDiff.compute(from: old, to: new)
                let label = "seed \(seed) round \(round)"

                let classes = diff.added + diff.removed + diff.contentChanged + diff.metadataChanged + diff.unchanged
                #expect(Set(classes).count == classes.count, "\(label): an identifier is classified twice")
                #expect(Set(classes) == Set(old.entries.map(\.identifier) + new.entries.map(\.identifier)), "\(label)")
                #expect(diff.applied(to: old) == new.entries, "\(label)")
                #expect(diff.targetOrder == new.entries.map(\.identifier), "\(label)")
                // Each class means what R-MAN-4 says.
                for id in diff.contentChanged {
                    #expect(old.entry(for: id)?.contentIdentity != new.entry(for: id)?.contentIdentity, "\(label)")
                }
                for id in diff.metadataChanged {
                    let before = try #require(old.entry(for: id))
                    let after = try #require(new.entry(for: id))
                    #expect(before.contentIdentity == after.contentIdentity && before != after, "\(label)")
                }
                for id in diff.unchanged {
                    #expect(old.entry(for: id) == new.entry(for: id), "\(label)")
                }
                #expect(diff.added.allSatisfy { !old.contains($0) && new.contains($0) }, "\(label)")
                #expect(diff.removed.allSatisfy { old.contains($0) && !new.contains($0) }, "\(label)")
                // Order alone is not a change: the diff is empty exactly when the same entries remain.
                #expect(diff.isEmpty == (Set(old.entries) == Set(new.entries)), "\(label)")
            }
        }

        @Test("R-MAN-4: a diff that does not belong to the older manifest cannot be applied, and change(of:) knows only its identifiers")
        func foreignDiffIsRejected() throws {
            var random = SplitMix64(seed: 41)
            let a = try Self.randomManifest(count: 5, random: &random)
            let b = try Self.randomManifest(count: 5, random: &random)
            let diff = ManifestDiff.compute(from: a, to: a)
            #expect(diff.applied(to: b) == nil)
            #expect(diff.change(of: "not.in.either") == nil)
            let removal = ManifestDiff.compute(from: a, to: .empty())
            #expect(removal.removed == a.entries.map(\.identifier))
            #expect(a.entries.allSatisfy { removal.change(of: $0.identifier) == .removed })
            let addition = ManifestDiff.compute(from: .empty(), to: a)
            #expect(a.entries.allSatisfy { addition.change(of: $0.identifier) == .added })
            #expect(ManifestChange.allCases.count == 5)
        }

        // MARK: - Generators

        /// A manifest of `count` random entries: checksummed or not, with random directories, names, tags and policy.
        static func randomManifest(count: Int, random: inout SplitMix64) throws -> ValidatedManifest {
            let entries = (0..<count).map { index in Self.randomEntry(id: "asset.\(index).\(random.next() % 1_000)", random: &random) }
            return try ValidatedManifest(entries: entries, digest: ContentHash.sha256(of: Data(entries.map(\.identifier.rawValue).joined().utf8)))
        }

        private static func randomEntry(id: String, random: inout SplitMix64) -> ManifestEntry {
            let hasChecksum = random.next() % 4 != 0
            let content = random.next() % 6
            let policies = AssetPolicy.allCases
            return ManifestEntry(
                identifier: AssetID(id),
                fileExtension: ["png", "heic", "mp4"][Int(random.next() % 3)],
                remotePath: "media/\(content)/\(id).bin",
                localPathComponents: (0..<Int(random.next() % 3)).map { "dir\($0)\(random.next() % 2)" },
                localFileName: random.next() % 2 == 0 ? nil : "name\(random.next() % 3)",
                byteSize: random.next() % 3 == 0 ? nil : Int64(random.next() % 10_000),
                checksum: hasChecksum ? ContentHash.sha256(of: Data("\(content)".utf8)) : nil,
                tags: (0..<Int(random.next() % 3)).map { _ in "tag\(random.next() % 4)" },
                policy: policies[Int(random.next() % UInt64(policies.count))]
            )
        }

        /// `old` with random removals, additions, content and metadata changes, and a shuffled order.
        private static func mutate(_ old: ValidatedManifest, random: inout SplitMix64) throws -> ValidatedManifest {
            var entries: [ManifestEntry] = []
            for entry in old.entries {
                var copy = entry
                switch random.next() % 7 {
                case 0:
                    continue
                case 1:
                    copy.checksum = ContentHash.sha256(of: Data("changed \(random.next())".utf8))
                case 2:
                    copy.remotePath += ".moved"
                case 3:
                    copy.localPathComponents.append("extra")
                case 4:
                    copy.tags = copy.tags.isEmpty ? ["new"] : []
                case 5:
                    copy.byteSize = (copy.byteSize ?? 0) + 1
                default:
                    break
                }
                entries.append(copy)
            }
            for index in 0..<Int(random.next() % 5) {
                entries.append(Self.randomEntry(id: "added.\(index).\(random.next())", random: &random))
            }
            for index in entries.indices.reversed() where index > 0 {
                entries.swapAt(index, Int(random.next() % UInt64(index + 1)))
            }
            return try ValidatedManifest(entries: entries, digest: ContentHash.sha256(of: Data([UInt8(entries.count & 0xFF)])))
        }
    }
}
