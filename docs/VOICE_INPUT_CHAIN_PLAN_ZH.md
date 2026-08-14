# VoiceOps 语音输入链路整改计划

## 对照快照

本计划基于 2026-08-14 16:57 CST 的代码状态：

| 项目 | 分支 / 提交 | 与本计划相关的做法 |
| --- | --- | --- |
| VoiceOps | `main` / `c9880e9`，本地 HEAD 与 `origin/main` 一致 | 当前工作区包含尚未提交的板端集成和输入链路修改 |
| OpenLess | `beta` / `40cd136` | 非激活悬浮窗；剪贴板 + 单次 Cmd+V；Session 状态机；条件恢复剪贴板 |
| Koe | `main` / `2629620` | private 事件源 + session event tap；目标 PID 和 Session guard；失败时只复制 |
| VocaMac | `main` / `23592f8` | AX 只用于少数原生单行输入框；编辑器/Electron/终端走剪贴板 + Cmd+V；串行剪贴板事务 |
| OpenWhisper | `main` / `f29eee8` | 剪贴板 + Cmd+V；流式预览与最终结果分离 |

## 目标链路

```text
屏幕 / PWR / BOOT 按下
  -> ESP32-S3 发送一次 F13 key-down
  -> VoiceOps 创建 Session，并记录当前前台应用 PID
  -> 只使用 MLX Voice Mic 录音，流式 ASR 只更新 UI
  -> 松开发送一次 F13 key-up
  -> 最终 ASR / 可选 LLM
  -> 校验 Session 仍有效、目标应用仍在前台、该 Session 尚未投递
  -> 写入剪贴板并发送一次 Cmd+V
  -> 标记该 Session 已投递
  -> 剪贴板未被用户修改时，延迟恢复原内容
```

必须维持的约束：

- 一个物理按住周期只创建一个 Session。
- 一个 Session 最多只有一个文字投递者。
- 流式识别只显示预览，不能写输入框。
- 不因 AX 无法验证 Electron/WebView 内容而重试。
- 用户切换应用后不把文字注入新应用；结果保留在剪贴板。
- 板端自然人声不能自行触发录音，只有屏幕、PWR、BOOT 按住有效。

## 整改前后对照

| 环节 | 整改前 | 2026-08-14 已实现 | 消除的风险 |
| --- | --- | --- | --- |
| 悬浮 UI | `PreviewPanel` 已是 `nonactivatingPanel` | 保持不抢焦点 | 避免 UI 抢走真实输入框 |
| 焦点 | 保存 AX 元素并强制恢复旧控件 | 只记录前台 PID；注入不匹配时 copy-only | 避免切回旧应用及 Electron AX 失效 |
| 注入 | Command down、V down/up、Command up 四个事件 | private event source；session tap 只发带 Command flag 的 V down/up | 避免实体 Fn/Control 污染快捷键 |
| 失败后备 | 事件失败后可能继续 AX 或 Unicode typing | 不做第二种写入；结果留在剪贴板 | 避免第一次已生效却再次写入 |
| 剪贴板 | 浅备份且无 `changeCount` 检查 | 深复制、共享串行槽、generation、compare-and-restore | 避免覆盖用户新复制内容和连续会话竞争 |
| 状态机 | `idle -> streaming -> ending` | `idle -> starting -> listening -> processing -> inserting` | 不再丢失 Starting 阶段的 key-up |
| 会话隔离 | 部分 UUID/token，无统一投递所有权 | 所有异步边界校验 UUID；原子领取一次投递权 | 旧回调不能影响新 Session |
| 流式识别 | 只更新 Preview | 保持且不持有 injector | 部分识别无法写输入框 |

## TODO

### P0：先消除无输入和重复输入

- [x] 在 `FnSessionController` 引入显式状态：`idle`、`starting`、`listening`、`processing`、`inserting`。
- [x] Session 在任何异步权限请求、音频启动之前创建，包含唯一 UUID、目标 PID 和投递状态。
- [x] `starting` 阶段收到 key-up 时设置 `pendingStop`；音频成功启动后立即执行停止，不能丢失松开事件。
- [x] 每个异步回调在改变 UI、停止音频或注入前检查 Session UUID。
- [x] 最终注入前原子领取一次投递权；领取失败时直接返回。
- [x] 已删除“最终 LLM 失败后再用原始 ASR 重试注入”的明显二次投递路径；后续测试继续防止其回归。
- [x] 当前 Fast ASR 只调用 `onPreviewText`；后续用测试锁定其不能调用 injector。
- [x] 保留 Fn/板端 key-down held guard，并增加 200ms Session 结束冷却，避免重复事件创建两个 Session。

验收条件：快速点按、长按、连续按两次、启动过程中立即松开时，每次最多生成一个最终注入；不存在持续录音或漏掉 key-up。

### P0：收敛为一个可靠的文字投递边界

