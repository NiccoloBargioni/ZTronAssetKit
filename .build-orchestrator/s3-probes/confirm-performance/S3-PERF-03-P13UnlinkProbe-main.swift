// S3-PERF P-13 root-cause probe (isolated; not part of the package). Measures the latency distribution of single
// unlink(2) calls of 64-byte files on this volume for fresh (unsynced) vs barrier-synced vs settled files, flat vs
// 256-way fan-out (the store's blobs/<aa>/ layout), sorted (the reaper's order) vs random order, with and without a
// concurrent F_FULLFSYNC writer. Per unlink it records wall time, the thread's on-CPU time and the process's
// voluntary / involuntary context switches (single-threaded phase), which tells "blocked in the kernel" (voluntary
// switch, little CPU) from "preempted by another process" (involuntary switch).
import Darwin
import Foundation

let root = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath + "/p13probe"
let count = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 10_000
let only = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : ""

func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
func cpu() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }
func switches() -> (v: Int, iv: Int) {
    var usage = Darwin.rusage()
    getrusage(RUSAGE_SELF, &usage)
    return (usage.ru_nvcsw, usage.ru_nivcsw)
}

struct Sample { var at: UInt64; var wall: Double; var onCPU: Double; var vol: Int; var invol: Int }

enum Layout { case flat, fanOut }
enum Prep { case fresh, barrierEach, fullEach, settled, freshThenIndexFullSync }
enum Order { case sorted, random }

var rng = SystemRandomNumberGenerator()
func hexName() -> String {
    var s = ""
    for _ in 0..<4 { s += String(format: "%016llx", UInt64.random(in: 0...UInt64.max, using: &rng)) }
    return s
}

func syncFD(_ fd: Int32, _ op: Int32) { if fcntl(fd, op) != 0 { _ = fsync(fd) } }
func syncPath(_ path: String, _ op: Int32, dir: Bool = false) {
    let fd = open(path, O_RDONLY | O_CLOEXEC | (dir ? O_DIRECTORY : 0))
    guard fd >= 0 else { return }
    syncFD(fd, op)
    close(fd)
}

func percentile(_ v: [Double], _ f: Double) -> Double {
    let s = v.sorted(); let r = Int((f * Double(s.count)).rounded(.up)) - 1
    return s[min(max(r, 0), s.count - 1)]
}

