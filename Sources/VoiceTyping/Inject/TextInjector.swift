import AppKit
import Carbon.HIToolbox

/// Outcome of a streaming inject call. `charsInjected` reflects what was
/// actually pasted into the focused app — a partial paste on cancellation
/// stays in the target app (we can't recall a Cmd+V), so the count tracks
/// reality rather than intent. Caller uses this for logging / latency
/// tracking. `cancelled` distinguishes user-driven Esc / focus loss from
/// a clean stream end. `streamError` is whatever the upstream `refineStream`
/// threw — `nil` on clean finish or cancellation.
struct InjectIncrementalResult {
    let charsInjected: Int
    let cancelled: Bool
    let streamError: Error?
}

@MainActor
final class TextInjector {

    private let ime = InputSourceManager.shared

    /// Injects `text` into whatever app is currently focused by writing to the
    /// general pasteboard and synthesizing a Cmd+V. CJK input methods that
    /// would intercept the paste shortcut are temporarily bypassed by switching
    /// to the ABC/US keyboard layout. The original pasteboard and input source
    /// are both restored afterwards.
    ///
    /// MUST run on the main thread — Carbon Text Input Services
    /// (TISCopyCurrentKeyboardInputSource etc.) trap if called off the main
    /// dispatch queue, and CGEvent.post is also main-thread sensitive.
    func inject(_ text: String) async {
        guard !text.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        let snapshot = Self.snapshot(pasteboard)

        var savedSource: TISInputSource?
        if let current = ime.currentSource(), ime.isCJKInputMethod(current) {
            savedSource = current
            do {
                try ime.selectASCII()
                try? await Task.sleep(nanoseconds: 30_000_000)
            } catch {
                Log.inject.warning("Could not switch to ASCII input source: \(String(describing: error), privacy: .public)")
            }
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        Self.simulateCmdV()

        try? await Task.sleep(nanoseconds: 80_000_000)

        if let saved = savedSource {
            ime.restore(saved)
        }

        Self.restore(pasteboard, from: snapshot)

        Log.inject.info("Injected \(text.count, privacy: .public) chars")
    }

    /// v0.7.0 #R5: streaming inject — consumes an `AsyncThrowingStream<String,
    /// Error>` from `LLMRefining.refineStream` and pastes chunks into the
    /// focused app at sentence / word boundaries. Pasteboard is snapshotted
    /// **once** at stream start and restored **once** at stream end (or
    /// cancel) — chunks share pasteboard ownership across the run, which is
    /// acceptable per ADR 0001 since user expectation during a refine is
    /// "don't touch the clipboard". IME bypass is also one-shot at start.
    ///
    /// **Flush boundaries** (whichever first):
    /// - chunk ends with punctuation / newline (sentence-ish boundary)
    /// - whitespace AND pending ≥ 8 chars (word boundary, 8 = "no half-words")
    /// - pending ≥ 32 chars (hard cap so the user always sees forward progress)
    ///
    /// Cancellation: caller cancels the wrapping Task; the in-loop
    /// `Task.checkCancellation()` propagates a `CancellationError` which
    /// short-circuits flush + bypasses the final-flush so a user's Esc
    /// doesn't paste a half-sentence buffer.
    func injectIncremental(stream: AsyncThrowingStream<String, Error>) async -> InjectIncrementalResult {
        let pasteboard = NSPasteboard.general
        let snapshot = Self.snapshot(pasteboard)

        var savedSource: TISInputSource?
        if let current = ime.currentSource(), ime.isCJKInputMethod(current) {
            savedSource = current
            do {
                try ime.selectASCII()
                try? await Task.sleep(nanoseconds: 30_000_000)
            } catch {
                Log.inject.warning("Could not switch to ASCII input source: \(String(describing: error), privacy: .public)")
            }
        }

        var pending = ""
        var charsInjected = 0
        var cancelled = false
        var streamError: Error?

        do {
            for try await chunk in stream {
                try Task.checkCancellation()
                pending += chunk
                if Self.shouldFlush(pending) {
                    let toFlush = pending
                    pending = ""
                    Self.writeAndPaste(toFlush, pasteboard: pasteboard)
                    charsInjected += toFlush.count
                    // Let the target app consume the Cmd+V before we overwrite
                    // the pasteboard with the next chunk. 50ms is conservative;
                    // dogfood spike measured ~12.5ms wall-clock per char so
                    // even a 32-char chunk lands well within this window.
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
        } catch is CancellationError {
            cancelled = true
        } catch {
            streamError = error
        }

        // Final flush — clean stream end or upstream error, but NOT user
        // cancel (don't paste a half-sentence the user just told us to drop).
        if !pending.isEmpty && !cancelled {
            Self.writeAndPaste(pending, pasteboard: pasteboard)
            charsInjected += pending.count
        }

        // Let the last Cmd+V settle before restoring the pasteboard, same as
        // single-shot `inject(_:)`.
        try? await Task.sleep(nanoseconds: 80_000_000)

        if let saved = savedSource {
            ime.restore(saved)
        }
        Self.restore(pasteboard, from: snapshot)

        Log.inject.info("Incremental injected \(charsInjected, privacy: .public) chars cancelled=\(cancelled, privacy: .public) errored=\(streamError != nil, privacy: .public)")
        return InjectIncrementalResult(charsInjected: charsInjected,
                                       cancelled: cancelled,
                                       streamError: streamError)
    }

    private static func writeAndPaste(_ text: String, pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        simulateCmdV()
    }

    /// Visible for testing — see `TextInjectorFlushBoundaryTests`. Pure
    /// function, no class state — `nonisolated` so tests can call it from
    /// any context without a MainActor hop.
    nonisolated static func shouldFlush(_ pending: String) -> Bool {
        guard let last = pending.last else { return false }
        // Sentence boundaries — both ASCII and CJK punctuation.
        let flushers: Set<Character> = [
            ",", ".", ";", ":", "!", "?", "\n",
            "，", "。", "；", "：", "！", "？"
        ]
        if flushers.contains(last) { return true }
        // Word boundary — whitespace AND enough buffered to not be a half-word.
        if last.isWhitespace && pending.count >= 8 { return true }
        // Hard cap — ensures forward progress on long strings without any
        // punctuation (rare for refined text, but defensive).
        if pending.count >= 32 { return true }
        return false
    }

    // MARK: - Cmd+V

    private static func simulateCmdV() {
        let vKey: CGKeyCode = 0x09 // kVK_ANSI_V
        let source = CGEventSource(stateID: .hidSystemState)

        if let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true) {
            down.flags = .maskCommand
            down.post(tap: .cghidEventTap)
        }
        usleep(20_000) // 20 ms
        if let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) {
            up.flags = .maskCommand
            up.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Pasteboard snapshot / restore

    private struct Snapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    private static func snapshot(_ pb: NSPasteboard) -> Snapshot {
        guard let items = pb.pasteboardItems else { return Snapshot(items: []) }
        let saved: [[NSPasteboard.PasteboardType: Data]] = items.map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type] = data
                }
            }
            return dict
        }
        return Snapshot(items: saved)
    }

    private static func restore(_ pb: NSPasteboard, from snapshot: Snapshot) {
        pb.clearContents()
        guard !snapshot.items.isEmpty else { return }
        let items: [NSPasteboardItem] = snapshot.items.map { dict in
            let item = NSPasteboardItem()
            for (type, data) in dict {
                item.setData(data, forType: type)
            }
            return item
        }
        pb.writeObjects(items)
    }
}
