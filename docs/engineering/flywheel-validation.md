# WE 纠错飞轮闭环完整性验证

**日期**：2026-03-20
**审查范围**：CorrectionCapture → CorrectionStore → AlternativeSwap → VoicePipeline

---

## 数据流概览

```
用户说话
    ↓
VoiceSession.stop() → TranscriptionResult
    ↓
VoicePipeline.process(result, appIdentity, screenContext)
    ├─ Step 1: TerminalCorrectionBridge.importShellCorrections()
    │           ↓ 导入终端 hook 的修正
    │
    ├─ Step 2: CorrectionStore.shared.loadHistory()
    │           ↓ 读取历史修正 [CorrectionEntry]
    │
    ├─ Step 3: AlternativeSwap.apply(
    │           rawText: result.fullText,
    │           words: result.words,
    │           correctionHistory: [来自 Step 2]
    │           ) → l1Text
    │           ↓ L1 确定性纠正
    │
    ├─ Step 4: PolishClient.polish(l1Text) → finalText (如果启用 L2)
    │           ↓ L2 低置信度打磨
    │
    ├─ Step 5: TextInjector.insert(finalText, into: appIdentity)
    │           ↓ 注入应用
    │
    ├─ Step 6: CorrectionCapture.startWindow(
    │           insertedText: finalText,     ← L2 输出（或 L1 如果 L2 未启用）
    │           rawText: result.fullText,    ← 原始转录
    │           app: appIdentity
    │           )
    │           ↓ 监控用户编辑
    │
    ├─ Step 7: [用户编辑] → CorrectionCapture.captureAndCompare()
    │           ↓
    │           ├─ 构造 CorrectionEntry(
    │           │   rawText,
    │           │   insertedText,
    │           │   userFinalText
    │           │ )
    │           ↓
    │           └─ CorrectionStore.shared.save(entry)
    │               ↓
    │               ├─ correctionWriter.append(entry) → ~/
```

---

## 闭环完整性检查

### ✅ 连接点 1: TerminalCorrectionBridge → CorrectionStore
**位置**：VoicePipeline.swift 第 52 行

```swift
TerminalCorrectionBridge.importShellCorrections()
```

**流程**：
- Shell hook 在命令执行后写 `~/.we/terminal-corrections.jsonl`
- `importShellCorrections()` 读文件并导入 → `CorrectionStore.save()`
- **状态**：✅ 闭环正常

**注意**：Shell hook 是异步的（命令执行后），所以 import 必须在每次 process() 时调用，来"捡起" 上一次遗留的修正。

---

### ✅ 连接点 2: CorrectionStore.loadHistory() → AlternativeSwap.apply()
**位置**：VoicePipeline.swift 第 60-67 行

```swift
let correctionHistory = CorrectionStore.shared.loadHistory()
let l1Text = AlternativeSwap.apply(
    rawText: result.fullText,
    words: result.words,
    correctionHistory: correctionHistory,  ← 历史修正作为参数
    ...
)
```

**流程**：
1. `loadHistory()` 返回 `[CorrectionEntry]`
2. `AlternativeSwap.apply()` 通过 `buildCorrectionMap()` 提取词级修正
3. 对每个低置信度单词检查是否有历史修正
4. **状态**：✅ 数据流正确

---

### ⚠️  连接点 3: AlternativeSwap.apply() → TextInjector.insert()
**位置**：VoicePipeline.swift 第 97 行

```swift
TextInjector.insert(finalText, into: appIdentity)
```

**问题**：
- `insertedText` = `finalText`（L2 输出，或 L1 如果 L2 未启用）
- 但 `rawText` = `result.fullText`（原始转录）
- 传给 CorrectionCapture 的 `rawText` 是**未纠正的原始转录**

