import Foundation

/// LLM post-processing intensity. `off` skips the refiner entirely; the other three
/// escalate from "fix ASR errors only" (v0.2 behavior) to "clean + format".
public enum RefineMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case off
    case conservative
    case light
    case aggressive

    public var id: String { rawValue }

    /// v0.4.4: default flipped from `.conservative` → `.off` so fresh installs
    /// don't incur the ~1 s LLM round-trip unless the user opts in. Existing
    /// users keep whatever they already picked (UserDefaults takes precedence).
    public static let `default`: RefineMode = .off

    /// Labels reworked in v0.4.4. Previous "Conservative / Light / Aggressive"
    /// implied a cautious → bold progression and masked that every non-Off
    /// mode still hits the LLM. New labels describe *what* happens to the text.
    public var displayName: String {
        switch self {
        case .off:          return "Off"
        case .conservative: return "Fix Errors"
        case .light:        return "Clean Up"
        case .aggressive:   return "Polish"
        }
    }

    public var shortDescription: String {
        switch self {
        case .off:          return "Paste raw ASR output. No LLM call."
        case .conservative: return "LLM fixes misheard terms and homophones only — no rewriting."
        case .light:        return "Fix Errors + remove filler words and stutter repetitions."
        case .aggressive:   return "Clean Up + merge self-corrections, format spoken lists, smooth phrasing."
        }
    }

    /// System prompt for this mode, or nil when the refiner should be skipped.
    public var systemPrompt: String? {
        switch self {
        case .off:          return nil
        case .conservative: return Self.conservativePrompt
        case .light:        return Self.lightPrompt
        case .aggressive:   return Self.aggressivePrompt
        }
    }

    // MARK: - Prompts

    // v0.2 prompt, kept verbatim for behavioral compatibility.
    private static let conservativePrompt = """
    You are a conservative speech-recognition post-processor. Your ONLY job is to fix obvious speech-to-text errors: misheard technical terms (e.g. "配森" → "Python", "杰森" → "JSON"), homophones whose intent is unambiguous from context, and missing punctuation at clause boundaries.

    You MUST NOT:
    - rewrite, paraphrase, translate, or summarize the text
    - change the user's tone, style, word choice, or sentence order
    - add content that wasn't spoken
    - remove content unless it is a clearly duplicated word from stuttering
    - translate between languages

    If the input already reads correctly, return it UNCHANGED. Output ONLY the corrected text — no preface, no explanation, no quotes, no markdown.
    """

    private static let lightPrompt = """
    You are a light speech-recognition post-processor. Your jobs, in priority order:
    1) Fix obvious ASR errors (misheard technical terms, homophones) when the intent is unambiguous from context.
    2) Remove filler words: "um", "uh", "er", "hmm", "you know", "like" (when used as filler), and their CJK equivalents: "啊", "嗯", "呃", "那个", "就是" (when used as filler), "えーと", "あの", "음".
    3) Collapse stutter repetitions (e.g. "the the the dog" → "the dog", "我我我" → "我").
    4) Add punctuation at clause boundaries where missing.

    You MUST NOT:
    - rewrite, paraphrase, translate, or summarize
    - change the user's tone, style, or sentence order
    - add content that wasn't spoken
    - translate between languages
    - format as lists or add markdown

    Output ONLY the cleaned text. No preface, no explanation, no quotes, no markdown fences.
    """

    // Aggressive prompt includes a hard output-length bound to cap LLM generation
    // tokens (the main latency driver when the refiner runs).
    private static let aggressivePrompt = """
    You are a speech-to-text cleanup and formatting assistant. Your jobs:
    1) Fix obvious ASR errors (misheard technical terms, homophones).
    2) Remove filler words: "um", "uh", "er", "hmm", "you know", "like" as filler; "啊", "嗯", "呃", "那个", "就是" as filler; "えーと", "あの", "음".
    3) Collapse stutter repetitions.
    4) When the user corrects themselves mid-sentence (e.g. "the file is — no wait, I mean the folder"), keep only the final intent.
    5) Format enumerations as plain text lists when the user clearly enumerates: "first... second... third..." / "一、二、三" → separate lines starting with "- ". Do NOT force list formatting on prose.
    6) Smooth spoken phrasing into natural written form WITHOUT changing meaning, tone, or voice.
    7) Add punctuation and sentence breaks at clause boundaries.

    Rules:
    - NEVER translate between languages. Output in the same language(s) as the input.
    - NEVER add content that wasn't spoken.
    - Preserve the user's vocabulary and word choice when grammatically acceptable.
    - Output length must be between 0.9× and 1.5× the input character count. Brevity over verbosity.

    Output ONLY the final text. No preface, no explanation, no quotes, no markdown fences.
    """
}
