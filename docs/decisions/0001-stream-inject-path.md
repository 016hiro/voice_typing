# ADR 0001 — Streaming refine inject path: Cmd+V incremental

**Status**: Accepted (2026-05-01)
**Context**: v0.7.0 #R1
**Supersedes**: —
**Superseded by**: —

## Context

v0.7.0 turns refine into a streaming UX — chunks arrive from the LLM and need to land in the focused app as they are produced, not all-at-once at the end. The existing `TextInjector` only does single-shot injection (snapshot pasteboard → set → Cmd+V → restore). Streaming requires either reusing that path per chunk or switching to a different OS-level injection primitive.

Three candidates were on the table:

1. **Cmd+V incremental** — reuse the existing pasteboard + Cmd+V path, looped per chunk
2. **CGEvent keystroke** — `CGEvent.keyboardSetUnicodeString` per chunk, no pasteboard
3. **NSAccessibility insertText** — set `kAXSelectedTextAttribute` on the focused element

Each has known concerns: Cmd+V pollutes the pasteboard, CGEvent is slow for CJK and may interact with IME, AX is unsupported in Terminal and many Electron apps. v0.7.0 design hinged on whether "all three are unusable in some app I care about" is true.

## Spike

A throwaway harness (`Sources/VoiceTyping/Spike/StreamInjectSpike.swift`, removed after the matrix) drove a fixed 200-char zh+en fixture in 5-char chunks at 50 ms intervals across the three methods × 7 target apps (TextEdit / Notes / Obsidian / VS Code / Cursor / Notion / Terminal; Slack out of scope per user, 微信 untestable due to client black screen).

Full matrix and per-app evidence in [`docs/spike/v0.7.0-inject.md`](../spike/v0.7.0-inject.md). The deciding case was Notion:

- **CGEvent** dropped 6+ characters at chunk boundaries — Notion's autocomplete / markdown heuristics ate `点观察:`, `\n2`, `\n3`, `示`, `\n微`. **Data loss.**
- **Cmd+V** delivered all 200 characters but inserted a blank Notion block between every paste and tripped `>` blockquote markdown on the `->` substring. **Lossless but ugly; user can Cmd-Z the whole thing.**
- **AX** produced empty output — Notion's editor doesn't honor `kAXSelectedTextAttribute`. **Doesn't work.**

In every other tested app the three methods behaved identically (✅) — the differentiator is what happens in the worst-case Electron / markdown-heavy target.

## Decision

**Cmd+V incremental is the v0.7.0 streaming inject path. CGEvent and AX are not implemented.**

Rationale:

1. **Lossless coverage** — Cmd+V is the only method that doesn't drop characters in any tested app. A streaming refine that silently loses words is worse than no streaming at all.
2. **No fallback earns its complexity** — CGEvent and AX both have *narrower* coverage than Cmd+V on its supported set (CGEvent fails Notion outright; AX fails Electron and Terminal). Neither would be a useful fallback because the apps where Cmd+V fails are also apps where they fail.
3. **Performance is fine** — Cmd+V hit ~12.5 ms/char wall clock, dominated by the inter-chunk sleep, not Cmd+V itself. LLM token cadence (30–80 ms/chunk) is the actual bottleneck.
4. **Pasteboard pollution is solvable** — snapshot once at stream start, restore once at stream end (not per chunk). User pressing Cmd+V mid-stream gets the latest chunk; acceptable.

### Notion handling

Cmd+V in Notion at 50 ms intervals creates one block per paste. Don't try to engineer around this — instead, **deny-list `notion.id` in `AppDelegate` → fall back to batch path** (await full refine string, single Cmd+V). Hardcoded, not user-facing. This is the only known target that needs special-casing.

## Consequences

**Positive**:
- `TextInjector` only needs one new entry point (`injectIncremental(stream:)` consuming `AsyncSequence<String>`); no method-selection plumbing.
- `LLMRefining.refineStream` protocol can ship without conditioning on inject capability.
- Existing single-shot `inject(_:)` stays intact for batch path / raw-first / Notion fallback.

**Negative**:
- Notion users see the streaming UX silently fall back to batch. Cosmetic, but undocumented from the user's perspective. v0.7.0 release notes should mention it.
- 微信 / Slack coverage is asserted from prior v0.5+ Cmd+V usage rather than fresh evidence. Verify during v0.7.0 dogfood; if 微信 regresses, re-enter the deny-list pattern.
- We're committing to "single inject primitive forever". If a future target app appears where Cmd+V fundamentally doesn't work (e.g. a future macOS sandboxing model), this ADR needs revisiting — not a per-app fallback added underneath.

**Neutral**:
- Pasteboard ownership held across the stream means users mid-stream Cmd+V get the in-flight chunk, not their original clipboard. Acceptable because the stream is short (1–3 s typical) and user expectation during a refine is "don't touch anything".

## Out of scope (will revisit later versions)

- IME bypass strategy under streaming — current plan is "switch to ASCII once at stream start, restore at end" (mirrors single-shot `TextInjector`). If CJK users dogfood and report composition glitches, this is the first place to look.
- Cursor / VS Code Cmd-Z chain behavior under chunked paste — user confirmed format is correct in dogfood, but R9 still has to verify Cmd-Z coalesces into one undo step rather than 40.
