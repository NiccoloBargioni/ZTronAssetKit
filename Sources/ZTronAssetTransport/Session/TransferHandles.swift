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
    private let staging: any StagingSink
    private let partial: StagingFileName

    init(job: TransferJob, updates: AsyncStream<TransferUpdate>, task: URLSessionDataTask, staging: any StagingSink) {
        self.id = job.id
        self.attempt = job.attempt
        self.updates = updates
        self.task = task
        self.staging = staging
        self.partial = job.partialName
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

    /// Stops the task and discards its partial (the Model's `cancel`); it ends with `cancelled(.byClient)`. The
    /// `discard` mark comes first, so no chunk is appended any more and whatever ends the task reports the client's
    /// cancellation; the partial is discarded before the task is cancelled, so the terminal element follows the
    /// discard. After the terminal element the task is completed and nothing happens: a staged file is the engine's.
    func cancel() {
        guard self.task.state != .completed else {
            return
        }
        TaskMarker.requestDiscard(on: self.task)
        Task { [task, staging, partial] in
            await staging.discard(partial)
            task.cancel()
        }
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
