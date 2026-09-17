import AppKit
import Foundation
import UniformTypeIdentifiers

/// "Harbor": a tiny shelf of files parked at the notch.
///
/// Files are referenced (security-scoped bookmarks), never copied, and the
/// store holds at most 8 items — overflow drops the oldest. Drag files onto
/// the island to park them; drag them out or click to reveal in Finder.
@MainActor
public final class HarborStore: ObservableObject {
    public struct Item: Identifiable, Codable, Equatable, Sendable {
        public var id: UUID
        public var name: String
        public var kind: String
        public var addedAt: Date
        public var bookmark: Data
    }

    public static let maxItems = 8

    @Published public private(set) var items: [Item] = []
    public var onChanged: (() -> Void)?

    private let storeURL: URL

    public init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Notcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storeURL = dir.appendingPathComponent("harbor.json")
        restore()
        pruneDead()
    }

    public var count: Int { items.count }

    @discardableResult
    public func add(urls: [URL]) -> Int {
        var added = 0
        for url in urls {
            guard items.count < HarborStore.maxItems || !items.isEmpty else { break }
            let resolved: URL
            if url.isFileURL {
                resolved = url.standardizedFileURL
            } else {
                continue
            }
            guard FileManager.default.fileExists(atPath: resolved.path) else { continue }
            guard let bookmark = try? resolved.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) else { continue }
            var kind = "doc"
            if let type = try? resolved.resourceValues(forKeys: [.contentTypeKey]).contentType {
                if type.conforms(to: .image) { kind = "image" }
                else if type.conforms(to: .audiovisualContent) { kind = "video" }
                else if type.conforms(to: .audio) { kind = "audio" }
                else if type.conforms(to: .pdf) { kind = "pdf" }
                else if type.conforms(to: .folder) { kind = "folder" }
            }
            let item = Item(id: UUID(), name: resolved.lastPathComponent, kind: kind,
                            addedAt: Date(), bookmark: bookmark)
            items.append(item)
            added += 1
        }
        while items.count > HarborStore.maxItems { items.removeFirst() }
        persist()
        onChanged?()
        return added
    }

    public func remove(id: UUID) {
        items.removeAll { $0.id == id }
        persist()
        onChanged?()
    }

    public func clear() {
        items.removeAll()
        persist()
        onChanged?()
    }

    public func resolve(_ item: Item) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: item.bookmark,
                                 options: .withSecurityScope,
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale)
        else { return nil }
        return url
    }

    public func reveal(id: UUID) {
        guard let item = items.first(where: { $0.id == id }),
              let url = resolve(item)
        else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        NSWorkspace.shared.activateFileViewerSelecting([url])
        if accessing { url.stopAccessingSecurityScopedResource() }
    }

    private func pruneDead() {
        let before = items.count
        items = items.filter { resolve($0) != nil }
        if items.count != before { persist() }
    }

    private struct Saved: Codable { var items: [Item] }

    private func persist() {
        try? JSONEncoder().encode(Saved(items: items)).write(to: storeURL, options: .atomic)
    }

    private func restore() {
        guard let data = try? Data(contentsOf: storeURL),
              let saved = try? JSONDecoder().decode(Saved.self, from: data)
        else { return }
        items = Array(saved.items.suffix(HarborStore.maxItems))
    }
}
