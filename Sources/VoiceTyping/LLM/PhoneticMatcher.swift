import Foundation
import NaturalLanguage

/// v0.8.0 #S1 Layer 2 — fuzzy phonetic matcher used by `RefineSkipHeuristic`
/// to detect hotword mishearings the user never enumerated as
/// `pronunciationHints`.
///
/// Mirrors the Python prototype in `Scripts/analysis/hotword_phonetic_replay.py`
/// (which was tuned on 303 dogfood refines + 11 hand-built FP cases):
///
///   1. Tokenize input with `NLTokenizer(.word)` (Foundation built-in — for
///      Chinese it dispatches to ICU's word boundary analyzer, similar enough
///      to jieba for the cases that matter; cross-word false positives like
///      `之前应该` → `qianyin` are killed by word boundaries.)
///   2. Build candidate forms: 1-token + 2-gram + 3-gram concatenations.
///      Catches both single-word hotwords (`原文` → `yuanwen`) and split
///      compounds (`曲文` jieba-split to `["曲","文"]` joins back to `quwen`).
///   3. Normalize each candidate AND each hotword variant (term + hints) to
///      a toneless phonetic latin string:
///        - ASCII letter → lowercased
///        - ASCII digit  → kept (so `e2e`, `k8s`, `h264` survive)
///        - CJK char     → toneless pinyin via `CFStringTransform`
///        - everything else dropped
///   4. Require candidate form length ≥ 4 — single-char Chinese pinyin
///      (2-3 chars) gives a noise floor that spuriously matches short
///      English hotwords like `qwen`. 4 keeps real hits, kills the noise.
///   5. For each (candidate, variant): substring → exact match; else
///      Levenshtein distance / variant length ≤ 0.3.
///
/// Known Python-vs-Swift divergences (acceptable — get absorbed by the
/// 0.3 threshold):
///   - `CFStringTransform` strips ü→u; `pypinyin.lazy_pinyin` keeps ü. No
///     current hotword has a ü character so this never bites in practice.
///   - `NLTokenizer` and `jieba` disagree on rare Chinese segmentation edge
///     cases. The 2-/3-gram concat recovers compound matches across either
///     tokenizer's boundaries; only the very-long-input region (rarely
///     reached because Variant C length=40 dominates) would diverge, and
///     such inputs go to refine regardless.
enum PhoneticMatcher {

    /// Edit-distance / variant-length ratio cap. 0.3 means "Qwen"(4) tolerates
    /// 1 edit; "Claude" (6) tolerates 1; "Claude Code"(10 normalized 9)
    /// tolerates 2.
    static let defaultThreshold: Double = 0.3

    /// Candidate forms shorter than this are dropped. 4 was chosen by
    /// inspection of the dogfood replay: 3 admits a long tail of
    /// 一字-pinyin → short-english-hotword cross-talk that nobody asked for.
    static let minFormLen: Int = 4

    /// Max consecutive-token concat length when building candidates. 3 covers
    /// every observed split-compound case in the dogfood data.
    static let maxNgram: Int = 3

    /// Variants with normalized form below this length are not matched
    /// against at all. Stricter than `minFormLen` because variant side has
    /// no n-gram aggregation safety net.
    static let minVariantFormLen: Int = 3

    struct Hit: Equatable, Sendable {
        let term: String          // the hotword's canonical term
        let variant: String       // the term/hint that won (debug aid)
        let source: String        // the input substring that matched (debug aid)
        let distance: Int         // 0 for substring, else Levenshtein
    }

