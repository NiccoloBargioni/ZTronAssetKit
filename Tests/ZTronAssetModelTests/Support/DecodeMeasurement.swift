import Darwin
import Foundation
import MachO
import Synchronization

/// What a measured run of a closure cost: CPU time of the calling thread and heap growth.
struct DecodeCost {
    /// CPU time the calling thread spent in the closure, in seconds (`CLOCK_THREAD_CPUTIME_ID`): unlike wall time,
    /// it does not grow when other tests or processes compete for the cores.
    var cpuSeconds: Double
    /// The highest heap growth observed while the closure ran, in bytes, over the in-use bytes before it.
    var peakHeapGrowth: Int
    /// The heap growth still live right after the closure returned (its result included).
    var retainedHeapGrowth: Int
}

/// Measures R-MAN-3's time and allocation bounds, and says when a measurement means something.
///
/// The heap is read with `malloc_zone_statistics` (in-use bytes over every zone). This allocator does not keep a
/// high-water mark (`max_size_in_use` reads 0 here), so the peak is *sampled*: a dedicated thread polls the in-use
/// bytes for as long as the closure runs and keeps the maximum. One poll takes 50–150 µs and holds the zones'
/// locks, so back-to-back polls would starve the decoder's own allocations; the sampler therefore spins on its own
/// CPU time for nine poll durations after each poll (a 10 % duty cycle, about one sample per millisecond, never a
/// sleep). The decoder's large allocations (the entry array, the identifier index, their growth copies, a decoded
/// string) live for milliseconds; what a sample can miss is a spike shorter than that, which is small next to the
/// 4x budget. The exact in-use growth right after the closure (its result alive) is reported and asserted too. The
/// sample also counts whatever other tests allocate meanwhile, which only makes it larger.
enum DecodeMeasurement {
    /// Whether this test binary runs under Thread Sanitizer, whose allocator and instrumentation make heap and
    /// time figures meaningless (detected by its runtime library being loaded).
    static let underThreadSanitizer: Bool = {
        (0..<_dyld_image_count()).contains { index in
            guard let name = _dyld_get_image_name(index) else {
                return false
            }
            return String(cString: name).contains("libclang_rt.tsan")
        }
    }()

    /// Whether the code under test is optimised: R-MAN-3's 1 s bound concerns the shipped (optimised) decoder; an
    /// unoptimised build runs the same code about 11x slower (ADR draft A-5).
    static var isOptimized: Bool {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }

    /// The in-use heap bytes over every malloc zone.
    static func heapInUse() -> Int {
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
        return Int(statistics.size_in_use)
    }

    /// CPU time of the calling thread, in nanoseconds.
    static func threadCPUNanoseconds() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    }

    /// Runs `body` on the calling thread while a sampler thread tracks the heap's in-use bytes.
    @available(macOS 15.0, *)
    static func measure<Result>(_ body: () throws -> Result) rethrows -> (result: Result, cost: DecodeCost) {
        let sampler = HeapSampler()
        let before = DecodeMeasurement.heapInUse()
        sampler.start(baseline: before)
        let cpuBefore = DecodeMeasurement.threadCPUNanoseconds()
        let result: Result
        do {
            result = try body()
        } catch {
            _ = sampler.stop()
            throw error
        }
        let cpuAfter = DecodeMeasurement.threadCPUNanoseconds()
        let retained = DecodeMeasurement.heapInUse()
        let peak = max(sampler.stop(), retained)
        let cost = DecodeCost(
            cpuSeconds: Double(cpuAfter - cpuBefore) / 1_000_000_000,
            peakHeapGrowth: peak - before,
            retainedHeapGrowth: retained - before
        )
        return (result, cost)
    }
}

/// A thread that polls the heap's in-use bytes until stopped and keeps the maximum.
@available(macOS 15.0, *)
private final class HeapSampler: Sendable {
    private let stopRequested = Atomic<Bool>(false)
    private let started = Atomic<Bool>(false)
    private let peak = Atomic<Int>(0)
    private let finished = DispatchSemaphore(value: 0)

    /// Starts polling; returns once the sampler took its first sample.
    func start(baseline: Int) {
        self.peak.store(baseline, ordering: .relaxed)
        let thread = Thread { [self] in
            repeat {
                let pollStart = DecodeMeasurement.threadCPUNanoseconds()
                let inUse = DecodeMeasurement.heapInUse()
                let pollEnd = DecodeMeasurement.threadCPUNanoseconds()
                var current = self.peak.load(ordering: .relaxed)
                while inUse > current {
                    let (exchanged, original) = self.peak.compareExchange(expected: current, desired: inUse, ordering: .relaxed)
                    if exchanged {
                        break
                    }
                    current = original
                }
                self.started.store(true, ordering: .releasing)
                // Leave the allocator alone for nine poll durations (at least 200 µs) of this thread's CPU time.
                let quiet = max(9 * (pollEnd - pollStart), 200_000)
                while DecodeMeasurement.threadCPUNanoseconds() - pollEnd < quiet, !self.stopRequested.load(ordering: .relaxed) {
                    continue
                }
            } while !self.stopRequested.load(ordering: .acquiring)
            self.finished.signal()
        }
        thread.qualityOfService = .userInitiated
        thread.start()
        while !self.started.load(ordering: .acquiring) {
            sched_yield()
        }
    }

    /// Stops polling, waits for the thread to finish and returns the highest in-use bytes seen.
    func stop() -> Int {
        self.stopRequested.store(true, ordering: .releasing)
        self.finished.wait()
        return self.peak.load(ordering: .relaxed)
    }
}
