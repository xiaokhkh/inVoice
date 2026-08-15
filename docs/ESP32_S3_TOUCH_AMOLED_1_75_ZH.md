# ESP32-S3 Touch AMOLED 1.75 收音器与集成交接

![ESP32-S3 圆屏收音器连接 Mac 的按住说话场景](assets/voiceops-hardware-use-case.png)

## 硬件型号

本项目把 Waveshare 圆屏开发板改造成 inVoice 专用的 USB 收音器、物理
按住说话控制器和剪贴板入口。当前实测目标为标准版
`ESP32-S3-Touch-AMOLED-1.75`，Waveshare SKU `31261`。

| 部件 | 型号 / 规格 | 本项目用途 |
| --- | --- | --- |
| 开发板 | `ESP32-S3-Touch-AMOLED-1.75`，SKU `31261` | 当前实测目标 |
| 主控 | `ESP32-S3R8`，双核 LX7，最高 240 MHz | USB Audio、HID、OTA 与 UI |
| 存储 | 8 MB PSRAM + 外置 16 MB Flash | 双 OTA 槽与保留的 Jam assets |
| 显示 | 1.75 英寸 466×466 AMOLED，`CO5300` | Jam 动画和绿色整圈音量环 |
| 触摸 | `CST9217` | 屏幕按住说话 |
| 音频 | 双麦克风 + `ES7210` | 24 kHz 单声道 USB 收音 |
| 电源 / I/O | `AXP2101` + `TCA9554` | PWR 输入、电源与扩展 GPIO |
| 其他 | `QMI8658` IMU + `PCF85063` RTC | 板载但当前链路不依赖 |

