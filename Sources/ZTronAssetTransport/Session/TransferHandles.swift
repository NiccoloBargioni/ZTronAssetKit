import Foundation
import ZTronAssetModel

/// The handle of one foreground data task (ADR-021): synchronous controls act on the task itself, which is
/// `Sendable`, so no lock and no control stream exist. A control after the terminal element finds a completed task
/// and changes nothing.
final class DataTransferHandle: TransferHandle {
    let id: TransferID
    let attempt: TransferAttempt
    let updates: AsyncStream<TransferUpdate>
    private let task: URLSessionDataTask

    init(job: TransferJob, updates: AsyncStream<TransferUpdate>, task: URLSessionDataTask) {
        self.id = job.id
        self.attempt = job.attempt
        self.updates = updates
        self.task = task
    }

    /// Changes `URLSessionTask.priority` in place (R-NET-10); the transfer is not restarted.
    func setPriority(_ priority: AssetPriority) {
        self.task.priority = priority.urlSessionTaskPriority
    }

    /// Marks the pause intent on the task, then cancels it; the delegate keeps the partial and its sidecar.
    func pause() {
        TaskMarker.requestIfUnmarked(.pause, on: self.task)
        self.task.cancel()
    }

    /// Cancels the task; it ends with `cancelled(.byClient)`.
    func cancel() {
        self.task.cancel()
    }
}

/// A handle whose stream already holds its terminal element: a request refused before any task existed (policy,
/// URL, shut-down session), or a background outcome delivered from the coordinator's buffer.
final class ImmediateTransferHandle: TransferHandle {
    let id: TransferID
    let attempt: TransferAttempt
    let updates: AsyncStream<TransferUpdate>

    init(id: TransferID, attempt: TransferAttempt, terminal: TransferUpdate) {
        self.id = id
        self.attempt = attempt
        let (updates, continuation) = AsyncStream.makeStream(of: TransferUpdate.self, bufferingPolicy: .bufferingNewest(1))
        continuation.yield(terminal)
        continuation.finish()
        self.updates = updates
    }

    /// Nothing runs: no effect.
    func setPriority(_ priority: AssetPriority) {}

    /// Nothing runs: no effect.
    func pause() {}

    /// Nothing runs: no effect.
    func cancel() {}
}
