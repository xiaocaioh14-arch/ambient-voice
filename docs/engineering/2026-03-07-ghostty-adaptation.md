# 优化记录: Ghostty 终端适配

**日期**: 2026-03-07
**类型**: 新应用适配
**模块**: TextInjector / CorrectionCapture / CaptureProfile

## 问题

语音输入在 Ghostty 终端中完全不工作：文本无法注入，纠错捕获拿到垃圾数据。

## 根因分析

### 1. 文本注入失败

TextInjector 默认走 AX API 路径（`AXUIElementSetAttributeValue`），对 Ghostty 返回 `.success` 但文本实际未进入终端——**AX API 谎报成功**。

Ghostty 不在 `clipboardOnlyBundleIDs` 列表中，所以未走剪贴板路径。

### 2. 剪贴板 + CGEvent Cmd+V 也不工作

将 Ghostty 加入 `clipboardOnlyBundleIDs` 后，切换到剪贴板路径。但 `CGEvent.post(tap: .cghidEventTap)` 模拟的 Cmd+V 按键在 Ghostty 中不生效，推测与 Secure Keyboard Entry 或 Ghostty 自身的输入处理机制有关。

### 3. 纠错捕获拿到终端全屏内容

edit-detection 模式的 `readViaClipboard()`（Cmd+A → Cmd+C）在终端中拿到的是整个屏幕内容（如 Claude Code TUI 界面 `▐▛███▜▌`），不是用户编辑的命令行。

### 4. TUI 应用的 AX buffer 不同步

在 Ghostty 中运行 TUI 应用（如 Claude Code）时，AX buffer 不反映输入区的实时文本。注入后即时读取和 300ms 后重试，AX buffer 中的输入提示符 `❯` 行始终为空。

## 解决方案

### 文本注入: AX 菜单 Paste（最终方案）

放弃键盘事件模拟，改为通过 Accessibility API 直接按目标应用的菜单栏 Edit → Paste：

```swift
// 1. 设置剪贴板
pasteboard.setString(text, forType: .string)

// 2. 通过 AX 导航菜单: Menu Bar → Edit → Paste → AXPress
AXUIElementPerformAction(pasteMenuItem, kAXPressAction as CFString)
```

**优势**: 走 AX 通道而非键盘事件注入，不受 Secure Keyboard Entry 限制。对所有有 Paste 菜单项的应用通用。

兜底: 如果菜单方式失败，回退到 CGEvent Cmd+V（`.cgSessionEventTap`）。

### 纠错捕获: 终端 prompt 前缀检测 + TUI 优雅降级

**Shell prompt 场景**（理论可用）:
1. 注入后从 AX buffer 中找到 `insertedText`，提取前面的 prompt 前缀（如 `user@host:~$ `）
2. 捕获时用同一前缀在 buffer 末尾找到最后一条非空命令行
3. 异步重试机制（Timer 300ms）等待 paste 生效后再检测

**TUI 场景**（优雅降级）:
- 检测到终端应用且 prompt 检测失败 → 判定为 TUI 应用
- 直接跳过纠错捕获，不捕获垃圾数据
- 日志记录 `tui-unsupported`

## 变更文件

| 文件 | 变更 |
|------|------|
| `TextInjector.swift` | 新增 Ghostty bundleID 到 `clipboardOnlyBundleIDs`；新增 `triggerPasteViaMenu()` AX 菜单粘贴方法；新增 `isTerminalApp()` 公开方法；`clipboardInsertion` 增加 pid 参数，注入前激活目标 app |
| `CorrectionCapture.swift` | 新增 `detectTerminalPrompt()` / `tryDetectPrompt()` / `readTerminalLine()` 终端命令行读取；TUI 场景优雅降级跳过捕获 |
| `CaptureProfile.swift` | 新增 Ghostty profile（`submitSignal: .enter`）|

## 迭代过程

| # | 尝试 | 结果 |
|---|------|------|
| 1 | 加入 `clipboardOnlyBundleIDs` | 未重新安装，实际未生效 |
| 2 | `clipboardInsertion` 增加 `activate()` + CGEvent Cmd+V | CGEvent 在 Ghostty 中不生效 |
| 3 | 换 `.cgSessionEventTap` + AppleScript System Events 兜底 | AppleScript 兜底逻辑未触发（CGEvent "成功"但无效） |
| 4 | AX 菜单 Edit → Paste | 注入成功 |
| 5 | 纠错: prompt 前缀检测 | AX buffer 不同步，TUI 场景检测失败 |
| 6 | 纠错: 异步重试 300ms | 仍然失败，确认 AX buffer 不反映 TUI 输入 |
| 7 | TUI 优雅降级 | 最终方案，干净跳过 |

## 经验总结

1. **AX API 会谎报成功**: 对终端应用，`AXUIElementSetAttributeValue` 返回 `.success` 不代表文本真的被写入。必须通过 `clipboardOnlyBundleIDs` 黑名单跳过。
2. **CGEvent 按键模拟不可靠**: Ghostty 等现代终端可能屏蔽合成键盘事件（Secure Keyboard Entry）。AX 菜单操作是更可靠的跨应用粘贴方式。
3. **`make install` vs `make build`**: 如果用户通过 `/Applications/WE.app` 运行，`make build` 只编译不部署，必须 `make install` 才能让改动生效。调试时要确认运行的是新版本。
4. **TUI 应用的 AX buffer 有根本局限**: 终端的 AX value 是屏幕文本的静态表示，TUI 应用的输入区内容可能不在其中。纠错捕获需要区分 shell prompt 和 TUI 场景。
5. **先查日志再改代码**: 日志 `Text injected via AX into Ghostty` 揭示了真正的问题路径，避免了在错误方向上浪费时间。
