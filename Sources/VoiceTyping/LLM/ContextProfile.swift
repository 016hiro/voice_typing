import Foundation

/// A per-application LLM refiner override. When the frontmost app at
/// `stopRecording` time matches `bundleID`, `systemPromptSnippet` is appended to
/// the mode's system prompt so the model can adapt its output style to the app
/// (casual for chat apps, code-flavored for editors, etc.).
///
/// Matching is exact on `bundleID`. Fancier patterns are out of scope for v0.3.1.
public struct ContextProfile: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var bundleID: String
    public var systemPromptSnippet: String
    public var enabled: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        bundleID: String,
        systemPromptSnippet: String,
        enabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.bundleID = bundleID
        self.systemPromptSnippet = systemPromptSnippet
        self.enabled = enabled
        self.createdAt = createdAt
    }

    var hasContent: Bool {
        !bundleID.trimmingCharacters(in: .whitespaces).isEmpty &&
        !systemPromptSnippet.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Case-insensitive dedup key: bundle ID is the natural unique key,
    /// since it's what we match on.
    var dedupKey: String {
        bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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

    /// First enabled profile whose `bundleID` matches `bundleID` exactly.
    /// Returns `nil` when nothing matches or when `bundleID` is nil/empty.
    func lookup(bundleID: String?) -> ContextProfile? {
        guard let bid = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bid.isEmpty else { return nil }
        return profiles.first { $0.enabled && $0.bundleID == bid }
    }

    // MARK: - Mutations

    /// Add or replace a profile. Dedup on `bundleID` is case-insensitive.
    @discardableResult
    func upsert(_ profile: ContextProfile) -> Bool {
        var p = profile
        p.name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
        p.bundleID = p.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        p.systemPromptSnippet = p.systemPromptSnippet.trimmingCharacters(in: .whitespacesAndNewlines)

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
