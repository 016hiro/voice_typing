import Foundation

/// v0.8.0 #S1 — pre-LLM gate that decides whether a live-mode ASR segment
/// can bypass the refiner entirely.
///
/// **Motivation**: v0.7.3 #B1 telemetry showed ~50% of inline local refines
/// are no-ops (`input == output`) yet each pays ~1.7 s wall-clock. Filtering
/// these out pre-LLM is pure latency win — the bottleneck question is
/// "filter them without losing the cases where refine actually fixes
/// something." Variant C below is the rule heuristic tuned offline on 303
/// real refines (`Scripts/analysis/skip_refine_replay.py`) at 95.7%
/// precision; the two hotword guards close the remaining "naked short
/// hotword" failure mode that the rule alone misses.
///
/// **Layered design**:
///
///   - **Variant C rule heuristic**: skip iff length < 40 AND none of the
///     8 block conditions fire (filler / stutter / number / code-switch /
///     ASCII-adjacent fullwidth punct, both ZH and EN flavors).
///   - **Layer 1 hotword substring guard**: if the rule would skip, check
///     whether the input substring-contains a hotword `term` or any
///     `pronunciationHint`. Cheap, exact, zero new code — reuses
///     `GlossaryBuilder.matchedEntryIDs`. Catches `Cloud Code` (`Claude
///     Code` hint), `EtoE` (`e2e` hint), etc.
///   - **Layer 2 hotword phonetic guard**: if the rule would skip AND
///     Layer 1 doesn't, run `PhoneticMatcher` (NLTokenizer + per-char
///     pinyin via `CFStringTransform` + Levenshtein with d/L ≤ 0.3).
///     Catches mishearings the user **never enumerated** as hints
///     (`曲文` → `Qwen` even though `pronunciationHints=[]`).
///
/// **Symmetry note**: the design is asymmetric on purpose — FN (skip
/// lost → wasted 1.7 s refine) is acceptable; FP (refine lost → user sees
/// uncleaned mishearing) is not. Both hotword guards are biased toward
/// "when in doubt, refine."
enum RefineSkipHeuristic {

    /// Telemetry label written into `RefineRecord.gate`. Single string
    /// because it has to survive JSON round-trip in `refines.jsonl` and
    /// stay greppable by the offline replay scripts.
    enum Gate: String, Codable, Sendable {
        /// Variant C rule said skip AND no hotword guard blocked it.
        /// Caller bypasses refine entirely.
        case skipped

        /// Variant C rule fired (length / filler / stutter / number /
        /// code-switch / punct guard). Refine runs.
        case rule

        /// Variant C would skip but Layer 1 substring guard saw a hotword
        /// term or hint in the input. Refine runs.
        case hotwordSubstring = "hotword_substring"

        /// Variant C would skip, Layer 1 didn't fire, Layer 2 phonetic
        /// guard caught a fuzzy hotword match. Refine runs.
        case hotwordPhonetic = "hotword_phonetic"
    }

    struct Decision: Equatable, Sendable {
        let gate: Gate
        /// Set only when `gate == .hotwordPhonetic`. Carried in logs to
        /// monitor Layer 2 FPs ("which input phrase did the matcher think
        /// looked like which hotword?").
        let phoneticHit: PhoneticMatcher.Hit?

        var shouldSkipRefine: Bool { gate == .skipped }
    }

    /// Threshold above which Variant C unconditionally lets refine run
    /// regardless of all the other conditions. 40 chars came from the
    /// offline replay's sweep: 40 → 200 only moves recall 32% → 33% so the
    /// extra range buys nothing but FP risk. Kept as a `let` constant
    /// rather than a parameter — tuning lives in the offline tool.
    static let lengthThreshold: Int = 40

    static func evaluate(input: String,
                         entries: [DictionaryEntry]) -> Decision {
        // Step 1: variant C rule. If a rule fires → refine.
        if !passesRuleHeuristic(input) {
            return Decision(gate: .rule, phoneticHit: nil)
        }
        // Step 2: Layer 1 substring guard (free — reuses LRU match path).
        if !GlossaryBuilder.matchedEntryIDs(in: input, entries: entries).isEmpty {
            return Decision(gate: .hotwordSubstring, phoneticHit: nil)
        }
        // Step 3: Layer 2 phonetic guard. Only runs when prior layers say
        // "would skip" — bounded work even on the worst dictionary.
        if let hit = PhoneticMatcher.match(input: input, entries: entries) {
            return Decision(gate: .hotwordPhonetic, phoneticHit: hit)
        }
        return Decision(gate: .skipped, phoneticHit: nil)
    }