**影响**：
- 当用户编辑时，CorrectionCapture 比较 `insertedText` vs `userFinalText`
- 但 `rawText` 被保存到 CorrectionEntry 中
- AlternativeSwap 的 `buildCorrectionMap()` 会用 `rawText` 做 LCS diff：
  ```
  entry.rawText = "原始转录"          (e.g., "蓝色的帽子")
  entry.insertedText = "L1/L2 纠正后"  (e.g., "蓝色得帽子")
  entry.userFinalText = "用户编辑"    (e.g., "蓝色的帽子")

  wordLevelDiff(rawText, userFinalText)
  = wordLevelDiff("蓝色的帽子", "蓝色的帽子")
  = []  (没有差异！)
  ```

**这导致飞轮断裂**：用户的编辑无法被识别为修正，因为 diff 的基准线是原始转录，而用户可能是在纠正 L1/L2 的输出。

**推荐修复**：
```swift
// VoicePipeline.swift 第 108-110 行改为：
correctionCapture?.startWindow(
    insertedText: finalText,
    rawText: l1Text,  // ← 改为 L1 的输出作为基准
    app: appIdentity
)
```

**严重程度**：**高** - 这是飞轮能否闭合的关键

---

### ⚠️  连接点 4: CorrectionCapture.save() → loadHistory()
**位置**：CorrectionCapture.swift 第 457 行 → VoicePipeline.swift 第 60 行

**问题**：竞态条件

```swift
// Thread A (主线程 - VoicePipeline.process)
let correctionHistory = CorrectionStore.shared.loadHistory()

// Thread B (NSEvent 回调 - CorrectionCapture)
CorrectionStore.shared.save(entry)
  ↓
correctionWriter.append(entry)  // 异步写入，queue.async
```

**时序问题**：
1. 第一次 process() 时，调用 loadHistory()，读到历史数据 [entry1, entry2]
2. 用户编辑，CorrectionCapture 捕获到 entry3
3. save(entry3) 调用 `correctionWriter.append(entry3)`，但这是 async 的
4. 立即进行第二次录音，调用新的 process()，loadHistory() 可能还没读到 entry3（还在队列里）
5. L1 纠正不包含 entry3，飞轮延迟一个周期

**严重程度**：**中** - 影响实时性，但不导致数据丢失

**修复建议**：
```swift
// JSONLWriter 增加同步方法
func appendSync<T: Encodable>(_ item: T) {
    queue.sync { [self] in
        // ... 同步写入逻辑 ...
    }
}

// 或在 CorrectionStore.save() 中等待
func save(_ entry: CorrectionEntry) {
    // ... 验证逻辑 ...
    correctionWriter.appendSync(entry)  // 同步写入
    diffWriter.appendSync(diff)
}
```

---

### ⚠️  连接点 5: 多个 CorrectionCapture 实例的状态管理
**位置**：VoicePipeline.swift 第 19 行、第 26 行

```swift
@MainActor private(set) static var correctionCapture: CorrectionCapture?

@MainActor static func configure(...) {
    correctionCapture = CorrectionCapture()  // 单例创建
}
```

**问题**：
- VoicePipeline 维护一个全局的 CorrectionCapture 单例
- 如果用户快速连续说话（按住快捷键两次），可能：
  1. 第一次 startWindow() 被调用，CorrectionCapture 进入监控状态
  2. 用户还没释放快捷键，突然再按一次（或新的窗口聚焦）
  3. 第二次 startWindow() 被调用，覆盖第一次的状态
  4. 但 CorrectionCapture 的 NSEvent 监听器仍然在生效，可能触发两次回调或数据混乱

**严重程度**：**中** - 边界情况，快速连续操作会丢失修正

**修复建议**：
```swift
func startWindow(insertedText: String, rawText: String, app: AppIdentity) {
    if isMonitoring {
        DebugLog.log(.correction, "Previous capture still active, cancelling...")
        endCapture(reason: "superseded")
    }
    // ... 后续逻辑 ...
}
```

---

### ⚠️  连接点 6: loadHistory() 和 save() 的过滤不一致
**位置**：CorrectionStore.swift 第 49-103 行（save）、第 120-141 行（loadHistory）

