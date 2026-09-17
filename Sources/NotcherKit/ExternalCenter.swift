import AppKit
import Foundation

/// MainActor owner of third-party waterline state: persistence of grants,
/// TTL sweeping, and publication of the single visible external activity.
/// All policy lives in ExternalStore (pure); this is glue + timers.
@MainActor
public final class ExternalCenter: ObservableObject {
    public enum Event {
        case needsConsent(String) // display name of the requester
        case shownNow
        case drained
    }

    @Published public private(set) var visible: ExternalActivity?
    @Published public private(set) var pending: [ExternalActivity] = []
    @Published public private(set) var grants: [(key: String, name: String, allowed: Bool)] = []

    public var onEvent: ((Event) -> Void)?

    private var store = ExternalStore()
    private var names: [String: String] = [:]
    private var sweep: Timer?
    private var wasVisible = false

    private static let grantsKey = "external.grants"
    private static let namesKey = "external.names"

    public init() {
        if let g = UserDefaults.standard.dictionary(forKey: Self.grantsKey) as? [String: Bool] {
            store = ExternalStore(grants: g)
        }
        names = UserDefaults.standard.dictionary(forKey: Self.namesKey) as? [String: String] ?? [:]
        refresh()
    }

    public func submit(_ activity: ExternalActivity) {
        names[activity.identityKey] = activity.bundleID ?? activity.source
        switch store.submit(activity) {
        case .shown, .updated:
            refresh()
            onEvent?(.shownNow)
        case .pendingConsent(let firstSeen):
            refresh()
            if firstSeen { onEvent?(.needsConsent(displayName(for: activity))) }
        case .droppedDenied, .droppedRateLimited:
            refresh()
        }
    }

    public func approve(identityKey: String) {
        store.approve(identityKey: identityKey)
        persist()
        refresh()
        onEvent?(.shownNow)
    }

    public func deny(identityKey: String) {
        store.deny(identityKey: identityKey)
        persist()
        refresh()
    }

    public func setAllowed(identityKey: String, allowed: Bool) {
        if allowed {
            store.approve(identityKey: identityKey)
        } else {
            store.revoke(identityKey: identityKey)
        }
        persist()
        refresh()
    }

    public func clear(id: String) {
        store.clear(id: id)
        refresh()
    }

    public func clearAll() {
        store.clearAll()
        refresh()
    }

    /// Ids owned by one sender (ids are namespaced `key:raw` at submit).
    public func ids(matchingPrefix prefix: String) -> [String] {
        store.activities.keys.filter { $0.hasPrefix(prefix) }
    }

    public func refresh() {
        store.tick()
        visible = store.visible()
        pending = store.pending.values.sorted { $0.updatedAt > $1.updatedAt }
        grants = store.grants.map { (key: $0.key, name: names[$0.key] ?? $0.key, allowed: $0.value) }
            .sorted { $0.name < $1.name }
        if visible == nil, wasVisible { onEvent?(.drained) }
        wasVisible = visible != nil
        if store.activities.isEmpty {
            sweep?.invalidate()
            sweep = nil
        } else if sweep == nil {
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            RunLoop.main.add(t, forMode: .common)
            sweep = t
        }
    }

    private func displayName(for activity: ExternalActivity) -> String {
        activity.bundleID.flatMap { id in
            NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.localizedName
        } ?? activity.source
    }

    private func persist() {
        UserDefaults.standard.set(store.grants, forKey: Self.grantsKey)
        UserDefaults.standard.set(names, forKey: Self.namesKey)
    }
}
