import Foundation

/// Persists the user's custom dictionary to a JSON file under Application Support.
/// Using a plain JSON file (not UserDefaults) lets import/export share the storage
/// format, lets power users edit the file directly, and keeps iCloud Drive as a
/// future no-code migration path.
///
/// Writes are debounced to avoid fsync per keystroke and per-matched-term update
/// during heavy dictation sessions.
@MainActor
final class CustomDictionary {

    /// Soft cap to prevent runaway growth. Real constraint is per-backend token
    /// budget at injection time, not this number.
    static let softEntryCap = 500

    private let fileURL: URL
    private var flushWorkItem: DispatchWorkItem?
    private let flushDelay: TimeInterval = 5.0

    /// Current in-memory state. Callers should not mutate directly; use the
    /// mutating methods so persistence stays in sync.
    private(set) var entries: [DictionaryEntry] = []

    init(fileURL: URL = CustomDictionary.defaultFileURL) {
        self.fileURL = fileURL
        self.entries = Self.loadFromDisk(at: fileURL)
    }

    /// `~/Library/Application Support/VoiceTyping/dictionary.json`
    static var defaultFileURL: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("VoiceTyping", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("dictionary.json", isDirectory: false)
    }

    // MARK: - Mutations

    /// Adds or replaces an entry. Dedup is case-insensitive on term.
    /// Returns true on success, false if soft cap is exceeded.
    @discardableResult
    func upsert(_ entry: DictionaryEntry) -> Bool {
        var e = entry
        e.term = e.term.trimmingCharacters(in: .whitespacesAndNewlines)
        e.pronunciationHints = e.pronunciationHints
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        e.note = e.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        if e.note?.isEmpty == true { e.note = nil }

        guard e.hasContent else { return false }

        if let idx = entries.firstIndex(where: { $0.id == e.id }) {
            entries[idx] = e
        } else if let idx = entries.firstIndex(where: { $0.dedupKey == e.dedupKey }) {
            // Preserve existing id / createdAt when dedup-merging a brand-new draft.
            var merged = e
            merged.id = entries[idx].id
            merged.createdAt = entries[idx].createdAt
            merged.lastMatchedAt = entries[idx].lastMatchedAt
            entries[idx] = merged
        } else {
            if entries.count >= Self.softEntryCap { return false }
            entries.append(e)
        }
        scheduleFlush()
        return true
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        scheduleFlush()
    }

    func replaceAll(_ newEntries: [DictionaryEntry]) {
        entries = Array(newEntries.prefix(Self.softEntryCap))
        scheduleFlush()
    }

    /// Bumps `lastMatchedAt` for each matched id. No-op if `ids` is empty.
    func updateLastMatched(ids: Set<UUID>, at date: Date = Date()) {
        guard !ids.isEmpty else { return }
        var changed = false
        for i in entries.indices where ids.contains(entries[i].id) {
            entries[i].lastMatchedAt = date
            changed = true
        }
        if changed {
            scheduleFlush()
        }
    }

    // MARK: - Persistence

    private struct DiskLayout: Codable {
        var version: Int
        var entries: [DictionaryEntry]
    }

    private func scheduleFlush() {
        flushWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flushNow()
        }
        flushWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + flushDelay, execute: work)
    }

    /// Write current state synchronously. Call on quit to guarantee durability.
    func flushNow() {
        flushWorkItem?.cancel()
        flushWorkItem = nil
        let layout = DiskLayout(version: 1, entries: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(layout)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.app.error("Dictionary flush failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func loadFromDisk(at url: URL) -> [DictionaryEntry] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let layout = try decoder.decode(DiskLayout.self, from: data)
            return layout.entries
        } catch {
            // Preserve the broken file for user inspection; start fresh.
            let ts = Int(Date().timeIntervalSince1970)
            let broken = url.deletingPathExtension().appendingPathExtension("corrupted-\(ts).json")
            try? fm.moveItem(at: url, to: broken)
            Log.app.error("Dictionary JSON corrupted, renamed to \(broken.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    // MARK: - Import / Export

    /// Returns pretty-printed JSON of the current state (same format as on-disk).
    func exportJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let layout = DiskLayout(version: 1, entries: entries)
        return try encoder.encode(layout)
    }

    /// Loads entries from JSON data (same format as exportJSON) and replaces state.
    /// Merges by dedup key: imported entry wins, but keeps existing id / createdAt.
    func importJSON(_ data: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let layout = try decoder.decode(DiskLayout.self, from: data)
        for entry in layout.entries {
            _ = upsert(entry)
        }
        flushNow()
    }
}
