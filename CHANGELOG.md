# Changelog

本项目所有**面向用户**的变更记录在此。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [SemVer](https://semver.org/lang/zh-CN/)。

## Unreleased

_（下个版本的用户可见变更在此累积）_

## v0.7.1 — 2026-05-02

### Fixed
- **闲置后首次 ASR 卡顿**（v0.6.4 修的同一个 bug，v0.6.4 实际没修干净）：v0.6.4 ship 后 dogfood 数据显示 ≥5 s outlier 反而从 2.2% 升到 5.3%，根因是当时的 keep-alive timer 在 release 里被 macOS App Nap 节流，且没人能观测到（log 默认 off）。v0.7.1 加 `ProcessInfo.beginActivity(.userInitiated)` 抑制 App Nap、`NSWorkspace.didWakeNotification` 监听 wake-from-sleep 立即补 tick、timer callback 的 QoS 从 `.background`（最低，可被任意 defer）升到 `.utility`、所有 keep-alive 日志从 `.dev` 升 `.notice`（release 默认可见）
- **Settings 设置面板里的 sheet（Dictionary / Profile 编辑器）现在支持 ⌘V/⌘C/⌘A/⌘X/⌘Z**：之前在 Add Vocabulary / Add Profile 弹窗里只能键入不能粘贴，因为 sheet 子窗口没继承主面板的快捷键转发

### Changed
- **Refine prompt 收紧**（Clean Up + Polish 两档）：明示要把 ASR 倾向输出的中文数字（"九十九" / "三点一四" / "二零二四" / "零点一点一"）转回阿拉伯数字（"99" / "3.14" / "2024" / "0.1.1"），但量词搭配（"三个文件" / "一只猫"）保留中文形态；中英混读时不要把英文术语（Python / Kubernetes / API / JSON）翻译成中文；"这个" 加进 filler / 口吃折叠列表。Polish 这档把"口语化→书面化重写"显式提升为差异点（之前藏在第 6 条"smooth phrasing"里，现在是 #5 主任务，配 "然后呢" / "and then like" 这种例子）
- **Debug capture meta 加 git commit SHA**（`make build` 时 PlistBuddy 把 `git rev-parse --short=12` 写进 Info.plist `GitCommitSHA`，运行时落到每个 session 的 `meta.json`）：dogfood 分析能按 build 切片，不再仅按 version string 聚合

### Removed
- **Refine 档位 "Fix Errors" (conservative) 砍掉**：跟 "Clean Up" 的核心职责重叠（修 ASR 错），保留三档没意义。老用户原 Fix Errors 自动迁到 Clean Up——多一些 filler / 口吃删除，但不会改写措辞或顺序

### Notes
- 完整开发记录：[`docs/devlog/v0.7.1.md`](docs/devlog/v0.7.1.md)

## v0.7.0 — 2026-05-02

## v0.7.0 — 2026-05-02

### Added
- **流式 refine**：refine 现在边生成边 paste，不再"沉默几秒后一次性 paste"。Cloud / Local 两个 backend 都支持。Settings → LLM → "Delivery" picker 选 Streaming（默认）或 Batch
- **Live 模式 + refine**：长按 Fn 边说边录的模式现在也支持 refine。
  - 用 **Local refiner** 时：每个 VAD 段独立 refine 并立即出现在目标 app；段间共享一个 chat session，所以"它/that/the cat" 这种跨段指代能保持一致
  - 用 **Cloud refiner** 时：录完后整段一次性 refine（避免 N 次 API 调用），自动 Cmd+Z 替换录制时的 raw 文本
- **流式期间可取消**：refine 中按 **Esc** 立即停；切到别的 app（focus 丢失）也立即停。已经 paste 的字符保留
- **Capsule 状态显示已写字数**：流式 refine 期间 capsule 文字从 "Refining" 变成 "Refining (N chars)"，N 实时累加
- **Notion 自动降级**：在 Notion 里录音，refine 自动切到一次性 paste（避免 Notion 把每次 paste 当独立 block 创建）。其他 app 不受影响

### Changed
- **Raw-first 模式移除**：v0.3 引入的"先 paste raw 后台 refine 再 Cmd+Z 替换"模式被砍掉。新的流式 refine 在感知延迟上更好（不闪烁、不需要 Cmd+Z 替换），覆盖了 raw-first 的所有用例。**老用户**：如果你之前开了 Raw-first，升级后会自动切到 Streaming，无需手动调

### Notes
- 完整开发记录：[`docs/devlog/v0.7.0.md`](docs/devlog/v0.7.0.md)

## v0.6.4 — 2026-05-01

### Fixed
- **闲置后首次 ASR 卡顿**：v0.6.0 切到 MLX backend 那天就有的存量 bug——闲置 1-2 小时后首次按 Fn 要等 9-30 秒（健康基线 100-500ms）。根因是 macOS unified-memory compressor 把 Qwen MLX 权重压缩成冷页，下次 access 要解压。修法：每 90s 后台跑一次 200ms 静音 dummy transcribe 让权重保持 active。CPU 成本 ~0.3% 持续，无可感发热。Whisper backend 不受影响（CoreML 走 ANE 池，不经 compressor）

### Notes
- 完整开发记录：[`docs/devlog/v0.6.4.md`](docs/devlog/v0.6.4.md)

## v0.6.3 — 2026-05-01

### Added
- **本地 LLM refiner**：Settings → LLM 多了 "Refiner" 段，可在 Cloud / Local 之间切换。Local 用 `mlx-community/Qwen3.5-4B-MLX-4bit`（~2.6 GB，首次启用时下载），完全离线，不需 API key，不出网。按 Mac 内存分层暴露：
  - **8 GB**：不显示 Local 入口（避免 swap）
  - **16-23 GB**：可开，显示 ⚠ "可能 swap on heavy multitasking" 警告
  - **24 GB+**：可开，无警告（默认仍 OFF；先 dogfood 收数据再考虑改默认）
- **Cloud refine 改流式（SSE）**：解决了某些云端 API（特别是 OpenRouter 路由的 reasoning 模型如 o1/r1/:thinking）非流式下 100% 超时的问题。心跳保活 + 部分内容渐进返回
- **Settings → Advanced → 调试采集** 现在也记录 LLM refine 的输入/输出/延迟（落到 `~/Library/Application Support/VoiceTyping/debug-captures/<session>/refines.jsonl`），方便用户/我自己 A/B 比较 cloud vs local 质量

### Fixed
- **调试采集长期数据丢失（潜伏 5 个版本）**：v0.5.1 起的 silent bug，`DebugCaptureWriter` 在 Task 结束时 race，所有 dogfood session 的 `audio.wav` 和完整 `meta.json`（含 `endedAt` / 总数）都没写盘，只剩 `meta.json` 局部 + `segments.jsonl`。开启过调试采集的用户，**新版本起所有数据完整**。历史数据不可恢复
- **Cloud refine 默认超时 8s → 60s**（reasoning 模型自动 90s）；老用户从 UserDefaults 读到 < 30s 的旧值会自动 bump 到新默认。修了 "in-app Test 通过但实际 refine 永远超时" 的混淆体验
- **Cloud refine 错误信息更人话**：408/429/524/529 现在会显示 "API edge timeout" / "Rate limited" / "Upstream provider timed out" / "Upstream provider overloaded"，不再统一吐 `NSURLErrorDomain Code=-1001`
- **Settings 面板高度 600 → 700**：之前 LLM tab Cloud 模式会顶到面板上下边距外。同时窗口尺寸调整规则进 `CLAUDE.md` 防再犯

### Notes
- 升级安装包不会重下任何模型；本地 refiner 模型按需在 Settings 里点 "Download" 下
- 中国用户走 hf-mirror（v0.6.1 已有），下载本地 refiner ~10 分钟
- v0.7.0 计划做 "流式 refine UX"（用户实际看到字逐渐出现）+ Live × Refine Cmd+Z 链
- 完整开发记录：[`docs/devlog/v0.6.3.md`](docs/devlog/v0.6.3.md)

## v0.6.1 — 2026-04-26

### Added
- **首次启动 onboarding**：装好后启动会弹一次确认对话框，提示下载默认模型 (Qwen3-ASR 1.7B, ~1.4 GB)。点 "Later" 可跳过，之后从 **Settings → Manage Models** 手动下载任意模型。既有用户（已有缓存模型）不会被再问
- **HuggingFace 自动镜像兜底**：启动时自动测速，若官方 HF 慢/不通则切到 `hf-mirror.com`。零配置、零账号、零环境变量。中国大陆用户开箱即用

### Fixed
- Settings → Manage Models 的当前 backend 行在"未下载模型"状态下不再误显示 "Active" / "Preparing…"；现在显示真实状态 ("Not downloaded" + "Download" 按钮)，按 Fn 时也会准确提示而不是 "still loading"

### Notes
- 模型仍存在 `~/Library/Application Support/VoiceTyping/models/`；Sparkle 升级**不会**重新下载模型（只换 `.app`）
- 如果你的网络通过 VPN/代理（如 clash），且日志显示 probe 持续 TLS 失败：把 `huggingface.co` 和 `hf-mirror.com` 加 DIRECT 规则即可

## v0.6.0.3 — 2026-04-25

### Notes
- 内部 dummy build：用于跑通 v0.6.0.2 → v0.6.0.3 的 Sparkle 真升级链路（detect → EdDSA 验签 → 替换 → 重启 → TCC 保留），验证通过。无 user-facing 改动

## v0.6.0.2 — 2026-04-25

### Fixed
- **Sparkle 自动更新链路修复**：v0.6.0 / v0.6.0.1 的 DMG 因 Sparkle helper 签名问题（自签证书 + `--deep` codesign 把 Sparkle 内部 XPC helper 一起重签了，破坏 IPC）无法走 Sparkle 升级。**装着 v0.6.0 / v0.6.0.1 的请手动下载 v0.6.0.2 DMG 拖进 Applications 一次**——之后所有版本的 Sparkle 自更新恢复正常

### Notes
- 无 user-facing 功能改动；仅修发版基础设施

## v0.6.0.1 — 2026-04-25

### Notes
- 内部 dummy build：用于验证 Sparkle 升级链路（v0.6.0 → v0.6.0.1）。链路没跑通，根因暴露后由 v0.6.0.2 修复

## v0.6.0 — 2026-04-24

### Added
- **DMG 安装包**：从 [Releases](https://github.com/016hiro/voice_typing/releases) 下载 `VoiceTyping-0.6.0.dmg`，双击 → 拖到 Applications → 首次右键 → 打开（绕过 Gatekeeper 一次）
- **Sparkle 自更新**：装好之后所有版本无感升级。启动时自动检查 + 每 24h 后台检查 + 菜单 "Check for Updates…" 手动触发。EdDSA 签名验证 update 完整性
- **PolyForm Noncommercial 1.0.0 LICENSE**：source-available，个人 / 教育 / 研究 / 非营利使用 OK；禁商用
- **Hands-free 模式**（Settings → Models, EXPERIMENTAL，原 v0.5.3 工作）：开启后短按 Fn（< 200ms）= 录音继续，1.5 秒静默自动停。再按 Fn = 取消丢弃。长按 Fn 行为不变。仅 Qwen 后端可用，所有 3 种 transcription timing 都支持。默认关闭 (dogfood opt-in)
- 胶囊 hands-free 视觉：morse 染橙 + "HF" 角标 + 进入时显示 "TAP FN TO CANCEL" 3 秒

### Changed
- 录音时长 cap 抽到单一来源 `RecordingPolicy.maxDuration(timing:backend:)`：live + Qwen = 600s，其他 = 60s。hands-free 共用同一规则

### Fixed
- **DebugCaptureWriter `meta.json` 缺失**：v0.5.2 dogfood 12% 完整率 → 现在 begin() 立刻写 partial meta，crash/force-quit 也能保留元数据
- **DebugCaptureWriter timestamp 秒精度**：`live_drain.py` 因为 `endedAt` 和 last inject 经常落同一秒报 0ms drain 全失效，现在 ISO8601 加 fractional seconds

### Notes
- v0.5.3 的全部代码工作（hands-free + writer 修补 + RecordingPolicy）从未发过 binary release，全部 fold 进 v0.6.0 首发
- 没有 Apple Developer 账号 → 没有 notarization → 首次启动 Gatekeeper 会拦，需要右键 → 打开。详见 [README "Install" 段](README.md#install-v060-prebuilt-dmg)
- 详细技术 + 决策见 [`docs/devlog/v0.6.0.md`](docs/devlog/v0.6.0.md)

## v0.5.2 — 2026-04-23

### Added
- **Transcription timing 设置**：Settings → Models 新增三选一选项 ("After recording — one shot" / "After recording — segmented" / "While speaking — live")。Live 模式（v0.5.0 起隐藏在 `defaults write liveStreamingEnabled`）现在有显式 UI 入口
- **行卡片设计 + chip 标签**：每个选项配 DEFAULT/QWEN/EXPERIMENTAL 小标签；hover 显示详细说明 tooltip；非 Qwen backend 时只灰掉 segmented + live 两行（one-shot 仍可用）
- **`Scripts/analysis/`**：5 个 Python stdlib-only 分析脚本读 debug-captures——`summary.py` / `hallucination_review.py` / `live_drain.py` / `focus_drop.py` / `segment_latency.py`。零依赖，`python3 summary.py "$ROOT"` 直接跑

### Changed
- 移除 Settings → Models 顶部 "Speech Recognition Model" 标题 + 底部 cache 路径说明，腾空间给 Transcription timing 卡片
- 旧的 `defaults write streamingEnabled` / `defaults write liveStreamingEnabled` 仍然有效（UserDefaults 是 Picker 的 backing store），不需要任何迁移操作
