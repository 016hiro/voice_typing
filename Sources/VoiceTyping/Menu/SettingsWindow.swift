import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Hashable {
    case models
    case llm

    var title: String {
        switch self {
        case .models: return "Models"
        case .llm:    return "LLM"
        }
    }
}

@MainActor
final class SettingsWindowController {

    private let state: AppState
    private var window: NSWindow?
    private let onRequestReloadBackend: (ASRBackend) -> Void

    init(state: AppState, onRequestReloadBackend: @escaping (ASRBackend) -> Void) {
        self.state = state
        self.onRequestReloadBackend = onRequestReloadBackend
    }

    func show(tab: SettingsTab = .models) {
        if let w = window {
            // If window exists, switch tab and bring to front.
            (w.contentViewController as? NSHostingController<SettingsView>)?.rootView.selectedTab = tab
            w.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView(
            state: state,
            selectedTab: tab,
            onClose: { [weak self] in
                self?.window?.close()
            },
            onRequestReloadBackend: onRequestReloadBackend
        )

        let host = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: host)
        w.title = "VoiceTyping Settings"
        w.styleMask = [.titled, .closable]
        w.setContentSize(NSSize(width: 580, height: 420))
        w.isReleasedWhenClosed = false
        w.center()

        self.window = w
        w.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

private struct SettingsView: View {
    @ObservedObject var state: AppState
    @State var selectedTab: SettingsTab
    let onClose: () -> Void
    let onRequestReloadBackend: (ASRBackend) -> Void

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selectedTab) {
                ModelsTab(state: state, onRequestReloadBackend: onRequestReloadBackend)
                    .tabItem { Label("Models", systemImage: "waveform") }
                    .tag(SettingsTab.models)

                LLMTab(state: state, onClose: onClose)
                    .tabItem { Label("LLM", systemImage: "sparkles") }
                    .tag(SettingsTab.llm)
            }
            .padding(16)

            Divider()

            HStack {
                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(minWidth: 560, minHeight: 400)
    }
}

// MARK: - Models tab

private struct ModelsTab: View {
    @ObservedObject var state: AppState
    let onRequestReloadBackend: (ASRBackend) -> Void

    @State private var pendingDelete: ASRBackend?
    @State private var downloadInFlight: Set<ASRBackend> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Speech Recognition Model")
                .font(.title3).bold()

            Text("Voice typing runs the selected model locally on Apple Silicon. Switch freely — downloads are cached and kept until you delete them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(ASRBackend.allCases) { backend in
                    ModelRow(
                        backend: backend,
                        state: state,
                        isDownloading: downloadInFlight.contains(backend),
                        onSelect: {
                            onRequestReloadBackend(backend)
                        },
                        onDelete: {
                            pendingDelete = backend
                        }
                    )
                    .id(state.modelInventoryTick) // force refresh when inventory changes
                    if backend != ASRBackend.allCases.last {
                        Divider()
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
            )

            Spacer()

            Text("Models are stored under `~/Library/Application Support/VoiceTyping/models/`.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .alert("Delete \(pendingDelete?.displayName ?? "") files?",
               isPresented: .init(
                   get: { pendingDelete != nil },
                   set: { if !$0 { pendingDelete = nil } }
               ),
               presenting: pendingDelete) { backend in
            Button("Delete", role: .destructive) {
                performDelete(backend)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: { backend in
            if backend == state.asrBackend {
                Text("This is the currently active model. Deleting will unload it and you'll need to switch to another model or re-download to use voice typing.")
            } else {
                Text("\(backend.estimatedSizeLabel) of weights will be removed. You can re-download later.")
            }
        }
    }

    private func performDelete(_ backend: ASRBackend) {
        do {
            try ModelStore.delete(backend)
            Log.app.info("Deleted model files for \(backend.rawValue, privacy: .public)")
            if backend == state.asrBackend {
                // Reloading will hit .failed or .loading immediately; user can then pick another.
                onRequestReloadBackend(backend)
            }
            state.modelInventoryTick &+= 1
        } catch {
            Log.app.error("Delete failed for \(backend.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

private struct ModelRow: View {
    let backend: ASRBackend
    @ObservedObject var state: AppState
    let isDownloading: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(backend.displayName).bold()
                    if backend == state.asrBackend {
                        Text("ACTIVE")
                            .font(.caption2).bold()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.18))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                    }
                }
                Text(statusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if backend == state.asrBackend, case let .loading(p) = state.recognizerState, p >= 0 {
                ProgressView(value: p)
                    .frame(width: 80)
            }

            Button(actionLabel) {
                onSelect()
            }
            .disabled(backend == state.asrBackend && stateIsActive)

            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(!ModelStore.isDownloaded(backend))
            .help(ModelStore.isDownloaded(backend) ? "Delete files" : "Not downloaded")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var stateIsActive: Bool {
        if case .ready = state.recognizerState { return true }
        return false
    }

    private var statusLabel: String {
        if backend == state.asrBackend {
            switch state.recognizerState {
            case .ready:
                return "Active · \(sizeOrEstimate())"
            case .loading(let p):
                if p < 0 { return "Loading…" }
                return String(format: "Downloading %d%%", Int(p * 100))
            case .failed(let err):
                return "Failed — \(err.localizedDescription)"
            case .unloaded:
                return "Preparing…"
            }
        }
        if ModelStore.isDownloaded(backend) {
            return "Downloaded · \(sizeOrEstimate())"
        }
        return "Not downloaded · \(backend.estimatedSizeLabel) to download"
    }

    private var actionLabel: String {
        if backend == state.asrBackend {
            return "Active"
        }
        return ModelStore.isDownloaded(backend) ? "Switch" : "Download & Switch"
    }

    private func sizeOrEstimate() -> String {
        let onDisk = ModelStore.sizeOnDisk(backend)
        if onDisk > 1_000_000 {
            return onDisk.humanReadableBytes
        }
        return backend.estimatedSizeLabel
    }
}

// MARK: - LLM tab

private struct LLMTab: View {
    @ObservedObject var state: AppState
    let onClose: () -> Void

    @State private var baseURL: String = ""
    @State private var apiKey: String = ""
    @State private var model: String = ""
    @State private var showAPIKey: Bool = false
    @State private var testStatus: TestStatus = .idle

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
            }
        }
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
