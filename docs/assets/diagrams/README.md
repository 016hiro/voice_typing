# 图表资源目录

架构文档里的流程图默认用 **Mermaid** 直接写在 markdown 里（GitHub 原生渲染），这个目录留给需要更复杂视觉的场景。

## 如何添加图表

### 方式 A：Mermaid（推荐，纯文本）

直接在 markdown 文件里写 ` ```mermaid ` 代码块。改起来像代码，diff 友好。

### 方式 B：Excalidraw（手绘风，需要导出图片）

1. 打开 https://excalidraw.com 画好
2. File → Export image → PNG（勾选 "Embed scene"，导出的 PNG 内嵌源数据，下次可以拖回 Excalidraw 二次编辑）
3. 保存到 `docs/assets/diagrams/<name>.excalidraw.png`
4. 在 markdown 里引用：`![说明](../assets/diagrams/<name>.excalidraw.png)`

### 方式 C：draw.io / 其他

同 B，统一放到这个目录，文件名用 `<name>.<tool>.<ext>` 以便识别来源。

## 命名惯例

- `pipeline-<scene>.mermaid.svg` —— Mermaid 预渲染副本（通常不需要，直接 inline）
- `<name>.excalidraw.png` —— Excalidraw 带嵌入数据的 PNG
- `<name>.drawio.svg` —— draw.io 源文件（可编辑）
