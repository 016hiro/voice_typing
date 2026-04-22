# Conventions

## 代码风格

- **Swift 6.0+**，开启 strict concurrency。`@MainActor` / `Sendable` 标注严格执行
- **不引入额外 formatter / linter** — 信任 Xcode 默认 4-space 缩进 + Swift 编译器警告
- **doc comment 写"为什么"不写"是什么"**：函数/字段名已经表达 what，`///` 留给约束、历史、踩坑、上下游契约
- `// MARK: -` 分段标注大文件内部结构（参考 `AppState.swift`、`SettingsWindow.swift`）
- 日志走 `Log.app.info/.error` / `Log.dev.info`（dev 通道由 `state.developerMode` 控制是否显式打印）
- subsystem 固定 `com.voicetyping.app`，filter：`log stream --predicate 'subsystem == "com.voicetyping.app"' --style compact`

## 命名

- **类型**：`UpperCamelCase`（`AppState`, `LiveTranscriber`, `TranscriptionTiming`）
- **方法 / 属性 / 变量**：`lowerCamelCase`
- **enum case**：`lowerCamelCase`（`.oneshot`, `.postrecord`, `.live`）
- **文件名 = 主类型名**：`AppState.swift` 装 `AppState`；扩展用 `+` 后缀（`AppDelegate+Live.swift`）
- **测试文件**：`<被测主体>Tests.swift`（`ModelStoreTests.swift`, `AppStateTranscriptionTimingTests.swift`）
- **test 方法**：`testFoo_When_Then` 风格或 `testFooDoesBar`，描述行为非实现
- **分支**：直接在 `main` 上推（小型项目，无 PR 强制流程；CI 在 push 时跑 swift build）
- **UserDefaults key**：`lowerCamelCase`（`streamingEnabled`, `liveStreamingEnabled`, `debugCaptureEnabled`）

## 提交信息

格式：`vX.Y.Z 主题：副标题`（中英混排可），跨多块时用 `+` 串联。

- **正常版本主线**：`v0.5.1 perf instrument + dl_init fix + Debug capture toggle + UX 补丁`
- **同版本后续修补**：`v0.5.0 fixup: live mode segment-level incremental injection`
- **planning / 文档**：`v0.5.2 planning: scope doc + roadmap v0.5.3 / v0.6.0 themes` 或 `v0.5.1 docs: devlog + ...`
- **CI / 工具链**：小写前缀 `ci: switch to macos-15 ...`
- 不强制 Conventional Commits；可读性优先
- **不要** skip git hooks（无 `--no-verify`）；hook 失败修根因不绕开

## 测试

- **分层**：Unit（`Tests/VoiceTypingTests/Unit/`）/ E2E（`Tests/VoiceTypingTests/E2E/`，跑真模型 + 真音频 fixture）
- **运行**：
  - `make test` — 仅 unit，CI 也跑这个，无需模型
  - `make test-e2e` — unit + E2E，需要 Qwen 模型已下载到 `~/Library/Application Support/VoiceTyping/models/` + `make setup-metal` 完成
  - `make benchmark-vad` / `make benchmark-speed` — E2E 子集 benchmark（不进 CI）
- **测试类约定**：`@MainActor final class XxxTests: XCTestCase`（如果触碰 AppState / UI）
- **UserDefaults 隔离**：测试触碰 `UserDefaults.standard` 时，`setUp` snapshot + `tearDown` restore（参考 `AppStateTranscriptionTimingTests`）
- **Fixture path**：通过 env `VT_FIXTURE_ROOT` 注入，避免 hardcode；E2E 跑前自动 setup（见 Makefile `test-e2e` target）
- **覆盖率目标**：无硬指标；新功能至少有一个 happy path test，回归坑必须有 regression test
