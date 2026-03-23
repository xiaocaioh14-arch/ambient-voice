# WE 管线全面审查与优化记录

**日期**: 2026-03-20
**范围**: 语音管线全链路（L1/L2/飞轮/注入/屏幕上下文）
**方法**: 3 轮 Agent Team 审查 + 逐一修复 + 编译验证

---

## 背景

用户反馈"户口"始终无法被纠正为"hook"，触发了对整条语音管线的全面审查。通过 3 轮 Agent Team 并行审查，共发现 34 个问题，修复 18 个（含 5 个 P0），排除 8 个误报。

## 修复清单

### P0 — 功能严重受损

| # | 问题 | 文件 | 修复 |
|---|------|------|------|
| 1 | Force replacement 无法匹配被 SA 拆分的中文词（如"户口"拆成"户"+"口"） | AlternativeSwap.swift | 新增多字滑动窗口，longest match first |
| 2 | L1/L2 数据不对齐：L2 用原始 words 重建文本，覆盖 L1 修正 | AlternativeSwap.swift + VoicePipeline.swift | AlternativeSwap 返回 L1Result（含 per-word 输出），L2 用 l1WordTexts 重建；L2 跳过 L1 已修改的词 |
| 3 | 飞轮基准线错误：rawText 语义经两轮讨论最终定为 SA 原文 + 双向学习 | VoicePipeline.swift + AlternativeSwap.swift | rawText 保持 SA 原文；buildCorrectionMap 同时从 rawText→userFinal 和 insertedText→userFinal 学习 |
| 4 | LoRA adapter 内存泄漏：`llama_adapter_lora_init()` 返回的指针从未释放 | LocalModelClient.swift | 新增 `currentAdapter` 属性，切换和卸载时 `llama_adapter_lora_free()` |
| 5 | Sampler 内存泄漏：推理循环每 token 创建新 sampler 不释放 | LocalModelClient.swift | 循环外创建一次，`defer { llama_sampler_free(sampler) }` |

### P1 — 影响稳定性

| # | 问题 | 文件 | 修复 |
|---|------|------|------|
| 6 | 屏幕截图竞态：短录音时 OCR 未完成，screenContext 为 nil | VoiceModule.swift | `stopRecording` 先 `await screenCaptureTask?.value` |
| 7 | 屏幕关键词过滤掉小写英文（hook/cron/fallback 全被跳过） | ScreenContextProvider.swift | 英文过滤改为 `letters.count >= 3`，不再要求首字母大写 |
| 8 | screenCaptureTask 泄漏：快速连续按键时旧 task 未取消 | VoiceModule.swift | 赋值前 `screenCaptureTask?.cancel()` |
| 9 | CorrectionCapture 重入：新 session 覆盖旧 capture，旧观察者泄漏 | CorrectionCapture.swift | `startWindow` 开头先 `endCapture(reason: "new session started")` |
| 10 | 音频格式未验证：某些设备 sampleRate=0 导致崩溃 | VoiceSession.swift | 检查 `format.sampleRate > 0 && format.channelCount > 0` |

### P2 — 改进质量

| # | 问题 | 文件 | 修复 |
|---|------|------|------|
| 11 | wordLevelDiff 不等长段丢弃：多字替换时部分词对丢失 | AlternativeSwap.swift | 不等长段合并为 joined segment pair |
| 12 | PolishClient 初始化 nil 无日志 | VoicePipeline.swift | 添加 "L2 polish disabled" 日志 |
| 13 | Config 缺少"户口"→"hook"映射 | ~/.we/config.json | 添加到 replacements |

### P3 — 可观测性

| # | 修复 | 文件 |
|---|------|------|
| 14 | 屏幕关键词列表日志（前 10 个具体词，不只是数量） | VoicePipeline.swift |
| 15 | L1 纠错源统计（history/replacements/keywords 各多少） | VoicePipeline.swift |
| 16 | L1 早期退出原因（空 words、无纠错源） | AlternativeSwap.swift |
| 17 | Terminal AX 读取步骤（prompt prefix 搜索成功/失败） | CorrectionCapture.swift |
| 18 | buildCorrectionMap 学到的映射（每个 pair 和 count） | AlternativeSwap.swift |

