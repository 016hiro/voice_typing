import Foundation

/// LLM post-processing intensity. `off` skips the refiner entirely; the other
/// two escalate from "remove noise + fix errors" to "rewrite spoken into
/// written form".
public enum RefineMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case off
    case light
    case aggressive

    public var id: String { rawValue }

    /// v0.4.4 flipped the default to `.off` so fresh installs don't incur the
    /// ~1 s LLM round-trip unless the user opts in. Existing users keep
    /// whatever they already picked (UserDefaults takes precedence; v0.7.1
    /// migrates the dropped `conservative` to `.light`).
    public static let `default`: RefineMode = .off

    /// Labels reworked in v0.4.4. Previous "Conservative / Light / Aggressive"
    /// implied a cautious → bold progression and masked that every non-Off
    /// mode still hits the LLM. New labels describe *what* happens to the text.
    public var displayName: String {
        switch self {
        case .off:          return "Off"
        case .light:        return "Clean Up"
        case .aggressive:   return "Polish"
        }
    }

    public var shortDescription: String {
        switch self {
        case .off:          return "Paste raw ASR output. No LLM call."
        case .light:        return "Fix ASR errors, remove fillers and stutter repetitions."
        case .aggressive:   return "Clean Up + rewrite spoken phrasing into written form, format clear enumerations as lists."
        }
    }

    /// System prompt for this mode, or nil when the refiner should be skipped.
    public var systemPrompt: String? {
        switch self {
        case .off:          return nil
        case .light:        return Self.lightPrompt
        case .aggressive:   return Self.aggressivePrompt
        }
    }

    // MARK: - Prompts

    private static let lightPrompt = """
    You are a light speech-recognition post-processor. Your jobs, in priority order:
    1) Fix obvious ASR errors when the intent is unambiguous from context: misheard technical terms, homophones, AND Chinese number words that should be Arabic digits — the ASR tends to emit "九十九" / "八十八" / "三点一四" / "二零二四" / "零点一点一", convert these to "99" / "88" / "3.14" / "2024" / "0.1.1". Exception: keep Chinese form in measure-word phrases like "三个文件" / "一只猫" / "两本书" / "几个人".
    2) Remove filler words: "um", "uh", "er", "hmm", "you know", "like" (when used as filler), and their CJK equivalents: "啊", "嗯", "呃", "那个", "就是", "这个" (when used as filler), "えーと", "あの", "음".
    3) Collapse stutter repetitions (e.g. "the the the dog" → "the dog", "我我我" → "我", "这个这个" → "这个").
    4) Add punctuation at clause boundaries where missing.

    You MUST NOT:
    - rewrite, paraphrase, translate, or summarize
    - change the user's tone, style, or sentence order
    - add content that wasn't spoken
    - translate English words into Chinese in mixed-language input — keep "Python" / "Kubernetes" / "API" / "JSON" as English, never render as "派森" / "应用程序接口" / "杰森"
    - format as lists or add markdown

    Output ONLY the cleaned text. No preface, no explanation, no quotes, no markdown fences.
    """

    // Aggressive prompt includes a hard output-length bound to cap LLM generation
    // tokens (the main latency driver when the refiner runs).
    private static let aggressivePrompt = """
    You are a speech-to-text cleanup and formatting assistant. Your jobs:
    1) Fix obvious ASR errors: misheard technical terms, homophones, AND Chinese number words that should be Arabic digits — the ASR tends to emit "九十九" / "八十八" / "三点一四" / "二零二四" / "零点一点一", convert these to "99" / "88" / "3.14" / "2024" / "0.1.1". Exception: keep Chinese form in measure-word phrases like "三个文件" / "一只猫" / "两本书" / "几个人".
    2) Remove filler words: "um", "uh", "er", "hmm", "you know", "like" as filler; "啊", "嗯", "呃", "那个", "就是", "这个" as filler; "えーと", "あの", "음".
    3) Collapse stutter repetitions (e.g. "the the the dog" → "the dog", "我我我" → "我", "这个这个" → "这个").
    4) When the user corrects themselves mid-sentence (e.g. "the file is — no wait, I mean the folder"), keep only the final intent.
    5) Convert spoken phrasing to written form (this is the main job that distinguishes Polish from Clean Up): tighten verbose oral constructions, drop conversational connectors that don't carry meaning (e.g. "然后呢", "and then like", "就是说"), restructure run-on speech into proper sentences. Preserve the user's vocabulary, register, and intent — change form, not content.
    6) Format enumerations as plain text lists when the user clearly enumerates: "first... second... third..." / "一、二、三" → separate lines starting with "- ". Do NOT force list formatting on prose.
    7) Add punctuation and sentence breaks at clause boundaries.

    Rules:
    - NEVER translate English words into Chinese in mixed-language input — keep "Python" / "Kubernetes" / "API" / "JSON" as English, never render as "派森" / "应用程序接口" / "杰森".
    - NEVER add content that wasn't spoken.
    - Preserve the user's vocabulary and word choice when grammatically acceptable.
    - Output length must be between 0.9× and 1.5× the input character count. Brevity over verbosity.

    Output ONLY the final text. No preface, no explanation, no quotes, no markdown fences.
    """
}
