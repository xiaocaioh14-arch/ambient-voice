# WE v0.2.1

修复版本。**没有新功能**——v0.2.0 已含的会议模式 L2、自定义热键、远程语音、字典纠错全部保持原状。这次主要修了三个会让 v0.2.0 装上后"不能用"的真实问题。

## 修复

### 🔴 全局热键装上后不响应（issue 隐藏的根因）

v0.2.0 装完按 Right Option 没反应、菜单栏图标在、Accessibility 显示已授权——根因是 **CGEventTap 需要 Input Monitoring 权限**（macOS 10.15+ 的真实要求），而 Accessibility 不够。`AXIsProcessTrustedWithOptions` 返回 true 且 `CGEvent.tapCreate` 成功不代表事件能投递。

**修复**：
- 启动时自动检查 `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)`，未授权时弹系统对话框
- 启动日志显式打印 `Input Monitoring: true/false`
- `INSTALL.txt` 把"输入监听"和"辅助功能"分开列，明确两个都要给

### 🔴 源码 `make build` 失败（issue #8）

Swift 6 严格模式下 `RemoteInbox.swift` 的 CGEventTap closure 触发 `SendingRisksDataRace` 错误（某些 toolchain 下从 warning 升级为 error）。本地 Swift 6.2.3 是 warning，但用户 toolchain 不一定。

**修复**：把 closure 捕获状态封装到 `HTTPRequestState` 引用类型 + 用 `MainActor.assumeIsolated` 同步声明 main actor 隔离。**不引入异步调度**，行为与原版完全等价。整个项目 471 个 Swift 6 warning 全清。

### 🔴 安装路径权限识别

承接 v0.2.0 已经替换过的 DMG：bundle 含 `PkgInfo` 文件 + INSTALL.txt 引导 `lsregister -f`，确保 macOS LaunchServices 注册 bundle id（否则 TCC 找不到 app，权限弹窗永不出现）。

## 内部工程改进（用户不可见）

- 客户端 `WEDataDir` 升级为完整目录树管理器（子目录 / 文件名常量 / 派生路径 helper），所有路径访问统一通过它
- 服务端目录树重组：`server/lib/` (8 个子步骤脚本) + `server/entry/` (3 个用户主入口) + `server/INDEX.md` (唯一权威入口索引) + `server/scripts/` (deprecated 旧脚本仍可用)
- 服务端 `lib/paths.py` 中央路径常量，支持 `WE_DATA_DIR` 环境变量覆盖（沙箱测试用）
- 自动构建错词表 `build_dictionary.py`：从 `voice-history.jsonl` 抽 polish-diff token + 低置信度英文/混合 token，实测扫 1264 条 → 自动发现 38 个新术语
- 字典 markdown 双向审核工具 `review_dictionary.py`
- AutoResearch 实验环境 `server/finetune-research/run_experiment.sh`
- 一键自动微调管线 `server/entry/finetune.sh`（字典 → AI 蒸馏 → 网格搜索 → 选 best → 自动 deploy）
- KPI 自动化测试框架 `client/scripts/kpi-test/`（6 个里程碑 binary + 5 项基线 continuous + 250 条测试集 + 月度报告归档）
- `WE --bench-voice <wav>` CLI 入口（端到端评估即时录音链路）

## 安装

```bash
# 下载 WE-0.2.1.dmg，拖 WE.app 到 /Applications，然后跑：
xattr -cr /Applications/WE.app
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f /Applications/WE.app
```

启动后系统会依次请求 4 个权限：

- **输入监听**（Input Monitoring）← 全局热键真正需要的权限
- **辅助功能**（Accessibility）← 文字注入光标用
- 麦克风
- 屏幕录制（仅会议模式录系统音频时需要）

> ⚠️ 输入监听 vs 辅助功能：很多人混淆。CGEventTap 监听 Right Option 真正需要的是「输入监听」；辅助功能只是用于把文字注入到光标。两个都要给。

## 升级方式

从 v0.2.0 升级：直接覆盖 `/Applications/WE.app`，跑一次 `xattr -cr` + `lsregister -f`，启动后给"输入监听"权限。

## 已知问题

- 默认 `server.model: qwen3:0.6b` 是 base 模型，效果有限（issue #14 反馈）。完整体验需自行用 `server/entry/finetune.sh` 在 GPU 上微调出 `we-polish` 模型替换。详见 `server/INDEX.md`。
- 会议模式两项基线（关键事实保留率 / 会议 WER）等待会议测试集就绪。
