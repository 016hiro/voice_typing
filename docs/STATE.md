# STATE

_Last updated: 2026-04-26_

## Current Focus

v0.6.1 已 close（doc 闭环完成）。主题：**中国大陆可用性**——HF 自动镜像兜底（race + bandwidth probe，零 Settings UI）+ 首次安装 onboarding confirm dialog（Qwen 1.7B）。下一步：bump Info.plist + `make release VERSION=0.6.1` + ship。**下一版号 + 主题 TBD**——沿用 v0.6.0.x 收尾后的 dogfood 模式，不预 bump。

## Current Version

v0.6.1（doc closed 2026-04-26，待 ship）

## In-flight Changes

无 in-flight（v0.6.1 close 完毕）。三件关键文档：

- 收尾段：[`docs/devlog/v0.6.1.md`](devlog/v0.6.1.md) close-iteration block
- 用户面变更：[`CHANGELOG.md`](../CHANGELOG.md) v0.6.1 section
- 归档：[`docs/todo/v0.6.1.md`](todo/v0.6.1.md) `_Closed_` 头

未完成项已迁入 [`docs/todo/backlog.md`](todo/backlog.md)：手动删模型后静默重下 + HF probe TLS 失败 troubleshooting 文档。

## Next Concrete Step

执行 v0.6.1 ship：Info.plist bump 0.6.0.3/17 → 0.6.1/18 → `make release VERSION=0.6.1 BUILD=18` → gh release + appcast push + tag → 升级链路实测一次。

## Blockers / Open Questions

- 100 KB/s 阈值 + 5x 倍率：ship 后 dogfood 数据定稿
- hf-mirror SLA 不确定：dogfood 期观察命中率
- `#33` dogfood live mode 5+ 天信号采集 仍 pending（持续累积）
