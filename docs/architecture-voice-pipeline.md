# WE 语音输入系统：三层纠错 + 数据飞轮

## 一句话概括

WE 是一个 macOS 语音输入系统，通过三层纠错架构（确定性规则 → 本地模型 → 用户反馈捕获）实现越用越准的语音输入体验。核心思路：不追求一次完美，而是建立一个从用户行为中持续学习的闭环。

## 为什么需要三层

语音识别（Apple SpeechAnalyzer）的输出不可避免地包含错误：

- **同音词混淆**：有福 → 有孚，crown → cron
- **专业术语**：fallback 被识别为 for back
- **上下文依赖**：20A 的机柜 被识别为 23 的机柜

单靠一层纠错解决不了所有问题。每层解决不同类型的错误，且计算开销递增：

| 层 | 解决什么 | 延迟 | 依赖 |
|----|---------|------|------|
| L1 | 已知的、重复出现的错误 | 0ms | 用户历史数据 |
| L2 | 未知的、需要语义理解的错误 | ~1s | 本地 0.6B 模型 |
| L3 | 采集新的错误模式 | 0ms | 被动监听 |

## 实时处理路径

```
按住热键 → 录音 → 松开热键
                ↓
        Apple SpeechAnalyzer 转录
        输出: words[] — 每个词带置信度 (0~1) 和候选列表
                ↓
        ┌───────────────────┐
        │  L1: 确定性纠错    │  ← corrections.jsonl + 屏幕关键词
        └─────────┬─────────┘
                  ↓
        ┌───────────────────┐
        │  L2: 模型润色      │  ← 只处理低置信度片段
        └─────────┬─────────┘
                  ↓
        TextInjector 注入到当前 app
                  ↓
        ┌───────────────────┐
        │  L3: 纠错捕获      │  → corrections.jsonl
        └───────────────────┘
```

## L1：确定性纠错（AlternativeSwap）

**延迟：0ms** — 纯逻辑运算，没有模型推理。

### 工作原理

Apple SpeechAnalyzer 为每个词提供：
- **置信度**（0~1）：模型对识别结果的信心
- **候选列表**：其他可能的识别结果

L1 的逻辑非常简单：

```
for 每个词:
    if 置信度 >= 0.5:
        保留原文，绝不修改    ← 核心原则：不确定时不改
    else:
        查候选列表 × 用户历史纠错:
            命中 → 替换
        查候选列表 × 屏幕关键词:
            命中 → 替换
        无匹配 → 保留原文
```

### 数据来源

1. **corrections.jsonl**：用户历史纠错记录，L3 自动采集
   - 同一纠错出现 ≥2 次才被信任（防止误触发）
   - 例：用户两次把"crown"改成"cron" → L1 下次自动替换

2. **屏幕上下文**：OCR 提取当前屏幕上的关键词
   - 如果低置信度词的候选匹配到屏幕上的词，优先采用
   - 例：屏幕上有"fallback"，识别出"for back" → 候选列表里有"fallback" → 替换

### 设计原则

**不确定时不改**（when uncertain, don't change）。错误的"纠正"比不纠正更糟糕。宁可留着让用户手动改，L3 会捕获这次修改，下次 L1 就知道怎么改了。

## L2：低置信度片段润色（Qwen3 0.6B）

**延迟：0ms（无低置信度片段时）/ ~1s（有片段时）**

### 工作原理

L1 处理的是"有已知答案"的错误。L2 处理的是"需要语义理解"的错误——L1 没有历史数据可查，但模型可能通过上下文推断出正确的词。

关键设计：**不做全文润色，只处理低置信度片段**。

```
L1 输出的文本，逐词检查置信度：

"明天早上 跟运维 对一下 广州 [有福] 机房 的 拆机"
  0.95      0.90    0.88   0.92  0.3   0.95  0.98 0.91
                                  ↑
                             低置信度片段

只提取 "有福" + 前后文 "对一下广州...机房的拆机" 发给模型
模型返回 "有孚"
拼接回全文 → "明天早上跟运维对一下广州有孚机房的拆机"
```

