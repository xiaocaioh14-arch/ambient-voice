# WE 开发上下文

## 环境

| 项目 | 值 |
|------|-----|
| macOS | 26.2 (Tahoe, 25C56) |
| Xcode | 26.4 Beta |
| Swift | 6.0 (swift-tools-version: 6.0) |
| CPU | Apple M2 (ARM64) |
| 项目路径 | `/Users/wyw/Project/WE` |
| App 路径 | `/Applications/WE.app` |
| 数据目录 | `~/.we/` |
| 签名证书 | "WE Dev Signing" (自签名, 钥匙串中) |

## 构建命令

```bash
make setup     # 首次: clone + build llama.cpp (需要 cmake)
make build     # swift build
make install   # build + 复制到 /Applications/WE.app + 签名 + 启动
make run       # swift run WE (开发用, 不需要 .app)
make clean     # 清理 .build + llama.cpp/build
make release   # swift build -c release
```

## 依赖

| 依赖 | 来源 | 用途 |
|------|------|------|
| llama.cpp | git clone (libs/llama.cpp) | 本地 GGUF 推理, Metal GPU |
| Sparkle 2.5+ | SPM (GitHub) | 自动更新框架 |
| cmake | brew install cmake | 编译 llama.cpp |

## 权限要求

| 权限 | 用途 | 授权方式 |
|------|------|---------|
| Accessibility | CGEvent tap (热键) + AX API (注入/读取) | 系统设置 → 隐私 → 辅助功能 → 添加 WE.app |
| Microphone | AVAudioEngine 录音 | 首次录音时自动弹窗 |
| Speech Recognition | SFSpeechRecognizer | 首次识别时自动弹窗 |

> 使用 "WE Dev Signing" 证书签名后，重编译 `make install` 不会丢失 Accessibility 权限。

## llama.cpp 集成注意事项

### 头文件
- `Sources/CllmBase/include/shim.h` → `libs/llama.cpp/include/llama.h`
- ggml 头文件通过 symlink 放在 `libs/llama.cpp/include/` 下 (指向 `ggml/include/`)
- 如果 `make setup` 重新 clone, 需要重建 symlink:
  ```bash
  cd libs/llama.cpp/include
  for f in ../ggml/include/*.h; do ln -sf "$f" "$(basename $f)"; done
  ```

### API 版本 (截至 2026-03)
最新 llama.cpp 的 API 与旧版有较大变化:

| 旧 API | 新 API |
|--------|--------|
| `llama_kv_cache_clear(ctx)` | `llama_memory_clear(llama_get_memory(ctx), true)` |
| `llama_lora_adapter_init(model, path)` | `llama_adapter_lora_init(model, path)` |
| `llama_lora_adapter_set(model, adapter, scale)` | `llama_set_adapters_lora(ctx, &adapters, n, &scales)` |
| `llama_tokenize(model, ...)` | `llama_tokenize(vocab, ...)` — 先 `llama_model_get_vocab(model)` |
| `llama_batch_add()` / `llama_batch_clear()` | 已移除, 需手动操作 batch 结构体字段 |

### 链接
Package.swift 使用 `Context.packageDirectory` 构建绝对路径:
```swift
"-L\(Context.packageDirectory)/libs/llama.cpp/build/src",
"-L\(Context.packageDirectory)/libs/llama.cpp/build/ggml/src",
"-L\(Context.packageDirectory)/libs/llama.cpp/build/ggml/src/ggml-blas",
"-L\(Context.packageDirectory)/libs/llama.cpp/build/ggml/src/ggml-metal",
```

## 当前功能状态

| 功能 | 状态 | 说明 |
|------|------|------|
| 热键 (右Cmd) | ✅ 正常 | 200ms debounce, CGEvent tap |
| 语音识别 | ✅ 正常 | Apple SFSpeechRecognizer, zh-Hans |
| L1 纠错 | ⚠️ 冷启动 | 代码完整, 但 corrections.jsonl 为空, 无历史数据 |
| L2 润色 | ❌ 已关闭 | 实时润色延迟过高, 已禁用 (polish.enabled=false) |
| AX 注入 | ✅ 正常 | 微信/Telegram/备忘录等均可 |
| 剪贴板注入 | ✅ 正常 | 终端/iTerm 走此路径 |
| 纠正捕获 | ✅ 全局覆盖 | 三层策略: AX 深度遍历+通知 / 按键重建(终端) / 直接AX读取 |
| 语音历史 | ✅ 正常 | voice-history.jsonl 已有记录 |
| 模型下载 | ❌ 服务不可达 | 配置的 4090 服务器 URL 无法访问, 且当前不需要 |
| 自动更新 | ⚠️ 未配置 | Sparkle 集成但无 appcast URL |

