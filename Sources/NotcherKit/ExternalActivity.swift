import Foundation

/// IslandKit v1 — third-party live activities as pure value types.
///
/// The store is deliberately UI-free and Sendable: the entire consent /
/// priority / TTL / eviction table is unit-probed without touching AppKit.
/// The coordinator (ExternalCenter, MainActor) owns persistence + timers and
/// publishes the single visible activity; IslandState renders it strictly
/// below user activities (timer › transfer › remoteTimer › media › external).
public struct ExternalActivity: Codable, Equatable, Sendable, Identifiable {
    public enum Priority: String, Codable, Sendable, Comparable {
        case low, normal, high

        public static func < (lhs: Priority, rhs: Priority) -> Bool {
            lhs.rank < rhs.rank
        }

        private var rank: Int {
            switch self {
            case .low: return 0
            case .normal: return 1
            case .high: return 2
            }
        }
    }

    public var id: String
    public var source: String
    public var bundleID: String?
    public var title: String
    public var subtitle: String?
    public var progress: Double?
    public var priority: Priority
    public var icon: String
    public var expiresAt: Date
    public var updatedAt: Date

    public static let maxTitle = 120
    public static let maxSubtitle = 200
    public static let maxTTL: TimeInterval = 3600
    public static let defaultTTL: TimeInterval = 120
    public static let maxStored = 8

    public init(id: String, source: String, bundleID: String? = nil,
                title: String, subtitle: String? = nil,
                progress: Double? = nil, priority: Priority = .normal,
                icon: String = "app.badge", ttl: TimeInterval = ExternalActivity.defaultTTL,
                now: Date = Date())
    {
        self.id = id
        self.source = source.isEmpty ? "script" : String(source.prefix(60))
        self.bundleID = bundleID
        self.title = String(title.prefix(Self.maxTitle))
        self.subtitle = subtitle.map { String($0.prefix(Self.maxSubtitle)) }
        if let p = progress { self.progress = min(1, max(0, p)) } else { self.progress = nil }
        self.priority = priority
        self.icon = icon
        self.expiresAt = now.addingTimeInterval(min(max(ttl, 1), Self.maxTTL))
        self.updatedAt = now
    }

    /// Consent is keyed on the resolved bundle id when we have one, else on
    /// the declared source string. This is attention management, not a
    /// security boundary: local processes are already fully trusted by the
    /// OS, so a spoofed source name buys an attacker nothing they lack.
    public var identityKey: String {
        if let b = bundleID, !b.isEmpty { return "bundle:" + b }
        return "source:" + source
    }
}

/// The whole third-party state machine. Value type: every transition is a
/// pure function of (state, input), which is what the probes assert.
public struct ExternalStore: Sendable {
    public enum Decision: Equatable, Sendable {
        case shown
        case updated
        case pendingConsent(firstSeen: Bool)
        case droppedDenied
        case droppedRateLimited
    }

    public var activities: [String: ExternalActivity] = [:] // id -> activity
    public var grants: [String: Bool] = [:]                 // identityKey -> allowed?
    public var pending: [String: ExternalActivity] = [:]    // identityKey -> first activity
    public var lastAccepted: [String: Date] = [:]           // identityKey -> last submit
    public static let minInterval: TimeInterval = 0.1       // 10/s flood cap per identity

    public init() {}
    public init(grants: [String: Bool]) {
        self.grants = grants
    }

    public mutating func submit(_ activity: ExternalActivity, now: Date = Date()) -> Decision {
        let key = activity.identityKey
        if grants[key] == false { return .droppedDenied }
        if let last = lastAccepted[key], now.timeIntervalSince(last) < Self.minInterval {
            return .droppedRateLimited
        }
        lastAccepted[key] = now
        guard grants[key] == true else {
            let first = pending[key] == nil
            if first { pending[key] = activity }
            return .pendingConsent(firstSeen: first)
        }
        let isUpdate = activities[activity.id] != nil
        activities[activity.id] = activity
        evictIfNeeded(now: now)
        return isUpdate ? .updated : .shown
    }

    public mutating func approve(identityKey: String) {
        grants[identityKey] = true
        if let first = pending.removeValue(forKey: identityKey) {
            activities[first.id] = first
            evictIfNeeded(now: Date())
        }
    }

    public mutating func deny(identityKey: String) {
        grants[identityKey] = false
        pending.removeValue(forKey: identityKey)
    }

    public mutating func revoke(identityKey: String) {
        grants[identityKey] = false
        activities = activities.filter { $0.value.identityKey != identityKey }
        pending.removeValue(forKey: identityKey)
    }

    public mutating func clear(id: String) {
        activities.removeValue(forKey: id)
    }

    public mutating func clearAll() {
        activities.removeAll()
    }

    /// Purge expired; returns nothing — callers read `visible`.
    public mutating func tick(now: Date = Date()) {
        activities = activities.filter { $0.value.expiresAt > now }
    }

    /// Top third-party activity: priority class, then recency.
    public func visible(now: Date = Date()) -> ExternalActivity? {
        activities.values
            .filter { $0.expiresAt > now }
            .sorted {
                if $0.priority != $1.priority { return $0.priority > $1.priority }
                return $0.updatedAt > $1.updatedAt
            }
            .first
    }

    private mutating func evictIfNeeded(now: Date) {
        tick(now: now)
        while activities.count > ExternalActivity.maxStored {
            if let victim = activities.values.sorted(by: {
                if $0.priority != $1.priority { return $0.priority < $1.priority }
                return $0.updatedAt < $1.updatedAt
            }).first {
                activities.removeValue(forKey: victim.id)
            } else { break }
        }
    }
}