- [x] 从最终语音输入路径移除 AX 焦点保存、强制激活旧应用和 AX 内容验证。
- [x] 注入时校验当前前台 PID 等于 Session 捕获的目标 PID；不相等时只复制并记录 `copiedFocusChanged`。
- [x] 使用 `CGEventSource(stateID: .privateState)` 创建不继承实体键盘修饰状态的事件源。
- [x] 在 `.cgSessionEventTap` 只发送 V key-down/key-up，并在两个事件上设置 `.maskCommand`。
- [x] 不再额外发送 Command key-down/key-up。
- [x] 事件源或事件创建失败时返回 copy-only，不调用 AX 写入和 Unicode 模拟打字。
- [x] 将注入结果定义为 `inserted`、`copiedFocusChanged`、`copiedNoPermission`、`copiedSessionSuperseded`、`copiedEventFailure`、`failedClipboardWrite`。

验收条件：Codex/Electron 输入框只出现一次文字；用户仍按着 Fn、Control、Option 或 Shift 时不会输出裸 `v`、错误快捷键或重复文字。

### P1：实现安全的剪贴板事务

- [x] 深复制剪贴板全部 item/type/data，不能保存会在 `clearContents()` 后失效的 `NSPasteboardItem` 引用。
- [x] 所有 `FocusInjector` 文字注入进入共享 MainActor 串行槽，上一笔 Cmd+V 发布前不能开始下一笔。
- [x] 写入文本后等待 50ms，再发送 Cmd+V。
- [x] 保存写入后的 `NSPasteboard.changeCount` 和 restore generation。
- [x] 750ms 后恢复；仅当 changeCount 仍等于本次写入值且 generation 仍为最新时执行。
- [x] 用户或剪贴板管理器在等待期间写入新内容时，跳过恢复。
- [x] copy-only 结果不恢复旧剪贴板，确保识别文本可手动粘贴。
- [x] 保留 `ClipboardObserver.markInternalWrite()`，避免内部写入污染 VoiceOps 剪贴板历史。

验收条件：粘贴成功后原剪贴板可恢复；等待期间手动复制的新内容不会被覆盖；连续两次语音输入最终仍恢复第一次之前的用户剪贴板。

### P1：输入法和目标兼容性

- [x] 按当前 ASCII-capable 键盘布局解析字符 `v` 的虚拟键码；解析失败才使用 keycode 9。
- [x] 保留 Accessibility 权限检查，因为 macOS 合成 Cmd+V 需要该权限，但不把 AX 控件写入作为通用方案。
- [x] 最终语音链路不保留 AX 直写，因此不会与 Cmd+V 在同一 Session 同时执行。

### P1：自动化测试

- [x] 状态机测试：`starting` 提前松开、重复 begin/stop、处理期间再按、旧 Session 回调和冷却。
- [x] 投递所有权测试：同一 Session 只有一次 `claimInsertion` 能成功。
- [ ] 焦点测试：目标 PID 不变时允许注入；切换应用时只复制。
- [x] 剪贴板测试：富类型深复制、用户中途复制、连续两次注入、copy-only 和串行槽。
- [x] 事件计划测试：只生成 V down/up，二者均带 Command flag；实际代码失败路径只有 copy-only。
- [x] Fast ASR 代码结构不持有 injector，部分结果只能调用 `onPreviewText`。

### P2：设备和人工回归

- [x] 代码一次只绑定一个 CoreAudio input；`system_profiler` 已识别 `MLX Voice Mic` 为 USB、单通道、24kHz。
- [ ] 分别测试屏幕、PWR、BOOT 的按住/松开，每种触发只产生一组 F13 down/up。
- [ ] 测试 Codex、Chrome/Safari contenteditable、飞书、TextEdit、Terminal/iTerm2、中文输入法和非 QWERTY 布局。
- [ ] 测试识别期间切换应用、点击其他输入框、复制新内容、拔插板子以及连续快速录音。
- [x] 日志统一携带 Session ID、状态转换、目标/当前 PID、投递所有权和最终 delivery status。
- [x] 本次未修改板端触发/UI 代码；固件继续只在物理按住期间显示绿色圆形音量环，松开隐藏且无底部文字。

## 实施与自动验证结果

- 新增独立 `VoiceOpsCore` Swift Package 和 11 个自动化测试，全部通过。
- VoiceOps Debug、Release 构建通过，Release app 签名验证通过。
- 已更新 `/Users/aminer/Applications/VoiceOps.app`，系统当前只运行一个实例。
- `scripts/doctor.sh` 对 sidecar、模型、Ollama、应用签名和资源路径检查为 0 警告。
- 尚未勾选的项目需要真实按键、说话和多目标应用交互，必须由人工回归完成。

## 实施顺序

1. **状态机和单次投递权**：先从逻辑上保证一个 Session 只能走到一次注入。
2. **替换 FocusInjector 最终路径**：移除强制 AX 焦点恢复，改为 PID guard + private/session Cmd+V；失败只复制。
3. **剪贴板事务**：加入深快照、串行队列、changeCount 和 generation。
4. **测试与日志**：先跑单元测试，再构建 Release，最后安装到 `/Users/aminer/Applications/VoiceOps.app` 做板端回归。

每一阶段完成并通过对应测试后再进入下一阶段，避免同时修改按键、录音、ASR 和注入导致问题无法定位。

## 暂不实施

- 不做流式文字实时写入输入框。
- 不通过自然人声自动开始录音。
- 不在焦点变化后强制切回原应用。
- 不以“AX 无法验证”为理由再次投递同一段文字。
- 不擦除开发板完整 Flash；继续保留 Jam assets 分区。
