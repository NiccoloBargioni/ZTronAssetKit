/// Identifies the `ZTronAssetSync` module at runtime (skeleton placeholder, replaced by the Stage 1 contracts).
public enum ZTronAssetSyncModule {
    /// The module's name, used by the skeleton smoke test to prove the target links.
    public static let name = "ZTronAssetSync"

    /// Returns the name when `flag` is set, else an empty string — gives the coverage gate a branch to see.
    public static func describe(_ flag: Bool) -> String {
        if flag {
            return self.name
        }
        return ""
    }
}
