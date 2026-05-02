# Scripts/analysis/

v0.5.2 起新增的 Debug Capture 数据分析工具集。读 `~/Library/Application Support/VoiceTyping/debug-captures/` 下的 JSONL 文件，输出 dogfood polish + v0.5.3 advancement 决策需要的指标。

## Requirements

- **Python 3.8+**（macOS 系统自带 `python3` 满足）
- **零第三方依赖** — 全部 stdlib（`json` / `argparse` / `pathlib` / `statistics` / `collections`）
- 不需要 `pip install` / venv / uv

## Usage

每个脚本都接受**两种 path**：

1. capture root（`~/Library/Application\ Support/VoiceTyping/debug-captures/`）→ 遍历所有 session
2. 单个 session 目录（`.../debug-captures/2026-04-21_18-30-42_a1b2c3d4/`）→ 只看那一个

```bash
# 进 analysis 目录跑（脚本之间有 import 依赖 _common.py）
cd Scripts/analysis

# 注意 macOS 系统路径有空格，要 escape 或加引号
python3 summary.py ~/Library/Application\ Support/VoiceTyping/debug-captures/

# 或者把 root 设个变量
ROOT=~/Library/Application\ Support/VoiceTyping/debug-captures
python3 summary.py "$ROOT"
python3 segment_latency.py "$ROOT"
```

## 7 个脚本

### `summary.py` — "dogfood pool 够不够"

Top-line 数字：sessions / audio / segments / injections / on-disk size + 4 个分组维度。

回答："数据够不够启动 v0.5.3？live mode 占比多少？哪个 backend 主流？哪种语言主流？profile 功能被用没？"

### `hallucination_review.py` — "filter 有没有拦错"

列出所有被 `HallucinationFilter` 拦掉的段，配 per-backend filter rate。

回答："filter 阈值是不是过激？" scope doc 拍板：抽样 20 条，**真实有效语音占比 ≥ 20% → 松阈值**。

```bash
# 抽 20 条人工判
python3 hallucination_review.py "$ROOT" --sample 20
# 复现某次抽样结果
python3 hallucination_review.py "$ROOT" --sample 20 --seed 42
```

### `live_drain.py` — "Fn↑ → 出完字要多久"

Live mode 专项：测 `meta.endedAt`（Fn↑）→ 最后一段 inject 完成的延迟分布。

回答："v0.5.0 卖的'live mode = ASR(last_segment) + drain'承诺成立吗？"

scope doc 阈值：**p95 < 500ms 可接受**；超了立刻查瓶颈（maxTokens / Metal queue / dl_init 修复后是否还在偷时）。

### `focus_drop.py` — "切焦点丢字的频率"

`status: focusChanged` + `skipped` 的双重 drop 率，按 target bundleID 排序。

回答："NSWorkspace activation race 是不是真有问题？哪个 app 受害最重？"

scope doc 阈值：**< 5% 总 drop 可接受；单 app > 10% 必查**（Slack / Discord / Chrome / VSCode 等 Electron app 是 race 重灾区）。

```bash
# 默认隐藏只有 < 3 次 inject 的 app（避免长尾噪声）。要全部显示就调小：
python3 focus_drop.py "$ROOT" --min-sessions 1
```

### `segment_latency.py` — "每段 ASR 跑多快"

Per-segment `transcribeMs` 分布 + RTF + cold/warm 对比。

- **RTF (Real-Time Factor)** = `transcribeMs / segment_audio_ms`：< 1.0 = ASR 快于实时（live 舒服），> 1.0 = ASR 慢于实时（live 必然堆积）
- **Cold/warm** = 每 session 第一段 vs 后续段。delta > +50% → warmup 仍存在，prepare() 还有优化空间

回答："Qwen 在用户硬件上是不是真的 real-time？v0.5.1 的 dl_init 修是不是真消除了 warmup？"

### `refine_quality.py` — "本地 vs 云端 refiner 谁更好" (v0.7.1+)

读 `refines.jsonl`（v0.6.3 #R8 起写盘），按 backend (cloud/local) 切分：调用次数 / latency p50-p99 / 每种 mode 用了哪个 backend / output 相对 input 是变短/相等/变长 / glossary + profile snippet 触发率 / 同 session 既调云端又调本地的 A/B 候选。

回答："local Qwen3.5-4B 跟云端 latency / 改写幅度差多少？是否能把本地默认 ON？"——v0.6.3 backlog 的 cloud↔local 质量比对就靠这个。

```bash
# 摘要
python3 refine_quality.py "$ROOT"
# 抽 10 条 (input → output) 配对人工看质量
python3 refine_quality.py "$ROOT" --sample 10
# 复现某次抽样
python3 refine_quality.py "$ROOT" --sample 10 --seed 42
```

