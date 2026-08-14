# ESP32-S3 Touch AMOLED 1.75 麦克风集成交接

## 项目目录

统一后的主项目目录：

```text
/Users/aminer/Documents/Codex/2026-08-10/https-github-com-xiaokhkh-mlx-voiceops/work/mlx-voiceops
```

板端固件已经集成到：

```text
firmware/esp32-s3-touch-amoled-1.75/
```

当前安装并运行的 macOS 应用：

```text
/Users/aminer/Applications/VoiceOps.app
```

原始小智完整备份、Jam assets 备份及独立刷机包仍保存在：

```text
/Users/aminer/Documents/Codex/2026-08-14/j/outputs/
```

## 已实现链路

```text
屏幕 / PWR 按住
  -> ESP32-S3 发送 HID F13 key-down
  -> VoiceOps 捕获原输入框和应用
  -> VoiceOps 选择 MLX Voice Mic 录音
  -> 24 kHz 单声道转换为 16 kHz ASR 输入
  -> 松开时发送 HID F13 key-up
  -> GLM-ASR 最终识别
  -> 本地 Ollama 可选处理
  -> 目标 PID 未变化时发送一次 Cmd+V；否则保留到剪贴板

固件运行时按一下 BOOT
  -> ESP32-S3 发送 HID F14 key-down / key-up
  -> VoiceOps 切换剪贴板历史面板
```

板端 USB 设备：

- 产品名：`MLX Voice Mic`
- VID/PID：`0x303A / 0x4002`
- 音频：24 kHz、单声道、16-bit PCM
- HID：F13 为语音 PTT，F14 为剪贴板面板开关
- 麦克风：板载 ES7210，模拟增益 36 dB

## 板端 UI 行为

- 保留原小智 `assets` 分区里的 Jam GIF。
- 待机不显示底部文字。
- 只有按住屏幕或 PWR 时显示绿色圆形实时音量环。
- 松开后圆环立即隐藏并结束 VoiceOps 本次输入。
- 固件正常运行时按 BOOT 只切换剪贴板面板，不启动录音或音量环。
- 自然人声和主机单独打开麦克风不会触发圆环或 F13。
- PWR 长按关机动作被关闭，避免长句录音时断电。

## “识别成功但没有输入文字”的原因

已经确认板端、USB 音频和 ASR 都正常。故障发生在 VoiceOps 的最后一步：

1. `FnSessionController` 录音开始时保存了目标应用 PID；识别完成后再次比较当前前台 PID。
2. 处理期间只要前台应用发生短暂变化，旧逻辑就执行 `inject_skip`，完全不尝试写入已保存的输入框。
3. `FocusInjector` 的 `kAXSelectedTextAttribute` 调用只检查 API 返回值，没有验证输入框内容是否真的改变。部分 WebView/Electron 输入框可能返回成功但没有完成可见写入。

历史记录数据库证明识别结果已经生成，目标应用也正确记录为
`com.openai.codex`：

```text
~/Library/Application Support/mlx-voiceops/clipboard.sqlite3
```

## 已完成的输入链路整改

截至 2026-08-14，临时 AX 焦点恢复方案已经移除，最终语音链路已完成：

- Session 在权限请求和音频启动前创建，状态为
  `idle -> starting -> listening -> processing -> inserting`。
- Starting 阶段提前松开会记录 `pendingStop`，不再丢失 key-up。
- 最终文字必须领取一次性投递权；Fast ASR 只能更新 Preview。
- 只记录目标应用 PID，不保存、恢复或写入 AX 输入控件。
- 使用 private event source，在 session tap 发送一组带 Command flag 的
  V down/up；失败时只复制，不再尝试第二种写入。
- 剪贴板使用深快照、共享串行槽、changeCount、generation 和 750ms
  compare-and-restore。
- 已加入 11 个自动化测试并通过 Debug、Release 和 doctor 检查。

完整差异、TODO 和实施顺序见：

```text
docs/VOICE_INPUT_CHAIN_PLAN_ZH.md
```

主要代码：

```text
apps/macos/VoiceOps/Services/FnSessionController.swift
apps/macos/VoiceOps/Services/FocusInjector.swift
```

## 构建与安装 VoiceOps

在主项目根目录执行：

```bash
xcodebuild -project apps/macos/VoiceOps.xcodeproj \
  -scheme VoiceOps -configuration Release build
```

或者使用项目安装器复用已有模型：

```bash
./scripts/install.sh --skip-models --skip-ollama
```

VoiceOps 需要三项 macOS 权限：

- 输入监控：接收 Fn，以及板端 F13/F14。
- 辅助功能：向当前目标应用发送合成 Cmd+V；最终方案不再强制恢复 AX 焦点。
- 麦克风：采集 `MLX Voice Mic`。

## 构建与更新板端固件

详见 `firmware/esp32-s3-touch-amoled-1.75/README.md`。关键限制：

- 仅适用于 Waveshare ESP32-S3-Touch-AMOLED-1.75，不能刷到 1.75C。
- 不要运行 `erase-flash`，否则会删除保留的 Jam assets。
- Jam assets 位于 Flash `0x800000-0xFFFFFF`。
- 麦克风固件正常运行时不暴露烧录串口；更新前需要按住 BOOT 重新连接 USB 进入 ROM 下载模式。

## 当前仍需关注

1. 自动化和构建检查已通过，仍需在 Codex、浏览器、飞书、TextEdit、
   Terminal 等输入框完成人工回归，并测试识别期间切换应用的 copy-only 行为。
2. 项目默认提示词面向“中文语音转自然英文”，所以中文 ASR 结果可能被本地 LLM 改成英文；若需要中文原样输入，应在 Preferences 调整语音提示词或让路由直接使用 ASR 文本。
3. Jam GIF 本体没有复制进仓库，固件继续读取开发板已有的 `assets` 分区；全片擦除后必须从备份恢复。
4. BOOT 在固件运行时用于剪贴板面板；上电或重连时按住 BOOT 仍会进入 ROM 下载模式。
