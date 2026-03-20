# 优化记录: 语音 Pipeline 全链路优化

**日期**: 2026-03-18
**版本**: v0.4.0
**类型**: 优化 + Bug 修复
**模块**: VoicePipeline / PolishClient / CorrectionCapture / AlternativeSwap / VoiceModule

## 变更历史

| 版本 | 日期 | 说明 |
|------|------|------|
| v0.1.0 | 2026-03-03 | 初始实现 |
| v0.2.0 | 2026-03-05 | L3 全局覆盖重写 |
| v0.3.0 | 2026-03-17 | L2 低置信度润色上线 |
| v0.4.0 | 2026-03-18 | 全链路优化：启动加速 + 词典配置化 + 终端纠错修通 |

## 今日优化总览

共 5 项优化，解决了 3 个阻塞性问题：

| 优化项 | 问题 | 解决方案 | 效果 |
|--------|------|---------|------|
| L2 上线测试 | 0.6B 模型输出全是 `!!!!` | 关闭 L2，等 adapter 训练 | 避免 1.7s 无效延迟 |
| 录音启动加速 | 按下热键到开始识别 ~2s | 截屏 OCR 改为并行 | 按下即录 |
| 配置驱动词典 | Claude 永远被识别为 cloud | keywords + replacements 配置化 | cloud→Claude 生效 |
| 终端纠错修通 | Ghostty 45 次语音 0 条纠错 | AX buffer 搜索替代 shell hook | 7 条纠错已积累 |
| 数据自动清理 | 脏数据污染 L1 学习 | 写入时自动过滤 | 28→25 条 |

## 优化 1: L2 低置信度润色（上线后关闭）

### 过程

1. 接入 Qwen3 0.6B (Q4_K_M, 378MB) 到 pipeline
2. 只处理低置信度片段，高置信度词不经过模型
3. 实测 38 tok/s，prompt 5ms，延迟 ~1.7s

### 问题

模型输出全是退化内容（`!!!!!...`）：
- Qwen3 默认开启 thinking 模式，`<think>` 消耗了所有 tokens
- 加了 `/no_think` 和 `cleanModelOutput()` 后仍然退化
- **根因：0.6B 通用模型无法完成指令跟随的纠错任务**

### 决策

关闭 L2（`config.json` 中 `"enabled": false`），等数据积累到 500 条后训练专用 LoRA adapter。已写好训练脚本：
- `scripts/prepare_training_data.py` — 数据预处理
- `scripts/train_adapter.py` — 在 4090 上训练

## 优化 2: 录音启动加速

### 问题

按下热键到开始识别有 ~2 秒延迟：
```
14:10:52  按下热键
14:10:52  截屏 OCR 开始
14:10:53  OCR 完成 (1039ms)
14:10:54  注入 keywords，识别开始  ← 2 秒后
```

### 解决

截屏 OCR 从阻塞改为并行：

**之前**: 截屏 → 等完 → 注入 keywords → 启动录音
**现在**: 注入 config keywords → 立即启动录音 → 截屏后台并行跑

录音通常持续 2-5 秒，截屏只要 1 秒，结束时 screenContext 早已就绪。

### 改动

`Sources/VoiceModule.swift`: 将 `ScreenContextProvider.capture()` 移到 `voiceSession.start()` 之后的 `Task {}` 中。

## 优化 3: 配置驱动的词典和替换

### 问题

"Claude" 在所有日志中被 SA 识别为 "cloud"（23 次全错），L3 纠错也从未产生有效的 `cloud→Claude` 记录。

### 分析

1. `contextualStrings` 注入 "Claude" 后 SA 仍然输出 "cloud" — SA 声学模型把这个发音锁死了
2. L3 历史纠正中没有有效的 cloud→Claude 记录（被按键重建 bug 污染）
3. 需要一个确定性的强制替换机制

### 解决

在 `~/.we/config.json` 中新增两个配置字段：

