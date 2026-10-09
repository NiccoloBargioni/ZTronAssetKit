import Darwin
import Foundation
import Synchronization

/// The benchmarks' one memory probe (ARCHITECTURE §13.5 item 6; WP-B writes it, WP-F and WP-G reuse it read-only):
/// the process's resident size and physical footprint from `task_info`, and a peak sampler.
///
/// `task_info` fills a caller-provided buffer, i.e. a mutable pointer: that is why this helper lives in the benchmarks
/// target, which the unsafe gate does not scan, and never in `Sources/` (ADR-040). No other file in this module may
/// declare a memory helper.
enum MemoryProbe {
    /// Current resident size in bytes (`MACH_TASK_BASIC_INFO.resident_size`), or 0 if the kernel refused.
    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { buffer in
                task_info(MemoryProbe.task, task_flavor_t(MACH_TASK_BASIC_INFO), buffer, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }

    /// Current physical footprint in bytes (`TASK_VM_INFO.phys_footprint`, what jetsam counts on iOS), or 0.
    static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { buffer in
                task_info(MemoryProbe.task, task_flavor_t(TASK_VM_INFO), buffer, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    /// Mebibytes, for reports and budgets.
    static func mebibytes(_ bytes: UInt64) -> Double {
        Double(bytes) / Double(1 << 20)
    }

    /// The task port of this process.
    private static var task: mach_port_t {
        mach_task_self_
    }

    /// Tracks the largest resident size seen between `start()` and the last `sample()`, from any thread.
    @available(macOS 15.0, iOS 18.0, *)
    final class PeakSampler: Sendable {
        private let state = Mutex<(baseline: UInt64, peak: UInt64, samples: Int)>((0, 0, 0))

        init() {}

        /// Records the baseline (and resets the peak to it and the sample count to zero).
        func start() {
            let now = MemoryProbe.residentBytes()
            self.state.withLock { $0 = (now, now, 0) }
        }

        /// Samples the resident size now.
        func sample() {
            let now = MemoryProbe.residentBytes()
            self.state.withLock { state in
                state.peak = max(state.peak, now)
                state.samples += 1
            }
        }

        /// How many samples were taken since `start()`.
        var samples: Int {
            self.state.withLock { $0.samples }
        }

        /// The peak above the baseline, in bytes.
        var peakDelta: UInt64 {
            self.state.withLock { $0.peak > $0.baseline ? $0.peak - $0.baseline : 0 }
        }
    }
}
