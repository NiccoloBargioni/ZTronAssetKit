import Foundation
import ZTronAssetModel

/// What a background download task carries in `taskDescription` (H-6, transport.md §4.3): the staging name it
/// writes, the manifest's decoded size, and whether the task was created from resume data, as
/// `ztak1 <staging name> <expected bytes | -> [resume]`.
///
/// A background task has no mailbox (S-2), and the OS persists `taskDescription` across relaunch, so this is the
/// only way a relaunched process learns which content an OS task is fetching, and whether its answers are those of
/// a continuation. It carries no secret and no manifest text (the staging name is hashes and numbers, ADR-013).
/// Parsing is strict: three fields, or four whose last is `resume`, at most 256 bytes, the `ztak1` version, a
/// `.part` staging name and a non-negative decimal size; anything else is foreign and decodes to `nil` (the
/// coordinator cancels such tasks at launch). A fresh download is written with three fields, exactly as before the
/// flag existed, so every tag an earlier build left with the OS still decodes, as a fresh download.
package struct BackgroundTaskTag: Sendable, Hashable {
    /// The staging file the download is moved to (kind `.partial`).
    package let name: StagingFileName
    /// The manifest's `byteSize`, when it has one (R-NET-7).
    package let expectedBytes: Int64?
    /// Whether the OS task was created from resume data (`downloadTask(withResumeData:)`), which the driver records
    /// without deciding anything (it was handed the data). Its answers are then those of a ranged request: a 206
    /// with a `Content-Range` continues the data, while −1002, 416 and a 206 without a range mean the data was stale
    /// (ARCHITECTURE §6.3, §7.6). Kept on the task, so a process that re-attaches the task after a relaunch reads
    /// them the same way.
    package let createdFromResumeData: Bool

    /// The tag format's version prefix.
    static let version = "ztak1"
    /// The fourth field, present only on a task created from resume data.
    static let resumeField = "resume"
    /// The longest description that decodes.
    static let maxBytes = 256

    /// Creates a tag; a fresh download unless `createdFromResumeData`.
    package init(name: StagingFileName, expectedBytes: Int64?, createdFromResumeData: Bool = false) {
        self.name = name
        self.expectedBytes = expectedBytes
        self.createdFromResumeData = createdFromResumeData
    }

    /// The tag of a task a driver is about to start: a continuation exactly when the coordinator handed it resume
    /// data (the driver decides nothing, it records what it was given). The only place this mapping is written:
    /// `LiveBackgroundSessionDriver` and the tests' fake driver both call it, so the tests run the line the device
    /// runs and the coverage-excluded live file keeps no expression of its own (ARCHITECTURE §14).
    package static func forStart(name: StagingFileName, expectedBytes: Int64?, resumeData: ResumeData?) -> BackgroundTaskTag {
        BackgroundTaskTag(name: name, expectedBytes: expectedBytes, createdFromResumeData: resumeData != nil)
    }

    /// Decodes a task description; `nil` for anything that is not exactly one of our tags.
    package init?(decoding description: String?) {
        guard let description, description.utf8.count <= Self.maxBytes else {
            return nil
        }
        let fields = description.split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 3 || (fields.count == 4 && fields[3] == Self.resumeField), fields[0] == Self.version[...],
            let name = StagingFileName(parsing: String(fields[1])), name.kind == .partial
        else {
            return nil
        }
        let createdFromResumeData = fields.count == 4
        if fields[2] == "-" {
            self.init(name: name, expectedBytes: nil, createdFromResumeData: createdFromResumeData)
            return
        }
        guard (1...19).contains(fields[2].utf8.count), fields[2].utf8.allSatisfy({ (0x30...0x39).contains($0) }),
            let expected = Int64(fields[2])
        else {
            return nil
        }
        self.init(name: name, expectedBytes: expected, createdFromResumeData: createdFromResumeData)
    }

    /// The task description.
    package var encoded: String {
        let fresh = "\(Self.version) \(self.name.rawValue) \(self.expectedBytes.map(String.init) ?? "-")"
        return self.createdFromResumeData ? "\(fresh) \(Self.resumeField)" : fresh
    }

    /// Labels a new download task before it is resumed: this tag as its `taskDescription` (what survives a
    /// relaunch), the lane's `priority`, and the decoded size as the OS's scheduling hint when known. Shared by the
    /// live driver and the fake one, so the device-only file stays decision-free (ARCHITECTURE §14).
    package func label(_ task: URLSessionTask, priority: Float) {
        task.taskDescription = self.encoded
        task.priority = priority
        if let expectedBytes = self.expectedBytes {
            task.countOfBytesClientExpectsToReceive = expectedBytes
        }
    }
}
