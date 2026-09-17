import Foundation
import UserNotifications

/// Single countdown timer. Persists across relaunch via a stored deadline;
/// fires a real notification and a callback on completion.
@MainActor
public final class TimerEngine: ObservableObject {
    public enum State: String, Equatable, Sendable {
        case idle, running, paused, done
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var remaining: TimeInterval = 0
    @Published public private(set) var total: TimeInterval = 0
    @Published public var label: String = ""
    /// Draft minutes text in the tray's custom-timer field (view state kept
    /// here because CLT SwiftUI lacks the @State macro plugin).
    @Published public var draftMinutes: String = "25"

    public var onFinished: (() -> Void)?
    public var onChanged: (() -> Void)?
    /// Test/snapshot hook: skip the system notification-permission prompt.
    public var permissionPromptEnabled = true

    private var tick: Timer?
    private var deadline: Date?
    private let storeURL: URL
    /// Set only when the system grants notification permission. Posting to
    /// UNUserNotificationCenter without a host app context (or after denial)
    /// must be a silent no-op, never a crash.
    private var notificationAuthorized = false

    public init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Notcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storeURL = dir.appendingPathComponent("timer.json")
        restore()
    }

    public var progress: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, remaining / total))
    }

    public var isActive: Bool { state == .running || state == .paused }

    public func start(seconds: TimeInterval, label: String) {
        cancelTick()
        total = max(1, seconds)
        remaining = total
        self.label = label
        deadline = Date().addingTimeInterval(total)
        state = .running
        persist()
        if permissionPromptEnabled { requestNotificationPermission() }
        scheduleTick()
        onChanged?()
    }

    public func pause() {
        guard state == .running else { return }
        state = .paused
        deadline = nil // frozen: remaining is the truth now, not the deadline
        cancelTick()
        persist()
        onChanged?()
    }

    public func resume() {
        guard state == .paused else { return }
        deadline = Date().addingTimeInterval(remaining)
        state = .running
        persist()
        scheduleTick()
        onChanged?()
    }

    public func cancel() {
        state = .idle
        remaining = 0
        total = 0
        deadline = nil
        cancelTick()
        persist()
        onChanged?()
    }

    private func scheduleTick() {
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
        RunLoop.main.add(t, forMode: .common)
        tick = t
    }

    private func cancelTick() {
        tick?.invalidate()
        tick = nil
    }

    private func update() {
        guard state == .running, let deadline else { return }
        remaining = max(0, deadline.timeIntervalSinceNow)
        if remaining <= 0 {
            state = .done
            cancelTick()
            persist()
            notifyDone()
            onFinished?()
            onChanged?()
            // Settle back to idle after the flash has had its moment.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                Task { @MainActor in
                    if self?.state == .done { self?.cancel() }
                }
            }
        }
    }

    // MARK: - Persistence

    private struct Saved: Codable {
        var total: TimeInterval
        var remaining: TimeInterval
        var deadline: Date?
        var label: String
        var state: String
    }

    private func persist() {
        let saved = Saved(total: total, remaining: remaining, deadline: deadline,
                          label: label, state: state.rawValue)
        try? JSONEncoder().encode(saved).write(to: storeURL, options: .atomic)
    }

    private func restore() {
        guard let data = try? Data(contentsOf: storeURL),
              let saved = try? JSONDecoder().decode(Saved.self, from: data),
              saved.state == "running" || saved.state == "paused"
        else { return }
        total = saved.total
        label = saved.label
        if saved.state == "paused" {
            // A paused timer has no deadline; remaining is authoritative.
            remaining = max(0, saved.remaining)
            guard remaining > 0 else { return }
            state = .paused
            self.deadline = nil
            return
        }
        guard let deadline = saved.deadline else { return }
        let left = deadline.timeIntervalSinceNow
        if left <= 0 {
            state = .done
            remaining = 0
            persist()
            onFinished?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                Task { @MainActor in
                    if self?.state == .done { self?.cancel() }
                }
            }
        } else {
            remaining = left
            state = .running
            self.deadline = deadline
            scheduleTick()
        }
    }

    // MARK: - Notification

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in self?.notificationAuthorized = granted }
        }
    }

    private func notifyDone() {
        guard notificationAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "Timer done"
        content.body = label.isEmpty ? "Your countdown finished." : label
        content.sound = .default
        let req = UNNotificationRequest(identifier: "notcher-timer-done", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
