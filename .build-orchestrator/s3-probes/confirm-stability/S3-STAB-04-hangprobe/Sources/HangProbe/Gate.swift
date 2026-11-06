/// A gate whose waiter is never resumed: the shape of a lost resume in a product wait.
public actor LostResume {
    public init() {}
    private var parked: [CheckedContinuation<Void, Never>] = []
    public func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.parked.append(continuation)
        }
    }
}