func run(_ name: String, layout: Layout, prep: Prep, order: Order, concurrentFullSync: Bool = false, qos: qos_class_t = QOS_CLASS_DEFAULT) {
    if !only.isEmpty && !name.contains(only) { return }
    let dir = root + "/" + name + "-" + UUID().uuidString
    mkdir(dir, 0o700)
    let blobs = dir + "/blobs"
    mkdir(blobs, 0o700)
    var paths: [String] = []
    paths.reserveCapacity(count)
    let payload = [UInt8](repeating: 0xA5, count: 64)
    for _ in 0..<count {
        let h = hexName()
        let parent: String
        switch layout {
        case .flat: parent = blobs
        case .fanOut:
            parent = blobs + "/" + String(h.prefix(2))
            mkdir(parent, 0o700)
        }
        let p = parent + "/" + h + ".png"
        let fd = open(p, O_WRONLY | O_CREAT | O_CLOEXEC | O_TRUNC, 0o600)
        precondition(fd >= 0)
        _ = payload.withUnsafeBytes { write(fd, $0.baseAddress, 64) }
        switch prep {
        case .barrierEach: syncFD(fd, F_BARRIERFSYNC)
        case .fullEach: syncFD(fd, F_FULLFSYNC)
        default: break
        }
        close(fd)
        paths.append(p)
    }
    switch prep {
    case .settled:
        sync()
        // Let the volume finish writing back everything (data and metadata) before measuring.
        Thread.sleep(forTimeInterval: 5)
    case .freshThenIndexFullSync:
        // The benchmark's shape: fresh blobs, then the store's commit (a file and directory full sync) right before
        // the reap.
        let idx = dir + "/index.bin"
        let fd = open(idx, O_WRONLY | O_CREAT | O_CLOEXEC | O_TRUNC, 0o600)
        _ = payload.withUnsafeBytes { write(fd, $0.baseAddress, 64) }
        syncFD(fd, F_FULLFSYNC); close(fd)
        syncPath(dir, F_FULLFSYNC, dir: true)
    default: break
    }
    switch order {
    case .sorted: paths.sort()
    case .random: paths.shuffle()
    }
    var child: pid_t = 0
    if concurrentFullSync {
        // A separate process (so this process's context-switch counters stay the unlinking thread's own) that
        // writes and F_FULLFSYNCs a file every 50 ms on the same volume, as any other process may.
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(CommandLine.arguments[0]), strdup("--syncer"), strdup(dir + "/other.bin"), nil]
        precondition(posix_spawn(&child, CommandLine.arguments[0], nil, &attr, argv, environ) == 0)
        usleep(200_000)
    }
    final class Box: @unchecked Sendable { var samples: [Sample] = []; var total = 0.0 }
    let box = Box()
    let paths2 = paths
    let done = DispatchSemaphore(value: 0)
    let worker = Thread {
        pthread_set_qos_class_self_np(qos, 0)
        var samples: [Sample] = []
        samples.reserveCapacity(paths2.count)
        let start = now()
        for p in paths2 {
            let r0 = switches(); let c0 = cpu(); let t0 = now()
            let rc = unlink(p)
            let t1 = now(); let c1 = cpu(); let r1 = switches()
            precondition(rc == 0)
            samples.append(Sample(at: t0 - start, wall: Double(t1 - t0) / 1e6, onCPU: Double(c1 - c0) / 1e6, vol: r1.v - r0.v, invol: r1.iv - r0.iv))
        }
        box.total = Double(now() - start) / 1e6
        box.samples = samples
        done.signal()
    }
    worker.start()
    done.wait()
    if child > 0 { kill(child, SIGTERM); var st: Int32 = 0; waitpid(child, &st, 0) }
    let samples = box.samples
    let total = box.total
    let walls = samples.map(\.wall)
    let stalls = samples.filter { $0.wall > 2.0 }
    let blocked = stalls.filter { $0.vol > 0 && $0.onCPU < $0.wall / 2 }
    let preempted = stalls.filter { $0.invol > 0 && $0.vol == 0 }
    var gaps: [Double] = []
    for (a, b) in zip(stalls, stalls.dropFirst()) { gaps.append(Double(b.at - a.at) / 1e6) }
    let stallDesc = stalls.prefix(12).map { String(format: "%.1f@%.0fms(cpu %.2f,v%d,i%d)", $0.wall, Double($0.at) / 1e6, $0.onCPU, $0.vol, $0.invol) }.joined(separator: " ")
    print(String(format: "%@: n=%d total %.0f ms; p50 %.3f p99 %.3f p99.9 %.3f max %.2f ms; >1ms %d >2ms %d >4ms %d; stalls blocked(vol,low cpu) %d preempted(invol only) %d; stall gap p50 %.0f ms",
                 name, count, total, percentile(walls, 0.5), percentile(walls, 0.99), percentile(walls, 0.999), walls.max()!,
                 walls.filter { $0 > 1 }.count, stalls.count, walls.filter { $0 > 4 }.count, blocked.count, preempted.count,
                 gaps.isEmpty ? 0 : percentile(gaps, 0.5)))
    if !stalls.isEmpty { print("   first stalls: " + stallDesc) }
    _ = try? FileManager.default.removeItem(atPath: dir)
}

if CommandLine.arguments.count > 2 && CommandLine.arguments[1] == "--syncer" {
    let other = CommandLine.arguments[2]
    let payload = [UInt8](repeating: 0x5A, count: 4096)
    while true {
        let fd = open(other, O_WRONLY | O_CREAT | O_CLOEXEC | O_TRUNC, 0o600)
        _ = payload.withUnsafeBytes { write(fd, $0.baseAddress, 4096) }
        syncFD(fd, F_FULLFSYNC); close(fd)
        usleep(50_000)
    }
}
func spin(_ ns: UInt64) -> UInt64 {
    let c0 = cpu(); var x: UInt64 = 0
    while cpu() - c0 < ns { x &+= 1 }
    return x
}

