import Foundation

/// v0.5.1 Debug Data Capture — namespace for shared concerns between the
/// `DebugCaptureWriter` (per-session log producer) and Settings UI consumers
/// ("Open captures folder", "Clear all", "Auto-purge after"). The writer's
/// behavior decisions all trace back to the seven items in `todo/v0.5.1.md`
/// "Debug 数据捕获 toggle" — kept centralised here so the audit trail stays
/// readable.
enum DebugCapture {

    /// `~/Library/Application Support/VoiceTyping/debug-captures/`. Created
    /// lazily on first access; safe to call before the user opts in (no
    /// content is written until the toggle is on, but the directory's
    /// existence is benign).
    static var folderURL: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("VoiceTyping", isDirectory: true)
            .appendingPathComponent("debug-captures", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Removes every per-session subdirectory under `folderURL`. Used by the
    /// Settings → Advanced "Clear all captures" button. Returns the count of
    /// session directories deleted (caller can surface this for confirmation).
    @discardableResult
    static func clearAll() -> Int {
        let fm = FileManager.default
        let dir = folderURL
        let contents = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var removed = 0
        for url in contents {
            do {
                try fm.removeItem(at: url)
                removed += 1
            } catch {
                Log.app.warning("DebugCapture.clearAll: failed to remove \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return removed
    }

    /// Sum of bytes used by all session subdirectories. Used in Settings UI
    /// to give the user a sense of storage cost before they opt in.
    static func totalBytesOnDisk() -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: folderURL, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let v = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
               v.isRegularFile == true, let size = v.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// Allowed values for the "Auto-purge after" UI dropdown. 0 means
    /// never-purge, surfaced in the UI as "Never". Per the v0.5.1.md decision
    /// (#4): default 7, dropdown lets user pick 7 / 14 / 30 / never.
    static let retentionDayOptions: [Int] = [7, 14, 30, 0]

    static func retentionLabel(_ days: Int) -> String {
        days == 0 ? "Never" : "\(days) days"
    }

    // MARK: - Purge

    /// Per `todo/v0.5.1.md` decision #5: 5 GB hard ceiling, sweep oldest down
    /// to 80 % of cap (4 GB) on overflow.
    static let capacityCapBytes: Int64 = 5 * 1024 * 1024 * 1024
    static let capacityFloorBytes: Int64 = 4 * 1024 * 1024 * 1024

    /// Removes session subdirectories older than `days` (mtime-based). 0 days
    /// is treated as "never purge" — the user explicitly opted into long-term
    /// retention via Settings → Auto-purge after → Never. Returns the count
    /// of sessions deleted (caller can log).
    @discardableResult
    static func purgeOlderThan(days: Int, now: Date = Date(),
                                root: URL? = nil) -> Int {
        guard days > 0 else { return 0 }
        let dir = root ?? folderURL
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return purgeWhere(root: dir) { mtime, _ in mtime < cutoff }
    }

    /// If total bytes under `root` exceed `capacityCapBytes`, delete oldest
    /// session subdirs until total drops below `capacityFloorBytes`.
    /// Returns the count deleted.
    @discardableResult
    static func purgeIfOverCap(root: URL? = nil) -> Int {
        let dir = root ?? folderURL
        let fm = FileManager.default
        let entries = sessionsByMtimeAscending(in: dir)
        var totalBytes: Int64 = entries.reduce(0) { $0 + $1.bytes }
        guard totalBytes > capacityCapBytes else { return 0 }
        var removed = 0
        for entry in entries {  // oldest first
            guard totalBytes > capacityFloorBytes else { break }
            do {
                try fm.removeItem(at: entry.url)
                totalBytes -= entry.bytes
                removed += 1
            } catch {
                Log.app.warning("DebugCapture purge: failed to remove \(entry.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return removed
    }

    // MARK: - Purge helpers

    private struct SessionEntry {
        let url: URL
        let mtime: Date
        let bytes: Int64
    }

    private static func sessionsByMtimeAscending(in dir: URL) -> [SessionEntry] {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: dir,
                                                    includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey])) ?? []
        var entries: [SessionEntry] = []
        for url in contents {
            let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            guard v?.isDirectory == true, let mtime = v?.contentModificationDate else { continue }
            let bytes = directoryBytes(at: url)
            entries.append(SessionEntry(url: url, mtime: mtime, bytes: bytes))
        }
        entries.sort { $0.mtime < $1.mtime }
        return entries
    }

    @discardableResult
    private static func purgeWhere(root: URL, predicate: (Date, Int64) -> Bool) -> Int {
        let fm = FileManager.default
        let entries = sessionsByMtimeAscending(in: root)
        var removed = 0
        for entry in entries where predicate(entry.mtime, entry.bytes) {
            do {
                try fm.removeItem(at: entry.url)
                removed += 1
            } catch {
                Log.app.warning("DebugCapture purge: failed to remove \(entry.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return removed
    }

    private static func directoryBytes(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let v = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
               v.isRegularFile == true, let size = v.fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}
