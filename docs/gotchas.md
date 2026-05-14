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

- **Sparkle 自更新 + 自签证书：`--deep` 重签 Sparkle 的 helper 会让 IPC 拒连**：自签证书的 `TeamIdentifier=not set`。Sparkle 2 的 XPC 安全模型要求 Autoupdate / Updater.app / Downloader.xpc / Installer.xpc 跟宿主"要么共享 Apple Team ID，要么 ad-hoc"。我们的 `codesign --force --deep --sign "VoiceTyping Dev"` 把这 4 个 helper 全用自签证书重签了——夹在两条路中间，Sparkle 启动 Autoupdate 后内部 sandbox profile 拒它写 `~/Library/Caches/com.voicetyping.app/.../Installation`，user 看到 generic "An error occurred while running the updater"。规避：Makefile 先把 Sparkle 4 个 helper 用 `codesign --sign -`（真 ad-hoc）+ `--preserve-metadata=entitlements,runtime` 重签，**然后宿主签名时不能加 `--deep`**（会覆盖回去）。Sparkle.framework 本身（不是 helper 子组件）用 ad-hoc 也行，宿主 cert 也行——但其内部 4 个 binary 必须 ad-hoc。等真上 Apple Developer ID 时这条作废（Team ID 天然匹配，整体 `--deep` 重签 OK）。(v0.6.0.2)

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

- **MLX 权重闲置后被 unified-memory compressor 压成冷页**：v0.6.0 起的存量 bug——闲置 1-2 h 后 macOS 把 2.5 GB Qwen MLX 权重压成 ~80 MB 压缩段，下次按 Fn 等 9-30 s 解压（overnight 11 h 后 37-51 s）。v0.6.4 用 90 s 周期 dummy transcribe 没修干净（timer 自身就跑满 decoder budget 30-45 s），v0.7.1 加 App-Nap 抑制也不行。规避：v0.7.2 #B7 起 `WiredMemoryTicket(.active)` 把权重页钉在 GPU residency 集合里。**必须 `.active` 不能 `.reservation`**——后者 idle 时不 keep limit elevated（mlx-swift `Articles/wired-memory.md:28-30` 明确）。Ticket 永不 `end()`，unload model 时才释放。代价：1.5 GB unified memory 长期 reserved 给 ASR backend。决策见 [`decisions/0002-pin-mlx-weights-not-keep-alive.md`](decisions/0002-pin-mlx-weights-not-keep-alive.md)。(v0.7.2)

- **`MLX.Memory.cacheLimit` 默认按 Metal `recommendedMaxWorkingSetSize`（24 GB Mac 上 ~16 GB）**：mlx-swift 的 GPU buffer 复用池不设上限，长跑下吞掉所有可用内存——v0.7.3 dogfood 2 天后进程 IOAccelerator 15.6 GB / 物理足迹 16.1 GB / 13.6 GB 被 compressor 压走，ASR p50 340 ms → 831 ms。**这跟权重 pin 是两个正交问题**：pin 守 `.active`，cacheLimit 守 cache pool；两个机制必须同时上。规避：`main.swift` 早期一行 `MLX.Memory.cacheLimit = 1_000_000_000`（1 GB）在 `AppDelegate` 构造前生效。1 GB 不是凭直觉拍——单次 refine working-set ~1.3 GB，512 MB 偏紧。详见 [`decisions/0003-bound-mlx-cache-pool.md`](decisions/0003-bound-mlx-cache-pool.md)。(v0.7.3)

- **MLX `CompiledFunction` 的 `NSRecursiveLock` 跨 `eval()` 持有，等 GPU 事件期间所有共享 op 的 caller 全串行**：`mx.compile()` 产物是进程全局缓存，每个 compiled function 一把锁，在 `innerCall` 里 lock + `eval()` + 等 `IOSurfaceSharedEvent waitUntilSignaledValue:` 全程持有。`relu` 这种被 `Qwen3AudioEncoder` / `SileroVADNetwork.forward` / refiner 共享的算子是最大踩坑点——任一 caller 冷路径 30+ s 时全链路 stuck，看起来像"录音胶囊卡死"。**v0.7.1 第一次 fix 失败原因**：以为竞争面是 `SileroVADModel` 实例状态，于是搞 `SharedVADBox` lock + 隔离 keep-alive 实例——没用，竞争面是进程全局的 compiled-function 缓存。规避：v0.7.2 起 live 模式 VAD 切到 `SileroVADEngine.coreml`（ANE+CPU，离开 MLX）；`TranscribeWatchdog` 5 s 阈值自动 `sample(1)` 抓栈到 `~/Library/Application Support/VoiceTyping/hang-stacks/`。**教训**：增加 keep-alive 类后台 MLX work 会反向恶化此问题，不是缓解。spike 全过程 [`spike/v0.7.1-vad-hang.md`](spike/v0.7.1-vad-hang.md)。(v0.7.2)

