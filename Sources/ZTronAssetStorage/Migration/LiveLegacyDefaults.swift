import Foundation
import ZTronAssetModel

/// The live `LegacyDefaults` over `UserDefaults` (R-STO-11).
///
/// It stores only the suite name, because `UserDefaults` is not `Sendable` (store.md §10). Called only inside
/// units, never on the main thread. Tests never use it: writing real defaults would write outside this
/// repository (owner directive), so its bodies are deliberately untested (ARCHITECTURE §14; ADR-052).
public struct LiveLegacyDefaults: LegacyDefaults {
    /// The suite; `nil` means `.standard`.
    public let suiteName: String?

    /// Creates the live defaults for a suite.
    public init(suiteName: String?) {
        self.suiteName = suiteName
    }

    /// The stored string, if any.
    public func string(forKey key: String) -> String? {
        self.defaults.string(forKey: key)
    }

    /// Removes the key.
    public func removeValue(forKey key: String) {
        self.defaults.removeObject(forKey: key)
    }

    private var defaults: UserDefaults {
        self.suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }
}
