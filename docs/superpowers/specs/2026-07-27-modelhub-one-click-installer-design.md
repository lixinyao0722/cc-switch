# ModelHub 一键安装器设计

## 背景

当前 ModelHub 交付流程要求用户下载多个附件、安装定制版 CC Switch、手工复制 Codex 与 CC Switch 状态，并手工设置进程环境变量。现有私密配置包不能公开发布，其中包含 `MODELHUB_AK`、Codex OAuth 信息、bearer token、用户本地路径、CC Switch 请求历史和完整用户数据库。

本设计使用一个由新版 GitHub Release 承载的无版本号引导命令替代现有流程。安装器保留用户已有配置，在最后一步才要求输入 `MODELHUB_AK`，并将该密钥保存到 macOS Keychain。

## 目标

- 提供以下稳定安装命令：

  ```bash
  curl -fsSL https://github.com/lixinyao0722/cc-switch/releases/latest/download/install.sh | bash -s
  ```

- 支持运行 macOS 12 或更高版本的 Apple Silicon Mac。
- 安装经过验证的 CC Switch 3.18.0 ModelHub 兼容版。
- 增加 ModelHub Codex Provider 和本地代理配置，不删除其他 Provider 或个人 Codex 设置。
- 安装时根据当前用户的真实主目录解析所有本地路径。
- 所有非敏感文件安装完成后，通过 macOS Keychain 提示用户输入 `MODELHUB_AK`。
- 保留由 ChatGPT 管理的 `~/.codex/auth.json`；已有 ChatGPT App 时验证后复用，缺失时从 OpenAI 官方 DMG 安装，再使用其中带 OpenAI 签名的 Codex 二进制。
- 支持失败自动恢复和显式执行 `--rollback latest`。
- 公开产物中不包含任何用户凭据、请求历史或用户本地路径。

## 非目标

- 支持 Intel Mac、Windows 或 Linux。
- 覆盖、修复或重新签名已存在但校验不通过的 ChatGPT App。
- 分发私有 Codex 回滚二进制。
- 分发或恢复 Codex OAuth token、bearer token、`auth.json`、CC Switch 请求历史或完整用户数据库。
- 替换无关的 CC Switch Provider、插件、项目信任、桌面偏好或 Codex 配置章节。
- 删除所有者飞书云盘中的旧交付文件。本次只从安装文档中移除对应附件块。

## Git 与 Release 结构

开发从 `origin/main` 创建 `feat/modelhub-one-click-installer` 分支。

以下现有 Release 保持不变：

- `modelhub-v3.18.0-20260726`
- `modelhub-v3.18.0-20260727-fork-fix`

新增一个正式 GitHub Release，tag 为 `modelhub-installer-20260727`，不标记为 Pre-release。它将成为仓库中第一个可由 `/releases/latest` 解析的 Release。以后发布新版安装器时，无需修改用户侧安装命令。

针对新机权限与 ChatGPT 缺失场景发布 follow-up 正式 Release `modelhub-installer-20260727-r2`。它成为新的 `/releases/latest` 目标；`modelhub-installer-20260727` 和更早的两个 Pre-release 全部保留不变。

新 Release 只包含以下公开资产：

- `install.sh`
- `CC-Switch-ModelHub-3.18.0-arm64.app.zip`
- `modelhub-installer-resources.tar.gz`
- `SHA256SUMS.txt`

R2 的 `install.sh` 内部固定不可变 tag `modelhub-installer-20260727-r2`。用户虽然通过 `/releases/latest` 获取脚本，但该脚本会从自身对应的精确 tag 下载其余资产，避免安装过程中因新版 Release 发布而混用不同版本的文件。

通过 stdin 执行的脚本还会从该精确 tag 重新下载一份 `install.sh`，与 App ZIP 和资源包一起使用 `SHA256SUMS.txt` 校验；校验后的副本用于本机回滚入口。

## 仓库文件

本功能新增一个职责集中的安装器目录：