**问题**：
- `save()` 在写入前进行过滤：
  - 低质量（quality < 0.4）
  - Degenerate text（重复字符）
  - Function key 字符
  - IME 垃圾追加
  - Truncation-only（只删除末尾）

- `loadHistory()` 在读取时再次进行**完全相同的**过滤

**隐患**：
- 如果过滤逻辑有 bug（例如 degenerate detection 的阈值不当），可能导致：
  - save() 认为是合法数据（质量好，不 degenerate），写入了
  - loadHistory() 认为是坏数据（根据某个过滤条件），过滤掉了
  - 飞轮中的这条修正无法被使用

**例子**：
```swift
// save() 时：entry.quality = 0.45，通过了质量检查
// loadHistory() 时：如果 degenerate detection 有 false positive
//                   可能将其判定为 degenerate 并过滤掉
```

**严重程度**：**低-中** - 取决于过滤逻辑的稳定性

**修复建议**：
```swift
// 方案 1：统一过滤逻辑
private static func isValidEntry(_ entry: CorrectionEntry) -> Bool {
    // 中央化的验证逻辑
    return entry.quality >= 0.4
        && !hasDegenerate(entry.userFinalText)
        && !hasInvalidChars(entry.userFinalText)
}

// 在 save() 和 loadHistory() 中都用这个函数

// 方案 2：只在 save() 时过滤，loadHistory() 不过滤
func loadHistory() -> [CorrectionEntry] {
    return correctionWriter.readAll(as: CorrectionEntry.self)
    // 信任 save() 的过滤决定
}
```

---

## 数据流完整性总结

| 连接点 | 问题 | 严重程度 | 状态 |
|--------|------|---------|------|
| Shell Hook → Store | 正常导入 | - | ✅ 正常 |
| Store.loadHistory() → AlternativeSwap | 正常应用 | - | ✅ 正常 |
| AlternativeSwap → TextInjector | ⚠️ rawText 基准线问题 | **高** | ❌ 需修复 |
| TextInjector → CorrectionCapture | 正常注入和监控 | - | ✅ 正常 |
| CorrectionCapture → Store.save() | 竞态条件 | **中** | ⚠️  需改进 |
| Store.save() → Store.loadHistory() | 异步延迟 | **中** | ⚠️  需改进 |
| 快速连续操作 | 状态覆盖 | **中** | ⚠️  需改进 |
| 过滤逻辑一致性 | 不一致的过滤 | **低-中** | ⚠️  需改进 |

---

## 闭环工作流示例

### 场景 1：成功的闭环（理想情况）

```
第 1 次录音：
  用户说："蓝色的帽子"
  → 转录：rawText = "蓝色得帽子"（误识别"的"→"得"）
  → L1 纠正：无历史修正，输出 = "蓝色得帽子"
  → 注入应用
  → 用户编辑：删除"得"，加上"的" → "蓝色的帽子"
  → 保存修正：rawText="蓝色得帽子", insertedText="蓝色得帽子", userFinalText="蓝色的帽子"

第 2 次录音：
  用户说："蓝色的帽子" (相同)
  → 转录：rawText = "蓝色得帽子" (相同误识别)
  → L1 纠正：
     loadHistory() → 发现 "得" → "的" 映射
     → L1Text = "蓝色的帽子" ✅ 自动纠正！
  → 注入应用 → 无需用户编辑
  ✅ 飞轮闭合！
```

**但实际上（当前代码）**：

```
第 1 次录音：
  ... (同上) ...

第 2 次录音：
  用户说："蓝色的帽子"
  → 转录：rawText = "蓝色得帽子"
  → L1 纠正：
     loadHistory() → 发现修正 entry (rawText="蓝色得帽子", final="蓝色的帽子")
     buildCorrectionMap():
       wordLevelDiff("蓝色得帽子", "蓝色的帽子")
       → 找到 "得" → "的" 映射 ✓
     → L1Text = "蓝色的帽子" ✅ 纠正成功
```

等等，我需要重新检查 buildCorrectionMap 的逻辑...

