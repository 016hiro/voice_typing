# Debug Capture 数据格式

> v0.5.1 起，Settings → Advanced → "Debug Data Capture" 开启后，每次按 Fn 录音都会落盘一组诊断文件。本文说明数据布局 + 几个常用 `jq` 查询。
>
> **不会上传到任何地方**——文件全在本机 `~/Library/Application Support/VoiceTyping/debug-captures/` 下，按 N 天 / 5 GB 自动清理（详见 Settings 同一面板）。
>
> 决策来源：`docs/todo/v0.5.1.md` "Debug 数据捕获 toggle" 段，七个 `[x] 拍` 项。

## 文件布局

```
~/Library/Application Support/VoiceTyping/debug-captures/
  2026-04-21_18-30-42_a1b2c3d4/
    meta.json         session 元数据（开始/结束时间、backend、language、frontmost app 等）
    audio.wav         16 kHz mono Float32 — 原始麦克风采集
    segments.jsonl    每个 ASR 段（包括被 HallucinationFilter 拦掉的）
    injections.jsonl  每次注入尝试（live 模式一段一行；batch 模式一录音一行）
```

每个 session 一个目录。目录名 = `<本地时间戳>_<8 字符 uuid 前缀>`，按文件名字典序就是时间序。

## meta.json 字段

```jsonc
{
  "sessionId": "a1b2c3d4",
  "appVersion": "0.5.1",
  "startedAt": "2026-04-21T18:30:42Z",
  "endedAt": "2026-04-21T18:30:50Z",
  "backend": "qwen-asr-1.7b",          // ASRBackend.rawValue
  "language": "zh",                     // Language.rawValue
  "liveMode": true,                     // false = batch 路径
  "frontmostBundleID": "com.tinyspeck.slackmacgap",
  "profileSnippet": "Casual tone…",     // 命中的 ContextProfile 片段
  "asrContextChars": 320,               // 注入给 ASR 的偏置上下文长度
  "totalAudioSec": 7.8,
  "totalSegments": 2,
  "totalInjections": 2
}
```

## segments.jsonl 字段

每行一个 JSON 对象。包含 HallucinationFilter 拦掉的段（`filter: "hallucinationFiltered"`），方便回溯过滤决策。

```jsonc
{
  "timestamp": "2026-04-21T18:30:46Z",
  "startSec": 0.32,                     // 段起点，相对 audio.wav 0 时刻
  "endSec": 4.10,
  "rawText": "今天我们来聊一下…",
  "filter": "kept",                     // 或 "hallucinationFiltered"
  "transcribeMs": 412
}
```

## injections.jsonl 字段

```jsonc
{
  "timestamp": "2026-04-21T18:30:46Z",
  "chars": 42,
  "textPreview": "今天我们来聊一下…",   // 前 120 字符
  "targetBundleID": "com.tinyspeck.slackmacgap",  // Fn↓ 时的焦点
  "actualBundleID": "com.tinyspeck.slackmacgap",  // 注入瞬间的焦点
  "status": "ok",                       // ok / focusChanged / skipped
  "elapsedMs": 8
}
```

`status: focusChanged` 表示用户中途切了 app；段被记录但没注入（避免文字洒到错误的 app）。

## 常用 `jq` 查询

下面几条假定你 `cd` 到一个 session 目录里。需要 `jq` 安装（`brew install jq`）。

### 一、列出本次 session 所有 ASR 原始段（含被过滤的）

```bash
jq -c '{filter, rawText, transcribeMs}' segments.jsonl
```

### 二、找所有被 HallucinationFilter 拦掉的段（人工审视过滤是否过激）

```bash
jq -c 'select(.filter == "hallucinationFiltered") | .rawText' segments.jsonl
```

### 三、统计每段平均转写耗时

```bash
jq -s '[.[] | .transcribeMs] | add / length' segments.jsonl
```

### 四、找所有因为切焦点被丢弃的注入

```bash
jq -c 'select(.status == "focusChanged") | {targetBundleID, actualBundleID, chars}' injections.jsonl
```

### 五、跨多个 session 聚合：某天所有"过滤掉的段 / 总段"比例

在 `debug-captures/` 父目录里跑：

```bash
for d in 2026-04-21_*; do
  total=$(wc -l < "$d/segments.jsonl")
  filtered=$(jq -c 'select(.filter == "hallucinationFiltered")' "$d/segments.jsonl" | wc -l)
  printf "%s: %s / %s filtered\n" "$d" "$filtered" "$total"
done
```

### 六、按 backend 分组所有 session 的平均录音时长（meta-only，快）

```bash
jq -s 'group_by(.backend) | map({backend: .[0].backend, avg_audio_sec: ([.[] | .totalAudioSec] | add/length), n: length})' \
  */meta.json
```

### 七、提取一段音频出来用 ffmpeg 转 mp3（方便发给别人）

```bash
ffmpeg -i 2026-04-21_18-30-42_a1b2c3d4/audio.wav -codec:a libmp3lame -qscale:a 4 sample.mp3
```

## 不在 capture 范围内的东西

明确说明几条**不会**落盘的数据，方便用户自己检查：

- **LLM refine 的 prompt / response**——v0.5.1 不抓。Refine 整体优化（含 capture）单独成版本。
- **API key / Authorization header**——任何路径都不写。Refine I/O 不抓本身就排除了一类风险。
- **用户对结果的修正动作**——需要 Accessibility 监控其它 app 的 keystroke，超出 v0.5.1 范围；"高频误识别词"分析因此也不做。

## 自动清理

- **按时间**：默认 7 天。Settings 里可调到 14 / 30 / 永不。0 = 永不清。
- **按容量**：硬顶 5 GB；超了就从最旧 session 开始删，删到 4 GB 以下停。两个清理都在 app 启动时跑一次，runtime 不再触发。

## 想把整个 session 发给我

- **Finder**：右键目录 → 压缩 → `<目录名>.zip` → 拖到对话框
- **Terminal**：`zip -r session.zip <目录名>`

如果 audio.wav 太大可以只发 `meta.json + segments.jsonl + injections.jsonl`——文本部分够还原大部分诊断。
