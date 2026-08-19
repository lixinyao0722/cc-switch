# ModelHub Codex 代理兼容说明

本文记录 OpenAI 官方签名 Codex CLI 经 CC Switch 本地路由访问 Bytedance ModelHub 原生 Responses API 时的兼容契约、验证方法与回滚边界。

## 目标架构

```text
ChatGPT App
  -> /Applications/ChatGPT.app/Contents/Resources/codex
  -> CC Switch http://127.0.0.1:15721/v1
  -> https://aidp.bytedance.net/api/modelhub/online/responses
```

官方 CLI 负责 ChatGPT App 的受信进程身份和标准 Responses 协议。CC Switch 只在目标 ModelHub Provider 上转换内部 API 链路字段，不修改 Codex 二进制。

## 一键安装

安装器支持 macOS 12 及以上版本的 Apple Silicon Mac。开始前只需从管理员处获取 `MODELHUB_AK`；如果 `/Applications/ChatGPT.app` 不存在，安装器会从 OpenAI 官方固定 HTTPS 地址下载新版 ChatGPT DMG，挂载、验签并安装。安装完成后，用户仍需自行打开 ChatGPT 并登录。

R16 基于 CC Switch 3.19.2，继承 R15 的 `1,050,000` GPT-5.5 模型窗口和 R14 的移动端强制路由。Golden live 配置直接指向 CC Switch 本地代理，把 review model 固定为 `gpt-5.5-2026-04-24`，只展示 high、xhigh、max 三档推理强度，并打包批准的 Computer Use MCP 与 ChatGPT 内置 Node REPL 入口。数据库 Provider 快照仍保存真实 ModelHub 上游，避免代理回环；编辑器偏好、Marketplace 缓存、凭据和用户绝对路径不进入公共包。一键安装入口保持不变：

```zsh
curl -fsSL https://github.com/lixinyao0722/cc-switch/releases/latest/download/install.sh | bash -s
```

必须以当前登录用户运行上面的原始命令，不要在 `curl` 或 `bash` 前添加 `sudo`。安装器会用 8 个中文步骤提示下载、校验、备份、覆盖、确认或输入 AK、启动和既有健康/黄金路由检查；如果 ChatGPT 缺失，则从 OpenAI 官方来源安装。随后安装器备份并整体覆盖 `~/.codex/config.toml`、`~/.cc-switch/cc-switch.db` 和 `settings.json`，并合并维护 `/etc/codex/managed_config.toml`。R16 使用清洗后的可移植配置，包括 Provider、模型 catalog 和批准的 Codex/MCP 运行时字段，但排除日志、请求/会话/用量记录、备份和凭据。

检测到已有 `~/.codex/config.toml` 时，安装器会询问 `检测到本地 Codex 个性化配置，是否使用 R16 标准配置完整覆盖？[y/N]`。回车或 `N` 默认采用合并模式：刷新 R16 管理的模型、Desktop、Computer Use、Node REPL 和 ModelHub 字段，同时保留编辑器、Marketplace、项目授权及其他插件配置；输入 `Y` 才会完整覆盖。新安装没有现有配置时直接写入 Golden，不额外询问。

Golden Codex 配置固定以下安装后状态：

```toml
review_model = "gpt-5.5-2026-04-24"

[desktop]
git-branch-prefix = "feat/"
show-context-window-usage = true
preventSleepWhileRunning = true
enabled-reasoning-efforts = ["high", "xhigh", "max"]

[plugins."computer-use@openai-bundled"]
enabled = true

[mcp_servers.computer-use]
args = ["mcp"]
command = "./Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient"
cwd = "."
enabled = true

[mcp_servers.node_repl]
command = "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl"

[mcp_servers.node_repl.env]
BROWSER_USE_AVAILABLE_BACKENDS = "chrome,iab"
BROWSER_USE_CODEX_APP_BUILD_FLAVOR = "prod"

[model_providers.modelhub]
base_url = "http://127.0.0.1:15721/v1"
```

Codex 已经运行时可能不会热更新这些设置或新的 catalog。安装完成后若界面状态未刷新，请重启 Codex 并新建任务。

