import Foundation
import os

enum Log {
    static let subsystem = "com.voicetyping.app"

    /// v0.4.4: flipped by Settings → Advanced → "Developer logging". When on,
    /// `Log.dev(...)` call sites emit at `.notice` (visible in `log stream`
    /// without `--level info`); when off they no-op. AppState mirrors this to
    /// UserDefaults so the preference persists across launches.
    nonisolated(unsafe) static var devMode: Bool = UserDefaults.standard.bool(forKey: "developerMode")

    static let app     = Logger(subsystem: subsystem, category: "app")
    static let hotkey  = Logger(subsystem: subsystem, category: "hotkey")
    static let audio   = Logger(subsystem: subsystem, category: "audio")
    static let asr     = Logger(subsystem: subsystem, category: "asr")
    static let inject  = Logger(subsystem: subsystem, category: "inject")
    static let llm     = Logger(subsystem: subsystem, category: "llm")
    static let ui      = Logger(subsystem: subsystem, category: "ui")

    /// Emit a verbose diagnostic line iff Developer logging is on. The
    /// autoclosure defers string building so the cost is zero when the flag
    /// is off. Use for init/setup/introspection logs that a normal user never
    /// needs to see (e.g. "Loading Silero VAD from …", "ASR bias: …").
    ///
    /// Note: `os.Logger` won't let us forward `OSLogMessage` values through a
    /// wrapper, so this helper flattens to `String` at the boundary and loses
    /// per-interpolation privacy markers. All fields go out as `.public`;
    /// check the call site when adding sensitive strings.
    static func dev(_ logger: Logger, _ message: @autoclosure () -> String) {
        guard devMode else { return }
        let s = message()
        logger.notice("\(s, privacy: .public)")
    }
}