官方还提供带壳版 `-B`（SKU `31262`）和 GPS 版 `-G`（SKU `31264`），
但本项目只对 SKU `31261` 做回归验证。不要刷入名字相近但硬件不同的
`ESP32-S3-Touch-AMOLED-1.75C`。型号与规格来源：
[Waveshare 官方文档](https://docs.waveshare.com/ESP32-S3-Touch-AMOLED-1.75)、
[Espressif ESP32-S3 数据手册](https://www.espressif.com/sites/default/files/documentation/esp32-s3_datasheet_en.pdf)。

## 项目目录

固件已集成在主仓库内：

```text
firmware/esp32-s3-touch-amoled-1.75/
```

macOS 应用的默认安装位置：

```text
~/Applications/inVoice.app
```

原始小智全片备份和 Jam assets 备份不纳入 Git；首次刷写前应另外保存一份，
并避免使用 `erase-flash`。

## 已实现链路

```text
屏幕 / PWR 按住
  -> ESP32-S3 发送 HID F13 key-down
  -> inVoice 捕获原输入框和应用
  -> inVoice 选择 MLX Voice Mic 录音
  -> 24 kHz 单声道转换为 16 kHz ASR 输入
  -> 松开时发送 HID F13 key-up
  -> GLM-ASR 最终识别
  -> 本地 Ollama 可选处理
  -> 目标 PID 未变化时发送一次 Cmd+V；否则保留到剪贴板

固件运行时按一下 BOOT
  -> ESP32-S3 发送 HID F14 key-down / key-up
  -> inVoice 切换剪贴板历史面板

650 ms 内短按屏幕两次
  -> ESP32-S3 直接发送一次标准 HID Enter key-down / key-up
  -> 当前前台应用按普通 Return 处理，不需要 inVoice 转译
```

板端 USB 设备：

- 产品名：`MLX Voice Mic`
- VID/PID：`0x303A / 0x4002`
- 音频：24 kHz、单声道、16-bit PCM
- HID：F13 为语音 PTT，F14 为剪贴板面板开关，标准 Enter 为屏幕短按 Return
- OTA：独立厂商 HID，通过现有 Type-C 传输，不产生键盘事件
- 麦克风：板载 ES7210，模拟增益 36 dB

## 扩展坞与热插拔保护

- macOS 不再把系统里的任意 F13/F14 当成板端输入，而是通过 IOKit 直接
  匹配 `0x303A / 0x4002` 的键盘 HID 接口。
- 每个已枚举板端设备独立保存按下状态；扩展坞重枚举或设备拔出时删除该
  设备，并立即强制结束仍在进行的板端输入。
- 固件每 250 ms 重发一次 F13/F14/Return 的完整绝对状态。扩展坞休眠/恢复期间
  即使丢失一次松开报告，也会在链路恢复后自动纠正，不会一直停留在输入状态。
- 屏幕连续稳定 40 ms 即接受点击；PWR 和 BOOT 仍要求
  连续稳定 100 ms。长按屏幕仍需 250 ms 才启动语音。
- 系统 Fn 快捷键仍按原逻辑工作；其他键盘或扩展坞产生的 F13/F14 不会
  触发板端录音。

## 板端 UI 行为

- 保留原小智 `assets` 分区里的 Jam GIF。
- 待机不显示底部文字。
- 只有按住屏幕或 PWR 时显示绿色圆形实时音量环。
- 松开后圆环立即隐藏并结束 inVoice 本次输入。
- 屏幕短按一次无动作；去抖后按住 250 ms 才启动语音，650 ms 内完成两次
  短按会直接发送标准 Return，可用于 Codex、浏览器、终端和聊天输入框。
  BOOT 仍是单击打开剪贴板。
- 固件正常运行时按 BOOT 只切换剪贴板面板，不启动录音或音量环。
- 自然人声和主机单独打开麦克风不会触发圆环或 F13。
- PWR 长按关机动作被关闭，避免长句录音时断电。

## “识别成功但没有输入文字”的原因

已经确认板端、USB 音频和 ASR 都正常。故障发生在 inVoice 的最后一步：

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

## 构建与安装 inVoice

在主项目根目录执行：

```bash
xcodebuild -project apps/macos/VoiceOps.xcodeproj \
  -scheme VoiceOps -configuration Release build
```

或者使用项目安装器复用已有模型：

```bash
./scripts/install.sh --skip-models --skip-ollama
```

inVoice 需要三项 macOS 权限：

- 输入监控：接收系统 Fn；板端 F13/F14 由绑定 VID/PID 的 IOKit HID
  监控独立接收。
- 辅助功能：向当前目标应用发送合成 Cmd+V；最终方案不再强制恢复 AX 焦点。
- 麦克风：采集 `MLX Voice Mic`。

## 构建与更新板端固件

详见 `firmware/esp32-s3-touch-amoled-1.75/README.md`。关键限制：

- 仅适用于 Waveshare ESP32-S3-Touch-AMOLED-1.75，不能刷到 1.75C。
- 不要运行 `erase-flash`，否则会删除保留的 Jam assets。
- Jam assets 位于 Flash `0x800000-0xFFFFFF`。
- OTA 使用 `ota_0/ota_1` 双应用分区，Jam assets 的地址和大小不变。
- 不需要 5 线下载器，不需要 Wi-Fi；主机通过同一根 Type-C 线上的独立厂商 HID 更新。
- 由于首次安装需要写入新分区表，只在这一次按住 BOOT 重新连接 USB 进入 ESP32-S3 ROM 下载模式。
- 首次安装完成后执行 `./scripts/update_esp32_firmware.sh` 即可自动校验、写入非活动槽并重启，不再按 BOOT/Fn/PWR/屏幕。
- 正常运行时 BOOT 始终只负责剪贴板面板，不再承担固件更新触发。

主机协议、分区地址、CRC 和回滚流程见：

```text
docs/ESP32_USB_OTA_PROTOCOL.md
```

## 当前仍需关注

1. 自动化和构建检查已通过，仍需在 Codex、浏览器、飞书、TextEdit、
   Terminal 等输入框完成人工回归，并测试识别期间切换应用的 copy-only 行为。
2. 项目默认提示词面向“中文语音转自然英文”，所以中文 ASR 结果可能被本地 LLM 改成英文；若需要中文原样输入，应在 Preferences 调整语音提示词或让路由直接使用 ASR 文本。
3. Jam GIF 本体没有复制进仓库，固件继续读取开发板已有的 `assets` 分区；全片擦除后必须从备份恢复。
4. BOOT 在固件运行时只用于剪贴板面板；仅首次安装或 OTA 已损坏的恢复场景才需要在重连时按住 BOOT 进入 ROM 下载模式。
