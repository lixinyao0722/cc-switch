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

## 安装（ModelHub R26 正式版，2026-09-23）

R26 在 R25 的 ModelHub 治理目录和 GPT-6 Astra 基础上，统一安装器与 CC Switch 运行时使用的 Codex 模型目录。保存 ModelHub 供应商时，会把用户新增映射合并进 Astra、Sol、Terra、Luna、GPT-5.5、GPT-5.4、GPT-5.2 等默认模型，并恢复 `low`、`medium` 推理等级。默认模型仍为 `gpt-5.6-sol`，应用版本继续为 `3.24.0`；历史基线和安装边界见 [R24 发布与验收说明](modelhub-r24-local-delivery-zh.md)。

正式发布标签为 `modelhub-installer-20260923-r26`，资源由本 fork 的 GitHub Release 提供。R26 默认关闭“支持手机远程会话”：安装器不创建或写入系统 managed config，桌面 Codex 仍可使用本地代理。手机远程路由需在供应商编辑页明确开启后保存。应用内仍保留官方更新渠道，将来官方版本超过 3.24.0 时，先核对定制能力兼容性再升级。

安装器支持 macOS 12 及以上版本的 Apple Silicon Mac。开始前只需从管理员处获取 `MODELHUB_AK`；如果 `/Applications/ChatGPT.app` 不存在，安装器会从 OpenAI 官方固定 HTTPS 地址下载新版 ChatGPT DMG，挂载、验签并安装。安装完成后，用户仍需自行打开 ChatGPT 并登录。

R23 基于 CC Switch 3.20.0，补齐 ModelHub / OpenAI Official 双向切换的历史会话兼容：旧 `modelhub` 会话和 Provider 模板会在启动时备份并一次性迁移到稳定的 `custom` 桶，安装器同时开启“统一 Codex 会话历史”并请求迁入既有官方会话，因此两个方向切换后都从同一个历史桶恢复。R23 保留 R22 的连续兼容恢复：当请求先因其他 Azure OpenAI 资源生成的 Responses item ID 失败、删除顶层 ID 后又暴露 `invalid_encrypted_content` 时，CC Switch 会继续删除失效的 reasoning 密文并进行最后一次重试，同时保留内容和 `call_id` 工具关系。每种兼容修复最多执行一次，普通 400 不会重试。R23 继续使用 `1,050,000` token 的 GPT-5.5 / Sol 模型窗口和 `600,000` token 自动压缩阈值；原生远程压缩、严格增量续接和 429 准入治理保持不变。Golden live 配置直接指向 CC Switch 本地代理，把 review model 固定为 `gpt-5.5-2026-04-24`，桌面菜单开放 low、medium、high、xhigh、max 五档推理强度，并打包批准的 Computer Use MCP 与 ChatGPT 内置 Node REPL 入口。数据库同时预置默认启用的 ModelHub 和非当前状态的 `OpenAI Official`；ChatGPT 登录态始终保留。数据库中的 ModelHub Provider 快照仍保存真实 ModelHub 上游；编辑器偏好、Marketplace 缓存、凭据和用户绝对路径不进入公共包。一键安装入口保持不变：

```zsh
curl -fsSL https://github.com/lixinyao0722/cc-switch/releases/latest/download/install.sh | bash -s
```

必须以当前登录用户运行，不要在 `curl` 或 `bash` 前添加 `sudo`。安装器用中文步骤提示资源校验、备份、配置处理、确认或输入 AK、启动和健康/黄金路由检查；如果 ChatGPT 缺失，则从 OpenAI 官方来源安装。`~/.codex/config.toml` 默认合并 R26 管理字段并保留个性化配置，明确确认后才完整覆盖；`settings.json` 保留用户偏好并更新必要路由字段。注意，完整安装仍会用 Golden 替换 `~/.cc-switch/cc-switch.db`，包括其中原有的自定义供应商；安装前保留完整备份。R26 的系统 managed config 默认不变；手机远程开关在 App 中单独管理。资源使用清洗后的可移植 Provider、模型 catalog 和批准的 Codex/MCP 字段，不包含日志、会话、用量记录、备份和凭据。

检测到已有 `~/.codex/config.toml` 时，安装器会询问是否使用 R26 标准配置完整覆盖。回车或 `N` 默认采用合并模式：刷新 R26 管理的模型、远程压缩、Desktop、Computer Use、Node REPL 和 ModelHub 字段，同时保留编辑器、Marketplace、项目授权及其他插件配置；顶层 `model_provider = "custom"` 必须写入且只能出现一次。输入 `Y` 才完整覆盖。若现有文件使用带引号键、点分键、多行字符串或多行数组等复杂 TOML，无法安全合并时默认 `N` 停止安装，明确输入 `Y` 才覆盖。新安装没有现有配置时直接写入 Golden。

Golden Codex 配置固定以下安装后状态：

```toml
review_model = "gpt-5.5-2026-04-24"

[desktop]
git-branch-prefix = "feat/"
show-context-window-usage = true
preventSleepWhileRunning = true
enabled-reasoning-efforts = ["low", "medium", "high", "xhigh", "max"]

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

[model_providers.custom]
base_url = "http://127.0.0.1:15721/v1"
```

