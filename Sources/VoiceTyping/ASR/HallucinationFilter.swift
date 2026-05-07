import Foundation

/// Drops VAD segments whose ASR output looks like a hallucination, not real speech.
/// Two failure modes seen in v0.4.2-v0.4.4 streaming + the v0.4.5 tuning benchmark:
///
/// - **Type A — training-data tails**: on near-silent or noisy short segments, Qwen /
///   Whisper fall back to high-frequency terminators from their training corpora
///   (`谢谢观看`, `Thank you.`, `♪`, `好的`, ...). Caught by a small static blacklist.
///
/// - **Type B — system-prompt echo**: Qwen3-ASR sometimes regurgitates the
///   `<|im_start|>system` slot we use for dictionary biasing. With dictionary
///   `["Rust", "Python", ...]` the user observed segments like
///   `"热词：Rust、Python、Qwen3-ASR、VAD、E2E。"` on noisy short inputs. Caught
///   by comparing the segment against the actual `context` we passed in.
public enum HallucinationFilter {

    /// v0.7.3 #B6: which layer dropped this segment. `nil` = kept.
    /// Recorded in `segments.jsonl.filterReason` so dogfood analysis can
    /// see *why* — the previous binary `kept`/`hallucinationFiltered` flag
    /// hid which layer was producing the false-positive of the moment.
    public enum FilterReason: String, Sendable, Codable {
        /// Layer 1 — segment matches a known training-data tail (`谢谢观看`,
        /// `Thank you.`, `♪`, …).
        case blacklist
        /// Layer 2a — segment starts with `热词：` / `热词:`, the deterministic
        /// Chinese signal of bias-prompt echo.
        case promptEchoChinesePrefix
        /// Layer 2b — `normalized.contains(normalizedCtx)` — segment fully
        /// reproduces the bias context (English bare-comma form, or zh form
        /// that Qwen mangled past the `^热词` fast-path).
        case promptEchoSubstring
    }

    /// Returns the reason this segment should be discarded, or `nil` if it
    /// should pass through.
    public static func classify(segment: String, context: String?) -> FilterReason? {
        let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Layer 1: known training tails. Compare on normalized form so
        // `"Yeah."`, `"yeah"`, and `"YEAH!"` all match the same entry.
        let normalized = normalize(trimmed)
        if blacklistNormalized.contains(normalized) { return .blacklist }

        // Layer 2a: deterministic Chinese prompt-echo signal. A real human
        // dictating into an input method does not start with `热词：` — that
        // string only appears as the prefix of our own bias context.
        if trimmed.hasPrefix("热词:") || trimmed.hasPrefix("热词：") {
            return .promptEchoChinesePrefix
        }

        // Layer 2b: prompt-echo via segment containing the full context
        // (English bare-comma form, or zh form that Qwen mangled past the
        // `^热词` fast-path). v0.7.3 dropped the inverse direction
        // (`normalizedCtx.contains(normalized)`): with hotwords like "Rust"
        // / "Qwen" / "VAD" in the dict, single-word user utterances
        // normalize to a 4-5 char string that the long context trivially
        // contains, falsely flagging legitimate one-word dictation as
        // echo. The remaining direction still catches the actual failure
        // mode — Qwen regurgitating the *whole* hotword list as one
        // segment.
        guard let raw = context?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        let normalizedCtx = normalize(raw)
        // Guard against pathological short contexts: a 1-term dictionary
        // ("Linus") would normalize to 5 chars and the substring test
        // would fire on any segment that quotes the term. Require enough
        // context that overlap genuinely indicates echo, not coincidence.
        guard normalizedCtx.count >= 12 else { return nil }

        if normalized.contains(normalizedCtx) {
            return .promptEchoSubstring
        }

        return nil
    }

    /// Bool wrapper for callsites that don't care which layer fired.
    /// Matches the v0.4.5+ public API; new code should prefer `classify`.
    public static func isLikelyHallucination(segment: String, context: String?) -> Bool {
        return classify(segment: segment, context: context) != nil
    }

    // MARK: - Static blacklist

    /// Training-data tail strings we see Qwen / Whisper produce on near-silent
    /// or non-speech segments. Stored as lowercased + raw form for human
    /// review; the actual lookup uses the normalized variants below.
    ///
    /// Curation rules:
    /// - Each entry is a complete utterance the model has been observed to
    ///   produce as the SOLE output of a segment with no real speech in it.
    /// - We drop the segment when the *whole* segment matches an entry, not
    ///   when an entry appears as a substring — `"Thank you for the help"`
    ///   from a real dictation must survive even though `"Thank you."` is
    ///   blacklisted.
    private static let blacklistRaw: [String] = [
        // Chinese — YouTube subtitle / closed-caption training pollution
        "谢谢观看",
        "谢谢大家观看",
        "明镜与点点栏目",
        "字幕由 Amara.org 社区提供",
        "字幕由志愿者翻译",
        // Chinese — minimal acknowledgements the model uses when audio is too short
        "好的",
        "嗯",
        "对",
        "啊",
        "谢谢",
        "好",
        // English — generic close-out hallucinations
        "Thank you.",
        "Thank you very much.",
        "Thanks.",
        "Thanks for watching.",
        "Thanks for watching!",
        "Yeah.",
        "Yes.",
        "OK.",
        "Okay.",
        "Mhm.",
        "Uh-huh.",
        // Non-speech token tails (music sting, applause stub)
        "♪",
        "♪♪",
        "♪♪♪",
        "(music)",
        "(applause)",
        "[music]",
        "[applause]"
    ]

    private static let blacklistNormalized: Set<String> = {
        Set(blacklistRaw.map { normalize($0) })
    }()

    // MARK: - Normalization

    /// Lowercases and strips whitespace + Unicode punctuation. The same shape
    /// as the test-side `normaliseForDiff` so segment / context comparison
    /// behaves consistently with the benchmark's similarity scoring.
    static func normalize(_ s: String) -> String {
        let lower = s.lowercased()
        var out = String.UnicodeScalarView()
        let drop = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        for scalar in lower.unicodeScalars where !drop.contains(scalar) {
            out.append(scalar)
        }
        return String(out)
    }
}
