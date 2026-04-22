# voice_typing

## 文档规范
本项目使用 devdoc 套件管理文档。常用 skill：

- `init-devdoc` — 初始化 docs 结构（已跑过）。
- `session-bootstrap` — 新 session 开始前读取项目当前状态。
- `session-handoff` — compact / 切 session 前存档。
- `write-adr` — 做架构决策时写 ADR。
- `close-iteration` — 收版本、写 devlog、更新 CHANGELOG。

详细触发条件与操作步骤见各 skill 的 SKILL.md。