    // MARK: - Variant C rule

    /// `true` iff every Variant C block condition is clear — caller is
    /// free to skip refine unless a downstream hotword guard fires.
    /// Same predicates as `Scripts/analysis/skip_refine_replay.py`'s
    /// `s1_predict_skip` at length threshold 40.
    static func passesRuleHeuristic(_ raw: String) -> Bool {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.isEmpty { return true }                     // empty → nothing to refine
        if input.count >= lengthThreshold { return false }

        if containsZHFiller(input) { return false }
        if zhStutterRegex.firstMatch(in: input) != nil { return false }
        if zhNumberRegex.firstMatch(in: input) != nil { return false }
        if codeSwitchRegex.firstMatch(in: input) != nil { return false }
        if punctEngRegex.firstMatch(in: input) != nil { return false }
        // English regexes need case-insensitive matching; we set the flag
        // on the precompiled NSRegularExpression below.
        if enFillerRegex.firstMatch(in: input) != nil { return false }
        if enStutterRegex.firstMatch(in: input) != nil { return false }
        return true
    }

    // MARK: - Variant C rule predicates

    /// Chinese-language filler tokens. Anchored substring search (not
    /// regex) for cheapness; `那个`/`这个`/`就是` are common and these are
    /// fast contains() calls. Mirrors the Python list exactly.
    private static let zhFillers: [String] = [
        "啊", "嗯", "呃", "唉", "哦", "嘛", "呢",
        "那个", "就是", "这个",
    ]

    private static func containsZHFiller(_ s: String) -> Bool {
        for f in zhFillers where s.contains(f) { return true }
        return false
    }

    /// `\b(?:um+|uh+|er+|hmm+|like|you know|kinda|sorta|basically|literally|i mean)\b`
    private static let enFillerRegex = compile(
        #"\b(?:um+|uh+|er+|hmm+|like|you\s+know|kinda|sorta|basically|literally|i\s+mean)\b"#,
        options: [.caseInsensitive])

    /// `(.{1,2})\1` — any 1- or 2-character repetition. Catches `嗯嗯`,
    /// `这个 这个`, `什么什么`. Wide net but the punct/codeswitch guards
    /// catch the obvious FPs.
    private static let zhStutterRegex = compile(#"(.{1,2})\1"#)

    /// `\b(\w+)\s+\1\b` — word repetition with whitespace between (`I I`,
    /// `the the`). Case-insensitive.
    private static let enStutterRegex = compile(
        #"\b(\w+)\s+\1\b"#, options: [.caseInsensitive])

    /// ≥2 consecutive Chinese number/decimal chars. Refining number reads
    /// is one of the LLM's main wins (`一百二十三 → 123`).
    private static let zhNumberRegex = compile(
        #"[零一二三四五六七八九十百千万亿点]{2,}"#)

    /// Unspaced CJK↔Latin transition. The LLM usually wants a space here
    /// (`使用Qwen → 使用 Qwen`). Bi-directional. Literal CJK range chars
    /// (U+4E00–U+9FFF) — NSRegularExpression / ICU doesn't accept Swift's
    /// `\u{...}` escape inside character classes.
    private static let codeSwitchRegex = compile(
        #"[一-鿿][A-Za-z]|[A-Za-z][一-鿿]"#)

    /// Fullwidth Chinese sentence punctuation immediately adjacent to ASCII
    /// alphanumerics. The dual of v0.7.3 #B2's ASCII-. rule — when the user
    /// dictates English next to CJK punct, refine should normalize.
    private static let punctEngRegex = compile(
        #"[A-Za-z0-9][。？！]|[。？！][A-Za-z0-9]"#)

    // MARK: - Regex helpers

    /// Force-compile static regexes. Patterns are constants written above;
    /// failure here is a programmer error, not a runtime condition.
    private static func compile(_ pattern: String,
                                options: NSRegularExpression.Options = []) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            preconditionFailure("RefineSkipHeuristic: bad regex \(pattern) — \(error)")
        }
    }
}

private extension NSRegularExpression {
    /// Convenience for the rule predicates above — runs `firstMatch` over
    /// the whole string with an `NSRange` derived from `String.utf16`.
    func firstMatch(in text: String) -> NSTextCheckingResult? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return firstMatch(in: text, options: [], range: range)
    }
}