如果安装器进程已继承非空 `MODELHUB_AK`，R16 会提示 `检测到当前环境已有 MODELHUB_AK，是否直接复用？[Y/n]`。回车、`Y` 或 `y` 直接复用；`N` 或 `n` 会显示 `请输入 MODELHUB_AK（向管理员获取，输入内容不会显示）`，允许无回显输入新值；其他回答会重新询问。没有环境变量时直接进入无回显输入。最终选择值是本次安装唯一凭据源：先写入 macOS Keychain 并回读，再用回读值更新 CC Switch ModelHub Provider 的 `auth.OPENAI_API_KEY`，LaunchAgent 则把同一凭据加载为当前登录会话的 `MODELHUB_AK`。launchd 环境加载后，安装器立即校验 Keychain、Provider API Key 与 `MODELHUB_AK` 均非空且完全一致；CC Switch 健康、黄金路由稳定后再校验一次。若环境值与旧 Keychain 不同，只有用户确认复用后才以环境值覆盖同步；选择新输入则以新值覆盖同步。校验不会输出密钥，任何写入或校验失败都会恢复安装前状态。

写入 `/Applications` 和 `/etc/codex` 等系统位置前，安装器会说明接下来需要输入当前 Mac 登录用户的管理员密码，而不是 `MODELHUB_AK`。密码输入时终端不会显示字符，输入完成后按回车；这和后续单独输入或复用的 ModelHub AK 是两类不同凭据。

R16 继续对系统文件采用 `/private/var/tmp` 安全 staging：管理员进程不会直接读取 Downloads 中的候选文件。`/etc/codex/managed_config.toml` 以 `root:wheel 0644` 原子替换，只改写下列两个根键并保留其他配置、表和注释；禁止定义保留的 `[model_providers.openai]`：

```toml
model_provider = "modelhub"
openai_base_url = "http://127.0.0.1:15721/v1"
```

CC Switch 不可用时，桌面默认会话和移动端显式 `openai` 会话都会失败，这是强制路由的预期边界；重新启动 CC Switch 后可继续请求。旧的失败 openai 线程可以重试，但发布验收重点是移动端新建全新会话。

整体覆盖会替换新电脑原有的 Codex/CC Switch Provider 与偏好，但安装前状态可通过下方命令恢复。`~/.codex/auth.json` 与 ChatGPT 登录态不覆盖；Release 不包含 AK/OAuth、日志、请求/会话/用量记录或备份。本机绝对路径在包内统一为 `__USER_HOME__`，安装时替换为新电脑真实用户目录。

如果 `/Applications/ChatGPT.app` 已存在，安装器只校验其 Bundle ID、OpenAI Team ID、arm64 主程序、严格代码签名及内置 Codex，不会下载或覆盖。任一校验失败都会阻断安装，并提示用户从 OpenAI 官方页面重新安装，避免把异常 App 当成受信运行时。

回滚到本次安装前状态：

```zsh
~/.local/share/cc-switch-modelhub/install.sh --rollback latest
```

ChatGPT bootstrap 独立于 CC Switch 配置事务。无论后续安装失败还是执行上述显式回滚，本次自动安装的官方 ChatGPT App 都会保留，不属于回滚目标。

## Provider 配置

目标 Provider 使用原生 Responses API：

```toml
model = "gpt-5.6-sol"
review_model = "gpt-5.5-2026-04-24"
model_max_output_tokens = 128_000
model_provider = "modelhub"
model_reasoning_effort = "high"
model_auto_compact_token_limit = 500000
model_context_window = 921_860
model_catalog_json = "/Users/<current-user>/.codex/models-modelhub-1m.json"

[desktop]
git-branch-prefix = "feat/"
enabled-reasoning-efforts = ["high", "xhigh", "max"]

[model_providers.modelhub]
name = "modelhub"
wire_api = "responses"
requires_openai_auth = true
base_url = "http://127.0.0.1:15721/v1"
env_key = "MODELHUB_AK"
stream_idle_timeout_ms = 600_000
request_max_retries = 2
stream_max_retries = 3
```

Provider 元数据承接全部 CC Switch ModelHub 兼容策略。这些字段在 CC Switch App 的 Codex Provider 高级配置中管理，不写入 Codex `config.toml`：

```json
{
  "localProxyRequestOverrides": {
    "codexSessionHeaderAdapter": "modelhub",
    "codexActivitySummaryMode": "map",
    "codexMetadataModel": "gpt-5.6-sol",
    "rememberInvalidEncryptedReasoning": true,
    "body": {
      "max_output_tokens": 128000
    },
    "retry429": {
      "maxRetries": 2,
      "baseDelayMs": 2000,
      "maxDelayMs": 30000,
      "honorRetryAfter": true
    }
  }
}
```

