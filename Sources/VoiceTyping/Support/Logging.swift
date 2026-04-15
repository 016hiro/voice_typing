import Foundation
import os

enum Log {
    static let subsystem = "com.voicetyping.app"
    static let app     = Logger(subsystem: subsystem, category: "app")
    static let hotkey  = Logger(subsystem: subsystem, category: "hotkey")
    static let audio   = Logger(subsystem: subsystem, category: "audio")
    static let asr     = Logger(subsystem: subsystem, category: "asr")
    static let inject  = Logger(subsystem: subsystem, category: "inject")
    static let llm     = Logger(subsystem: subsystem, category: "llm")
    static let ui      = Logger(subsystem: subsystem, category: "ui")
}