- `scripts/modelhub-installer/install.sh`：兼容 Bash 3.2 的引导、安装、验证和回滚入口。
- `scripts/modelhub-installer/package-release.sh`：从显式白名单构建公开资源包和校验文件。
- `scripts/modelhub-installer/assets/models-modelhub-1m.json`：不含凭据和本地路径的公开 ModelHub 模型目录。
- `scripts/modelhub-installer/templates/modelhub-provider.toml`：包含 `__USER_HOME__` 占位符的 Codex Provider 受管字段。
- `scripts/modelhub-installer/templates/modelhub-provider-meta.json`：`max_output_tokens`、ModelHub 会话适配器和同 Provider 429 重试元数据。
- `scripts/modelhub-installer/templates/com.ccswitch.modelhub-env.plist`：LaunchAgent 模板。
- `scripts/modelhub-installer/templates/load-modelhub-env.sh`：从 Keychain 读取 AK，并把 `MODELHUB_AK` 与 `CODEX_CLI_PATH` 注入用户 launchd 域。
- `scripts/modelhub-installer/helpers/rename-exclusive.c`：使用 `renamex_np(..., RENAME_EXCL)` 排他发布已验证 ChatGPT App 的最小 arm64 helper 源码；只在 Release 打包时编译和 ad-hoc 签名。
- `tests/scripts/modelhub-installer.test.sh`：隔离运行的安装器回归测试。
- `src-tauri/src/proxy/providers/codex.rs`：当 Codex Provider 没有持久化 key、但其活跃 TOML Provider 显式声明 `env_key` 时，从 CC Switch 进程环境解析凭据。

Release 打包器不以旧私密配置包为输入，而是只打包上述受版本控制的白名单文件。这能避免私密包以后新增字段时绕过黑名单检查。

## 前置检查与下载流程

安装器使用 `set -euo pipefail`，并禁用命令跟踪。它只依赖 macOS 系统工具，包括 `/bin/bash`、`curl`、`shasum`、`tar`、`ditto`、`codesign`、`plutil`、`sqlite3`、`security`、`launchctl`、`osascript`、`open`、`mktemp`、`hdiutil`、`file` 和 `sudo`；不要求安装 Homebrew、Node.js、Python、`jq` 或 `rg`。

修改系统前，安装器依次执行：

1. 拒绝以 root 身份执行整个安装器；用户必须运行普通的 `curl | bash -s` 命令，由安装器在必要步骤自行请求管理员权限。
2. 确认 `uname -s` 为 `Darwin`、`uname -m` 为 `arm64`，且 macOS 版本不低于 12。
3. 使用 `mktemp -d` 创建私有暂存目录，并注册清理 trap。
4. 检查 `/Applications` 以及已存在的 `/Applications/CC Switch.app`。父目录不可写，或已有 App 及其受保护内容不能由当前用户替换时，先执行 `sudo -v`；后续 CC Switch 删除、安装、隔离属性清理和回滚恢复统一通过权限包装器执行。
5. 验证或安装官方 ChatGPT App，并确认其内置 Codex 可用，详见下一节。
6. 从不可变 Release tag 下载 App ZIP、资源包和校验文件。
7. 解压前校验精确文件名与 SHA-256。
8. 拒绝资源包中的绝对路径、`..` 路径穿越、符号链接、非预期文件和非预期顶层目录。
9. 校验所有受管模板，并确认除声明的运行时占位符外不存在未解析占位符。

除“ChatGPT 缺失时安装官方 App”这个独立 bootstrap 外，所有检查通过前不修改 CC Switch、Codex 配置、Keychain 或 launchd 状态。

## ChatGPT 官方应用 bootstrap