    /// Returns the first hit on any hotword, or nil. Order of `entries`
    /// determines tie-breaking but every nontrivial dictionary has only one
    /// reasonable match per input so it's deterministic in practice.
    static func match(input: String,
                      entries: [DictionaryEntry],
                      threshold: Double = defaultThreshold) -> Hit? {
        let candidates = buildCandidates(input)
        guard !candidates.isEmpty else { return nil }

        for entry in entries {
            let variants = [entry.term] + entry.pronunciationHints
            for variant in variants {
                let vForm = normalizeForm(variant)
                guard vForm.count >= minVariantFormLen else { continue }
                let L = vForm.count
                let allowed = threshold * Double(L)
                let allowedInt = Int(allowed)

                for cand in candidates {
                    if cand.form.contains(vForm) {
                        return Hit(term: entry.term,
                                   variant: variant,
                                   source: cand.source,
                                   distance: 0)
                    }
                    if abs(cand.form.count - L) > allowedInt { continue }
                    let d = levenshtein(cand.form, vForm)
                    if Double(d) <= allowed {
                        return Hit(term: entry.term,
                                   variant: variant,
                                   source: cand.source,
                                   distance: d)
                    }
                }
            }
        }
        return nil
    }

    // MARK: - Tokenize + candidate forms

    private struct Candidate {
        let form: String
        let source: String
    }

    private static func buildCandidates(_ text: String) -> [Candidate] {
        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return [] }

        var out: [Candidate] = []
        for n in 1...maxNgram {
            guard tokens.count >= n else { break }
            for i in 0...(tokens.count - n) {
                let source = tokens[i..<(i + n)].joined()
                let form = normalizeForm(source)
                if form.count >= minFormLen {
                    out.append(Candidate(form: form, source: source))
                }
            }
        }
        return out
    }

    static func tokenize(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var tokens: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let piece = String(text[range])
            if !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                tokens.append(piece)
            }
            return true
        }
        return tokens
    }

    // MARK: - Normalization

    /// CJK char → toneless pinyin via `CFStringTransform`. Per-character so
    /// each Hanzi syllable contributes its own pinyin run independent of
    /// surrounding context (matches `pypinyin.lazy_pinyin` semantics).
    private static func pinyin(of scalar: Unicode.Scalar) -> String {
        let s = NSMutableString(string: String(scalar))
        CFStringTransform(s, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(s, nil, kCFStringTransformStripDiacritics, false)
        return (s as String).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizeForm(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v < 0x80 {
                // ASCII fast path
                if (0x30...0x39).contains(v) {        // '0'-'9'
                    out.unicodeScalars.append(scalar)
                } else if (0x41...0x5A).contains(v) {  // 'A'-'Z' → lowercase
                    out.unicodeScalars.append(Unicode.Scalar(v + 0x20)!)
                } else if (0x61...0x7A).contains(v) {  // 'a'-'z'
                    out.unicodeScalars.append(scalar)
                }
                // other ASCII (punct/space) dropped
            } else if (0x4E00...0x9FFF).contains(v) {
                // CJK Unified Ideographs
                out += pinyin(of: scalar)
            }
            // everything else (latin-1 supplement diacritics, kana, hangul,
            // emoji, CJK extensions) dropped — same as the Python prototype
        }
        return out
    }

    // MARK: - Levenshtein

    /// Standard two-row DP. Operates on `Character` arrays so multi-scalar
    /// graphemes (unlikely here — input is pre-normalized ASCII pinyin) are
    /// handled uniformly.
    static func levenshtein(_ a: String, _ b: String) -> Int {
        if a == b { return 0 }
        let ac = Array(a)
        let bc = Array(b)
        if ac.isEmpty { return bc.count }
        if bc.isEmpty { return ac.count }

        // Make `s` the shorter so prev/cur stays small.
        let (s, t) = ac.count <= bc.count ? (ac, bc) : (bc, ac)
        var prev = Array(0...s.count)
        var cur = [Int](repeating: 0, count: s.count + 1)
        for i in 1...t.count {
            cur[0] = i
            let ti = t[i - 1]
            for j in 1...s.count {
                let cost = s[j - 1] == ti ? 0 : 1
                cur[j] = Swift.min(prev[j] + 1,
                                   cur[j - 1] + 1,
                                   prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[s.count]
    }
}
