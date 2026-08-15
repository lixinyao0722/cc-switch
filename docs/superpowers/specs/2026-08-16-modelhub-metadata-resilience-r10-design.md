# ModelHub 元数据与加密推理韧性 R10 设计

## 背景

R9 已能识别 Codex Desktop 的回合活动摘要请求，并在 CC Switch 本地返回不可重试的 HTTP 400，避免固定使用 `gpt-5.6-luna` 的活动摘要流量到达无 Luna 权限的 ModelHub。R9 上线后的本机日志仍显示两类可优化流量：

1. 任务标题、任务描述、标题重考虑等其他 Codex 内部元数据请求仍使用 Luna，形成每项 5–22 次 HTTP 401 重放；
2. 长会话会携带历史 `reasoning.encrypted_content`，ModelHub 无法验证时先返回 `invalid_encrypted_content`，CC Switch 删除加密推理项后才整包重发。

用户已明确批准：保留活动摘要本地拦截；将其他内部元数据 Luna 请求精确映射到 Sol；首次确认某会话的加密推理与 ModelHub 不兼容后，同会话后续请求发送前预清理。

## 目标

- 保留任务标题、描述和标题重考虑等 UI 元数据功能。
- 只将可确认属于 Codex Desktop 内部元数据生成的 Luna 请求映射到 `gpt-5.6-sol`。
- 活动摘要继续本地拦截，不映射到 Sol。
- 用户主动发送的普通 Luna 请求保持原样。
- 对已确认不兼容的 Provider + Codex 会话，在发送前删除历史加密推理项，避免重复的先失败再整包重发。
- 发布 ModelHub 一键安装器 R10，App 版本继续保持 CC Switch 3.19.2。

## 元数据识别与模型映射

### Provider 配置

在 `LocalProxyRequestOverrides` 增加可选字段：

```json
{
  "codexMetadataModel": "gpt-5.6-sol"
}
```

字段为空或不存在时不做元数据模型映射。R10 的 ModelHub 模板固定写入 `gpt-5.6-sol`。

### 识别范围

请求必须同时满足以下条件才允许映射：

1. 路由属于 ModelHub Codex Responses 路由族；
2. 请求顶层 `model` 精确等于 `gpt-5.6-luna`；
3. Responses `input` 中的 user 文本以当前 Codex Desktop 固定元数据提示词之一开头：
   - 新任务标题：`You are a helpful assistant. You will be presented with a user prompt, ...`
   - 现有对话标题：`You are a helpful assistant. You will be presented with the most recent messages in an existing conversation, ...`
   - 任务描述：`You are in a fork of an existing Codex thread.`
   - 标题重考虑：`You are in a fork of an existing Codex thread at a possible durable title checkpoint.`
   - 语音任务标题：`You are in a fork of a voice chat.`

活动摘要提示词 `You write the one-line activity update displayed beneath an existing Codex task title.` 的优先级更高，继续命中 R9 本地拦截，不进入映射。

普通 Luna、相似但不精确的提示词、非 user message、非 Responses 路由、其他 Provider 和 Copilot 请求均不映射。

### 映射行为

在最终出站 body 完成协议转换与 Provider body override 后、网络发送前识别元数据类型。命中非活动摘要元数据时只改写 body 顶层 `model`，保留输入、输出 schema、session/thread headers 和其他字段。日志只记录元数据类型及目标模型，不记录提示词正文或真实身份。

## 加密推理会话级预清理

### Provider 配置

在 `LocalProxyRequestOverrides` 增加可选字段：

```json
{
  "rememberInvalidEncryptedReasoning": true
}
```

仅当该字段为 `true`、请求属于 ModelHub Codex Responses、且客户端提供了稳定 session ID 时启用学习与预清理。

### 状态与生命周期

`ProxyState` 持有进程内共享集合，键为 `(provider_id, session_id)`。集合跨 HTTP 请求和 `RequestForwarder` 实例共享，CC Switch 重启后自动清空。为限制内存，集合最多保留 2048 个键；达到上限时整体清空后写入当前键。集合不持久化、不写数据库，也不记录真实 session ID 到日志。

### 首次失败与后续请求

首次请求仍保留原有兼容探测：

1. 原样发送；
2. 若 ModelHub 返回精确 `invalid_encrypted_content`，删除含 `encrypted_content` 的 reasoning items；
3. 若确实删除了至少一项，则记录该 Provider + session 为不兼容并重发一次。

同一 Provider + session 的后续请求在第一次发送前检查共享集合；命中时先删除加密 reasoning items，再发送。未携带稳定客户端 session ID、未启用配置、其他 Provider、其他路由或没有加密 reasoning items 的请求保持现状。

## 错误处理与安全边界

- 元数据映射到 Sol 后，429 仍沿用已有最多 3 次同 Provider 退避策略。
- 映射不改变用户主任务模型，不把普通 Luna 请求改投 Sol。
- 会话预清理只在上游已用精确错误证明不兼容后生效，不对所有会话无条件删除推理状态。
- 日志不得包含 AK、真实 session/thread ID、完整提示词或 encrypted content。
- 活动摘要仍以本地 400 失败，因此不会占用 Sol TPM。

## 测试

### 元数据映射

- 每种真实提示词均识别为对应元数据类型。
- 活动摘要仍识别为本地拦截类型。
- 普通 Luna、Sol、相似提示词、developer message 不识别。
- forwarder 集成测试证明标题/描述请求以 Sol 到达 mock 上游且只到达一次。
- forwarder 集成测试证明活动摘要到达上游次数为 0、普通 Luna 保持 Luna。
- 配置不存在时不映射。

### 加密推理预清理

- 首次会话请求先收到 `invalid_encrypted_content`，清理后重发并成功，同时学习会话状态。
- 同会话第二次请求第一次到达 mock 上游时已无加密 reasoning item，且总共只发送一次。
- 不同会话仍执行一次兼容探测。
- 不同 Provider 不共享状态。
- 配置关闭或 session 非客户端提供时不预清理。

### 安装器与发布

- R10 模板和打包后 Golden DB 必须包含 `codexMetadataModel = gpt-5.6-sol` 与 `rememberInvalidEncryptedReasoning = true`。
- 安装器 tag 固定为 `modelhub-installer-20260816-r10`。
- Release 保持四项资产，执行 SHA、签名、架构、Golden DB、敏感扫描、安装、重复安装和回滚烟测。

## 发布与回滚

- 分支：`feat/modelhub-metadata-resilience-r10`。
- 新建独立 R10 MR，目标为已合并 R9 的 `main`。
- Release tag：`modelhub-installer-20260816-r10`。
- App 版本：CC Switch 3.19.2。
- 回滚可使用安装器的 `--rollback latest` 恢复安装前状态；代码级回滚可关闭两个 Provider 字段，分别停用元数据映射和会话学习。
