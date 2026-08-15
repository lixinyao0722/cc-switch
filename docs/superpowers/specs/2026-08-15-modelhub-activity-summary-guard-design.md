# ModelHub 活动摘要请求本地拦截设计

## 背景

Codex Desktop 会在用户消息和最终回复后生成任务列表活动摘要。当前桌面版本将该内部请求固定发送到 `gpt-5.6-luna`，ModelHub AK 没有 Luna 权限，因此每次由 ModelHub 返回 HTTP 401。Codex 外层会继续重试，单次摘要可形成约 21 次真实上游请求；这些请求不产生模型推理 token，但会占用网关 QPS、连接和共享 AK 流量，并可能放大限流。

## 目标

- 在 CC Switch 本地识别 Codex Desktop 活动摘要的 Luna 请求。
- 返回明确、不可重试的 HTTP 400，不访问 ModelHub。
- 不把 Luna 映射到 Sol，避免消耗 Sol 容量并加剧 429。
- 不拦截用户主动选择的普通 Luna 请求。
- 只对 ModelHub 定制的 Codex Responses 路由生效。

## 识别边界

请求必须同时满足以下条件才拦截：

1. 路由通过 `is_modelhub_codex_responses_route` 判定；
2. body 顶层 `model` 精确等于 `gpt-5.6-luna`；
3. body 的 Responses `input` 中存在文本内容，以 Codex Desktop 固定活动摘要提示词 `You write the one-line activity update displayed beneath an existing Codex task title.` 开头。

只匹配模型、不匹配提示词的 Luna 请求继续转发。只匹配提示词、不使用 Luna 的请求继续转发。非 ModelHub、非 Codex 或非 Responses 路由继续走原逻辑。

## 实现位置

- 在 `src-tauri/src/proxy/modelhub_compat.rs` 增加纯函数识别器，负责检查 model 与输入文本。
- 在 `src-tauri/src/proxy/forwarder.rs` 完成 body 定稿之后、任何网络发送之前调用识别器；命中时返回 `ProxyError::InvalidRequest`。
- 复用现有 `ProxyError::InvalidRequest -> HTTP 400` 映射和 ModelHub 客户端错误不可重试规则，不新增协议或数据库字段。

## 错误语义

错误信息应明确说明：CC Switch 已在本地阻止无权限的 Codex Desktop Luna 活动摘要，以保护 ModelHub 配额。不得包含用户消息正文、AK、session/thread 标识或其他敏感内容。

## 测试

- 精确活动摘要 Luna 请求命中。
- 普通 Luna 请求不命中。
- Sol 活动摘要请求不命中。
- 仅包含相似短语、不具有固定前缀的请求不命中。
- 顶层 message content 与 Responses content block 两种文本承载均可识别。
- forwarder 路由测试证明只在 ModelHub Codex Responses 路由返回 400，且不会进入上游 mock server。

## 发布

- 安装器 tag 升级为 `modelhub-installer-20260815-r9`。
- App 版本保持 CC Switch `3.19.2`，资产名保持 `CC-Switch-ModelHub-3.19.2-arm64.app.zip`。
- R9 Release 继续包含四项资产并在公开前完成 SHA、签名、架构、数据库、敏感扫描和安装烟测。