高置信度的词**永远不经过模型**——零延迟、零风险。

### 当前状态

L2 目前已关闭。原因：Qwen3 0.6B 通用模型对指令跟随能力不足，无法可靠完成纠错任务。

解决方案：用 L3 积累的 corrections.jsonl 数据微调一个专用 LoRA adapter，让 0.6B 在"语音纠错"这个窄场景下达到可用水平。详见"Adapter 训练"章节。

### 为什么不用云端大模型

| | 云端 API | 本地 0.6B + adapter |
|--|---------|-------------------|
| 延迟 | 1-3s（网络 RTT） | ~1s（本地推理） |
| 隐私 | 数据上传到云端 | 数据不出设备 |
| 费用 | 按量付费 | 免费 |
| 离线 | 不可用 | 可用 |

WE 的核心定位是**私密的 AI 语音入口**，数据不出设备是硬约束。

## L3：用户纠错捕获（CorrectionCapture）

**延迟：0ms** — 被动监听，不阻塞注入。

### 工作原理

文本注入后，L3 开始监听用户行为。如果用户修改了注入的文本再提交，L3 捕获修改前后的差异：

```
注入: "你帮我设置一个crown"
用户改为: "你帮我设置一个cron"   ← 退格删 "rown"，打 "ron"
按 Enter 提交

L3 记录:
  insertedText: "你帮我设置一个crown"
  userFinalText: "你帮我设置一个cron"
  → 保存到 corrections.jsonl
```

### 两种捕获模式

不同 app 的技术架构不同，L3 自动检测并选择最合适的捕获方式：

**AX Observer 模式**（大多数 app）
- 通过 macOS Accessibility API 注册文本变化通知
- 实时追踪每一次编辑
- 覆盖：Telegram、Obsidian、Chrome 等标准 app

**Edit-Detect 模式**（AX 不可用的 app）
- 监听退格键判断用户是否有修改
- 确认有修改后，在提交时用一次剪贴板快照（Cmd+A → Cmd+C）读取最终文本
- 用完立即恢复剪贴板内容
- 覆盖：终端、微信、Claude 等

### 自动模式选择

```
app 启动时自动检测：

  能找到 AX 文本元素？
    ├─ 是 → AX buffer 正常大小？
    │        ├─ 是 → AX Observer 模式
    │        └─ 否（终端 scrollback 5万+ 字符）→ Edit-Detect 模式
    └─ 否（微信/Claude 等）→ Edit-Detect 模式
```

### 提交信号检测

不同 app 的"提交"动作不同：

| App 类型 | 提交信号 | 示例 |
|---------|---------|------|
| 聊天 app | Enter | Telegram、微信 |
| 终端 | Enter（检测到编辑时） | Terminal、Ghostty |
| 编辑器 | Cmd+Enter 或焦点切换 | Obsidian |

## 数据飞轮

三层不是独立工作的，而是形成一个正反馈循环：

```
               ┌─────────────────────┐
               │  corrections.jsonl  │
               │  （用户纠错数据库）    │
               └──┬──────────────┬───┘
                  │              │
          L1 读取 ↓              ↓ 训练数据
    ┌─────────────────┐   ┌──────────────┐
    │  L1 确定性纠错    │   │  LoRA 微调    │
    │  实时替换规则更新  │   │  (积累到500条) │
    └────────┬────────┘   └──────┬───────┘
             │                   ↓
             │            ┌──────────────┐
             │            │  L2 专用模型   │
             │            │  低置信度纠错  │
             │            └──────────────┘
             ↓
      注入文本到 app
             ↓
    ┌─────────────────┐
    │  L3 捕获用户修改  │ ──→ 写入 corrections.jsonl
    └─────────────────┘
```

### 飞轮加速过程

