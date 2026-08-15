# ModelHub 可配置兼容策略 R11 设计

## 背景

R10 已为 ModelHub Codex Responses 路由提供三项 Provider 级隐藏策略：

- 将可确认属于 Codex Desktop 的标题、描述和标题重考虑请求从 `gpt-5.6-luna` 精确映射到 `gpt-5.6-sol`；
- 将活动摘要请求在 CC Switch 本地返回不可重试的 HTTP 400；
- 首次确认某个 Provider + Codex 会话无法验证历史加密推理后，同会话后续请求在发送前预清理。

这些字段保存在 `Provider.meta.localProxyRequestOverrides`，UI 保存时会保留，但用户不能直接查看或修改。R10 实机验证还确认：活动摘要提示词可被精确识别，普通一问一答通常在用户消息和最终回复后各触发一次；摘要单次上下文远小于主任务，但历史上出现过同秒大量重复触发，当前 Sol 容量也仍出现最终 429。

用户已批准：将 R10 的兼容策略做成 CC Switch Provider 配置；活动摘要支持映射，且 R11 安装器默认映射到元数据目标模型；线程协调辅助 Luna 请求先做脱敏指纹观测，精确分类前不直接映射。

## 配置归属

所有行为都属于 CC Switch 对特定上游 Provider 的请求分类、改写、重试和兼容策略，存放在 `Provider.meta.localProxyRequestOverrides`，不写入 Codex `config.toml`。

Codex `config.toml` 继续只承载 Codex 官方支持的模型、Provider、base URL、认证和通用客户端参数。R11 不向 `model_providers.<id>` 注入 Codex 不认识的私有字段，也不通过自定义 HTTP Header 传递本地策略。

## 方案选择

### 方案 A：继续使用隐藏 Provider metadata

改动最小，但用户无法切换活动摘要策略或修改元数据目标模型，重装 R11 还会恢复安装器默认值。不采纳。

### 方案 B：把策略写入 Codex `config.toml`

配置表面集中，但这些字段不属于 Codex 官方 schema，Codex 不消费它们，项目级配置还会忽略部分 Provider 字段。会造成所有权混乱和兼容风险。不采纳。

### 方案 C：CC Switch Provider 高级配置

在现有“本地代理请求覆盖”内增加 ModelHub 兼容策略控件，直接读写已有 Provider metadata；运行时仍按 Provider、Codex Responses 路由和精确提示词分类生效。采纳。

## Provider 配置模型

### 现有字段

- `codexSessionHeaderAdapter = "modelhub"`：启用 ModelHub 会话头适配，也是以下策略的作用域门禁。
- `retry429`：主请求和普通元数据的同 Provider 429 退避参数。
- `codexMetadataModel`：非空时启用标题、描述和标题重考虑映射，同时作为活动摘要 `map` 模式的目标模型。
- `rememberInvalidEncryptedReasoning`：是否学习 Provider + 客户端会话的不兼容状态并预清理。
- `blockCodexActivitySummaries`：R9/R10 兼容字段，仅用于旧数据读取，不再作为 R11 UI 的主写入字段。

### 新字段

```text
codexActivitySummaryMode = "passthrough" | "block" | "map"
```

- `passthrough`：保留原始 `gpt-5.6-luna`，用于拥有 Luna 权限的 Provider。
- `block`：本地不可重试 400，不占用上游配额。
- `map`：只将精确活动摘要请求改写到 `codexMetadataModel`。

兼容读取优先级：

1. 存在 `codexActivitySummaryMode` 时使用新字段；
2. 否则 `blockCodexActivitySummaries = true` 等价于 `block`；
3. 两者均不存在时等价于 `passthrough`，保持普通 CC Switch Provider 的旧行为。

R11 UI 保存时写入新字段并移除旧布尔字段。R11 安装器模板写入 `map`，默认恢复侧边栏活动摘要；短窗去重和摘要 429 不重试负责限制辅助流量对主任务的影响。

## UI 设计

在 Codex Provider 的“本地代理请求覆盖”中，将现有 ModelHub 会话头与 429 设置归入同一“ModelHub 兼容策略”区域，增加：

1. **内部元数据映射**开关：关闭时清除 `codexMetadataModel`；开启时要求目标模型非空。
2. **元数据目标模型**输入框：默认 `gpt-5.6-sol`，供标题、描述、标题重考虑和活动摘要 `map` 模式复用。
3. **活动摘要策略**三选一：原样发送、本地拦截、映射到元数据模型。
4. **记忆加密推理不兼容会话**开关：对应 `rememberInvalidEncryptedReasoning`。

