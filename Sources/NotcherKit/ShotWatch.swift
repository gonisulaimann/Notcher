import Foundation

/// Watches ~/Desktop for newly arriving images (screenshots first and
/// foremost) so they wash into the Harbor without any gesture.
/// Single O_EVTONLY fd + DispatchSource: event-driven, zero polling.
/// Only genuinely NEW names trigger — the seen-set is seeded with the
/// current directory contents, so first launch never parks the whole
/// Desktop. Toggleable via the Harbor card (`harbor.watchShots`).
@MainActor
public final class ShotWatch {
    public var onShot: ((URL) -> Void)?
    public var isEnabled = true

    private var source: DispatchSourceFileSystemObject?
    private var seen = Set<String>()
    private let dir: URL

    private static let exts = ["png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "webp"]

    public static let watchShotsKey = "harbor.watchShots"

    public init(directory: URL? = nil) {
        let base = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        dir = directory ?? base
        seen = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write], queue: .main)
        src.setEventHandler { [weak self] in
            Task { @MainActor in self?.scan() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    deinit { source?.cancel() }

    private func scan() {
        guard isEnabled else { return }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .creationDateKey])
        else { return }
        for url in files {
            let name = url.lastPathComponent
            guard !seen.contains(name) else { continue }
            seen.insert(name)
            guard Self.exts.contains(url.pathExtension.lowercased()) else { continue }
            guard let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .creationDateKey]),
                  vals.isRegularFile == true,
                  (vals.fileSize ?? 0) > 0
            else { continue }
            // Belt and braces with the seen-set: a renamed-in old file has a
            // new name but an old birth date — it did not just wash in.
            if let created = vals.creationDate, created.timeIntervalSinceNow < -180 { continue }
            IslandDebug.log("shotwatch: new image \(name)")
            onShot?(url)
        }
    }
}