`codexActivitySummaryMode` 只作用于 Codex Desktop 固定的 `gpt-5.6-luna` 活动摘要提示词，可选 `passthrough`、`block`、`map`。R14 默认 `map`，复用 `codexMetadataModel` 生成摘要；`block` 在本地返回不可重试 400；`passthrough` 保留 Luna，适用于拥有 Luna 权限的 Provider。完全相同的 Provider/thread/摘要内容在 5 秒内只允许一次上游请求，映射摘要及动态 Skill 选择辅助请求遇到 429 都只访问上游一次。

`codexMetadataModel` 改写 Codex Desktop 固定的任务标题、任务描述、标题重考虑、语音标题，以及使用 `skill_selection` schema、developer/assistant/user 三段角色结构和完整有序 Skill 指令标记的动态 Skill 选择请求，也是活动摘要 `map` 模式的目标模型。主任务、标题和活动摘要 helper 都使用这一协议。普通 Luna、错误 schema、角色乱序或缺少稳定标记的结构化请求不匹配精确分类，仍按原路由转发。App 中关闭“内部元数据映射”会清除该字段；活动摘要处于 `map` 时必须提供非空目标模型。

`rememberInvalidEncryptedReasoning` 在 ModelHub 精确返回 `invalid_encrypted_content` 后，按 Provider + 客户端会话在进程内记录不兼容状态。同会话后续请求会在第一次发送前删除 reasoning item 的 `encrypted_content`；含非空明文 `summary/content` 的 item 继续保留，只有密文且没有可用明文的 item 才整项删除。状态不写数据库，CC Switch 重启后自动清空；将该字段改为 `false` 可关闭学习与预清理。

作用域内仍使用 Luna、但未命中上述精确提示词或 Skill 选择协议的请求不会被 R14 自动映射。CC Switch 只记录一次脱敏的短指纹、input/user 数量和 schema 标志；日志不记录提示词、session/thread ID 或凭据。发布验收要求一个完整 Codex 回合中的有效 Skill 选择均映射到 Sol，未分类 Luna 与 ModelHub Luna 401 均为 0。

Codex 的 `request_max_retries` 负责 5xx、超时和传输错误，`stream_max_retries` 负责 SSE 中断重连；OpenAI 官方 schema 不包含 `retry_429`。ModelHub HTTP 429 由 CC Switch 独立处理：主请求最多额外尝试两次，优先遵循 `Retry-After` 且最长等待 30 秒。任一主请求收到 429 后会建立 Provider 共享冷却，冷却结束时只放行一个 recovery probe；probe 仍为 429 时延长冷却，避免每个并发请求分别启动完整重试链。

## Header 映射

官方 CLI 入站：

```text
session-id: <wire session id>
thread-id: <current thread id>
x-client-request-id: <current thread id>
```

ModelHub 出站：

```text
session_id: <wire session id>
thread_id: <current thread id>
extra: {"session_id":"<wire session id>"}
x-client-request-id: <current thread id>
```

规则：

- 只在 Codex 的 `/responses` 与 `/responses/compact` 路由族生效。
- OpenAI Official、Copilot、Grok Build、`/models` 和其他 Provider 不应用该映射。
- 同时兼容私有 CLI 的 `session_id`、`thread_id`、`x-session-id` 输入，便于紧急回滚。
- `extra` 已存在时必须是 JSON object；保留其他静态字段，并用当前真实 session 覆盖 `session_id`。
- 缺少 session/thread、值为空、超过 256 字节或 `extra` 非法时拒绝请求，不生成随机上游身份。
- 日志只记录字段是否存在和是否合并，不记录真实 ID 或完整 `extra`。

## Body 覆盖

`localProxyRequestOverrides.body` 在协议转换完成后、最终序列化前深度合并：

```json
{
  "max_output_tokens": 128000
}
```

顶层 `stream` 属于受保护协议字段，不能通过 Body override 修改。Header、Body 和 adapter 均为 Provider 级配置，不得设置成全局默认。

## 请求兼容与流式保护

- ModelHub 出站前会为 `namespace` 工具补齐空白 `description`，避免上游严格校验路径随机返回 HTTP 400；既有非空描述保持原值。
- HTTP 400、401、403 属于客户端请求或凭据问题，直接返回，不进入跨 Provider 重试。
- Codex SSE 无论是否开启自动故障转移都设置 600 秒总时长上限；heartbeat、注释和 `response.created` / `response.in_progress` 不算有效进展，不能无限续命。

## HTTP 429 重试

