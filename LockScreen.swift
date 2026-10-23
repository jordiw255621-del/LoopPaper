import Foundation

/// One of Apple's downloaded Aerial wallpapers. Its video is what plays on the lock screen.
struct Aerial {
    let id: String
    let name: String
    var video: URL { LockScreen.aerials.appendingPathComponent("videos/\(id).mov") }
    var thumbnail: URL { LockScreen.aerials.appendingPathComponent("thumbnails/\(id).png") }
}

/// Puts a clip on the lock screen by writing it over one Aerial's video.
/// The original video and thumbnail are backed up first and can be put back with `restore()`.
enum LockScreen {
    static let aerials = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials")
    static let store = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    static let backupDir = AppPaths.support.appendingPathComponent("backup")

    /// Aerials whose video is downloaded on this Mac, in Apple's order.
    static func downloaded() -> [Aerial] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: aerials.appendingPathComponent("videos").path)) ?? []
        let ids = Set(files.filter { $0.hasSuffix(".mov") }.map { String($0.dropLast(4)) })

        var names: [String: String] = [:]
        var order: [String] = []
        if let data = try? Data(contentsOf: aerials.appendingPathComponent("manifest/entries.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let assets = json["assets"] as? [[String: Any]] {
            for a in assets {
                guard let id = a["id"] as? String else { continue }
                names[id] = a["accessibilityLabel"] as? String
                order.append(id)
            }
        }
        let sorted = ids.sorted { (order.firstIndex(of: $0) ?? .max) < (order.firstIndex(of: $1) ?? .max) }
        return sorted.map { Aerial(id: $0, name: names[$0] ?? "Aerial \($0.prefix(8))") }
    }

    /// The Aerial currently chosen in System Settings, if it's one that's downloaded.
    static func currentlySelected() -> Aerial? {
        guard let data = try? Data(contentsOf: store) else { return nil }
        // The selection is buried in nested binary plists; the asset ID appears as plain text inside.
        let text = String(decoding: data, as: UTF8.self)
        let nested = (try? PropertyListSerialization.propertyList(from: data, format: nil)).map { flatten($0) } ?? ""
        return downloaded().first { text.contains($0.id) || nested.contains($0.id) }
    }

    private static func flatten(_ value: Any) -> String {
        switch value {
        case let d as [String: Any]: return d.values.map(flatten).joined(separator: " ")
        case let a as [Any]: return a.map(flatten).joined(separator: " ")
        case let data as Data:
            if let inner = try? PropertyListSerialization.propertyList(from: data, format: nil) { return flatten(inner) }
            return String(decoding: data, as: UTF8.self)
        default: return "\(value)"
        }
    }

    static func isBackedUp(_ a: Aerial) -> Bool {
        FileManager.default.fileExists(atPath: backupDir.appendingPathComponent("\(a.id).mov").path)
    }

    /// IDs of every Aerial that currently has a clip of ours in it.
    static func swappedIDs() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: backupDir.path)) ?? []
        return files.filter { $0.hasSuffix(".mov") }.map { String($0.dropLast(4)) }
    }

    static func apply(slot: Aerial, video: URL, thumbnail: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        if !isBackedUp(slot) {
            // Only ever back up Apple's original, never one of our clips.
            try fm.copyItem(at: slot.thumbnail, to: backupDir.appendingPathComponent("\(slot.id).png"))
            try fm.copyItem(at: slot.video, to: backupDir.appendingPathComponent("\(slot.id).mov"))
        }
        try overwrite(slot.video, with: video)
        if fm.fileExists(atPath: thumbnail.path) { try overwrite(slot.thumbnail, with: thumbnail) }
        restartWallpaper()
    }

    static func restore() throws {
        for id in swappedIDs() {
            let a = Aerial(id: id, name: id)
            let mov = backupDir.appendingPathComponent("\(id).mov")
            let png = backupDir.appendingPathComponent("\(id).png")
            try overwrite(a.video, with: mov)
            if FileManager.default.fileExists(atPath: png.path) {
                try overwrite(a.thumbnail, with: png)
                try FileManager.default.removeItem(at: png)
            }
            try FileManager.default.removeItem(at: mov)
        }
        restartWallpaper()
    }

    /// Swaps in a fresh copy of `source`. Copying next to the target and renaming means the
    /// target is never half-written, and Apple's download tags (LastETag) don't carry over onto our clip.
    static func overwrite(_ target: URL, with source: URL) throws {
        let fm = FileManager.default
        let tmp = target.deletingLastPathComponent().appendingPathComponent(".looppaper-\(UUID().uuidString).tmp")
        try fm.copyItem(at: source, to: tmp)
        if source.path.hasPrefix(AppPaths.library.path) {
            // Our clips get no extended attributes; Apple's backed-up originals keep theirs.
            removexattr(tmp.path, "com.apple.quarantine", 0)
        }
        do {
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            guard rename(tmp.path, target.path) == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: target.path])
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    /// macOS restarts these on its own and reloads the videos when it does.
    /// On macOS 26 a swapped Aerial shows black on the lock screen after a lock or wake
    /// unless the wallpaper process is restarted, so the app calls this on those events too.
    static func restartWallpaper() {
        for name in ["WallpaperAerialsExtension", "WallpaperAgent"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            p.arguments = [name]
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
    }
}
