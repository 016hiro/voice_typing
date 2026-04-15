import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {

    private let state: AppState
    private var window: NSWindow?

    init(state: AppState) {
        self.state = state
    }

    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView(state: state, onClose: { [weak self] in
            self?.window?.close()
        })

        let host = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: host)
        w.title = "LLM Refinement Settings"
        w.styleMask = [.titled, .closable]
        w.setContentSize(NSSize(width: 520, height: 320))
        w.isReleasedWhenClosed = false
        w.center()

        self.window = w
        w.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

private struct SettingsView: View {
    @ObservedObject var state: AppState

    @State private var baseURL: String = ""
    @State private var apiKey: String = ""
    @State private var model: String = ""
    @State private var showAPIKey: Bool = false
    @State private var testStatus: TestStatus = .idle

    let onClose: () -> Void

    enum TestStatus: Equatable {
        case idle
        case running
        case ok(String)
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("LLM Refinement")
                .font(.title3).bold()

            Text("Post-process transcriptions with an OpenAI-compatible chat API. Used only to fix obvious speech-recognition errors; your text is not rewritten.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                LabeledContent("API Base URL") {
                    TextField("https://api.openai.com/v1", text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("API Key") {
                    HStack(spacing: 6) {
                        Group {
                            if showAPIKey {
                                TextField("sk-…", text: $apiKey)
                            } else {
                                SecureField("sk-…", text: $apiKey)
                            }
                        }
                        .textFieldStyle(.roundedBorder)

                        Button {
                            showAPIKey.toggle()
                        } label: {
                            Image(systemName: showAPIKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(showAPIKey ? "Hide API key" : "Show API key")

                        Button {
                            apiKey = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .help("Clear API key")
                        .disabled(apiKey.isEmpty)
                    }
                }
                LabeledContent("Model") {
                    TextField("gpt-4o-mini", text: $model)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                testStatusView
                Spacer()
                Button("Test") { runTest() }
                    .disabled(!canTest || testStatus == .running)
                Button("Save") { save() }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
                Button("Close") { onClose() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 300)
        .onAppear { loadCurrent() }
    }

    private var testStatusView: some View {
        Group {
            switch testStatus {
            case .idle:
                Text("")
            case .running:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Testing…").foregroundStyle(.secondary)
                }
            case .ok(let reply):
                Label("OK — \(reply.prefix(40))", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .lineLimit(1)
            case .failed(let msg):
                Label("Failed — \(msg)", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
        .font(.caption)
    }

    private var canTest: Bool {
        !baseURL.trimmingCharacters(in: .whitespaces).isEmpty &&
        !apiKey.trimmingCharacters(in: .whitespaces).isEmpty &&
        !model.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func loadCurrent() {
        baseURL = state.llmConfig.baseURL
        apiKey  = state.llmConfig.apiKey
        model   = state.llmConfig.model
    }

    private func save() {
        var cfg = state.llmConfig
        cfg.baseURL = baseURL.trimmingCharacters(in: .whitespaces)
        cfg.apiKey  = apiKey
        cfg.model   = model.trimmingCharacters(in: .whitespaces)
        state.llmConfig = cfg
        onClose()
    }

    private func runTest() {
        testStatus = .running
        var cfg = state.llmConfig
        cfg.baseURL = baseURL
        cfg.apiKey  = apiKey
        cfg.model   = model
        cfg.enabled = true
        let refiner = LLMRefiner()
        Task {
            let result = await refiner.test(config: cfg)
            await MainActor.run {
                switch result {
                case .ok(let reply):
                    testStatus = .ok(reply.trimmingCharacters(in: .whitespacesAndNewlines))
                case .failed(let msg):
                    testStatus = .failed(msg)
                }
            }
        }
    }
}