429 policy 位于单个 ModelHub Provider attempt 内，与跨 Provider 故障转移分离：

- 主用户请求在初始请求之外最多进行 2 次同 Provider 恢复尝试；一次逻辑请求最多访问上游 3 次。
- 活动摘要、Skill 选择、标题、描述和标题重考虑等明确 metadata/helper 请求不继承 429 重试，只访问上游 1 次。
- 所有尝试复用相同 method、URL、最终 Header 和序列化 body。
- 优先解析 `Retry-After` 的秒数或 HTTP-date，并限制在 30 秒以内。
- 有效 `Retry-After` 原样遵循但限制在 30 秒内；否则以 2 秒为基础并增加 0–25% 随机抖动。
- 首次 429 会建立 Provider 共享冷却；冷却结束时只放行一个 recovery probe。probe 再次收到 429 时延长冷却，其余并发请求继续等待，不各自启动重试链。
- 中间 429 先排空响应体，不更新 Provider 熔断状态。
- 单次恢复耗尽后把最终 429 交给原有错误处理。
- 自动故障转移保持关闭，不因 429 切换 Provider。

## 验证

源码验证：

```zsh
pnpm typecheck
pnpm format:check
pnpm test:unit

cd src-tauri
LZMA_API_STATIC=1 cargo fmt --check
LZMA_API_STATIC=1 cargo clippy --all-targets -- -D warnings
LZMA_API_STATIC=1 cargo test
```

本机 Intel Homebrew 可能把 `/usr/local/Cellar/xz/5.2.7/lib` 注入 arm64 链接；使用 `LZMA_API_STATIC=1` 从 vendored xz 构建静态 arm64 liblzma，避免错误动态库进入测试或发布产物。

上线后验证：

- ChatGPT 主 `app-server` 和 `node_repl` 子 `app-server` 均运行 App 内置官方 CLI。
- CC Switch 全局代理与 Codex takeover 开启，监听 `127.0.0.1:15721`。
- 自动故障转移关闭。
- 新会话、恢复会话和子代理均能调用 ModelHub。
- 电脑、内置浏览器和 Chrome 插件均无签名拒绝。
- `/usr/local/bin/codex` 保持原 hash，作为快速回滚入口。

## 敏感信息

禁止在提交、测试 fixture、命令输出或日志中记录：

- `auth.json` 完整内容；
- `MODELHUB_AK`；
- bearer token、API Key；
- 真实 `session_id`、`thread_id` 或完整 `extra`；
- 带凭证的完整上游 URL。

测试使用固定虚构 UUID 和本地 mock response。

## 升级

ChatGPT App 更新后重新核对：

- 内置 CLI 路径和 Team ID `2DC432GLL2`；
- `session-id`、`thread-id` 和 `x-client-request-id` 行为；
- `node_repl` 中 App 版本、trusted browser client hashes 与 Computer Use bundle 路径。

CC Switch 更新后，从新 tag 重放以下独立提交并重新跑完整验证：

1. Provider 元数据类型；
2. ModelHub session header adapter；
3. 同 Provider 429 retry loop；
4. 活动摘要模式、去重与未分类 Luna 观测；
5. Provider UI 与四语文案。

在重新验证完成前，不使用上游 updater 覆盖定制 App。

## 回滚

快速回滚只把 ChatGPT 主进程和 `node_repl` 的 `CODEX_CLI_PATH` 恢复为 `/usr/local/bin/codex`；ModelHub adapter 兼容私有 CLI 的下划线头，但电脑、浏览器和 Chrome 的旧签名失败会重新出现。

完整回滚必须先退出 ChatGPT 和 CC Switch，再恢复：

- 原 `/Applications/CC Switch.app`；
- `~/.cc-switch/cc-switch.db` 与 `settings.json`；
- `~/.codex/config.toml`；`~/.codex/auth.json` 从不由安装器读取、修改、备份或恢复；
- `/etc/codex/managed_config.toml`；原文件存在则恢复原内容和权限，原本不存在则删除本次创建文件，并仅在空目录时移除安装器创建的 `/etc/codex`；
- LaunchAgent 和 `launchctl CODEX_CLI_PATH`；
- 迁移前 Provider、代理与 takeover 状态。

`/Applications/ChatGPT.app` 同样不在完整回滚范围内；若由安装器 bootstrap，它会继续保留。

完整操作顺序见 Codex 仓库中的 `docs/superpowers/plans/2026-07-26-official-cli-cc-switch-migration.md`。
