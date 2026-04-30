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
    refines.jsonl     每次 LLM refine 调用的 input / output / latency（v0.6.3+；refine 没跑则不存在）
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
  "totalInjections": 2,
  "totalRefines": 2                   // v0.6.3+；缺字段或 null = 该 session 没跑过 refine
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

## refines.jsonl 字段（v0.6.3+）

每次 `LLMRefining.refine(...)` 实际跑了之后写一行（`.off` 模式 / 空输入 / 缺凭证早返回都不写）。设计目的是离线对比 cloud vs local refiner 的输出质量 + 延迟。

```jsonc
{
  "timestamp": "2026-04-21T18:30:50Z",
  "input": "今天我们来聊一下…",       // ASR 输出 + 过滤后的原文
  "output": "今天我们来聊一下…",       // refiner 改写结果（失败 / no-op 时 = input）
  "mode": "aggressive",                  // RefineMode.rawValue: light / aggressive / conservative
  "backend": "local",                    // "cloud" 或 "local"
  "latencyMs": 745,                      // 整次 refine() await 的 wall-clock
  "glossary": "热词：Agent、Claude Code。",  // 投给模型的字典块（可能为 null）
  "profileSnippet": null,                // 命中的 ContextProfile 片段（无则 null）
  "rawFirst": false                      // false = 等 refine 完再贴；true = 先贴 raw 后台 refine 再 Cmd+Z 替换
}
```

**敏感性提醒**：`input` / `output` / `glossary` / `profileSnippet` 是用户实际说的话和实际配置——只在你自己分析时跑，发出去之前确认下里面没有要保密的内容。API key 不在这里（永远不写盘）。

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

### 八、按 backend 看 refine 延迟分布（v0.6.3+）

```bash
jq -s 'group_by(.backend) | map({backend: .[0].backend, n: length, p50_ms: (sort_by(.latencyMs) | .[length/2|floor].latencyMs), max_ms: ([.[].latencyMs] | max)})' \
  */refines.jsonl
```

### 九、抓所有 refine 把内容改长 / 改短的样本（diff 一下 input / output）

```bash
jq -c 'select((.input | length) != (.output | length)) | {input, output, mode, backend}' refines.jsonl
```

## 进阶分析

v0.5.2 起在 [`Scripts/analysis/`](../Scripts/analysis/) 下提供 5 个 Python stdlib 脚本，覆盖上面 jq 查询答不动的几类问题：sessions/audio 总览 + 多维分组、HallucinationFilter 拦掉的段抽样、live mode drain 时间分布、focus drop 频率 per-app、per-segment ASR latency + RTF + cold/warm。

```bash
# 跑全套（`$ROOT` 指向 debug-captures 目录）
ROOT=~/Library/Application\ Support/VoiceTyping/debug-captures
cd Scripts/analysis
python3 summary.py "$ROOT"
python3 hallucination_review.py "$ROOT" --sample 20
python3 live_drain.py "$ROOT"
python3 focus_drop.py "$ROOT"
python3 segment_latency.py "$ROOT"
```

零依赖（macOS 自带 `python3` 即可），决策矩阵 + 输出示例见 [`Scripts/analysis/README.md`](../Scripts/analysis/README.md)。

## 不在 capture 范围内的东西

明确说明几条**不会**落盘的数据，方便用户自己检查：

- **API key / Authorization header**——任何路径都不写。
- **OpenRouter / 云端 endpoint URL**——不写盘（只 refine input/output 在 `refines.jsonl`，URL 在 `LLMConfig` 里，不进 capture）。
- **用户对结果的修正动作**——需要 Accessibility 监控其它 app 的 keystroke，超出范围；"高频误识别词"分析因此也不做。

> v0.6.3 之前 refine I/O 也不抓；v0.6.3 #R8 起开始抓（见上面 `refines.jsonl` 段）。

## 自动清理

- **按时间**：默认 7 天。Settings 里可调到 14 / 30 / 永不。0 = 永不清。
- **按容量**：硬顶 5 GB；超了就从最旧 session 开始删，删到 4 GB 以下停。两个清理都在 app 启动时跑一次，runtime 不再触发。

## 想把整个 session 发给我

- **Finder**：右键目录 → 压缩 → `<目录名>.zip` → 拖到对话框
- **Terminal**：`zip -r session.zip <目录名>`

如果 audio.wav 太大可以只发 `meta.json + segments.jsonl + injections.jsonl`——文本部分够还原大部分诊断。