Codex 已经运行时可能不会热更新这些设置或新的 catalog。安装完成后若界面状态未刷新，请重启 Codex；迁移完成后可直接打开旧任务继续。

## 一键切换 ModelHub 与官方 Codex

安装后打开 CC Switch 的 Codex 供应商列表即可看到两个入口：

- `Bytedance ModelHub - 官方CLI`：默认选中，经 CC Switch 转发到 ModelHub。
- `OpenAI Official`：使用当前 ChatGPT Plus/Pro 登录态，关闭 Codex 接管后直连 OpenAI 官方 Codex。

切到 ModelHub 后确保 Codex 接管和本地监听可用；切到 `OpenAI Official` 后关闭 Codex 接管，不停止其他应用使用的代理。卡片、开关和代理状态在成功或失败后重新读取，切换期间禁止冲突操作。

“支持手机远程会话”位于供应商编辑页的“ModelHub 会话头适配”上方，默认关闭。只有明确开启才写系统 managed config：Provider 使用 `custom`，本地代理地址取实际监听配置而非固定端口。关闭已启用的手机路由或切回官方时，只撤销 CC Switch 自己管理的路由键，保留其他策略和注释。旧 R23 没有归属记录的系统强制路由不会被默认关闭开关擅自删除；若与目标路由冲突，界面需要明确提示处理，不能仅凭卡片判断已经官方直连。

需要管理员权限的变更先于 Live 路由切换；后续失败恢复必要状态，回滚未完成必须反馈给界面。两种模式切换后都需要重启 Codex；旧 ModelHub 与既有官方任务仍使用 `custom` 统一历史桶。只能由原上游解密的 reasoning 内容仍可能无法跨供应商续接。

如果安装器进程已继承非空 `MODELHUB_AK`，R23 会提示 `检测到当前环境已有 MODELHUB_AK，是否直接复用？[Y/n]`。回车、`Y` 或 `y` 直接复用；`N` 或 `n` 会显示 `请输入 MODELHUB_AK（向管理员获取，输入内容不会显示）`，允许无回显输入新值；其他回答会重新询问。没有环境变量时直接进入无回显输入。最终选择值是本次安装唯一凭据源：先写入 macOS Keychain 并回读，再用回读值更新 CC Switch ModelHub Provider 的 `auth.OPENAI_API_KEY`，LaunchAgent 则把同一凭据加载为当前登录会话的 `MODELHUB_AK`。launchd 环境加载后，安装器立即校验 Keychain、Provider API Key 与 `MODELHUB_AK` 均非空且完全一致；CC Switch 健康、黄金路由稳定后再校验一次。若环境值与旧 Keychain 不同，只有用户确认复用后才以环境值覆盖同步；选择新输入则以新值覆盖同步。校验不会输出密钥，任何写入或校验失败都会恢复安装前状态。

写入 `/Applications` 需要权限时，安装器会说明接下来需要当前 Mac 登录用户的管理员密码，而不是 `MODELHUB_AK`。密码输入时终端不会显示字符，输入完成后按回车。系统手机路由的授权在 App 明确开启开关时另行处理。

明确启用手机远程路由时，候选文件置于权限受限的暂存目录，管理员进程验证它的所有者和权限。`/etc/codex/managed_config.toml` 以 `root:wheel 0644` 替换，管理下列两个根键并保留其他配置、表和注释；不定义保留的 `[model_providers.openai]`。下面端口仅为默认值，运行时使用实际监听地址：

```toml
model_provider = "custom"
openai_base_url = "http://127.0.0.1:15721/v1"
```

只有启用手机远程强制路由时，CC Switch 不可用才会同时影响桌面默认会话和移动端显式 `openai` 会话；重新启动 CC Switch 后可继续请求。手机验收重点是重启 Codex 后新建全新远程会话，不以旧失败线程重试代替。

完整安装会替换 CC Switch 供应商数据库，安装前状态可通过备份恢复；Codex 个性化配置默认合并，CC Switch 偏好保留。`~/.codex/auth.json` 与 ChatGPT 登录态不覆盖。包内不包含 AK/OAuth、日志、会话、用量记录或备份；用户路径统一为 `__USER_HOME__`，安装时替换为真实用户目录。

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
model_provider = "custom"
model_reasoning_effort = "high"
model_auto_compact_token_limit = 600000
model_context_window = 921_860
model_catalog_json = "/Users/<current-user>/.codex/cc-switch-model-catalog.json"

[features]
remote_compaction_v2 = true

[desktop]
git-branch-prefix = "feat/"
enabled-reasoning-efforts = ["low", "medium", "high", "xhigh", "max"]

