# WE 系统架构

## 概览

WE 是一个 macOS 本地语音输入系统，采用 Shell + Module 架构。按住右 Command 键说话，松开后文字自动注入到当前应用的光标位置。

```
┌─────────────────────────────────────────────────────┐
│                    WEApp (Shell)                     │
│  SwiftUI MenuBarExtra + AppDelegate                  │
│  ┌─────────────┐  ┌──────────┐  ┌────────────────┐  │
│  │ModuleManager│  │ WEConfig │  │ RuntimeConfig  │  │
│  │             │  │ (.json)  │  │ (hot-reload)   │  │
│  └──────┬──────┘  └──────────┘  └────────────────┘  │
│         │                                            │
│  ┌──────▼──────────────────────────────────────────┐ │
│  │              VoiceModule (Module #1)             │ │
│  │  State: idle → preparing → recording → processing│ │
│  └─────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────┘
```

## 核心数据流

```
用户按住右Cmd
    │
    ▼
GlobalHotKey (CGEvent tap, 200ms debounce)
    │
    ▼
VoiceSession (AVAudioEngine + SFSpeechRecognizer zh-Hans)
    │  产出: TranscriptionResult (fullText + [TranscribedWord])
    │         每个 word 带 confidence + alternatives
    ▼
VoicePipeline.process()
    │
    ├─ Step 1: AlternativeSwap (L1 确定性纠错)
    │    读取 CorrectionStore 历史 → 构建纠正映射表
    │    低置信度词 + 历史纠正匹配 → 替换
    │
    ├─ Step 2: PolishClient (L2 模型润色)
    │    路由: local (llama.cpp) / ollama / openai / fm-adapter
    │    当前状态: 模型未加载, pass-through
    │
    ├─ Step 3: TextInjector (文字注入)
    │    优先 AX API 直接写入
    │    终端/iTerm → 走剪贴板 + Cmd+V
    │
    ├─ Step 4: CorrectionCapture (纠正捕获)
    │    监听用户编辑 → 对比注入文本 vs 最终文本
    │    通过 submit signal 判断编辑完成 (Enter/Cmd+Enter/焦点切换)
    │
    └─ Step 5: VoiceHistory (历史记录)
         保存到 ~/.we/voice-history.jsonl
```

## 文件结构

```
Sources/
├── WEApp.swift              # @main, MenuBarExtra, AppDelegate
├── WEModule.swift            # WEModule 协议 + ShellContext
├── ModuleManager.swift       # 模块注册/激活/停用
│
├── GlobalHotKey.swift        # 右Cmd CGEvent tap, 200ms debounce
├── VoiceSession.swift        # AVAudioEngine + SFSpeechRecognizer
├── TranscriptionAccumulator.swift  # 词级聚合 (confidence, alternatives)
├── VoiceModule.swift         # 状态机, 协调 session → pipeline
│
├── VoicePipeline.swift       # L1→L2→注入→捕获→历史 编排
├── AlternativeSwap.swift     # L1: LCS diff + 纠正历史映射
├── PolishClient.swift        # L2: 多后端路由 (local/ollama/openai)
├── LocalModelClient.swift    # llama.cpp C API 封装, LoRA 热切换
├── TextInjector.swift        # AX API 注入 + 剪贴板回退
│
├── CorrectionCapture.swift   # 用户编辑监控 (NSEvent + AX)
├── CaptureProfile.swift      # 12个应用的提交信号配置
├── CorrectionStore.swift     # corrections.jsonl + semantic-diffs.jsonl
│
├── WEConfig.swift            # ~/.we/config.json 配置
├── RuntimeConfig.swift       # runtime-config.json 热重载 (DispatchSource)
├── DebugLog.swift            # 结构化日志 → ~/.we/debug.log (10MB 轮转)
├── JSONLWriter.swift         # 通用 JSONL 写入器 (带轮转)
├── VoiceHistory.swift        # voice-history.jsonl
├── ModelManager.swift        # 模型下载, SHA256 校验, manifest
├── PermissionManager.swift   # Accessibility + Microphone 检查
├── PermissionGuideController.swift  # 权限引导窗口
├── SetupWindowController.swift      # 首次运行模型下载 UI
├── UpdaterService.swift      # Sparkle 自动更新
│
└── CllmBase/                 # llama.cpp C 桥接
    ├── module.modulemap
    └── include/shim.h → libs/llama.cpp/include/llama.h

sa-adapter/                   # QLoRA 训练管线 (Python)
├── train_qlora_0.6b.py       # Qwen3-0.6B QLoRA 训练
├── gen_training_data_v3.py   # 从 corrections + synthetic 生成训练数据
├── eval_0.6b.py              # fix_rate, break_rate, CER 评估
├── merge_lora.py             # LoRA 合并 + GGUF 转换
└── scripts/retrain.sh        # 7 步重训管线

speech-bench/                 # ASR 基准测试
we-model-serve/               # 模型分发服务 (port 9191)
scripts/                      # release.sh, verify-update.sh
```

## 学习闭环

```
用户说话 → 识别 → L1纠错 → L2润色 → 注入文字
                                         │
                                    用户手动修改
                                         │
                                         ▼
                              CorrectionCapture 捕获差异
                                         │
                                         ▼
                              CorrectionStore 持久化
                              (corrections.jsonl)
                                    │         │
                    ┌───────────────┘         └──────────────┐
                    ▼                                         ▼
           AlternativeSwap                          sa-adapter 训练管线
         (L1: 下次自动替换)                    (离线 QLoRA fine-tune)
         同一个错出现2次后生效                   生成新 adapter.gguf
                                                       │
                                                       ▼
                                              ModelManager 分发
                                            (manifest + SHA256)
```

## 关键设计决策

| 决策 | 选择 | 原因 |
|------|------|------|
| 语音引擎 | Apple SFSpeechRecognizer | 零延迟、零成本、带词级 confidence + alternatives |
| L1 纠错 | 确定性 LCS diff | 不确定时不改，比模型更可靠 |
| L2 模型 | Qwen3-0.6B via llama.cpp | 够小(~400MB)、本地推理、支持 Metal |
| 文字注入 | AX API 优先 | 不污染剪贴板，终端类 app 回退到剪贴板 |
| 配置 | JSON + DispatchSource | 支持运行时热重载，不需重启 |
| 并发 | Swift 6 strict concurrency | @MainActor, @unchecked Sendable, nonisolated |
| 签名 | 自签名证书 "WE Dev Signing" | 重编译后 Accessibility 权限不丢失 |

## 运行时文件

```
~/.we/
├── config.json              # 主配置 (polish 后端, 模型 URL, adapter 映射)
├── runtime-config.json      # 运行时配置 (热重载)
├── debug.log                # 结构化日志
├── voice-history.jsonl      # 语音会话历史
├── corrections.jsonl        # 用户纠正记录 (学习数据)
├── semantic-diffs.jsonl     # 语义差异 (训练数据导出)
└── models/
    ├── qwen3-0.6b.gguf      # 基础模型
    └── sa-adapter.gguf       # LoRA adapter
```