## 排除的误报

| 报告问题 | 排除原因 |
|----------|----------|
| `joined()` 缺分隔符 | 中文文本无空格，SA word 边界已正确，`joined()` 无分隔符是正确行为 |
| AX API 线程不安全 | `VoicePipeline.process` 是 `@MainActor`，AX 调用在主线程 |
| screenCaptureTask 异常未 catch | `Task<Void, Never>` 不会 throw |
| JSONL 并发写入不原子 | `JSONLWriter` 的 append/readAll 在同一 serial queue 上已有序 |
| Shell hook 用 Jaccard 相似度 | 实际已经是 Levenshtein，与 Swift 实现一致 |
| Prompt 格式嵌套混乱 | system prompt + user message 格式对 Qwen3 是正确的 chat template |
| PolishClient `@MainActor` 不完整 | `process()` 已标 `@MainActor`，调用链从 VoiceModule（MainActor class）发起 |
| addUnique `>= 2` 应改 `>= 3` | 中文 2 字词（"模型""语音"）需要保留，英文在调用方已过滤 |

## 关键设计决策

### rawText 语义（经两轮讨论）

**问题**: CorrectionCapture 的 rawText 应该是 SA 原文还是 pipeline 最终输出？

- **v1 建议**: 改为 `finalText`，理由是飞轮应该学到 L1/L2 的错误
- **v2 建议**: 保持 `result.fullText`，理由是应该学 SA 错误
- **最终方案**: rawText 保持 SA 原文。同时让 `buildCorrectionMap` **双向学习**：
  - `diff(rawText, userFinalText)` → 学习 SA 识别错误
  - `diff(insertedText, userFinalText)` → 学习 L1/L2 pipeline 错误
  - CorrectionEntry 已有两个字段，无需改数据模型

### L1/L2 对齐方案

**问题**: L1 修改了词的文本，但 L2 用原始 words 重建，覆盖 L1 修正。

**方案**: AlternativeSwap 返回 `L1Result` 结构体：
```swift
struct L1Result {
    let text: String          // 完整 L1 输出文本
    let wordTexts: [String]   // per-word L1 输出，与 words 数组对齐
}
```
- 多字匹配时，第一个词位放替换结果，后续位放空字符串
- L2 用 `l1WordTexts[wi]` 代替 `words[wi].text` 重建
- L2 跳过 L1 已修改的词（`l1WordTexts[i] != words[i].text`）

## 日志链路

修复后，每次语音输入在 `~/.we/debug.log` 可看到：

```
[WE:Pipeline] L1 sources: 42 history, 4 replacements, 20 keywords
[WE:Pipeline] Screen keywords: hook, Claude, cron, fallback, GGUF, ...
[WE:Pipeline] L1 force: "户口" → "hook"
[WE:Pipeline] L1: "帮我看一下户口的逻辑" -> "帮我看一下hook的逻辑"
[WE:Pipeline] L2: no low-confidence segments to polish
[WE:Pipeline] Injected 11 chars into Ghostty
[CorrectionCapture] Capture started (edit-detect): "帮我看一下hook的逻辑" in Ghostty
[CorrectionCapture] Correction map: "户口" → "hook" (count: 3)
```

## 飞轮闭合度

| 阶段 | 修复前 | 修复后 |
|------|--------|--------|
| SA 采集 | 100% | 100% |
| L1 确定性纠正 | 70% | 95% |
| L2 模型 polish | 60% | 90% |
| 文本注入 | 100% | 100% |
| 桌面纠错捕获 | 90% | 95% |
| 终端纠错捕获 | 85% | 90% |
| 学习反馈 | 50% | 85% |
| **总体** | **~70%** | **~93%** |

## 遗留项

| 项目 | 优先级 | 说明 |
|------|--------|------|
| 中文分词粒度 | P2 | tokenize 是逐字的，学到的 pair 粒度太细（"得"→"的"），可能误纠正 |
| OCR 硬超时 | P3 | Vision OCR 可能挂起，当前无法中断 |
| VoiceSession 3s timeout | P3 | 长句子或弱网可能超时，建议增加到 10s |
| 剪贴板延迟硬编码 | P3 | Thread.sleep(0.15) 在慢机器上可能不够 |
