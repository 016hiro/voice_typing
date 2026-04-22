# Gotchas

本文档记录**非显而易见**的坑、反直觉行为、踩过的雷。每条短小精干，给出触发条件和规避方法。来源：12 版 devlog 提炼。

## macOS / TCC / 签名

- **ad-hoc 签名每次 rebuild 重置 TCC**：`codesign --sign -` 每次产生新 cdhash → macOS 把 .app 当新 app → Microphone + Accessibility 授权丢失。规避：`make setup-cert` 一次性创建本地自签名身份，`make build` 自动用它，cdhash 跨重建稳定。(v0.1.0, v0.4.1)

- **Carbon Text Services API 必须主线程**：`TISCopyCurrentKeyboardInputSource` 等 Carbon 调用内部有 `dispatch_assert_queue` 检查，子线程跑会 SIGTRAP。规避：包装函数加 `@MainActor` 或显式跳到 main queue 再调。(v0.1.0)

- **LSUIElement / `.accessory` app 丢 ⌘A/⌘C/⌘V**：没有 main menu 的 app 不进 AppKit 默认 responder chain。规避：自定义 `performKeyEquivalent` 拦截 → `NSApp.sendAction(_:to:from:)` 手动转发。(v0.3.2)

- **NSVisualEffectView 不吃 `cornerRadius + masksToBounds`**：blur 材质渲染绕开 layer cornerRadius。规避：用 `effect.maskImage` + 9-slice 圆角 capsule 图（Apple 官方推荐路径）。(v0.1.0)

## Swift / SwiftUI / Concurrency

- **SourceKit 索引经常假阳性报 "Cannot find type X in scope"**：编辑后保存触发 indexing race，错误能持续几秒到几十秒。规避：跑 `swift build`，build 干净就忽略 IDE 红线。本项目尤其多发于 `DebugCapture` / `LiveTranscriber` 这类新增类型。

- **SwiftUI Picker 绑 computed property 必须手写 `Binding`**：`@Published` 才有 `$` 投影；computed 没有。规避：`Picker(selection: Binding(get:set:))` 内联包一层（参考 v0.5.2 `transcriptionTiming` 用法）。(v0.5.2)

- **闭包 type inference 偶尔挂在 `.map { x in ... }`**：复杂泛型上下文里 Swift 推不出闭包参数类型。规避：`if let x = optional { ... }` 改写，或显式 `(Type) -> ReturnType in` 标注。(v0.5.1)

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

## 构建 / 资源 bundle

- **WhisperKit CoreML 模型大小约 2× 原始 checkpoint**：~1.5GB 原始 weights → ~3GB 编译后（AudioEncoder 1.2GB + TextDecoder 1.5GB）。下载进度估算需要按编译后 size，不然中途 cancel 看起来是失败。(v0.1.0)

- **`make build` 必须把 `mlx.metallib` 拷到 `Contents/MacOS/`**：MLX 通过 `Bundle.main.executableURL` 同目录找，不是 Resources。Test bundle 同理（test 进程的 executableURL 是 xctest，不是 .app），E2E 测试要手动 stage 到 `TEST_BUNDLE_MACOS/mlx.metallib`，Makefile 已自动化。(v0.2.0, v0.4.3)

- **Silero VAD 不 bundle 会触发首次启动 hang**：`SileroVADModel.fromPretrained()` 离线时找不到模型 → HuggingFace request → 用户首次按 Fn 卡死。规避：Resources 内嵌 1.2MB 模型，`make build` 自动拷进 `Contents/Resources/SileroVAD/`。(v0.4.4)
