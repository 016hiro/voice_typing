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
- **Debug Data Capture**：Settings → Advanced 开启 → 每次录音 audio + 段级 transcript + inject result 落盘到 `~/Library/Application Support/VoiceTyping/debug-captures/<session>/`，schema 见 `docs/debug-captures.md`
- **模型缓存**：`~/Library/Application Support/VoiceTyping/models/<backend>/`；删了重启会重新下载
- **prepare 计时**：v0.5.1 起 Qwen 启动会打 `Qwen prepare timing: backend=… cached=… offline=… total=…ms load=…ms warmup=…ms stages=[...]`

## 发布

参考 `docs/devlog/v0.5.1.md` 流程：

1. 完成所有 `docs/todo/vX.Y.Z.md` 必做项 → all green: `make test-e2e`
2. 写 `docs/devlog/vX.Y.Z.md`（参照已有版本结构：背景 + 决策 + 落地 + 验证 + 已知遗留）
3. 更新 `docs/roadmap.md` 当前 ship 行 + 最近三里程碑列表
4. 更新 `docs/todo/backlog.md`（划掉已完成项 / 把决策移到对应版本 doc）
5. 更新 `CHANGELOG.md` 用户可见变更
6. bump `Resources/Info.plist` 的 `CFBundleShortVersionString` + `CFBundleVersion`
7. commit：`vX.Y.Z 主题：副标题`
8. `git tag vX.Y.Z`
9. push（CI 跑 build + unit test smoke）

发版无 GitHub Release / homebrew 流程，开发者自行 `make install`。
