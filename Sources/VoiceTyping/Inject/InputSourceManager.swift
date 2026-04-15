import Foundation
import Carbon.HIToolbox

final class InputSourceManager {

    enum Error: Swift.Error {
        case noASCIISource
        case selectFailed(OSStatus)
    }

    static let shared = InputSourceManager()

    // MARK: - Queries

    func currentSource() -> TISInputSource? {
        TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
    }

    func sourceID(_ src: TISInputSource) -> String {
        guard let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { return "" }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    func languages(_ src: TISInputSource) -> [String] {
        guard let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceLanguages) else { return [] }
        let cf = Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue()
        return (cf as? [String]) ?? []
    }

    /// A CJK input method (not a keyboard layout like ABC) — the kind that intercepts Cmd+V.
    func isCJKInputMethod(_ src: TISInputSource) -> Bool {
        let id = sourceID(src)
        let langs = languages(src)
        let cjkLangPrefixes = ["zh", "ja", "ko"]

        let idTriggers = [
            "Pinyin", "Chinese", "SCIM", "TCIM", "Zhuyin",
            "Japanese", "Kotoeri", "Kana",
            "Korean", "Hangul", "2SetKorean", "3SetKorean",
            "InputMethod"
        ]

        let idHit = idTriggers.contains { id.localizedCaseInsensitiveContains($0) }
        let langHit = langs.contains { lang in
            let prefix = String(lang.prefix(2))
            return cjkLangPrefixes.contains(prefix)
        }

        // ABC / US / Pinyin-Pro etc. that are pure keyboard layouts have id starting with com.apple.keylayout.*
        // Those are NOT CJK input methods — they don't intercept Cmd+V.
        if id.hasPrefix("com.apple.keylayout.") {
            return false
        }

        return idHit || langHit
    }

    // MARK: - Selection

    func selectASCII() throws {
        let preferredIDs = ["com.apple.keylayout.ABC", "com.apple.keylayout.US"]
        for id in preferredIDs {
            if let src = findSource(withID: id, onlyEnabled: true) ?? findSource(withID: id, onlyEnabled: false) {
                let status = TISSelectInputSource(src)
                if status == noErr { return }
            }
        }
        throw Error.noASCIISource
    }

    @discardableResult
    func restore(_ src: TISInputSource) -> Bool {
        TISSelectInputSource(src) == noErr
    }

    // MARK: - Private

    private func findSource(withID id: String, onlyEnabled: Bool) -> TISInputSource? {
        let includeAllInstalled: CFBoolean = onlyEnabled ? kCFBooleanFalse : kCFBooleanTrue
        let list = TISCreateInputSourceList(nil, CFBooleanGetValue(includeAllInstalled))?.takeRetainedValue() as? [TISInputSource]
        guard let list else { return nil }
        for src in list where sourceID(src) == id {
            return src
        }
        return nil
    }
}