OpenAI 官方下载页为 [https://openai.com/chatgpt/download/](https://openai.com/chatgpt/download/)，当前新版 macOS 应用链接为：

```text
https://persistent.oaistatic.com/codex-app-prod/ChatGPT.dmg
```

该链接与页面中单独列出的 ChatGPT Classic 不同；安装器只使用上面的新版 ChatGPT/Codex 应用。

如果 `/Applications/ChatGPT.app` 已存在，安装器不下载、不覆盖，只执行以下校验；任一失败都阻断后续流程，并提示用户从 OpenAI 官方页面重新安装：

- `CFBundleIdentifier` 为 `com.openai.codex`；
- App Team ID 为 `2DC432GLL2`；
- 主可执行文件包含 `arm64`；
- `codesign --verify --deep --strict` 通过；
- `/Applications/ChatGPT.app/Contents/Resources/codex` 存在、可执行，且 Team ID 为 `2DC432GLL2`。

如果 ChatGPT App 缺失，安装器执行：

1. 仅从 `persistent.oaistatic.com` 的固定 HTTPS URL 下载 DMG，使用有限次数重试；
2. 通过 `hdiutil attach -nobrowse -readonly` 挂载到私有临时目录；
3. 对 DMG 内的 `ChatGPT.app` 执行上述完整 Bundle ID、Team ID、arm64、严格签名和内置 Codex 校验；
4. 先复制到 `/Applications` 下同卷的私有临时 App 路径并再次校验，记录暂存 App 的 device/inode，再通过最小 helper 调用 `renamex_np(..., RENAME_EXCL)` 排他发布为 `/Applications/ChatGPT.app`；目标在并发窗口出现或暂存源身份改变时失败，不覆盖任何既有目标；
5. 无论成功或失败都卸载 DMG 并清理临时文件。

ChatGPT bootstrap 位于 CC Switch 事务之前。若 ChatGPT 安装成功，但后续 CC Switch 安装失败或用户执行 `--rollback latest`，新安装的官方 ChatGPT App 都会保留，不进入 CC Switch 的备份 manifest。安装器不读取 ChatGPT 登录状态；安装结束后用户需要自行打开 ChatGPT 并完成登录。

helper 的信任链由打包器和安装器共同固定：打包器以 `arm64`、macOS 12 最低版本编译并 ad-hoc 签名 helper，把其 SHA-256 精确写入本次 Release 的 `install.sh`；安装器先验证资源包 allowlist、helper 严格签名、单一 `arm64` 架构和固定哈希。需要管理员权限时，安装器只把已验证 helper 复制到 `/private/var/tmp` 下由 root 创建的随机私有目录；执行前再次确认父目录为 root-owned sticky namespace、子目录和文件均为 root 所有且不可由普通用户写入，并重新核对固定哈希。helper 执行后立即清理该隔离目录。

## 备份与事务边界

首次修改前，安装器退出 ChatGPT 和 CC Switch，并创建：

```text
~/.cc-switch/backups/modelhub-installer/<UTC timestamp>/
```

该目录权限为 `0700`。其中的 manifest 记录每个受管目标在安装前是否存在，并保存安装器可能修改的本地目标副本：

- `/Applications/CC Switch.app`
- `~/.codex/config.toml`
- `~/.codex/models-modelhub-1m.json`
- `~/.cc-switch/cc-switch.db`
- `~/.cc-switch/settings.json`
- `~/Library/LaunchAgents/com.ccswitch.modelhub-env.plist`
- `~/.local/share/cc-switch-modelhub/load-modelhub-env.sh`

安装器不读取、不复制，也不修改 `~/.codex/auth.json`。

CC Switch 数据库使用系统 `sqlite3 .backup` 生成一致逻辑快照；恢复前删除 `cc-switch.db-wal` 与 `cc-switch.db-shm`，避免新事务 sidecar 重放到旧主库。

备份完成后，如果 App 安装、配置合并、Keychain 设置、launchd 加载或健康检查中的任一步失败，安装器都会根据 manifest 自动回滚。回滚恢复原文件，并删除安装前不存在的目标。若失败流程新建了 Keychain 条目，则删除该条目；若条目此前已经存在，则保留当前条目，不把旧密钥导出到文件。

安装器把自身复制到 `~/.local/share/cc-switch-modelhub/install.sh`，以支持：

```bash
~/.local/share/cc-switch-modelhub/install.sh --rollback latest
```

该 launcher 是持久回滚入口，不属于用户显式回滚的普通受管目标。每次安装会在事务开始时保存一个仅用于失败恢复的私有 launcher 快照；只有当前事务失败且已替换 launcher 时才恢复旧版本或删除本次新建版本。安装成功后，显式 `--rollback latest` 会保留当前已验证 launcher，因此可重复执行。

## 增量配置合并

### CC Switch App

在暂存目录中解压已校验的 App ZIP，并执行 `codesign --verify --deep --strict`。随后使用权限包装器替换现有 App。安装器不修改或重新签名 ChatGPT App 及其内置 Codex 二进制。

### Codex 配置

模型目录安装到运行时路径：

```text
${HOME}/.codex/models-modelhub-1m.json
```

安装器通过可识别 TOML 章节的转换器，在暂存目录生成新的 `config.toml`，校验后原子替换线上文件。安装器只管理以下顶层字段：

- `model`
- `review_model`
- `model_provider`
- `model_reasoning_effort`
- `model_auto_compact_token_limit`
- `model_context_window`
- `model_catalog_json`

安装器还只管理 `[model_providers.modelhub]` 表。其他顶层字段和章节保持原有相对顺序及字节内容，包括插件、MCP servers、项目信任、hooks、memories、桌面偏好和 skills。

模板使用 `__USER_HOME__`。安装器会先按 TOML 规则转义当前绝对 `$HOME`，再替换该占位符。仓库和 Release 中不得出现 `/Users/shopee` 路径。

### CC Switch Provider 与代理

如果 `~/.cc-switch/cc-switch.db` 不存在，安装器会隐藏启动一次新安装的 App 以初始化数据库结构，然后在继续配置前退出 App。

安装器在一个 SQLite 事务中完成以下操作：

- 查找名为 `Bytedance ModelHub - 官方CLI` 的现有 Codex Provider；如果存在，则保留其 Provider ID，只更新受管字段。
- 如果不存在，则插入 Provider ID `bytedance-modelhub-official-cli`。
- 保存包含空 `auth` 对象和合并后 ModelHub TOML 的 `settings_config`，不保存 OAuth 或 bearer 信息。
- 保存公开模板中精确的 `localProxyRequestOverrides` 元数据。
- 将 ModelHub Provider 设为当前 Codex Provider，不改变其他应用类型的 Provider。
- 只新增或更新 Codex 的 `proxy_config` 行：监听 `127.0.0.1:15721`，启用代理与接管、启用日志并关闭自动故障转移。
- 不修改请求日志、其他 Provider、价格、profiles、prompts、skills 和其他无关表。

当前 CC Switch Codex 适配器只从 Provider 持久化配置提取 API key。为使空 `auth` 的公开模板可用，适配器增加以下窄范围回退：只有活跃 `[model_providers.<model_provider>]` 显式声明 `env_key`、且现有持久化 key 为空时，才读取同名进程环境变量。它不读取非活跃 Provider 的 `env_key`，不把解析结果写回数据库，也不改变已有持久化 key 的优先级。

安装器只更新 `~/.cc-switch/settings.json` 中的以下字段，其他字段保持不变：

- `currentProviderCodex`
- `enableLocalProxy`
- `preserveCodexOfficialAuthOnSwitch`

### 运行环境与 Keychain

LaunchAgent 和环境加载脚本不包含密钥。运行时占位符解析为当前用户主目录、UID 和已验证的 ChatGPT Codex 路径。

所有非敏感文件安装完成后，安装器提示用户向管理员获取 AK，并执行：

```bash
security add-generic-password \
  -a "$USER" \
  -s "com.ccswitch.modelhub.ak" \
  -U -w </dev/tty
```

`-w` 是最后一个参数，因此 `security` 会通过 `/dev/tty` 提示输入。录入阶段 AK 不进入 shell 变量或命令参数，也不会写入配置文件、plist、输出或日志。登录时环境加载脚本必须把从 Keychain 读出的值短暂传给 `launchctl setenv NAME VALUE`；该值只存在于进程内存和瞬时参数中，不持久化到脚本、plist 或日志。

环境加载脚本在用户登录时读取该 Keychain 条目，并通过 `launchctl setenv` 设置：

- `MODELHUB_AK`
- `CODEX_CLI_PATH=/Applications/ChatGPT.app/Contents/Resources/codex`

安装器在当前 `gui/<uid>` 域中加载或刷新 LaunchAgent，为当前登录会话立即执行一次环境加载脚本，启动 CC Switch，并等待 `http://127.0.0.1:15721/health` 返回包含 `"status":"healthy"` 的 JSON（同时兼容旧裸字符串 `healthy`）。回滚时会卸载该 job，并清除当前 launchd 会话中的 `MODELHUB_AK` 与 `CODEX_CLI_PATH` 后再恢复旧 LaunchAgent。

## 幂等与失败处理

- 重复运行同一安装器会创建新备份并更新同一受管 Provider，不会重复新增 Provider。
- 既有非受管 Codex 设置和 CC Switch 数据行保持不变。
- 下载使用有限次数重试，SHA 或归档校验失败时立即终止。
- 已存在但签名、Bundle ID、架构或内置 Codex 不符合约束的 ChatGPT App 会阻断安装，不自动覆盖。
- 本次新安装的官方 ChatGPT App 不参与 CC Switch 失败回滚或显式回滚。
- Keychain 输入为空或取消时，安装失败并触发自动回滚。
- 健康检查设置有限超时时间，且只输出不含敏感信息的诊断内容。
- 安装器不打印 AK、OAuth 信息、完整 Provider JSON、完整 Codex 配置或数据库内容。
- `--rollback latest` 可重复执行；没有可恢复的完整备份时给出明确提示。

## 测试策略

开发遵循红灯、绿灯、重构。Shell 测试使用临时主目录、临时应用目录和命令桩，不接触真实 `/Applications`、Keychain、launchd 域或用户配置。

自动化用例覆盖：

- 拒绝 root 运行、非 macOS、非 arm64 和不支持的 macOS 版本。
- `/Applications` 可写但已有 root-owned CC Switch App 不可写时，仍会预先获取 sudo，并让删除、安装和失败回滚走同一权限包装器。
- ChatGPT 已存在且有效时不下载；已存在但 Bundle ID、Team ID、架构、严格签名或内置 Codex 不符时阻断。
- ChatGPT 缺失时从固定 OpenAI 官方 DMG 下载、挂载、验签、同卷临时安装并原子改名。
- ChatGPT 原子发布使用固定哈希的 `renamex_np(..., RENAME_EXCL)` helper；管理员路径只从 root-owned sticky namespace 中执行 root-owned、不可写的受信副本。
- ChatGPT 下载失败、DMG 挂载失败或验签失败时不留下目标 App；ChatGPT 安装成功后即使 CC Switch 后续失败也会保留。
- 在首次修改前拒绝 SHA 不匹配、归档路径穿越、符号链接、非预期资产或未解析占位符。
- 不存在 CC Switch 数据库或 Codex 配置时的首次安装。
- 增量合并既有 Codex 配置并保留无关章节。
- 更新现有 ModelHub Provider 且不产生重复项。
- 保留无关 CC Switch Provider、设置和数据库行。
- Codex Provider 在无持久化 key 时从活跃 Provider 的 `env_key` 读取 AK，并忽略非活跃 Provider 或空环境值。
- 当用户主目录包含空格时正确替换 `__USER_HOME__`。
- 取消 Keychain 输入后自动恢复备份。
- 健康检查超时后自动回滚。
- 成功重复运行安装器。
- `--rollback latest` 恢复既有文件并删除本次新建文件。
- Bash 3.2 语法检查和安装器帮助输出。

Release 验证还包括：

1. 运行安装器测试，以及仓库适用的格式、类型、前端和 Rust 检查。
2. 从显式白名单构建资源包。
3. 扫描仓库改动和解压后的 Release 资产，确保不含 `/Users/shopee`、`auth.json`、token 字段名、`MODELHUB_AK` 值、请求日志和非预期 SQLite 数据库。
4. 从 GitHub 重新下载所有已发布资产。
5. 对下载后的字节重新执行 SHA-256、归档白名单、占位符和凭据扫描。
6. 使用下载后的资产执行沙箱安装和回滚冒烟测试。

## Pull Request 与 Release 流程

完成最新验证后：

1. 在 `feat/modelhub-one-click-installer` 提交安装器、模板、测试、打包逻辑和文档。
2. 推送分支并创建以 `main` 为目标的草稿 GitHub PR。
3. R2 follow-up 创建 tag 为 `modelhub-installer-20260727-r2`、指向已验证功能分支提交的草稿 GitHub Release；旧 Release 保留。
4. 上传四个声明的资产，并对比 GitHub 资产摘要与本地 SHA-256。
5. 发布为正式 Release，使 `/releases/latest/download/install.sh` 可以解析。
6. 下载并验证已发布资产，执行最终沙箱冒烟测试。

Release 说明需要注明：App 只支持 Apple Silicon，使用 ad-hoc 签名且未经过 Apple 公证；安装器会要求用户输入由管理员提供的 ModelHub AK，并将其保存到 Keychain。

## 飞书安装文档

将文档 `LPm1dcaQuogMRFx5UPMlf5KPg6P` 精简为四个章节：

1. 前置条件：Apple Silicon Mac，以及能够获取管理员提供的 ModelHub AK；ChatGPT 缺失时安装器会从 OpenAI 官方来源自动安装。
2. 一键安装：无版本号 `curl | bash` 命令、明确禁止给管道添加 sudo，以及预期出现的管理员权限/Keychain 输入提示。
3. 验收：CC Switch 健康检查、普通 ModelHub 请求、fork/“接续自任务”、Computer Use、Browser 和 Chrome。
4. 回滚：本地 `--rollback latest` 命令，以及必要时重新打开原 App。

改写时移除手工复制命令、实现细节、旧附件表、私有 Codex 回滚说明、tier 边界备注、已由安装器执行的校验值，以及四个旧附件块。移除附件块不会删除其飞书云盘源文件。文档只保留一个新版 GitHub Release 链接和一个详细技术手册链接。