| 阶段 | 时间线 | 系统行为 |
|------|--------|---------|
| 冷启动 | Day 1~7 | L1 只靠 SA alternatives + 屏幕关键词，有限纠错 |
| 规则积累 | Day 7+ | L3 积累到同一纠错 ≥2 次，L1 开始自动替换 |
| 模型训练 | Day 30+（500 条） | 用数据微调 adapter，L2 上线处理未见过的错误 |
| 持续优化 | 持续 | L3 继续采集 → L1 规则更新 + L2 定期重训 |

## Adapter 训练

### 为什么要训练专用 Adapter

通用 0.6B 模型（Qwen3-0.6B）无法可靠完成指令跟随的纠错任务——模型太小，对"修正这个词"这种指令理解不了。

但用 LoRA 微调后，0.6B 可以在"语音纠错"这个窄任务上达到可用水平：
- 训练数据就是用户自己的纠错记录，完全匹配使用场景
- 不需要通用能力，只需要学会 `口语片段 + 上下文 → 正确文字` 这一个模式

### 训练流程

```bash
# 1. 在 Mac 上导出训练数据
python3 scripts/prepare_training_data.py --output train.jsonl --stats

# 2. 传到 GPU 服务器
scp train.jsonl gpu-server:~/we-training/

# 3. 在 GPU 服务器上训练（4090，约 5-10 分钟）
pip install unsloth datasets trl
python3 scripts/train_adapter.py --data train.jsonl --epochs 5

# 4. 转换为 GGUF 格式
python3 llama.cpp/convert_hf_to_gguf.py ./we-merged \
    --outfile we-adapter-q4_k_m.gguf --outtype q4_k_m

# 5. 部署回 Mac
scp we-adapter-q4_k_m.gguf mac:~/.we/models/qwen3-0.6b.gguf

# 6. 开启 L2
# ~/.we/config.json 中设置 "polish": { "enabled": true }
```

### 训练数据格式

`corrections.jsonl` 自动转换为 ChatML 格式：

```json
{
  "messages": [
    {"role": "system", "content": "纠正语音识别错误，只输出纠正结果。"},
    {"role": "user", "content": "你帮我设置一个crown"},
    {"role": "assistant", "content": "你帮我设置一个cron"}
  ]
}
```

### 数据质量控制

- 去重：相同的 (insertedText, userFinalText) 只保留一条
- 质量过滤：quality < 0.4 的丢弃（可能是捕获噪声）
- 退化检测：包含重复字符的记录丢弃（按键重建 bug 残留）

## 技术实现细节

### 文件结构

| 文件 | 职责 |
|------|------|
| `VoicePipeline.swift` | 流水线编排：L1 → L2 → 注入 → L3 |
| `AlternativeSwap.swift` | L1 确定性纠错逻辑 |
| `PolishClient.swift` | L2 模型推理客户端 |
| `LocalModelClient.swift` | llama.cpp 封装（模型加载、推理、adapter 热切换）|
| `CorrectionCapture.swift` | L3 纠错捕获（AX observer + edit-detect）|
| `CorrectionStore.swift` | corrections.jsonl 读写 |
| `ScreenContextProvider.swift` | OCR 屏幕关键词提取 |

### 运行时数据

| 文件 | 内容 |
|------|------|
| `~/.we/corrections.jsonl` | 用户纠错记录（L3 写入，L1 读取）|
| `~/.we/voice-history.jsonl` | 语音会话历史（含音频路径，供离线蒸馏）|
| `~/.we/models/qwen3-0.6b.gguf` | 本地模型文件（378MB, Q4_K_M 量化）|
| `~/.we/config.json` | 系统配置 |
| `~/.we/debug.log` | 调试日志 |

### 性能指标

| 指标 | 数值 |
|------|------|
| L1 延迟 | 0ms |
| L2 延迟（无低置信度词） | 0ms |
| L2 延迟（有低置信度词） | ~1s（38 tok/s） |
| L3 延迟 | 0ms（被动监听） |
| 模型内存（进程 RSS） | ~121MB |
| 模型磁盘 | 378MB |
| 端到端延迟（语音结束到文字出现） | < 100ms（L2 关闭时）|
