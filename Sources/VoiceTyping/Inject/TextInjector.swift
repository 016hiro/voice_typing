import AppKit
import Carbon.HIToolbox

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
