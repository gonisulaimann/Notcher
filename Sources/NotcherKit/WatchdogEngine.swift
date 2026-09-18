import AppKit
import Foundation
import os.log

/// Automated watchdog thread monitoring main-thread latency and memory footprint.
/// If main thread latency exceeds the hang threshold or memory allocation crosses
/// the limit, it executes a graceful self-termination and unregisters window server
/// layers so the system is never blocked.
public final class WatchdogEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.notcher.watchdog", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var isRunning = false
    private let maxLatencySeconds: TimeInterval
    private let maxMemoryBytes: UInt64
    private let teardownHandler: (@MainActor () -> Void)?

    public init(
        maxLatencySeconds: TimeInterval = 6.0,
        maxMemoryMB: UInt64 = 512,
        onTeardown: (@MainActor () -> Void)? = nil
    ) {
        self.maxLatencySeconds = maxLatencySeconds
        self.maxMemoryBytes = maxMemoryMB * 1024 * 1024
        self.teardownHandler = onTeardown
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2.0, repeating: 2.5)
        t.setEventHandler { [weak self] in
            self?.checkHealth()
        }
        timer = t
        t.resume()
    }

    public func stop() {
        isRunning = false
        timer?.cancel()
        timer = nil
    }

    private func checkHealth() {
        // 1. Check process resident memory size
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kerr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if kerr == KERN_SUCCESS {
            let resident = UInt64(info.resident_size)
            if resident > maxMemoryBytes {
                os_log(.fault, "Notcher Watchdog: resident memory %llu exceeded ceiling %llu. Gracefully terminating.", resident, maxMemoryBytes)
                triggerTeardown()
                return
            }
        }

        // 2. Check main-thread latency with a timeout semaphore
        let sema = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            sema.signal()
        }

        let timeout = DispatchTime.now() + maxLatencySeconds
        let result = sema.wait(timeout: timeout)
        if result == .timedOut {
            os_log(.fault, "Notcher Watchdog: main thread unresponsive for >%.1fs. Gracefully terminating.", maxLatencySeconds)
            triggerTeardown()
        }
    }

    private func triggerTeardown() {
        stop()
        DispatchQueue.main.async { [weak self] in
            self?.teardownHandler?()
            NSApp.terminate(nil)
        }
        // Force exit fallback if main queue is deadlocked
        queue.asyncAfter(deadline: .now() + 1.0) {
            exit(1)
        }
    }

    deinit {
        stop()
    }
}
