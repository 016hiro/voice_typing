import Foundation

/// A single user-curated vocabulary entry. The `term` is the canonical spelling
/// injected into ASR context and LLM glossary. `pronunciationHints` are alternate
/// ways the user might say it; they bias the ASR and help the LLM recognize
/// variants. `note` is a UI-only free text comment (never injected into prompts).
///
/// `lastMatchedAt` tracks when this entry was last observed in ASR or LLM output
/// (for LRU ordering at injection time). Absent → fall back to `createdAt`.
public struct DictionaryEntry: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var term: String
    public var pronunciationHints: [String]
    public var note: String?
    public var createdAt: Date
    public var lastMatchedAt: Date?

    public init(
        id: UUID = UUID(),
        term: String,
        pronunciationHints: [String] = [],
        note: String? = nil,
        createdAt: Date = Date(),
        lastMatchedAt: Date? = nil
    ) {
        self.id = id
        self.term = term
        self.pronunciationHints = pronunciationHints
        self.note = note
        self.createdAt = createdAt
        self.lastMatchedAt = lastMatchedAt
    }

    /// Ranking key for LRU ordering. Newer wins.
    var recency: Date {
        lastMatchedAt ?? createdAt
    }

    /// Case-insensitive dedup key for save-time uniqueness checks.
    var dedupKey: String {
        term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// True if the user-visible content (term / hints / note) is non-empty.
    var hasContent: Bool {
        !term.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