现有 Header/Body JSON、高级 429 参数继续保留。`body.max_output_tokens` 已能通过 Body 覆盖修改，本版不再增加重复输入框。

关闭 ModelHub 会话头适配时，清除所有 ModelHub 专属策略，避免 UI 显示关闭而隐藏策略仍生效。

## 活动摘要映射与削峰

活动摘要只有同时满足以下条件才进入新策略：

1. Codex `/responses` 路由族；
2. Provider 开启 ModelHub 会话头适配；
3. 顶层模型精确等于 `gpt-5.6-luna`；
4. user message 文本以当前 App 的固定活动摘要提示词开头。

`map` 模式执行：

- 将顶层 `model` 改为 `codexMetadataModel`，保留 output schema、输入和身份 Header；
- 不使用 Provider 的 `retry429`，活动摘要遇到 429 直接失败，避免 UI 辅助请求放大主任务限流；
- 对同 Provider、thread 和摘要提示内容计算进程内指纹，5 秒内重复请求只允许第一次访问上游，其余返回本地不可重试 400；
- 指纹缓存最多 2048 项，达到上限时整体清空；不持久化，不记录正文或真实 thread ID。

正常的一问一答中，用户请求摘要和最终回复摘要内容不同，因此不会互相去重。该策略只削减完全相同的重放和并发重复。

## 未分类 Luna 请求观测

对于作用域内、模型为 `gpt-5.6-luna`、但未命中标题、描述、标题重考虑或活动摘要的请求，R11 记录一次脱敏诊断日志：

- 固定标签 `request_kind=unclassified_codex_luna`；
- user 文本内容的 SHA-256 截断指纹；
- input item 数、user message 数、是否包含 output schema；
- 不记录提示词正文、session/thread ID、AK 或完整 Header。

每个进程仅记录每个唯一指纹一次，集合最多 256 项，达到上限时整体清空。该观测用于锁定“线程协调辅助请求”的稳定特征；R11 不按工具名、session 或普通 Luna 模型粗暴映射。

## 保持内部的兼容机制

以下机制不提供 UI 开关：

- `namespace` 空 description 修复；
- HTTP 400/401/403 快速失败；
- SSE 有效进展与总时长保护；
- 精确元数据提示词分类规则；
- 进程缓存容量、敏感信息脱敏和清理策略。

它们属于安全或协议正确性约束，关闭会产生难以解释的损坏状态。

## 安装器与发布

- App 版本保持 `3.19.2`。
- 发布 tag 为 `modelhub-installer-20260816-r11`。
- R11 Golden DB 默认：会话头适配开启、活动摘要 `map`、元数据目标模型 `gpt-5.6-sol`、加密推理学习开启、主请求 429 最多重试 3 次。
- 安装器重新执行会恢复上述 R11 默认策略；用户应在安装完成后通过 App 修改 Provider 配置。
- 回滚继续使用 `install.sh --rollback latest`。

## 验证要求

### 配置与 UI

- 旧 `blockCodexActivitySummaries = true` 正确显示为 `block`。
- 保存后使用 `codexActivitySummaryMode`，其他 Header/Body/429 配置不丢失。
- 元数据映射关闭、目标模型为空、活动摘要 `map` 缺少目标模型均有明确行为或校验。
- 关闭会话头适配会清除所有 ModelHub 专属策略。

### 路由行为

- 活动摘要 `block` 不到达上游。
- 活动摘要 `map` 以目标模型到达上游一次。
- `passthrough` 保持 Luna。
- 普通 Luna、标题/描述、主任务和其他 Provider 不受活动摘要设置误伤。
- 完全相同的并发/短窗摘要只产生一次上游请求。
- 映射摘要收到 429 时不走三次退避；主任务仍按原配置重试。

### 观测与隐私

- 未分类 Luna 输出稳定指纹与结构计数。
- 已分类元数据不输出未分类日志。
- 日志不含原始提示词、session/thread ID 或凭据。

### 发布

- 前端 typecheck、format、unit tests 全绿。
- Rust fmt、clippy、全量 tests 全绿。
- 安装器全套测试通过。
- 新 App 的架构、版本、签名、SHA、Golden DB、实际安装、重复安装、回滚和远端回下载均通过。
