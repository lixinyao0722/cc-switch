# ModelHub R15 优化记录草稿

## 1. Codex gpt-5.5 上下文窗口同步到 1.05M

来源：Codex 任务 `01a00ed2-fcb9-78e0-b5cc-97d74dea6426` 委托记录。

### 结论

Codex UI 右下角之前显示“共 258k”，不是 tooltip 展示错误，而是运行时按 model catalog 中的 `gpt-5.5-2026-04-24` 配置计算。`~/.codex/config.toml` 顶层虽然写了 `model_context_window = 921_860`，但当前会话实际使用的是 `~/.codex/models-modelhub-1m.json` 中的 catalog 值：

- 原 `context_window = 272000`
- 原 `effective_context_window_percent = 95`
- 有效窗口为 `272000 * 0.95 = 258400`

### 已执行调整

文件：`/Users/shopee/.codex/models-modelhub-1m.json`

模型：`gpt-5.5-2026-04-24`

- `context_window`: `272000` -> `1050000`
- `max_context_window`: `272000` -> `1050000`
- `effective_context_window_percent`: `95` -> `100`

保持不变：

- `gpt-5.6-sol` 保持 `1050000 / 100%`
- `gpt-5.6-terra` 保持 `272000 / 95%`
- `gpt-5.6-luna` 保持 `272000 / 95%`

### 验证

- 已用 `jq empty /Users/shopee/.codex/models-modelhub-1m.json` 校验 JSON 有效。
- 已用 `jq` 确认 `gpt-5.5-2026-04-24` 当前为 `context_window: 1050000`、`max_context_window: 1050000`、`effective_context_window_percent: 100`。

### R15 注意事项

当前已经运行中的 Codex 任务可能不会热更新，需要新开任务或重启 Codex 后右下角才可能显示约 1.05M。真实超过 272k 是否能跑通，还取决于 ModelHub 后端是否真正支持这么大的上下文。

本工作区核对到的打包资产仍需在 R15 实现阶段单独处理：`scripts/modelhub-installer/assets/models-modelhub-1m.json` 中的 `gpt-5.5` 仍为 `272000 / 95%`，`src-tauri/src/resources/gpt5_5_template.json` 也仍为 `272000 / 95%`。已确认 R15 需要同步更新仓库打包资产与模板，并在实现时核对运行时 `gpt-5.5-2026-04-24` 与仓库模板 `gpt-5.5` 的生成/映射关系，避免用户目录修复和发布资产脱节。

## 2. 安装器 sudo 密码提示需要说明密码类型

来源：用户截图反馈。安装命令执行到 `[2/8] 检查 Applications 权限和现有 ChatGPT 应用` 后，终端只出现默认 `Password:` 提示。

### 问题

当前提示没有说明需要输入哪一种密码，用户容易误以为是 ModelHub AK、GitHub 密码或其他服务密码。该提示实际来自 macOS `sudo` 权限校验，要求输入当前登录 Mac 用户的管理员密码；终端输入密码时不会显示字符。

### R15 要求

安装器在首次触发 `sudo` 前必须输出明确中文说明，至少包含：

- 这是当前 Mac 登录用户的管理员密码，不是 `MODELHUB_AK`。
- 输入时终端不会显示字符，输入完成后按回车。
- 该权限用于检查/写入 `/Applications` 和 `/etc/codex` 等系统位置。

建议文案：

```text
接下来 macOS 会请求管理员权限。
请输入当前 Mac 登录用户的管理员密码（不是 MODELHUB_AK）。输入时终端不会显示字符，输完按回车。
```

实现时优先使用统一 sudo 入口，避免不同 privileged 操作出现不一致提示；若使用 `sudo -p` 自定义 prompt，也要保留上述语义。

### 验收

- R15 安装器首次进入需要管理员权限的步骤时，先显示中文解释，再出现密码输入。
- `MODELHUB_AK` 的无回显输入提示继续保持独立文案，不与 macOS 管理员密码混淆。
- 测试覆盖至少一个需要 `sudo -v` 的路径，断言输出包含“Mac 登录用户的管理员密码”或等价说明，并包含“不是 MODELHUB_AK”。
