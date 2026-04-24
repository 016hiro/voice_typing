import Foundation

/// Formats dictionary entries into the three prompt shapes we inject:
/// 1. Qwen3-ASR `context` (natural language instructions in the system prompt slot).
/// 2. WhisperKit `DecodingOptions.prompt` (token-level bias, terse word list).
/// 3. LLM refiner system-prompt glossary (Markdown bullet list).
///
/// Each builder sorts by LRU recency, then greedy-fills up to the per-destination
/// token budget. Storage is unlimited (up to `CustomDictionary.softEntryCap`); what
/// gets injected depends entirely on budget.
enum GlossaryBuilder {

    /// Budget reserved for the Qwen `context` slot. The Qwen 3 chat template has
    /// plenty of headroom before its ~2048-token decoder limit, but keeping this
    /// tight reduces prompt processing latency and leaves room for audio tokens.
    static let qwenBudget = 460

    /// WhisperKit's `sampleLength` is 224 tokens which is also the hard prompt ceiling.
    /// We reserve headroom for the rest of the prefill so stay well under that.
    static let whisperBudget = 200

    /// LLM refiner can absorb a lot, but glossary bloat costs time and money.
    static let llmBudget = 1500

    // MARK: - Result

    struct InjectionReport {
        let injected: Int
        let total: Int
        let tokens: Int
        let budget: Int
    }

    // MARK: - Qwen context

    /// Produces the Qwen3-ASR `context` string. Format follows the only two shapes
    /// that appear in Alibaba's own examples:
    ///   - Chinese (zh-*): `热词：X、Y、Z。`
    ///   - Non-Chinese: bare comma list (matches `-c "Qwen-ASR, DashScope, FFmpeg"`
    ///     from the official toolkit).
    /// Pronunciation hints are deliberately NOT injected here — the `A→B` substitution
    /// pattern has zero precedent in training data; that rewriting belongs to the LLM
    /// refiner glossary, not the ASR context. Returns nil if the dictionary is empty.
    static func buildQwenContext(from entries: [DictionaryEntry],
                                 language: Language,
                                 budget: Int = qwenBudget) -> String? {
        let selected = greedyFill(entries, budget: budget, estimator: estimateQwenCost(for:))
        guard !selected.isEmpty else { return nil }

        let terms = selected.map(\.term)
        if language.isChinese {
            return "热词：\(terms.joined(separator: "、"))。"
        } else {
            return terms.joined(separator: ", ")
        }
    }

    static func qwenReport(from entries: [DictionaryEntry],
                           budget: Int = qwenBudget) -> InjectionReport {
        let selected = greedyFill(entries, budget: budget, estimator: estimateQwenCost(for:))
        let tokens = selected.reduce(0) { $0 + estimateQwenCost(for: $1) }
        return InjectionReport(injected: selected.count, total: entries.count, tokens: tokens, budget: budget)
    }

    // MARK: - ASR dispatch

    /// Returns the ASR-bias string for the given backend + language, or nil if the
    /// backend takes no bias or the dictionary is empty.
    static func buildForASR(_ backend: ASRBackend,
                            entries: [DictionaryEntry],
                            language: Language) -> String? {
        switch backend {
        case .whisperLargeV3:
            return buildWhisperPrompt(from: entries)
        case .qwenASR06B, .qwenASR17B:
            return buildQwenContext(from: entries, language: language)
        }
    }

    // MARK: - Whisper prompt

    /// Produces a terse space-separated term list. Ignores hints (Whisper's prompt
    /// is a token-bias, not a transformation rule).
    static func buildWhisperPrompt(from entries: [DictionaryEntry],
                                   budget: Int = whisperBudget) -> String? {
        let selected = greedyFill(entries, budget: budget, estimator: estimateWhisperCost(for:))
        guard !selected.isEmpty else { return nil }
        return selected.map(\.term).joined(separator: " ")
    }

    static func whisperReport(from entries: [DictionaryEntry],
                              budget: Int = whisperBudget) -> InjectionReport {
        let selected = greedyFill(entries, budget: budget, estimator: estimateWhisperCost(for:))
        let tokens = selected.reduce(0) { $0 + estimateWhisperCost(for: $1) }
        return InjectionReport(injected: selected.count, total: entries.count, tokens: tokens, budget: budget)
    }

    // MARK: - LLM glossary

