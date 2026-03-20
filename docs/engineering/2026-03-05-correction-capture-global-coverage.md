# 优化记录: CorrectionCapture 全局覆盖

**日期**: 2026-03-05
**版本**: v0.2.0
**类型**: 优化
**模块**: CorrectionCapture / CaptureProfile

## 变更历史

| 版本 | 日期 | 说明 |
|------|------|------|
| v0.1.0 | 2026-03-03 | 初始实现，仅 AX 直接读取，只在 Telegram 可用 |
| v0.2.0 | 2026-03-05 | 全局覆盖重写，经历 3 轮迭代 |

## 问题

纠错捕获功能只在 Telegram 中能正常工作，微信、Claude、Terminal 等常用 app 均无法捕获用户修改。

### 根因

原始 `readFocusedText()` 实现过于简单，只做了一步：

```swift
取 app 的 focusedUIElement → 读 kAXValueAttribute
```

失败场景：
- **微信**: 自定义输入框不暴露 kAXValueAttribute，AX 元素不可找到
- **Claude**: Electron app，AX 元素不暴露
- **Terminal**: AX 返回整个 scrollback buffer（5万+字符），不是当前命令行

## 迭代过程

### 迭代 1: 三层策略（AX + 按键重建 + 直接读取）

初始方案：
1. AX 深度遍历 + `kAXValueChangedNotification` 实时追踪
2. 按键重建（追踪退格和字符输入重建最终文本）
3. 直接 AX 读取兜底

**问题发现**：
- 终端提交信号配为 `cmdEnter`，但用户实际按 Enter → 永远捕获不到
- 解决：按键模式下检测 `hasEdited`（按过退格），Enter 时自动触发

### 迭代 2: 按键去重

**问题发现**：
- 按键重建文本中每个字符重复 8 次（`ccccccccoooooooowwwwwwww`）
- 原因：按住键时系统发 key repeat 事件
- 解决：`event.isARepeat` 过滤

**问题发现**：
- Electron app (Claude) 每个按键重复 2 次（`ggeemmiinnii`）
- 原因：Electron 对每个按键发两次 keyDown，不算 isARepeat
- 解决：50ms 内同一 keyCode 去重

### 迭代 3: 放弃按键重建，改用剪贴板快照

**问题发现**：
- 中文输入法下按键重建根本不可行：NSEvent keyDown 捕获的是原始拼音（`rizhi`），不是 IME 提交的汉字（`日志`）
- 这是按键重建方案的根本性缺陷，无法通过去重修复

**最终方案**：
- 按键监听只负责**检测是否有修改**（退格键 → `hasEdited = true`）
- 确认有修改后，用**一次剪贴板快照**读取真实文本
- 剪贴板使用最小化：仅在 AX 不可用 + 确认有编辑 + 提交时才触发一次

## 最终架构

```
startWindow() 启动时自动检测：

  AX 可找到文本元素？
    ├─ 是 → AX buffer > 5x 注入文本？
    │    ├─ 是 → edit-detect 模式（终端）
    │    └─ 否 → AX observer 模式
    └─ 否 → edit-detect 模式（Electron 等）

AX observer 模式:
  注册 kAXValueChangedNotification → 实时追踪 latestText/previousText
  提交信号时 → 读 latestText（如空则用 previousText）

edit-detect 模式:
  监听退格键 → hasEdited = true
  Enter + hasEdited → 剪贴板快照（Cmd+A → Cmd+C → 读取 → 恢复 → 取消选中）
  Enter + !hasEdited → 忽略（用户没修改）
```

## 设计原则

- **AX 优先** — 能用 AX 的 app 完全不碰剪贴板
- **剪贴板最小化** — 只在 AX 不可用 + 确认有编辑时才用一次，用完立即恢复
- **自动检测，零配置** — 无需 per-app 配置捕获方法
- **metadata 记录捕获模式** — `captureMode: "ax" | "clipboard"`，便于分析

## 改动文件

| 文件 | 改动 |
|------|------|
| `Sources/CorrectionCapture.swift` | 完全重写：AX observer + edit-detect + 剪贴板快照 |
| `docs/dev-context.md` | 更新纠正捕获状态，移除已知 AX 限制记录 |

## 实测结果

### 已验证的 app

| App | Bundle ID | 模式 | 结果 |
|-----|-----------|------|------|
| Telegram | ru.keepcoder.Telegram | AX observer | 纠正捕获成功，quality 0.92 |
| Claude | com.anthropic.claudefordesktop | edit-detect | 触发成功（v0.2.0 前按键重建有精度问题，v0.2.0 改用剪贴板快照） |
| 微信 | com.tencent.xinWeChat | edit-detect | 触发成功，未修改时正确跳过 |
| 终端 | com.apple.Terminal | edit-detect | 触发成功（v0.2.0 前按键重建有精度问题，v0.2.0 改用剪贴板快照） |

### 已知的遗留问题

1. **重复 Submit signal** — 部分 app 每次 Enter 触发 2-3 次事件，已通过 `isMonitoring` guard 防止重复处理
2. **Obsidian / Chrome 未实测** — 理论上 edit-detect 模式应可工作

## 完整闭环

```
语音输入 → VoicePipeline.process()
  Step 1: AlternativeSwap.apply()     ← 读 corrections.jsonl
  Step 3: TextInjector.insert()       → 注入文字
  Step 4: CorrectionCapture.startWindow()
            ↓
          AX 模式: 通知实时记录
          edit-detect 模式: 退格检测修改
            ↓
          提交信号 (Enter / Cmd+Enter / 焦点切换)
            ↓
          captureAndCompare()
            AX 模式: 读 latestText
            edit-detect 模式: 剪贴板快照读取真实文本
            ↓
          CorrectionStore.save() → corrections.jsonl
            ↓
          下次 AlternativeSwap 读取历史，同一纠正 >=2 次后自动替换
```

## 测试方法

1. 语音输入一段话 → 退格修改错字 → Enter 发送
2. 检查 `~/.we/corrections.jsonl` 是否有新记录
3. 检查 `~/.we/debug.log` 中 `[CorrectionCapture]` 日志
4. 重复同一纠正 2 次后，第 3 次语音输入应自动替换
5. 在以下 app 中分别测试: Telegram、微信、Claude、Terminal、Obsidian、Chrome
