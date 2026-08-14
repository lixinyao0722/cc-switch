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

R6 已合并上游 CC Switch 3.19.1；一键安装入口保持不变，继续使用以下命令：

```zsh
curl -fsSL https://github.com/lixinyao0722/cc-switch/releases/latest/download/install.sh | bash -s
```

必须以当前登录用户运行上面的原始命令，不要在 `curl` 或 `bash` 前添加 `sudo`。安装器会用 8 个中文步骤提示下载、校验、备份、覆盖、写入 AK、启动和验真进度；如果 ChatGPT 缺失，则从 OpenAI 官方来源安装。随后安装器备份并整体覆盖 `~/.codex/config.toml`、`~/.cc-switch/cc-switch.db` 和 `settings.json`。R6 使用清洗后的本机完整配置，包括 Provider、MCP、Prompt、模型价格、技能仓库和偏好，但排除日志、请求/会话/用量记录、备份和凭据。

安装器会显示中文提示 `请输入 MODELHUB_AK（向管理员获取，输入内容不会显示）`。R6 将这次输入作为唯一凭据源：先写入 macOS Keychain 并回读，再用回读值更新 CC Switch ModelHub Provider 的 `auth.OPENAI_API_KEY`，LaunchAgent 则把同一凭据加载为当前登录会话的 `MODELHUB_AK`。launchd 环境加载后，安装器立即校验 Keychain、Provider API Key 与 `MODELHUB_AK` 均非空且完全一致；CC Switch 健康、黄金路由稳定后再校验一次，防止启动同步把 Provider 恢复为旧值。校验只比较一致性，不会把密钥写入进度提示、日志或命令输出；任何写入或校验失败都会触发自动回滚。写入 `/Applications` 时可能另行提示 Mac 管理员密码。

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
review_model = "gpt-5.6-sol"
model_max_output_tokens = 128_000
model_provider = "modelhub"
model_reasoning_effort = "high"
model_auto_compact_token_limit = 829_674
model_context_window = 921_860
model_catalog_json = "/Users/<current-user>/.codex/models-modelhub-1m.json"

[model_providers.modelhub]
name = "modelhub"
wire_api = "responses"
requires_openai_auth = true
base_url = "https://aidp.bytedance.net/api/modelhub/online"
env_key = "MODELHUB_AK"
stream_idle_timeout_ms = 600_000
request_max_retries = 10
stream_max_retries = 10
retry_429 = true
```

Provider 元数据还承接 ModelHub 会话适配和同 Provider 429 重试：

```json
{
  "localProxyRequestOverrides": {
    "codexSessionHeaderAdapter": "modelhub",
    "body": {
      "max_output_tokens": 128000
    },
    "retry429": {
    "maxRetries": 3,
      "baseDelayMs": 1000,
      "maxDelayMs": 30000,
      "honorRetryAfter": true
    }
  }
}
```

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

- 初始请求之外最多重试 3 次。
- 所有尝试复用相同 method、URL、最终 Header 和序列化 body。
- 优先解析 `Retry-After` 的秒数或 HTTP-date，并限制在 30 秒以内。
- 有效 `Retry-After` 原样遵循但限制在 30 秒内；否则按 1、2、4 秒指数退避，并增加 0–25% 随机抖动，避免并发任务同步重试。
- 中间 429 先排空响应体，不更新 Provider 熔断状态。
- 重试耗尽后把最终 429 交给原有错误处理。
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
4. Provider UI 与四语文案。

在重新验证完成前，不使用上游 updater 覆盖定制 App。

## 回滚

快速回滚只把 ChatGPT 主进程和 `node_repl` 的 `CODEX_CLI_PATH` 恢复为 `/usr/local/bin/codex`；ModelHub adapter 兼容私有 CLI 的下划线头，但电脑、浏览器和 Chrome 的旧签名失败会重新出现。

完整回滚必须先退出 ChatGPT 和 CC Switch，再恢复：

- 原 `/Applications/CC Switch.app`；
- `~/.cc-switch/cc-switch.db` 与 `settings.json`；
- `~/.codex/config.toml`；`~/.codex/auth.json` 从不由安装器读取、修改、备份或恢复；
- LaunchAgent 和 `launchctl CODEX_CLI_PATH`；
- 迁移前 Provider、代理与 takeover 状态。

`/Applications/ChatGPT.app` 同样不在完整回滚范围内；若由安装器 bootstrap，它会继续保留。

完整操作顺序见 Codex 仓库中的 `docs/superpowers/plans/2026-07-26-official-cli-cc-switch-migration.md`。