## 进化能力分析

### 当前可自动进化的部分
1. **L1 AlternativeSwap**: 当 CorrectionCapture 捕获到用户修改 ≥2 次相同纠正后, AlternativeSwap 会自动学习该映射。这是纯客户端侧的学习闭环, 无需模型。

### 需要手动触发的部分
2. **L2 LoRA adapter**: 需要:
   - corrections.jsonl 积累足够数据
   - 在 4090 服务器上运行 `sa-adapter/scripts/retrain.sh`
   - 通过 we-model-serve 分发新 adapter
   - 客户端 ModelManager 下载更新

### 当前阻塞点
- **corrections.jsonl 为空**: CorrectionCapture 的触发条件是用户在注入后修改文本, 且 Jaccard 相似度在 0.3~1.0 之间。目前无捕获记录。
- **CorrectionCapture submit signal**: 需要确认各 app 的 submit 信号是否正确触发 (如微信 Enter, 终端 Cmd+Enter)。

## 设计决策记录

### 2026-03-03: L2 实时润色暂不启用
- **尝试**: 接入 MiniMax Anthropic 代理 (`https://api.minimaxi.com/anthropic`) 作为 L2 实时润色后端
- **结果**: API 延迟过高, 影响语音输入体验
- **决策**: 关闭实时润色 (`polish.enabled=false`), 语音输入直接注入原文, 零延迟
- **后续方向**: 如需润色, 考虑异步批量处理而非实时拦截; 但原始设计中不包含此步骤, 暂不实现

### 2026-03-03: sa-adapter 训练管线未实现
- **现状**: `sa-adapter/` 目录下有训练脚本框架 (`train_qlora_0.6b.py`, `retrain.sh` 等), 但:
  - corrections.jsonl 为空, 无训练数据
  - 4090 服务器不可达, 无法执行训练
  - we-model-serve 分发服务未部署
  - 客户端 ModelManager 下载的模型文件为 0 bytes
- **依赖链**: 用户实际使用积累纠正数据 → 导出训练数据 → 4090 训练 → 分发 adapter → 客户端加载
- **阻塞**: 整条链路从数据采集端 (CorrectionCapture) 到训练端 (4090 服务器) 均未打通

## 配置文件

### ~/.we/config.json (当前)
```json
{
  "polish": {
    "enabled": false,
    "type": "local",
    "system_prompt": "口语转书面。只输出结果。",
    "temperature": 0,
    "max_tokens": 256,
    "timeout": 10
  },
  "downloads": {
    "base_model": "http://4090.ts.andy.qzz.io:9191/qwen3-0.6b.gguf",
    "adapter": "http://4090.ts.andy.qzz.io:9191/sa-adapter.gguf",
    "manifest": "http://4090.ts.andy.qzz.io:9191/manifest.json"
  },
  "adapters": {}
}
```

### 支持的 polish 后端类型
| type | 说明 | 状态 |
|------|------|------|
| `local` | llama.cpp 本地推理 | 模型未下载 |
| `ollama` | Ollama HTTP API | 未配置 |
| `openai` | OpenAI 兼容 API | 代码就绪, 支持 api_key + model 字段 |
| `anthropic` | Anthropic Messages API | 代码就绪, 测试过 MiniMax 代理, 延迟过高 |
| `fm-adapter-api` | FM adapter 端点 | 未配置 |

## 已知问题

1. VoiceModule `activate()` 被调用两次 (日志显示两条 "VoiceModule activated")
2. PermissionManager 对 Accessibility 的检查用 `AXIsProcessTrusted()`, 但 `checkAll()` 结果与实际不一致 (日志报 not granted 但热键可用)
3. ModelManager 下载到 0 bytes 文件但标记为 "ready" — 需要加 size 校验
4. `NSLog` 在 GlobalHotKey.swift 中仍有一处残留, 应改为 DebugLog