> **schema 注**：`RefineRecord.rawFirst` 在 v0.7.0 砍掉 raw-first feature 后，新 capture 永远是 `false`；脚本不读这个字段，老 capture 兼容。

### `keep_alive.py` — "v0.6.4 keep-alive 真在跑吗" (v0.7.1+)

读 `Meta.keepAliveTicksAtStart` / `keepAliveTicksAtEnd`（v0.7.1 新增），按 `appVersion[@gitCommitSHA]` 切分。回答 v0.6.4 dogfood 翻车那个问题：**"keep-alive timer 是真的在 fire 还是被 App Nap 节流？"**

健康的 v0.7.1+ build：>0 列应该明显超过 ==0 列（90s 周期 + App Nap 抑制让大部分 session 开始时已经至少 fire 过一次）。如果 ==0 占大头，说明 App Nap 抑制没生效或 timer 别处出错。

```bash
python3 keep_alive.py "$ROOT"
# 输出每个 build 的：
#   sess / instr (有 v0.7.1+ 字段的) / >0 / ==0 / p50 / p95 / >30s sess
```

> **schema 注**：v0.7.1 起 `Meta` 新增 `gitCommitSHA`（`make build` 时 PlistBuddy 注入 Info.plist `GitCommitSHA`）+ `keepAliveTicksAtStart` + `keepAliveTicksAtEnd` 三个字段。pre-v0.7.1 capture 缺这些字段，脚本兼容。

## 共享代码：`_common.py`

5 个脚本共享的迭代器 + 数学 + 格式化 helpers。不直接调用，只 import。修改 schema 时改这一处即可。

主要 API：
- `iter_sessions(path)` — 自适应 root vs 单 session
- `load_meta(dir)` / `load_segments(dir)` / `load_injections(dir)`
- `parse_iso(ts)` — Python 3.8+ 兼容的 ISO 8601 + Z 后缀解析
- `percentiles(values, ps)` — 线性插值实现，无依赖
- `histogram_ascii(values, bucket=…)` — ASCII 柱图
- `human_bytes(n)` / `fmt_pct(num, den)` / `fmt_ms(v)` — 输出格式化

## 不做的事

| 想算的 | 为啥这套不行 | 何时补 |
|---|---|---|
| 不同 VAD config 重跑同一段音频对比分段 | 要加载 Silero VAD + 跑 Swift 推理 | v0.5.3+，单独 Swift CLI |
| 同一段音频跑 3 个 backend 对比 transcript | 同上 | v0.5.3+，单独 Swift CLI |
| ~~Refine 质量 / LLM 改动量~~ | ~~Refine I/O 没 capture~~ → v0.6.3 #R8 已加 capture，v0.7.1 加了 `refine_quality.py` | done |
| 用户改字 / "重新打字率" | 需 OS 级 keystroke 监控其他 app | v0.6.x 或不做 |
| 时序模式（早晚使用频率等） | 数据有但 v0.5.2 不优先 | 需要时再加 |

## 决策矩阵

每个脚本的输出应该如何指导 v0.5.2 polish 决策，详见 [`docs/todo/v0.5.2.md`](../../docs/todo/v0.5.2.md) 决策矩阵段。

## Schema 参考

数据布局 + JSONL 字段定义见 [`docs/debug-captures.md`](../../docs/debug-captures.md)。

## 测试

5 个脚本都 happy-path 验证过，用合成 capture 数据（2 session，含 live + batch、双 backend、双语言、含 hallucinationFiltered + focusChanged 各一例）。手动重跑：

```bash
# 准备 2 个最小 session 验证 import 链 + 主路径输出
mkdir -p /tmp/vt_test/2026-04-21_18-30-42_a1b2c3d4
echo '{"sessionId":"a1","backend":"qwen-asr-1.7b","language":"zh","liveMode":true,"endedAt":"2026-04-21T18:30:50Z","totalAudioSec":7.8,"totalSegments":1,"totalInjections":1,"profileSnippet":"x"}' > /tmp/vt_test/2026-04-21_18-30-42_a1b2c3d4/meta.json
echo '{"timestamp":"2026-04-21T18:30:46Z","startSec":0.32,"endSec":4.10,"rawText":"hi","filter":"kept","transcribeMs":412}' > /tmp/vt_test/2026-04-21_18-30-42_a1b2c3d4/segments.jsonl
echo '{"timestamp":"2026-04-21T18:30:46Z","chars":2,"targetBundleID":"com.example","actualBundleID":"com.example","status":"ok","elapsedMs":8}' > /tmp/vt_test/2026-04-21_18-30-42_a1b2c3d4/injections.jsonl

python3 summary.py /tmp/vt_test
```

未加自动化 unit test —— 脚本简单到回归风险低于维护测试的成本。如果以后字段 schema 改动多，再补 `test_common.py` 验 `_common.py`。
