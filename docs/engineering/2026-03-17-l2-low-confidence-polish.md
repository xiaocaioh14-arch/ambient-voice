# 优化记录: L2 低置信度片段润色

**日期**: 2026-03-17
**版本**: v0.3.0
**类型**: 新功能
**模块**: VoicePipeline / PolishClient

## 变更历史

| 版本 | 日期 | 说明 |
|------|------|------|
| v0.1.0 | 2026-03-03 | 初始 L2 全文润色（后下线） |
| v0.2.0 | 2026-03-05 | L2 从实时路径移除，改为离线 distill |
| v0.3.0 | 2026-03-17 | L2 重新上线，仅处理低置信度片段 |

## 背景

之前 L2 做全文润色有两个问题：
1. 0.6B 模型对全文润色容易改错（改对的不多，改错的风险大）
2. 全文推理增加延迟，影响注入体验

用户需求：**只对 SpeechAnalyzer 置信度低的词做候选替换，不做全文润色**。

## 设计

### 核心原则

- **高置信度词绝不经过模型** — 零延迟零风险
- **低置信度片段带上下文送模型** — 让 0.6B 在窄场景下发挥最大价值
- **没有低置信度片段时完全跳过 L2** — 大多数情况零开销

### 流程

```
L1 AlternativeSwap 输出 → 遍历 words
  ├─ 所有词 confidence >= 0.5 → 跳过 L2，直接注入
  └─ 发现 confidence < 0.5 的连续片段：
       提取片段 + 前后 3 个词作为上下文
       → 发给 Qwen3 0.6B（本地 llama.cpp）
       → 模型返回修正后的片段
       → 拼接回完整文本（高置信度词原样保留）
       → 注入
```

### 示例

语音识别: `"明天早上跟运维对一下广州有福机房的拆机"`
- `有福` confidence = 0.3（低）
- 发给模型: `前文:对一下广州 需要修正:有福 后文:机房的拆机`
- 模型返回: `有孚`
- 最终: `"明天早上跟运维对一下广州有孚机房的拆机"`

### System Prompt

```
你是语音识别纠错助手。用户给出前文、需要修正的片段、后文。
根据上下文修正识别错误的片段。只输出修正后的片段，不要解释，不要输出前文后文。
```

## 完整 Pipeline（L1 → L2 → 注入 → L3 纠错捕获）

```
语音输入 → SpeechAnalyzer 转录（带 word-level confidence）
  │
  ├─ L1: AlternativeSwap（确定性纠错）
  │   - 低置信度词查 SA alternatives + correction history
  │   - 屏幕上下文关键词匹配
  │   - 纠正次数 >= 2 才信任
  │   - 延迟: 0ms（纯逻辑）
  │
  ├─ L2: Low-Confidence Polish（Qwen3 0.6B 本地推理）
  │   - 只处理 L1 后仍低置信度的片段
  │   - 带前后文上下文送模型
  │   - 高置信度词完全不经过模型
  │   - 延迟: 0ms（无低置信度片段）/ 100-300ms（有片段时）
  │   - 后端: llama.cpp 本地推理，不需要 Ollama
  │
  ├─ 注入: TextInjector（剪贴板 Cmd+V）
  │
  └─ L3: CorrectionCapture（用户纠错捕获）
      - AX 模式: 实时追踪文本变化
      - edit-detect 模式: 退格检测 + 剪贴板快照
      - 保存到 corrections.jsonl → 反馈回 L1
      - 延迟: 0ms（被动监听）
```

## 配置

`~/.we/config.json`:
```json
{
  "polish": {
    "enabled": true,
    "type": "local",
    "system_prompt": "你是语音识别纠错助手...",
    "temperature": 0.2,
    "max_tokens": 256,
    "timeout": 5.0
  }
}
```

关闭 L2: 设 `"enabled": false` 或删除 `polish` 字段。

## 改动文件

| 文件 | 改动 |
|------|------|
| `Sources/VoicePipeline.swift` | 新增 `polishLowConfidence()` 方法，L2 重新接入 pipeline |
| `~/.we/config.json` | 新增 `polish` 配置，type=local |

## 模型资源

- 模型: `~/.we/models/qwen3-0.6b.gguf`
- 内存占用: ~400MB（2-bit 量化 + Metal GPU offload）
- 推理后端: llama.cpp（已编译链接）
- 不需要外部进程（Ollama 等）

## 测试方法

1. 语音输入一段话，观察 debug.log 中:
   - `L1:` 行 — 确定性纠错结果
   - `L2 segment:` 行 — 低置信度片段修正
   - `L2:` 行 — 汇总（几个 segments，耗时）
2. 对比注入文本和原始转录，确认只改了低置信度部分
3. 高置信度的长句应显示 `L2: no low-confidence segments to polish`
