# Runbook

## 一次性环境准备

```bash
make setup-metal   # 装 Apple Metal Toolchain（Qwen MLX backends 需要）
                   # 如果报 DVTPlugInLoading 错，先 `sudo xcodebuild -runFirstLaunch` 再 retry
make setup-cert    # 创建本地自签名证书 → cdhash 跨重建稳定 → TCC 授权不丢
                   # 跳过也行，但每次 rebuild 都得重授 Microphone + Accessibility
```

## 启动 / 构建

```bash
make build         # 编 release + 签名 + 打 .app bundle 到 ./build/VoiceTyping.app
                   # 内嵌 mlx.metallib + Silero VAD model + WhisperKit shaders
make run           # build + open .app
make install       # build + 拷到 /Applications/
make debug         # 仅 swift build（不打 bundle，给 Xcode debug 用）
make clean         # rm -rf build .build + swift package clean
```

## 测试

```bash
make test              # unit only，CI 也跑这个，~10s
make test-e2e          # unit + E2E（真模型 + 真音频），~分钟级
make benchmark-vad     # VAD tuning preset 横扫（v0.4.5 用）
make benchmark-speed   # 3 backend × N fixture 转写速度 + RTF（v0.5.1 用）
```

E2E 前置：`make setup-metal` 完成 + 至少一次 `make run` 触发 Qwen 模型下载。

## Debug

- **日志**：subsystem `com.voicetyping.app`
  ```bash
  log stream --predicate 'subsystem == "com.voicetyping.app"' --style compact
  ```
- **dev 通道**：默认关。Settings → Advanced → Verbose pipeline diagnostics 打开 → `Log.dev.*` 调用点开始打印
- **TCC 重授权**：`make reset-perms` → `tccutil reset Microphone/Accessibility com.voicetyping.app`，下次启动重弹授权
- **Debug Data Capture**：Settings → Advanced 开启 → 每次录音 audio + 段级 transcript + inject result（v0.6.3+ 含 LLM refine I/O + 延迟，v0.7.3+ 含 MLX 内存快照）落盘到 `~/Library/Application Support/VoiceTyping/debug-captures/<session>/`，schema 见 `docs/debug-captures.md`
- **模型缓存**：`~/Library/Application Support/VoiceTyping/models/<backend>/`；删了重启会重新下载
- **prepare 计时**：v0.5.1 起 Qwen 启动会打 `Qwen prepare timing: backend=… cached=… offline=… total=…ms load=…ms warmup=…ms stages=[...]`
- **挂起线程栈**（v0.7.2+）：live-mode 转写胶囊卡 5 s 以上时 `TranscribeWatchdog` 自动跑 `sample(1)` 把线程栈落到 `~/Library/Application Support/VoiceTyping/hang-stacks/<timestamp>_<callsite>.txt`。MLX `relu` 锁卡 GPU 事件的 spike 全过程见 `docs/spike/v0.7.1-vad-hang.md`
- **MLX 内存实时观察**（v0.7.3+）：`Log.llm` 每次 refine 跑完会打 `mlxActive=… mlxCache=… mlxPeak=…`。长跑下若 `mlxCache` 持续上涨说明 `MLX.Memory.cacheLimit` 没生效（应稳定在 ~1 GB），决策见 [`decisions/0003-bound-mlx-cache-pool.md`](decisions/0003-bound-mlx-cache-pool.md)

## 发布

**v0.6.0 起走 DMG + Sparkle 流程，详见 [`docs/release-process.md`](release-process.md)**。要点速览：

1. 完成所有 `docs/todo/vX.Y.Z.md` 必做项 → `make test-e2e` 全绿
2. 写 `docs/devlog/vX.Y.Z.md`（背景 + 决策 + 落地 + 验证 + 已知遗留）
3. 更新 `CHANGELOG.md` 用户可见变更（这是 release notes 的源）
4. 更新 `docs/todo/backlog.md`（划掉完成项 / 把决策迁到对应版本 doc）
5. bump `Resources/Info.plist`：`CFBundleShortVersionString` + `CFBundleVersion`
6. `make release` 打 DMG（hard-check `mlx.metallib` 嵌入，签名 + EdDSA 签 sparkle update）
7. commit + `git tag vX.Y.Z` + push
8. `gh release create vX.Y.Z build/VoiceTyping-X.Y.Z.dmg --notes-file docs/devlog/vX.Y.Z.md`
9. 把 `build/gh-pages/appcast.xml` push 上去触发已装用户 Sparkle 自动检测

> ~~v0.5.x 以前的"`make install` 开发者自取"流程已废弃~~。具体命令、Sparkle EdDSA 签名 key 管理、TCC 跨升级保留验证等见上面 `release-process.md`。
>
> 也可以走 `close-iteration` skill 自动化前 6 步（写 devlog + 更 CHANGELOG + bump Info.plist + commit）。
