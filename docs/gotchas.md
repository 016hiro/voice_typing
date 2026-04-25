# Gotchas

本文档记录**非显而易见**的坑、反直觉行为、踩过的雷。每条短小精干，给出触发条件和规避方法。来源：12 版 devlog 提炼。

## macOS / TCC / 签名

- **ad-hoc 签名每次 rebuild 重置 TCC**：`codesign --sign -` 每次产生新 cdhash → macOS 把 .app 当新 app → Microphone + Accessibility 授权丢失。规避：`make setup-cert` 一次性创建本地自签名身份，`make build` 自动用它，cdhash 跨重建稳定。(v0.1.0, v0.4.1)

- **Carbon Text Services API 必须主线程**：`TISCopyCurrentKeyboardInputSource` 等 Carbon 调用内部有 `dispatch_assert_queue` 检查，子线程跑会 SIGTRAP。规避：包装函数加 `@MainActor` 或显式跳到 main queue 再调。(v0.1.0)

- **LSUIElement / `.accessory` app 丢 ⌘A/⌘C/⌘V**：没有 main menu 的 app 不进 AppKit 默认 responder chain。规避：自定义 `performKeyEquivalent` 拦截 → `NSApp.sendAction(_:to:from:)` 手动转发。(v0.3.2)

- **NSVisualEffectView 不吃 `cornerRadius + masksToBounds`**：blur 材质渲染绕开 layer cornerRadius。规避：用 `effect.maskImage` + 9-slice 圆角 capsule 图（Apple 官方推荐路径）。(v0.1.0)

- **SwiftPM `.executableTarget` 不给嵌入 framework 加 rpath**：`swift build -c release` 产出的可执行文件 `LC_RPATH` 只有 `/usr/lib/swift`、`@loader_path`、Xcode toolchain 三条——**没有** `@executable_path/../Frameworks`。把第三方 framework（如 Sparkle）放进 `Contents/Frameworks/` 后，dyld 启动时按 rpath 找不到，应用 SIGABRT crash 在启动前（"Library not loaded: @rpath/X.framework/..."）。规避：`make build` 跑 `install_name_tool -add_rpath "@executable_path/../Frameworks" $(BIN)`，幂等（先 `otool -l` grep 检查）。(v0.6.0)

- **Hardened runtime + 自签名证书 = library validation 拒所有 framework**：`codesign --options runtime` 启用后，dyld 要求加载的 framework 与 host 共享 Apple Team ID；自签名 / ad-hoc 签名的 Team ID 都是空 → 验证策略 fall back 到更严，连同 cert 签的自家 framework 也被拒。错误形式："code signature in '...' (...) "。规避：app entitlements 加 `com.apple.security.cs.disable-library-validation`。等真上 Apple Developer ID + notarize 时这条可以删（Team ID 验证天然通过）。(v0.6.0)

- **`make build` 嵌入 metallib 失败只 warn 不 fail → release 静默打出残废 DMG**：`make build` 的 metallib 嵌入步骤是软失败（dev 没装 Metal Toolchain 时还要能继续 iterate），结果 `make release` 在 metallib 缺失下还是会成功打出 DMG——只是少了 100MB Metal kernel，Qwen ASR runtime SIGABRT。规避：`make dmg` 在打包前 hard-check `$(PAYLOAD)/Contents/MacOS/mlx.metallib` 存在，不在直接 exit 1。触发场景：`swift package clean` / 第一次 setup / SwiftPM 拉新 dep 把 `.build/release/mlx.metallib` 一起清掉。(v0.6.0.1)

## Swift / SwiftUI / Concurrency

- **SourceKit 索引经常假阳性报 "Cannot find type X in scope"**：编辑后保存触发 indexing race，错误能持续几秒到几十秒。规避：跑 `swift build`，build 干净就忽略 IDE 红线。本项目尤其多发于 `DebugCapture` / `LiveTranscriber` 这类新增类型。

- **SwiftUI Picker 绑 computed property 必须手写 `Binding`**：`@Published` 才有 `$` 投影；computed 没有。规避：`Picker(selection: Binding(get:set:))` 内联包一层（参考 v0.5.2 `transcriptionTiming` 用法）。(v0.5.2)

- **闭包 type inference 偶尔挂在 `.map { x in ... }`**：复杂泛型上下文里 Swift 推不出闭包参数类型。规避：`if let x = optional { ... }` 改写，或显式 `(Type) -> ReturnType in` 标注。(v0.5.1)

- **`@Sendable` closure 在三元运算里 type inference 失败**：`let x: T? = cond ? { ... } : nil` 触发 "failed to produce diagnostic" 编译器 bug。规避：拆成 `if cond { let observer: T = { ... }; x = observer } else { x = nil }`。(v0.5.3)

- **`ISO8601DateFormatter` 不是 Sendable 但事实上线程安全**：Apple 文档说 thread-safe，类没标 Sendable，Swift 6 strict concurrency 报错。规避：`nonisolated(unsafe) static let formatter = ...`。同类问题不适用 `JSONEncoder`（它本身 Sendable，加 `nonisolated(unsafe)` 反而 warning）。(v0.5.3)

## ASR backend specifics