```json
"keywords": ["Claude", "Claude Code", "CLAUDE.md", "cron", "fallback", "SSH"],
"replacements": {
    "cloud": "Claude",
    "cold": "Code",
    "crown": "cron"
}
```

- **keywords**: 注入 SA 的词汇提示（尝试让 SA 识别对）
- **replacements**: L1 强制替换（SA 识别不对时兜底），逐词匹配

改完 config 即生效，不需要重新编译。

### 改动

| 文件 | 改动 |
|------|------|
| `Sources/WEConfig.swift` | 新增 `keywords` 和 `replacements` 字段 |
| `Sources/AlternativeSwap.swift` | `apply()` 新增 `replacements` 参数，强制替换优先级最高 |
| `Sources/VoicePipeline.swift` | 传入 `replacements` |
| `Sources/VoiceModule.swift` | 用 `config.keywords` 替代硬编码列表 |

## 优化 4: 终端纠错修通（核心修复）

### 问题

Ghostty 终端占语音输入 90%（45 次/天），但**纠错捕获为 0**。

### 根因分析

终端纠错经历了三次方案迭代，全部失败：

| 方案 | 失败原因 |
|------|---------|
| shell hook (preexec) | 只在执行 shell 命令时触发，Claude Code 聊天不触发 preexec |
| 剪贴板快照 (Cmd+A) | 终端里 Cmd+A 选中整个 buffer（3万+字符），不是输入行 |
| prompt prefix 检测 | Claude Code 是 TUI 应用，没有固定的 shell prompt |

### 最终解决

**AX buffer 前缀搜索**：

```
1. 注入时记住 insertedText
2. 用户按 Enter 时，从 AX buffer 末尾反向搜索
3. 找到包含 insertedText 前 8 个字符的行
4. 提取该行内容作为 finalText（用户可能已编辑）
5. 对比 insertedText vs finalText，保存差异
```

适用于所有终端场景：shell 命令、Claude Code、vim 等 TUI。

### 验证

修复后立即积累到 7 条 Ghostty 纠错：
```
forback → fallback     q=0.82
crown → cron           q=0.84
拍清楚 → 看清楚        q=0.96
赚大端 → 端到端        q=0.95
emo → eval             q=0.73
```

### 改动

`Sources/CorrectionCapture.swift`:
- 新增 `readTerminalEditedText()` 方法
- 终端优先用 prompt prefix，fallback 到前缀搜索
- 非终端 app 继续用剪贴板快照

## 优化 5: 数据自动清理

### 问题

corrections.jsonl 中有脏数据（按键重建 bug 残留），污染 L1 学习：
```
"嗯那" → "ggeemmiinnii"     ← 重复字符
"juju2"                      ← 按键重建垃圾
quality < 0.4                ← 捕获噪声
```

### 解决

`CorrectionStore.save()` 写入前自动检查三项：
- 未修改（insertedText == userFinalText）→ 不写
- quality < 0.4 → 不写
- 包含重复字符（同一字符连续出现 4 次以上）→ 不写

同时手动清理了历史数据：28 → 25 条。

## 当前数据状态

```
corrections.jsonl: 30 条
  ├── Telegram:  13 条
  ├── Ghostty:    7 条  ← 今天新增（之前为 0）
  ├── Claude:     3 条
  ├── 终端:       2 条
  ├── Chrome:     2 条
  ├── 微信:       2 条
  └── Obsidian:   1 条

L2 训练就绪: 30/500 (继续积累中)
```

## 当前系统配置

`~/.we/config.json`:
```json
{
  "keywords": ["Claude", "Claude Code", "CLAUDE.md", "cron", "fallback", "SSH", "Ghostty", "GGUF", "LoRA", "Qwen", "llama.cpp"],
  "replacements": {"cloud": "Claude", "cold": "Code", "crown": "cron"},
  "polish": {"enabled": false, "type": "local", ...},
  "screenContext": {"enabled": true, ...}
}
```
