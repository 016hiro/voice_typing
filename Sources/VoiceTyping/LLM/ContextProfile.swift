import Foundation

/// A per-application hotword scope. When the frontmost app at
/// `stopRecording` time matches `bundleID`, the effective hotword set for that
/// recording is:
///
///   effective = (includeGlobal ? global : []) + entries
///
/// where `global` is the shared `CustomDictionary` and `entries` are this
/// app's private hotwords. Apps with no profile resolve to `global` only
/// (the defaults below reproduce that: `includeGlobal == true`, empty
/// `entries`).
///
/// See `docs/decisions/0005-per-app-independent-hotwords.md` for the model
/// (global shared baseline + per-app private additions) and why it superseded
/// the v0.8.0 whitelist (ADR-0004).
public struct ContextProfile: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var bundleID: String
    public var entries: [DictionaryEntry]
    public var includeGlobal: Bool
    public var enabled: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        bundleID: String,
        entries: [DictionaryEntry] = [],
        includeGlobal: Bool = true,
        enabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.bundleID = bundleID
        self.entries = entries
        self.includeGlobal = includeGlobal
        self.enabled = enabled
        self.createdAt = createdAt
    }

    /// Codable with backward compatibility for pre-release profiles.json:
    /// - v0.7.x `systemPromptSnippet` and pre-release v0.8.0 `dictionaryFilter`
    ///   are simply absent from CodingKeys → ignored on decode.
    /// - `entries` / `includeGlobal` are `decodeIfPresent` so older JSON
    ///   without them defaults to "no private entries, use global" — the
    ///   same as an unconfigured app.
    private enum CodingKeys: String, CodingKey {
        case id, name, bundleID, entries, includeGlobal, enabled, createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.bundleID = try c.decode(String.self, forKey: .bundleID)
        self.entries = try c.decodeIfPresent([DictionaryEntry].self, forKey: .entries) ?? []
        self.includeGlobal = try c.decodeIfPresent(Bool.self, forKey: .includeGlobal) ?? true
        self.enabled = try c.decode(Bool.self, forKey: .enabled)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
    }

    var hasContent: Bool {
        !bundleID.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Case-insensitive dedup key: bundle ID is the natural unique key,
    /// since it's what we match on.
    var dedupKey: String {
        bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Resolve the effective hotword set for this app. Centralized here so
    /// every pipeline call site that needs hotwords routes through one helper —
    /// ASR bias, refine glossary, and the #S1 skip-gate guard must all see the
    /// same list or hotword scope desyncs across consumers.
    public func effectiveEntries(global: [DictionaryEntry]) -> [DictionaryEntry] {
        (includeGlobal ? global : []) + entries
    }
}

/// Persists per-app context profiles to JSON under Application Support.
/// Mirrors `CustomDictionary`'s shape — debounced writes, corruption recovery,
/// import/export roundtrip. Kept main-actor isolated since callers are UI-bound
/// and pipeline reads happen on the main thread at `stopRecording`.
@MainActor
final class ContextProfileStore {

    /// Realistic upper bound for per-app profiles. Much lower than the dictionary
    /// cap — a user is unlikely to maintain distinct prompts for 100+ apps.
    static let softCap = 100

    private let fileURL: URL
    private var flushWorkItem: DispatchWorkItem?
    private let flushDelay: TimeInterval = 3.0

    private(set) var profiles: [ContextProfile] = []

    init(fileURL: URL = ContextProfileStore.defaultFileURL) {
        self.fileURL = fileURL
        self.profiles = Self.loadFromDisk(at: fileURL)
    }

    /// `~/Library/Application Support/VoiceTyping/profiles.json`
    static var defaultFileURL: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("VoiceTyping", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("profiles.json", isDirectory: false)
    }

    // MARK: - Lookup

    /// First enabled profile whose `bundleID` matches `bundleID`.
    /// Returns `nil` when nothing matches or when `bundleID` is nil/empty.
    ///
    /// Comparison is case-insensitive to mirror `dedupKey` and match Apple's
    /// convention: bundle identifiers are tokens, not strings with meaningful
    /// case. A JSON hand-edit that differs only in case still resolves.
    func lookup(bundleID: String?) -> ContextProfile? {
        guard let raw = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        let needle = raw.lowercased()
        return profiles.first { $0.enabled && $0.bundleID.lowercased() == needle }
    }

    // MARK: - Mutations

    /// Add or replace a profile. Dedup on `bundleID` is case-insensitive.
    @discardableResult
    func upsert(_ profile: ContextProfile) -> Bool {
        var p = profile
        p.name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
        p.bundleID = p.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)

        guard p.hasContent else { return false }

        if let idx = profiles.firstIndex(where: { $0.id == p.id }) {
            profiles[idx] = p
        } else if let idx = profiles.firstIndex(where: { $0.dedupKey == p.dedupKey }) {
            var merged = p
            merged.id = profiles[idx].id
            merged.createdAt = profiles[idx].createdAt
            profiles[idx] = merged
        } else {
            if profiles.count >= Self.softCap { return false }
            profiles.append(p)
        }
        scheduleFlush()
        return true
    }

    func remove(id: UUID) {
        profiles.removeAll { $0.id == id }
        scheduleFlush()
    }

    func replaceAll(_ newProfiles: [ContextProfile]) {
        profiles = Array(newProfiles.prefix(Self.softCap))
        scheduleFlush()
    }

    // MARK: - Persistence

    private struct DiskLayout: Codable {
        var version: Int
        var profiles: [ContextProfile]
    }

    private func scheduleFlush() {
        flushWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flushNow()
        }
        flushWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + flushDelay, execute: work)
    }

    func flushNow() {
        flushWorkItem?.cancel()
        flushWorkItem = nil
        let layout = DiskLayout(version: 1, profiles: profiles)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(layout)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.app.error("ContextProfile flush failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func loadFromDisk(at url: URL) -> [ContextProfile] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let layout = try decoder.decode(DiskLayout.self, from: data)
            return layout.profiles
        } catch {
            let ts = Int(Date().timeIntervalSince1970)
            let broken = url.deletingPathExtension().appendingPathExtension("corrupted-\(ts).json")
            try? fm.moveItem(at: url, to: broken)
            Log.app.error("Profiles JSON corrupted, renamed to \(broken.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    // MARK: - Import / Export

    func exportJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let layout = DiskLayout(version: 1, profiles: profiles)
        return try encoder.encode(layout)
    }

    func importJSON(_ data: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let layout = try decoder.decode(DiskLayout.self, from: data)
        for p in layout.profiles {
            _ = upsert(p)
        }
        flushNow()
    }
}
