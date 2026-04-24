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