- **MLX 缺 metallib 直接 abort 不抛 Swift error**：`MLX.loadArrays` 找不到 `mlx.metallib` 触发 C++ `std::runtime_error`，绕开 Swift 错误处理直接 SIGABRT。规避：`MLXSupport.isAvailable` 在调任何 MLX API 前先 file-existence preflight，不可用就 graceful 降级到 Whisper backend。(v0.2.0)

- **`Qwen3ASRModel.fromPretrained(cacheDir:)` 要的是终态目录不是 base**：参数名叫 `cacheDir` 但实际期待 `/models/<modelId>` 完整路径，库内会反推 download base。传 `/models/` 会静默 model-not-found。(v0.2.0)

- **WhisperKit `modelFolder` vs `downloadBase` 语义反了**：`modelFolder` 期待"已下载好的模型目录"，`downloadBase` 才是"我要下载到这个根"。前者会让库以为模型缺失。(v0.1.0)

- **WhisperKit prompt 从 string 改成 token array**：`DecodingOptions.prompt` 老版本是 String，新版变 `promptTokens: [Int]?`。规避：`pipe.tokenizer?.encode()` + 过滤 `>= specialTokenBegin` 的 token。(v0.3.0)

- **Whisper feature extractor 空/超短 buffer 索引越界**：< 400 samples（< 25ms @ 16kHz）会 crash on `audio[max(0, -1)]`。规避：调用前 guard `audio.count >= 400`，三层防御（v0.3.0 落地）；upstream `soniqo/speech-swift` 待报 issue。(v0.3.0)

- **`speech-swift` StreamingASR closure 是同步而非真流式**：构造时闭包同步 fire，AsyncThrowingStream 返回时段已经全填好，"流式" UI 是假象。规避：v0.4.2 自己用 `Task.detached` + per-segment loop 重做；v0.5.0 起走 `LiveTranscriber` 自家实现。(v0.4.2)

- **HuggingFaceDownloader `offlineMode: false` 永远跑 HEAD check**：即使本地全有，仍发 ETag verify request → 加 3-7s 启动延迟。规避：本地 file-existence 检查（`ModelStore.isComplete`）通过后传 `offlineMode: true`。(v0.5.1)

## VAD / 转写质量

- **Silero VAD 默认参数为低延迟流式调，不是转写质量调**：`(0.25s speech, 0.10s silence)` 切出来切到词中间，丢上下文。规避：转写场景用 `minSpeechDuration: 0.3` + `minSilenceDuration: 0.7`（v0.4.5 拍板）。(v0.4.5)

- **Qwen3-ASR 短/弱音频会吐训练集尾巴 + 回显 prompt**：常见幻觉 `"谢谢观看"` / `"Thank you."` / `"Yeah."`，或者把 glossary context 整段 echo 回来。规避：`HallucinationFilter` 静态黑名单 + substring containment 检测，不只关键字匹配。(v0.4.5)

- **`AsyncStream` 是单消费者**：v0.5.3 hands-free 在 non-live timing 下需要 VAD watchdog 同时消费 `AudioCapture.samples`，但 `startLiveTranscriberIfEnabled` 默认会 drain 同一 stream → 两个消费者抢，watchdog 拿不到 chunks。规避：给 `startLiveTranscriberIfEnabled` 加 `drainIfNotLive: Bool` 参数，watchdog 路径下传 false 自己接管 drain。(v0.5.3)

- **DebugCaptureWriter `meta.json` 直到 finalize 才写**：v0.5.1 设计漏 — crash / force-quit / early bail 路径让 `meta.json` 永远缺席。dogfood 303 sessions 只有 12% 完整率。规避：v0.5.3 起 init() 末尾 enqueue partial meta 写入，finalize/abort 复用同一 `writeMeta()` update endedAt + totals。(v0.5.3)

- **`encoder.dateEncodingStrategy = .iso8601` 默认无 fractional seconds**：写出来 `2026-04-23T19:13:19Z` 秒级精度，跨毫秒 delta 全报 0ms（live_drain.py 全失效）。规避：用 `.custom { ... ISO8601DateFormatter([.withInternetDateTime, .withFractionalSeconds]) ... }`。(v0.5.3)

## 构建 / 资源 bundle

- **WhisperKit CoreML 模型大小约 2× 原始 checkpoint**：~1.5GB 原始 weights → ~3GB 编译后（AudioEncoder 1.2GB + TextDecoder 1.5GB）。下载进度估算需要按编译后 size，不然中途 cancel 看起来是失败。(v0.1.0)

- **`make build` 必须把 `mlx.metallib` 拷到 `Contents/MacOS/`**：MLX 通过 `Bundle.main.executableURL` 同目录找，不是 Resources。Test bundle 同理（test 进程的 executableURL 是 xctest，不是 .app），E2E 测试要手动 stage 到 `TEST_BUNDLE_MACOS/mlx.metallib`，Makefile 已自动化。(v0.2.0, v0.4.3)

- **Silero VAD 不 bundle 会触发首次启动 hang**：`SileroVADModel.fromPretrained()` 离线时找不到模型 → HuggingFace request → 用户首次按 Fn 卡死。规避：Resources 内嵌 1.2MB 模型，`make build` 自动拷进 `Contents/Resources/SileroVAD/`。(v0.4.4)
