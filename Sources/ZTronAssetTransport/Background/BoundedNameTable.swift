import ZTronAssetModel

/// A table keyed by staging name that keeps at most `capacity` entries, dropping the oldest first, so the background
/// coordinator's memory stays bounded however long the process lives (transport-2 T2-17): unclaimed outcomes, the
/// resume data of pauses, and the names whose terminal event was already processed.
///
/// Small by construction (a few times `BackgroundTransferOptions.maxTasks`), so the linear removals cost nothing.
struct BoundedNameTable<Value: Sendable>: Sendable {
    /// The most entries kept.
    let capacity: Int
    private var values: [StagingFileName: Value] = [:]
    private var order: [StagingFileName] = []

    /// An empty table keeping at most `capacity` (at least 1) entries.
    init(capacity: Int) {
        self.capacity = max(capacity, 1)
    }

    /// The value stored for `name`.
    subscript(name: StagingFileName) -> Value? {
        self.values[name]
    }

    /// Whether `name` is stored.
    func contains(_ name: StagingFileName) -> Bool {
        self.values[name] != nil
    }

    /// The oldest stored name matching `predicate`.
    func first(where predicate: (StagingFileName) -> Bool) -> StagingFileName? {
        self.order.first(where: predicate)
    }

    /// Stores `value` for `name` (a new name is the newest entry), then drops the oldest entries past `capacity`.
    mutating func set(_ value: Value, for name: StagingFileName) {
        if self.values.updateValue(value, forKey: name) == nil {
            self.order.append(name)
        }
        while self.order.count > self.capacity {
            self.values.removeValue(forKey: self.order.removeFirst())
        }
    }

    /// Removes and returns the value stored for `name`.
    @discardableResult
    mutating func remove(_ name: StagingFileName) -> Value? {
        guard let value = self.values.removeValue(forKey: name) else {
            return nil
        }
        if let index = self.order.firstIndex(of: name) {
            self.order.remove(at: index)
        }
        return value
    }

    /// Removes every entry and returns them, oldest first.
    mutating func removeAll() -> [(name: StagingFileName, value: Value)] {
        let entries = self.order.compactMap { name in self.values[name].map { (name: name, value: $0) } }
        self.values = [:]
        self.order = []
        return entries
    }
}