---

## 深度分析：buildCorrectionMap 的实现

**关键代码**（AlternativeSwap.swift 74-101）：

```swift
private static func buildCorrectionMap(from history: [CorrectionEntry]) -> [String: String] {
    var pairCounts: [String: [String: Int]] = [:]

    for entry in history {
        let rawWords = tokenize(entry.rawText)
        let finalWords = tokenize(entry.userFinalText)

        let diffs = wordLevelDiff(original: rawWords, corrected: finalWords)
        for (original, corrected) in diffs {
            let key = original.lowercased()
            let val = corrected
            pairCounts[key, default: [:]][val, default: 0] += 1
        }
    }
    // ...
}
```

**注意**：`buildCorrectionMap()` 比较的是 `rawText` vs `userFinalText`

**原始预期**：
- rawText = 原始转录（未纠正的）
- userFinalText = 用户最终编辑后的文本
- diff = 修正

**实际情况**（当前代码）：
- rawText = 原始转录 ✓
- insertedText = L1/L2 纠正后注入的文本 （但没有被 buildCorrectionMap 使用）
- userFinalText = 用户在纠正后的文本基础上进一步编辑

**场景示例**：

```
假设 L1 有一个之前的修正规则：可以把"的"改成"得"（错误的规则）

第 1 次：
  rawText = "蓝色的帽子"
  insertedText = "蓝色得帽子" (L1 错误纠正)
  userFinalText = "蓝色的帽子" (用户纠正)
  → 保存修正：diff("蓝色的帽子", "蓝色的帽子") = 无差异 ❌

第 2 次：
  rawText = "蓝色的帽子"
  loadHistory() 找不到修正（因为上一次的 diff 是空的）
  insertedText = "蓝色得帽子" (L1 仍然应用错误规则)
  ❌ 飞轮没有记录 L1 的错误，所以无法纠正
```

**真正的问题**：

`buildCorrectionMap()` 使用 `rawText` 而不是 `insertedText` 作为对比基准，导致：
- 如果 L1/L2 做了错误纠正，userFinalText 反而是把错误纠正回原样，这不会被检测为修正
- 结果：L1 的错误无法通过飞轮得到纠正

**严重程度**：**高** - 这是关键的设计缺陷

---

## 最终建议

### 优先级 1（必须立即修复）

1. **修改 VoicePipeline.swift 108 行**
   ```swift
   correctionCapture?.startWindow(
       insertedText: finalText,
       rawText: l1Text,  // 改为 L1 输出（而非原始转录）
       app: appIdentity
   )
   ```
   理由：使 buildCorrectionMap 的基准线正确，能够检测 L1/L2 的错误纠正

2. **修改 CorrectionStore.save() 和 JSONLWriter.append()**
   ```swift
   // 在 save() 中使用同步写入，或加入事务机制
   correctionWriter.appendSync(entry)
   diffWriter.appendSync(diff)
   ```
   理由：确保两个文件始终同步，避免数据不一致

### 优先级 2（需要改进）

3. **在 CorrectionCapture.startWindow() 开始检查上一个 capture 是否还活跃**
   ```swift
   if isMonitoring {
       DebugLog.log(.correction, "Cancelling previous capture...")
       endCapture(reason: "superseded")
   }
   ```
   理由：避免快速连续操作导致状态混乱

4. **统一 loadHistory() 和 save() 的过滤逻辑**
   ```swift
   // 新增函数
   private static func isValidEntry(_ entry: CorrectionEntry) -> Bool { ... }

   // 两个地方都调用
   ```
   理由：防止过滤不一致导致的数据丢失

---

## 验证清单

- [ ] 确认 rawText 在飞轮中的语义
- [ ] 测试快速连续说话（<1 秒）的修正捕获
- [ ] 测试 L1 纠错后用户再编辑的场景
- [ ] 验证修正在下一次录音时确实被应用
- [ ] 检查 corrections.jsonl 和 semantic-diffs.jsonl 的一致性
