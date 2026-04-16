import AppKit
import AVFoundation
import ApplicationServices

enum Permissions {
    // MARK: - Accessibility

    /// Returns true if the process is trusted. If `prompt` is true and not trusted,
    /// the system shows the "open System Settings" dialog.
    @discardableResult
    static func checkAccessibility(prompt: Bool) -> Bool {
        // kAXTrustedCheckOptionPrompt is a Carbon CFStringRef constant whose value is
        // documented as "AXTrustedCheckOptionPrompt"; we hardcode it to sidestep the
        // strict-concurrency diagnostic on the extern var.
        let options: [String: Any] = ["AXTrustedCheckOptionPrompt": prompt]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Microphone

    static func microphoneAuthorized() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestMicrophone() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
    }

    static func openMicrophoneSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }
}