[model_providers.custom]
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
    "codexRemoteSessions": false,
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
    },
    "contextOptimization": {
      "enabled": true,
      "checkpointTtlSeconds": 21600
    },
    "admissionControl": {
      "enabled": true,
      "largeRequestTokens": 100000,
      "concurrency": 4
    }
  }
}
```

R23 继承对真实 ModelHub 的三项协议验真：`store=true` 返回可续接的 `resp_...`，仅发送新输入和 `previous_response_id` 能恢复上一轮精确信息，`/responses/compact` 返回的完整 opaque compaction output 也能在下一轮恢复压缩前细节。CC Switch 因此仅在 Provider、会话、模型、稳定请求选项和完整历史前缀逐项匹配时发送增量；fork、并发请求、过期游标、重启或任意哈希不一致都自动发送完整历史。若完整历史仍携带其他 Azure OpenAI 资源生成的顶层 item `id`，CC Switch 会在收到精确跨资源 400 后移除这些 ID 并单次重试；若该重试继续精确返回 `invalid_encrypted_content`，会再清除失效 reasoning 密文并进行最后一次重试。checkpoint 只保存在内存中，本地原始 transcript 不会删除。

`remote_compaction_v2` 交给 Codex 原生实现 compact 时机与 opaque output 延续，CC Switch 负责透明透传。ModelHub Provider 同时启用按 Provider + 模型隔离的 token 加权准入：估算达到 10 万输入 token 的请求独占四个并发槽，小请求占一个槽；`-2004` 容量不足最多恢复一次，标题、摘要与 Skill 选择等 helper 仍只请求一次。日志只记录 full/delta、估算 token、请求体字节数、排队耗时和 checkpoint 是否存在，不记录正文、会话 ID、response ID 或凭据。

`codexActivitySummaryMode` 只作用于 Codex Desktop 固定的 `gpt-5.6-luna` 活动摘要提示词，可选 `passthrough`、`block`、`map`。R14 默认 `map`，复用 `codexMetadataModel` 生成摘要；`block` 在本地返回不可重试 400；`passthrough` 保留 Luna，适用于拥有 Luna 权限的 Provider。完全相同的 Provider/thread/摘要内容在 5 秒内只允许一次上游请求，映射摘要及动态 Skill 选择辅助请求遇到 429 都只访问上游一次。

`codexMetadataModel` 改写 Codex Desktop 固定的任务标题、任务描述、标题重考虑、语音标题，以及使用 `skill_selection` schema、developer/assistant/user 三段角色结构和完整有序 Skill 指令标记的动态 Skill 选择请求，也是活动摘要 `map` 模式的目标模型。主任务、标题和活动摘要 helper 都使用这一协议。普通 Luna、错误 schema、角色乱序或缺少稳定标记的结构化请求不匹配精确分类，仍按原路由转发。App 中关闭“内部元数据映射”会清除该字段；活动摘要处于 `map` 时必须提供非空目标模型。

`rememberInvalidEncryptedReasoning` 只在 ModelHub 精确返回 `invalid_encrypted_content` 且清理后的兼容重试成功后，按 Provider + 客户端会话临时记录不兼容状态；清理后若得到 400、429 或其他失败，不会记录。同会话下一次请求会在第一次发送前删除 reasoning item 的 `encrypted_content`，请求成功后自动清除该提示并恢复原始历史探测。含非空明文 `summary/content` 的 reasoning 继续保留；即使明文为空，只要后续存在依赖它的 `function_call`、`custom_tool_call` 及对应 output，也会保留整个依赖组，避免产生孤儿调用。只有没有可见内容且没有工具依赖的 reasoning 才整项删除。状态不写数据库，CC Switch 重启后自动清空；将该字段改为 `false` 可关闭学习与预清理。

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

从旧 ModelHub 安装器升级到包含 catalog 统一修复的版本后，打开当前 ModelHub Provider 并保存一次。CC Switch 会把历史 `models-modelhub-1m.json` 指针迁移为 `cc-switch-model-catalog.json`，保留内置默认模型并合并表格中的新增模型；其他自定义 catalog 文件不会被接管。随后完整退出并重开 Codex，使其重新加载目录。

在重新验证完成前，不使用上游 updater 覆盖定制 App。

## 回滚

快速回滚只把 ChatGPT 主进程和 `node_repl` 的 `CODEX_CLI_PATH` 恢复为 `/usr/local/bin/codex`；ModelHub adapter 兼容私有 CLI 的下划线头，但电脑、浏览器和 Chrome 的旧签名失败会重新出现。

完整回滚必须先退出 ChatGPT 和 CC Switch，再恢复：

- 原 `/Applications/CC Switch.app`；
- `~/.cc-switch/cc-switch.db` 与 `settings.json`；
- `~/.codex/config.toml`；`~/.codex/auth.json` 从不由安装器读取、修改、备份或恢复；
- 系统 managed config：R26 默认安装不改变此文件，所以安装回滚不恢复未改变的对象。App 开启手机路由后，关闭开关只撤销其拥有的路由字段，不能删除用户其他配置；历史 R23 备份恢复须核对其独立清单；
- LaunchAgent 和 `launchctl CODEX_CLI_PATH`；
- 迁移前 Provider、代理与 takeover 状态。

`/Applications/ChatGPT.app` 同样不在完整回滚范围内；若由安装器 bootstrap，它会继续保留。

完整操作顺序见 Codex 仓库中的 `docs/superpowers/plans/2026-07-26-official-cli-cc-switch-migration.md`。