/// Alternates one unlink and one ~equal-length CPU spin on the same thread, so both see the same scheduler: a stall
/// that is preemption hits both alike; a stall the unlink causes in the kernel hits only the unlinks.
func interleaved(_ name: String, prep: Prep, qos: qos_class_t, layout: Layout = .fanOut, base: String = root, spinNs: UInt64 = 45_000) {
    if !only.isEmpty && !name.contains(only) { return }
    mkdir(base, 0o700)
    let dir = base + "/" + name + "-" + UUID().uuidString
    mkdir(dir, 0o700); let blobs = dir + "/blobs"; mkdir(blobs, 0o700)
    var paths: [String] = []
    let payload = [UInt8](repeating: 0xA5, count: 64)
    for _ in 0..<count {
        let h = hexName(); let parent = layout == .flat ? blobs : blobs + "/" + String(h.prefix(2)); mkdir(parent, 0o700)
        let p = parent + "/" + h + ".png"
        let fd = open(p, O_WRONLY | O_CREAT | O_CLOEXEC | O_TRUNC, 0o600)
        _ = payload.withUnsafeBytes { write(fd, $0.baseAddress, 64) }
        if prep == .barrierEach { syncFD(fd, F_BARRIERFSYNC) }
        close(fd); paths.append(p)
    }
    if prep == .settled { sync(); Thread.sleep(forTimeInterval: 5) }
    paths.sort()
    final class Box: @unchecked Sendable { var u: [Double] = []; var s: [Double] = []; var uc: [Double] = []; var sink: UInt64 = 0 }
    let box = Box(); let done = DispatchSemaphore(value: 0); let paths2 = paths
    let worker = Thread {
        pthread_set_qos_class_self_np(qos, 0)
        for p in paths2 {
            let c0 = cpu(); let t0 = now(); precondition(unlink(p) == 0); let t1 = now(); let c1 = cpu()
            box.u.append(Double(t1 - t0) / 1e6); box.uc.append(Double(c1 - c0) / 1e6)
            let t2 = now(); box.sink &+= spin(spinNs); let t3 = now()
            box.s.append(Double(t3 - t2) / 1e6)
        }
        done.signal()
    }
    worker.start(); done.wait()
    func line(_ label: String, _ v: [Double]) -> String {
        String(format: "%@ p50 %.3f p99 %.3f max %.2f ms, >2ms %d, >4ms %d, >8ms %d, sum of excess over 1ms %.0f ms", label, percentile(v, 0.5), percentile(v, 0.99), v.max()!, v.filter { $0 > 2 }.count, v.filter { $0 > 4 }.count, v.filter { $0 > 8 }.count, v.filter { $0 > 1 }.reduce(0, +))
    }
    let idx = box.u.indices.filter { box.u[$0] > 2 }
    let gaps = zip(idx, idx.dropFirst()).map { Double($1 - $0) }
    var la = [Double](repeating: 0, count: 3); getloadavg(&la, 3)
    let stallTimes = idx.map { Double($0) * (percentile(box.u, 0.5) + percentile(box.s, 0.5)) }
    let timeGaps = zip(stallTimes, stallTimes.dropFirst()).map { $1 - $0 }
    print(String(format: "[load %.1f] approx stall time gap p50 %.0f ms; ", la[0], timeGaps.isEmpty ? 0 : percentile(timeGaps, 0.5)) + "\(name): " + line("unlink", box.u) + " | " + line("spin(45us cpu)", box.s) + String(format: " | unlink on-CPU p50 %.3f ms", percentile(box.uc, 0.5)) + " | unlink-stall indices gap p50 \(gaps.isEmpty ? 0 : percentile(gaps, 0.5)) first \(idx.prefix(10))")
    _ = try? FileManager.default.removeItem(atPath: dir)
}
func control() {
    // Method check: calls that certainly block in the kernel must count a voluntary switch.
    let dir = root + "/control-" + UUID().uuidString
    mkdir(dir, 0o700)
    var rows: [String] = []
    for i in 0..<5 {
        let r0 = switches(); let t0 = now(); usleep(3000); let t1 = now(); let r1 = switches()
        rows.append(String(format: "usleep(3ms) %.2fms v%d i%d", Double(t1 - t0) / 1e6, r1.v - r0.v, r1.iv - r0.iv))
        let p = dir + "/f\(i)"
        let fd = open(p, O_WRONLY | O_CREAT | O_CLOEXEC | O_TRUNC, 0o600)
        let payload = [UInt8](repeating: 1, count: 1 << 20)
        _ = payload.withUnsafeBytes { write(fd, $0.baseAddress, 1 << 20) }
        let r2 = switches(); let t2 = now(); _ = fcntl(fd, F_FULLFSYNC); let t3 = now(); let r3 = switches()
        rows.append(String(format: "F_FULLFSYNC(1MiB dirty) %.2fms v%d i%d", Double(t3 - t2) / 1e6, r3.v - r2.v, r3.iv - r2.iv))
        close(fd)
    }
    print("control: " + rows.joined(separator: "; "))
    _ = try? FileManager.default.removeItem(atPath: dir)
}
var la = [Double](repeating: 0, count: 3); getloadavg(&la, 3)
print(String(format: "load average %.1f %.1f %.1f; root %@", la[0], la[1], la[2], root))
if only.isEmpty || only == "control" { control() }
let U = QOS_CLASS_UTILITY, D = QOS_CLASS_DEFAULT, BG = QOS_CLASS_BACKGROUND, UI = QOS_CLASS_USER_INTERACTIVE
let NI = root + ".noindex"
interleaved("T1-period-fresh-fanout-default-spin45us", prep: .fresh, qos: D)
interleaved("T2-period-fresh-fanout-default-spin400us", prep: .fresh, qos: D, spinNs: 400_000)
interleaved("M1-matrix-fresh-fanout-default", prep: .fresh, qos: D)
interleaved("M2-matrix-settled-fanout-default", prep: .settled, qos: D)
interleaved("M3-matrix-barrier-fanout-default", prep: .barrierEach, qos: D)
interleaved("M4-matrix-fresh-flat-default", prep: .fresh, qos: D, layout: .flat)
interleaved("M5-matrix-settled-flat-default", prep: .settled, qos: D, layout: .flat)
interleaved("M6-matrix-fresh-fanout-default-noindex", prep: .fresh, qos: D, base: NI)
interleaved("M7-matrix-settled-fanout-default-noindex", prep: .settled, qos: D, base: NI)
interleaved("M8-matrix-fresh-fanout-utility", prep: .fresh, qos: U)
interleaved("M9-matrix-fresh-fanout-utility-noindex", prep: .fresh, qos: U, base: NI)
interleaved("X1-interleaved-fresh-utility", prep: .fresh, qos: U)
interleaved("X2-interleaved-fresh-default", prep: .fresh, qos: D)
interleaved("X3-interleaved-barrier-utility", prep: .barrierEach, qos: U)
interleaved("X4-interleaved-settled-utility", prep: .settled, qos: U)
interleaved("X5-interleaved-fresh-userInteractive", prep: .fresh, qos: UI)
run("H4-fresh-fanout-sorted-userInteractive", layout: .fanOut, prep: .fresh, order: .sorted, qos: UI)
run("H5-settled-fanout-sorted-userInteractive", layout: .fanOut, prep: .settled, order: .sorted, qos: UI)
run("A1-fresh-fanout-sorted-default", layout: .fanOut, prep: .fresh, order: .sorted, qos: D)
run("A2-fresh-fanout-sorted-utility", layout: .fanOut, prep: .fresh, order: .sorted, qos: U)
run("B1-barrierEach-fanout-sorted-default", layout: .fanOut, prep: .barrierEach, order: .sorted, qos: D)
run("B2-barrierEach-fanout-sorted-utility", layout: .fanOut, prep: .barrierEach, order: .sorted, qos: U)
run("C1-settled-fanout-sorted-default", layout: .fanOut, prep: .settled, order: .sorted, qos: D)
run("C2-settled-fanout-sorted-utility", layout: .fanOut, prep: .settled, order: .sorted, qos: U)
run("D2-fresh-flat-sorted-utility", layout: .flat, prep: .fresh, order: .sorted, qos: U)
run("E2-fresh+indexFullSync-fanout-sorted-utility", layout: .fanOut, prep: .freshThenIndexFullSync, order: .sorted, qos: U)
run("F1-settled-fanout-sorted-default+otherProcessFullSync", layout: .fanOut, prep: .settled, order: .sorted, concurrentFullSync: true, qos: D)
run("F2-settled-fanout-sorted-utility+otherProcessFullSync", layout: .fanOut, prep: .settled, order: .sorted, concurrentFullSync: true, qos: U)
run("G3-settled-fanout-sorted-background", layout: .fanOut, prep: .settled, order: .sorted, qos: BG)
getloadavg(&la, 3)
print(String(format: "load average at end %.1f %.1f %.1f", la[0], la[1], la[2]))
