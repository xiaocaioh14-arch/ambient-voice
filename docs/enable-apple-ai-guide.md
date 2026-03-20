# enableAppleAI — 在国行 Mac 上启用 Apple Intelligence

来源：https://github.com/kanshurichard/enableAppleAI

## 前提条件

- **M1 或更新的芯片**
- **macOS 15.1 或更高版本**
- 系统地区设为**美国**，语言设为简体中文或英语（美国）
- Siri 语言与系统语言一致

## 安装步骤

### 第一步：关闭 SIP（系统完整性保护）

1. 关机，然后**长按电源键**进入恢复模式
2. 顶部菜单选择 **实用工具 > 终端**
3. 输入：`csrutil disable`
4. 输入 `y` 确认，然后重启

### 第二步：运行安装脚本

重启进入系统后，打开终端运行：

```bash
curl -sL https://raw.githubusercontent.com/kanshurichard/enableAppleAI/main/enable_ai.sh | bash
```

如果网络不好，用国内 CDN：

```bash
curl -sL https://cdn.jsdelivr.net/gh/kanshurichard/enableAppleAI@main/enable_ai.sh | bash
```

或者手动下载后审查再执行：

```bash
curl -O https://raw.githubusercontent.com/kanshurichard/enableAppleAI/main/enable_ai.sh
cat enable_ai.sh        # 审查脚本内容
chmod +x enable_ai.sh
./enable_ai.sh
```

### 第三步：按提示操作

1. 选择语言（中文）
2. 选择「Enable Apple Intelligence」
3. 推荐选 **Method 1**（更全面），如果失败再试 Method 2
4. macOS 26 可选「Force Region to USA」来解锁 ChatGPT 集成
5. 按提示重启
6. 在 **系统设置 > Apple Intelligence 与 Siri** 中确认已启用

### 第四步：重新开启 SIP

确认 Apple Intelligence 可用后，再次进入恢复模式，运行：

```bash
csrutil enable
```

## 工作原理

### Method 1（推荐）

- 使用 LLDB 临时注入 eligibilityd 守护进程，模拟美国 Mac 型号
- 修改 `/private/var/db/eligibilityd/eligibility.plist` 移除地区/启动盘限制
- 用 immutable flag（`uchg`）锁定文件防止系统刷新

### Method 2（备选）

- 直接修改 eligibility plist 文件
- 不依赖 LLDB，但可能无法启用部分高级功能

### 区域覆盖（macOS 26 可选）

- 修改 `/private/var/db/com.apple.countryd/countryCodeCache.plist`
- 强制系统识别设备位置为美国
- 解锁 ChatGPT 集成和 Apple News

## 注意事项

- **iPhone 镜像**：先完成 iPhone-Mac 配对，再运行区域修改，否则配对可能失败。如果出问题，先卸载、配对、再重装
- **看图创作（Image Playground）**：在简体中文下可能不好用，临时切换到英语（美国）
- **SIP**：安装时需要关闭，安装完成后可以安全地重新开启，不影响已激活的 AI 功能

## 卸载

重新运行脚本，选择「Unlock Files (Uninstall)」即可恢复原始状态。

## 故障排查

- **ChatGPT 无响应**：尝试 Method 2 或启用「Force Region to USA」
- **缺少新功能**：更新到 v3.21+ 并先卸载旧版本
- **脚本访问失败**：仓库同时提供 `enable_ai.sh`（当前版本）和 `enable_ai_old.sh`（旧版本）