    /// Produces a Markdown glossary to append after the RefineMode system prompt.
    /// Entries are split by shape so the LLM gets an unambiguous instruction for each:
    ///   - `term` only  → Preserve section (do not paraphrase).
    ///   - `term + hints` → Rewrite section (map each hint to the canonical term).
    /// Returns nil if the dictionary is empty.
    static func buildLLMGlossary(from entries: [DictionaryEntry],
                                 budget: Int = llmBudget) -> String? {
        let selected = greedyFill(entries, budget: budget, estimator: estimateLLMCost(for:))
        guard !selected.isEmpty else { return nil }

        let preserve = selected.filter { $0.pronunciationHints.isEmpty }
        let rewrite  = selected.filter { !$0.pronunciationHints.isEmpty }

        var lines: [String] = []
        lines.append("## User's Custom Vocabulary")

        if !preserve.isEmpty {
            lines.append("")
            lines.append("Preserve these exact spellings whenever they appear (do NOT paraphrase or translate):")
            for e in preserve {
                lines.append("- \(e.term)")
            }
        }

        if !rewrite.isEmpty {
            lines.append("")
            lines.append("Rewrite these user pronunciations to the canonical spelling on the right:")
            for e in rewrite {
                let hints = e.pronunciationHints.joined(separator: " / ")
                lines.append("- \(hints) → \(e.term)")
            }
        }

        return lines.joined(separator: "\n")
    }

    static func llmReport(from entries: [DictionaryEntry],
                          budget: Int = llmBudget) -> InjectionReport {
        let selected = greedyFill(entries, budget: budget, estimator: estimateLLMCost(for:))
        let tokens = selected.reduce(0) { $0 + estimateLLMCost(for: $1) }
        return InjectionReport(injected: selected.count, total: entries.count, tokens: tokens, budget: budget)
    }

    // MARK: - Match detection

    /// Returns the ids of entries whose `term` or any `pronunciationHints` appear
    /// in `text`. English terms require word boundaries; CJK / mixed terms use
    /// substring. Used to bump `lastMatchedAt` after ASR / LLM completes.
    static func matchedEntryIDs(in text: String, entries: [DictionaryEntry]) -> Set<UUID> {
        guard !text.isEmpty else { return [] }
        let lowered = text.lowercased()
        var hits: Set<UUID> = []
        for entry in entries {
            if entry.term.nilIfEmpty != nil, contains(term: entry.term, in: text, lowered: lowered) {
                hits.insert(entry.id)
                continue
            }
            for hint in entry.pronunciationHints where contains(term: hint, in: text, lowered: lowered) {
                hits.insert(entry.id)
                break
            }
        }
        return hits
    }

    private static func contains(term: String, in text: String, lowered: String) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // ASCII-only terms get word-boundary regex to avoid "Pythonic" matching "Python".
        let isASCII = trimmed.unicodeScalars.allSatisfy { $0.value < 0x80 }
        if isASCII {
            let escaped = NSRegularExpression.escapedPattern(for: trimmed)
            let pattern = "\\b\(escaped)\\b"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                return regex.firstMatch(in: text, options: [], range: range) != nil
            }
            return lowered.contains(trimmed.lowercased())
        }
        return text.contains(trimmed)
    }

    // MARK: - LRU + greedy fill

    private static func greedyFill(
        _ entries: [DictionaryEntry],
        budget: Int,
        estimator: (DictionaryEntry) -> Int
    ) -> [DictionaryEntry] {
        let sorted = entries
            .filter { $0.hasContent }
            .sorted { $0.recency > $1.recency }
        var acc: [DictionaryEntry] = []
        var used = 0
        for entry in sorted {
            let cost = estimator(entry)
            if used + cost > budget { continue }
            acc.append(entry)
            used += cost
        }
        return acc
    }

    // MARK: - Token estimation

    /// Rough token count using a char-weighted heuristic calibrated to BPE
    /// tokenizers: ~4 ASCII chars / token, ~1-2 CJK chars / token. Good enough
    /// for budgeting; we leave 10% headroom in the budget constants above.
    static func estimateTokens(_ s: String) -> Int {
        var total: Double = 0
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if v < 0x80 {
                total += 0.28
            } else if v < 0x2000 {
                total += 0.7
            } else if v < 0xAC00 {
                total += 1.0   // CJK Unified Ideographs, Hiragana, Katakana
            } else {
                total += 1.1   // Hangul syllables, rare CJK extensions
            }
        }
        return max(1, Int(total.rounded(.up)))
    }

    /// Per-entry cost in Qwen's terse `Terms: …` / `Pronunciations: …` formulation.
    private static func estimateQwenCost(for e: DictionaryEntry) -> Int {
        var total = estimateTokens(e.term) + 2 // ", Python"
        for hint in e.pronunciationHints {
            total += estimateTokens(hint) + estimateTokens(e.term) + 2 // ", 配森→Python"
        }
        return total
    }

    /// Per-entry cost as a single space-separated term.
    private static func estimateWhisperCost(for e: DictionaryEntry) -> Int {
        estimateTokens(e.term) + 1 // trailing space
    }

    /// Per-entry cost in the LLM Markdown glossary. Preserve-section entries are a
    /// bare `- Python` bullet. Rewrite-section entries expand to `- 配森 / 派森 → Python`.
    private static func estimateLLMCost(for e: DictionaryEntry) -> Int {
        if e.pronunciationHints.isEmpty {
            return estimateTokens(e.term) + 3 // "- Python"
        }
        let hintsLen = e.pronunciationHints.reduce(0) { $0 + estimateTokens($1) + 2 } // "/" separators
        return hintsLen + estimateTokens(e.term) + 4 // " → Python" + bullet
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
