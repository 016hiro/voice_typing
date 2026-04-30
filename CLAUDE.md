# voice_typing

## 文档规范
本项目使用 devdoc 套件管理文档。常用 skill：

- `init-devdoc` — 初始化 docs 结构（已跑过）。
- `session-bootstrap` — 新 session 开始前读取项目当前状态。
- `session-handoff` — compact / 切 session 前存档。
- `write-adr` — 做架构决策时写 ADR。
- `close-iteration` — 收版本、写 devlog、更新 CHANGELOG。

详细触发条件与操作步骤见各 skill 的 SKILL.md。

## 提交前检查（硬规则）

每次 `git commit` 前必须先跑：

```bash
make test
```

= CI 同款 `swift test --skip E2E --arch arm64`。失败不许 commit。

理由：CI 编译整个 SwiftPM package（含 test target），本地 `make build`（release config + main only）不编 tests。Swift 6 严格并发若在 test 文件里翻车，本地 build 全绿但 CI 必挂。v0.5.0..v0.5.3 期间 CI 红了 5 个版本没人发现，根因就是本地缺 mirror CI 的 gate。

兜底机制：`.claude/hooks/swift-precheck.sh` 在 Claude 任何修改 `*.swift` 的 turn 末尾自动跑 `make test`，失败 exit 2 强制 Claude 继续修。`make release` 也已 hard-depend on `test`，跑发版前会自动校验。

## Settings UI 改动规则（硬规则）

任何改动 `Sources/VoiceTyping/Menu/SettingsWindow.swift` 的 PR 都必须：

1. **算账再写代码**：列出受影响 tab 的 worst-case 分支（含所有 picker / `if-else` / 条件 modifier 展开后的最大形态），逐控件估高，对照"可用 tab 内容区"。
   - 当前可用区 = `Panel.height - 144pt chrome`（上 76 + 下 68）。
   - 不要单独看默认分支；fresh-install 默认值常常就是最大分支（例如 LLM tab 的 Cloud refiner）。

2. **空间不够时优先扩容**：改 `Panel.height`（`SettingsWindow.swift:42`），不要靠砍说明文字、缩字号、塞 ScrollView 来挤。窗口空一点没事，控件溢出面板=用户看不到 Done 按钮。

3. **边距/buffer 阈值**（硬性下限，违反必须改）：

   | 维度 | 下限 |
   |------|------|
   | 面板上 chrome（panel top → tab content top） | ≥ 60pt |
   | 面板下 chrome（tab content bottom → panel bottom） | ≥ 60pt |
   | 面板左/右 chrome | ≥ 20pt |
   | **worst-case tab body 与可用高度之差（buffer）** | **≥ 40pt** |

   buffer 不是参考值——SwiftUI 实际渲染高度会因系统字体/控件版本浮动 ±5-10pt，40pt 是吸收这些波动的安全垫。

4. **改完必须人工实测**：估算只能保下限，不能精确预测。每次改完跑 `make build && open build/VoiceTyping.app`，五个 tab 都点一遍，确认没控件溢出、Done 按钮正常可见。

历史教训：v0.5.1..v0.6.3 期间 Settings UI 至少 3 次因新加控件没算账导致溢出，每次都是用户截图反馈才发现。本规则是为了把"算账"前置成 Claude 改动 SettingsWindow 时的默认动作。