## VAD / 转写质量

- **Silero VAD 默认参数为低延迟流式调，不是转写质量调**：`(0.25s speech, 0.10s silence)` 切出来切到词中间，丢上下文。规避：转写场景用 `minSpeechDuration: 0.3` + `minSilenceDuration: 0.7`（v0.4.5 拍板）。(v0.4.5)

- **Qwen3-ASR 短/弱音频会吐训练集尾巴 + 回显 prompt**：常见幻觉 `"谢谢观看"` / `"Thank you."` / `"Yeah."`，或者把 glossary context 整段 echo 回来。规避：`HallucinationFilter` 静态黑名单 + substring containment 检测，不只关键字匹配。(v0.4.5)

- **`AsyncStream` 是单消费者**：v0.5.3 hands-free 在 non-live timing 下需要 VAD watchdog 同时消费 `AudioCapture.samples`，但 `startLiveTranscriberIfEnabled` 默认会 drain 同一 stream → 两个消费者抢，watchdog 拿不到 chunks。规避：给 `startLiveTranscriberIfEnabled` 加 `drainIfNotLive: Bool` 参数，watchdog 路径下传 false 自己接管 drain。(v0.5.3)

- **DebugCaptureWriter `meta.json` 直到 finalize 才写**：v0.5.1 设计漏 — crash / force-quit / early bail 路径让 `meta.json` 永远缺席。dogfood 303 sessions 只有 12% 完整率。规避：v0.5.3 起 init() 末尾 enqueue partial meta 写入，finalize/abort 复用同一 `writeMeta()` update endedAt + totals。(v0.5.3)

- **`encoder.dateEncodingStrategy = .iso8601` 默认无 fractional seconds**：写出来 `2026-04-23T19:13:19Z` 秒级精度，跨毫秒 delta 全报 0ms（live_drain.py 全失效）。规避：用 `.custom { ... ISO8601DateFormatter([.withInternetDateTime, .withFractionalSeconds]) ... }`。(v0.5.3)

## 文本注入 / 目标 app

- **`CGEvent.keyboardEvent` 在多数现代 app 里丢字 / 顺序错乱**：低层 keyboard event 跟系统 IME 输入栈竞争——Slack / Notion / VSCode / Chrome 编辑器一律有不同程度的丢字、字符插错位置、键修饰键残留。v0.7.0 spike 在 ~10 个目标 app 上验证，CGEvent 没有一个能干净跑流式分段输出。**这条路死了，别再试**。spike 全过程 [`spike/v0.7.0-inject.md`](spike/v0.7.0-inject.md)。(v0.7.0)

- **Accessibility `AXValue` setValue 在多数 app 里替换整个字段而不是 append**：理论上可以 `AXSelectedTextRange` + setSelected 拼出 append 语义，实测大量 app 把 setValue 当 replace 处理（Safari 地址栏 / Chrome 编辑器尤其严重），流式 chunk 互相覆盖。(v0.7.0)

- **Cmd+V incremental 是唯一通用 inject 路径**：v0.7.0 起 `pasteboard.setString(chunk)` + `CGEvent` 模拟 ⌘V，spike 用 `chunkSize=5 chars / chunkInterval=50 ms` 在 TextEdit / Notes / VS Code / Cursor / Notion / Terminal / 微信 上验证 lossless。代价：(1) 污染剪贴板——必须"开始 snapshot，inject 完恢复"双缓冲，IME bypass 仅在 stream 起点 toggle 一次；(2) Notion 把每次 paste 当独立 block 创建 + `>` 触发 blockquote markdown——bundleID deny-list 兜底走一次性 batch paste；(3) Notes 首行被自动 promote 成 note 标题（cosmetic，不修）。(v0.7.0)

## 构建 / 资源 bundle

- **WhisperKit CoreML 模型大小约 2× 原始 checkpoint**：~1.5GB 原始 weights → ~3GB 编译后（AudioEncoder 1.2GB + TextDecoder 1.5GB）。下载进度估算需要按编译后 size，不然中途 cancel 看起来是失败。(v0.1.0)

- **`make build` 必须把 `mlx.metallib` 拷到 `Contents/MacOS/`**：MLX 通过 `Bundle.main.executableURL` 同目录找，不是 Resources。Test bundle 同理（test 进程的 executableURL 是 xctest，不是 .app），E2E 测试要手动 stage 到 `TEST_BUNDLE_MACOS/mlx.metallib`，Makefile 已自动化。(v0.2.0, v0.4.3)

- **Silero VAD 不 bundle 会触发首次启动 hang**：`SileroVADModel.fromPretrained()` 离线时找不到模型 → HuggingFace request → 用户首次按 Fn 卡死。规避：Resources 内嵌 1.2MB 模型，`make build` 自动拷进 `Contents/Resources/SileroVAD/`。(v0.4.4)
