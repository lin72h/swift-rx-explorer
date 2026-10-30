// id-011 follow-up probes for the cooperative executor. Run each test on its
// own (`swift test --filter <name>`), with and without
// LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 (macOS: cooperative pool width 1).
// Both tests block cooperative threads on purpose, so every block is bounded:
// nothing here can hang the runner, a starved writer becomes a recorded issue.
import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Mutex-protected counters and flags with timed waits, usable from blocked
/// cooperative threads and from a plain Thread alike (no Swift concurrency).
final class Gate: @unchecked Sendable {
    private let mutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
    private let cond = UnsafeMutablePointer<pthread_cond_t>.allocate(capacity: 1)
    private var count = 0
    private var flags: Set<String> = []

    init() {
        pthread_mutex_init(mutex, nil)
        pthread_cond_init(cond, nil)
    }

    deinit {
        pthread_cond_destroy(cond)
        pthread_mutex_destroy(mutex)
        mutex.deallocate()
        cond.deallocate()
    }

    private func locked<T>(_ body: () -> T) -> T {
        pthread_mutex_lock(mutex)
        defer { pthread_mutex_unlock(mutex) }
        return body()
    }

    var started: Int { locked { count } }
    func isSet(_ flag: String) -> Bool { locked { flags.contains(flag) } }

    func set(_ flag: String) {
        locked {
            flags.insert(flag)
            pthread_cond_broadcast(cond)
        }
    }

    /// Waits until `flag` is set or `seconds` pass; true if it was set.
    @discardableResult
    func wait(for flag: String, seconds: Int) -> Bool {
        var deadline = timespec()
        clock_gettime(CLOCK_REALTIME, &deadline)
        deadline.tv_sec += seconds
        return locked {
            while !flags.contains(flag) {
                if pthread_cond_timedwait(cond, mutex, &deadline) == ETIMEDOUT { break }
            }
            return flags.contains(flag)
        }
    }

    /// Counts the caller as started, then blocks its thread until `flag` is
    /// set or `seconds` pass.
    func enterAndBlock(until flag: String, seconds: Int) {
        locked { count += 1 }
        wait(for: flag, seconds: seconds)
    }
}

func monotonicSeconds() -> Double {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
}

func makeTemporaryDirectory() throws -> String {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("pool-probe-\(getpid())-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
}

@Suite(.serialized)
struct PoolProbeTests {
    /// Submits `tasks` detached tasks that each block their thread, while this
    /// test task blocks its own; counts how many started at each sample time.
    /// The width is that count plus this task. The SwiftPM FIFO test needs 2.
    @Test func cooperativePoolWidthForBlockedTasks() async {
        let tasks = 64
        let gate = Gate()
        let t0 = monotonicSeconds()
        let workers = (0..<tasks).map { _ in
            Task.detached { gate.enterAndBlock(until: "release", seconds: 10) }
        }
        var samples: [(Double, Int)] = []
        for at in [0.5, 1.0, 2.0, 4.0] {
            while monotonicSeconds() - t0 < at { usleep(10_000) }  // blocks this thread
            samples.append((at, gate.started))
        }
        gate.set("release")
        for worker in workers { await worker.value }

        let width = (samples.first { $0.0 == 1.0 }?.1 ?? 0) + 1
        let line = samples.map { "t=\($0.0)s started=\($0.1)" }.joined(separator: " ")
        print("POOL_PROBE width_at_1s=\(width) tasks=\(tasks) \(line) "
            + "active_cpus=\(ProcessInfo.processInfo.activeProcessorCount) "
            + "strict=\(ProcessInfo.processInfo.environment["LIBDISPATCH_COOPERATIVE_POOL_STRICT"] ?? "unset")")
        #expect(width >= 2, "the executor gave blocked tasks \(width) thread(s); a test task that blocks its thread (SwiftPM FileSystemTests.swift:30-47) then starves its Task.detached writer")
    }

    /// SwiftPM 6.4.0 FileSystemTests.swift:30-47 with POSIX I/O: this test task
    /// blocks its thread in open(O_RDONLY) on a FIFO that only a Task.detached
    /// writer opens. A watchdog on a plain Thread, outside the executor,
    /// unblocks the reader after 10 s and records the starvation instead of
    /// hanging, then keeps a read end open so the late writer can finish.
    @Test func fifoReaderBlocksTaskWriterDetached() async throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/token.fifo"
        try #require(mkfifo(path, 0o600) == 0)
        let expected = "test-secret-token"
        let gate = Gate()

        let writer = Task.detached {
            defer { gate.set("writerDone") }
            let fd = open(path, O_WRONLY)
            guard fd >= 0 else { return }
            defer { close(fd) }
            gate.set("writerOpened")
            _ = expected.withCString { write(fd, $0, strlen($0)) }
        }

        let watchdog = Thread {
            if gate.wait(for: "readerDone", seconds: 10) { return }
            gate.set("watchdogFired")
            // A reader is blocked in open(2): a non-blocking writer open wakes
            // it (and fails harmlessly with ENXIO if the reader just left).
            let wfd = open(path, O_WRONLY | O_NONBLOCK)
            if wfd >= 0 { close(wfd) }
            // Give the starved writer's blocking open(O_WRONLY) a reader.
            let rfd = open(path, O_RDONLY | O_NONBLOCK)
            gate.wait(for: "writerDone", seconds: 30)
            if rfd >= 0 { close(rfd) }
        }
        watchdog.start()

        let t0 = monotonicSeconds()
        let fd = open(path, O_RDONLY)  // blocks this task's thread, as SwiftPM's readFileContents does
        try #require(fd >= 0)
        var buf = [UInt8](repeating: 0, count: 64)
        let n = read(fd, &buf, buf.count)
        close(fd)
        let elapsed = monotonicSeconds() - t0
        gate.set("readerDone")
        let contents = String(decoding: buf.prefix(max(n, 0)), as: UTF8.self)
        let fired = gate.isSet("watchdogFired")
        print("FIFO_PROBE watchdog_fired=\(fired) reader_blocked_s=\(String(format: "%.3f", elapsed)) "
            + "read='\(contents)' writer_opened_before_reader_returned=\(gate.isSet("writerOpened")) "
            + "strict=\(ProcessInfo.processInfo.environment["LIBDISPATCH_COOPERATIVE_POOL_STRICT"] ?? "unset")")
        #expect(!fired, "the Task.detached writer did not open the FIFO within 10 s while this task blocked its thread in open(O_RDONLY)")
        #expect(fired || contents == expected)

        await writer.value  // frees this thread, so a starved writer can now run
    }
}
