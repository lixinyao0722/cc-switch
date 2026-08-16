# ModelHub 辅助流量与上下文保真 R12 设计

## 背景

R11 已把 Codex Desktop 的标题、描述、标题重考虑和活动摘要请求精确映射到 Provider 配置的 `codexMetadataModel`，并为活动摘要增加短窗去重和 429 不重试保护。R11 还对其余 Luna 请求记录脱敏指纹与结构计数，但不自动映射。

R11 安装后的实机日志确认：每次活动摘要 helper thread 在 `build_skills_and_plugins` 阶段都会产生两条结构化 Luna 辅助请求；ModelHub 对每条请求返回 401，客户端各重试一次，因此一次更新额外产生四次 Luna 401。请求与主任务、活动摘要正文和 auto-review 均可区分。

同一轮验证还确认：`invalid_encrypted_content` 回退当前会删除整条带 `encrypted_content` 的 reasoning item，即使 item 内存在可用明文 `summary`。使用当前真实会话 reasoning item 进行受控验证时，仅删除 `encrypted_content`、保留 `id + summary` 的请求由 ModelHub 单次返回 200。

用户已批准将这两项优化合并到 R12 并发布。

## 目标

1. 精确识别活动摘要 helper thread 内的动态 Skill 选择辅助请求，将其映射到 `codexMetadataModel`，消除 Luna 401 与客户端重试。
2. 在 `invalid_encrypted_content` 回退和已学习会话的预清理中，只删除不可用密文字段，尽量保留可用明文 reasoning 上下文。
3. 收紧 ModelHub 429 重试并增加 Provider 级共享冷却，避免并发请求各自启动完整退避链。
4. 保持 R11 Provider 配置字段不变，发布安装器 `modelhub-installer-20260816-r12`。

## 非目标

- 不映射用户主动发起的普通 Luna 请求。
- 不把所有结构化 Luna 请求统一映射。
- 不在 R12 合成动态 Skill 选择的本地成功响应。当前尚未证明该响应 schema 和调用方回退语义稳定，错误的伪成功会比映射更难诊断。
- 不改变标题、描述、标题重考虑、活动摘要或主任务已有分类规则。
- 不新增 Provider UI 字段，不修改 Codex `config.toml` 私有配置。
- 不删除 CC Switch 的同 Provider 429 恢复能力；Codex 当前只为 5xx/传输错误执行 request retry，不能替代这一层。

## 动态 Skill 选择辅助请求

### 分类

新增独立请求类型 `ActivitySummarySkillSelection`，不与现有四类元数据复用名称。只有同时满足以下条件时才命中：

1. 顶层模型精确为 `gpt-5.6-luna`；
2. 请求包含结构化输出 schema；
3. `input` 结构与实机观测一致：3 个 input item、1 个 user message；
4. user message 中包含完整的活动摘要固定提示词，但不以该提示词开头，因此不会命中正常 `ActivitySummary`。

分类函数继续是纯函数。R12 测试使用字面量结构夹具覆盖前置选择指令、活动摘要提示词和结构化 schema，并覆盖空白变化、相似但非同类提示词、普通结构化 Luna、主动 Luna、已知元数据和 Sol 请求。发布前必须用安装后的真实流量确认该分类命中；如果当前 App 请求不包含完整活动摘要提示词，则停止发布并根据新增的脱敏结构日志收紧分类，不能退化为仅按 item 数量或 schema 映射。

### 路由

命中后：

- 仅在 Codex `/responses` 路由、Provider 开启 ModelHub session adapter 且不是 Copilot 时生效；
- 将顶层模型改写为现有 `codexMetadataModel`；
- 设置 `skip_modelhub_429_retry = true`，不继承 Provider 主请求的 429 退避；
- 记录 `mapped Codex metadata request kind=ActivitySummarySkillSelection`，不记录正文；
- 不进入 `unclassified_codex_luna` 观测集合。

R12 先采用映射而不是本地成功响应，因为映射保留了 Codex 动态 Skill 选择的真实语义。后续只有在拿到稳定响应契约和调用方容错测试后，才考虑本地 no-op。

## Encrypted reasoning 上下文保真

### 清理规则

将整项删除函数替换为共享 sanitizer，并在首次 400 回退与已学习会话预清理中复用：

1. 只处理 `type = "reasoning"` 且存在 `encrypted_content` 的 input item；
2. 删除 `encrypted_content` 字段；
3. `summary` 含至少一条非空文本，或 `content` 含至少一条非空文本时，保留整个 reasoning item，包括 `id` 和兼容元数据；
4. 删除密文后没有可用 `summary/content` 时，删除整个 reasoning item；
5. assistant message、function call、function-call output、user message 和不含密文的 reasoning item保持原样。

sanitizer 返回两个计数：删除的密文字段数和删除的空 reasoning item 数。日志只记录计数，不记录 ID、summary、content 或密文。

### 回退语义

- 首次命中 `invalid_encrypted_content`：sanitizer 产生变化后记住 Provider + session，使用清洗后的 body 对同一 Provider 重试一次。
- 已学习会话：发送前运行相同 sanitizer，避免再次产生预期 400。
- sanitizer 没有产生变化时不得重试，保持现有快速失败行为。

## ModelHub 429 削峰

### 职责边界

OpenAI 官方配置 schema 仅定义 `request_max_retries` 和 `stream_max_retries`；`retry_429` 不是 `ModelProviderInfo` 字段。当前 Codex Provider 构建将 HTTP 429 retry 固定为 `false`，因此职责划分为：

- Codex `request_max_retries = 2`：处理 5xx、超时和传输错误；
- Codex `stream_max_retries = 3`：处理 SSE 流中断重连；
- CC Switch `retry429`：仅处理 ModelHub Codex Responses 主用户请求的 HTTP 429。

安装器必须删除无效的 `retry_429 = true`，避免用户误以为 Codex 会处理 429。

### 默认策略

R12 的 ModelHub 默认值改为：

```text
maxRetries = 1
baseDelayMs = 2000
maxDelayMs = 30000
honorRetryAfter = true
```

一次逻辑主请求最多产生初始请求和一次同 Provider 恢复尝试。`Retry-After` 优先，但始终受 30 秒上限约束。

标题、描述、标题重考虑、活动摘要和 `ActivitySummarySkillSelection` 等明确 metadata/helper 请求全部设置 `skip_modelhub_429_retry = true`，上游 429 时只访问一次。普通用户主请求才允许一次恢复尝试。

### Provider 共享冷却

新增进程内、Provider 级共享 429 gate，key 为 app type + Provider ID，不持久化：

1. 任一受管主请求收到 429 后，根据 `Retry-After` 或当前退避规则记录共享冷却截止时间；并发请求不得各自 sleep 后独立探测。
2. 冷却截止前的新请求等待同一截止时间，不访问上游。
3. 冷却结束后只允许一条请求作为恢复 probe；其他等待者继续等待 probe 结果。
4. probe 再次收到 429 时延长共享冷却；等待者不启动自己的重试链。
5. probe 收到非 429 响应或传输错误时解除 gate，等待中的逻辑请求再正常发送。
6. 共享 gate 只约束启用了 ModelHub `retry429` 的主请求；metadata/helper 的零重试请求不创建或参与共享冷却。

该设计允许冷却前已经在途的请求完成，但能阻止后续 retry storm。状态集合设置容量上限，超过上限时清理已过期项，不能记录请求正文、session/thread ID 或凭据。

## 安装器与发布

- App 版本保持 `3.19.2`。
- 发布 tag 为 `modelhub-installer-20260816-r12`。
- Golden DB 默认保持 session adapter 开启、活动摘要 `map`、元数据模型 `gpt-5.6-sol`、加密推理学习开启；主请求 429 改为最多重试 1 次、基础延迟 2000ms。
- Provider UI 启用 ModelHub 429 策略时的新默认值同步为 1 次和 2000ms；已保存 Provider 的显式值不做数据库迁移，安装器覆盖后的 Golden Provider 使用 R12 默认值。
- Codex 模板和 Golden config 写入 `request_max_retries = 2`、`stream_max_retries = 3`，并删除 `retry_429 = true`。
- 安装器文案、测试名称、发布目录和指南升级为 R12。
- R12 Release 保持四项资产：App ZIP、`install.sh`、资源包和 `SHA256SUMS.txt`。
- 回滚继续使用 `install.sh --rollback latest`。

## 验证要求

### 分类与路由

- 真实动态 Skill 选择字面量请求被分类为 `ActivitySummarySkillSelection`。
- 两类真实辅助请求均映射到 Sol 并单次成功，不再出现 Luna 401。
- 该类请求收到 429 时 CC Switch 不做 Provider 级重试。
- 普通 Luna、其他结构化 Luna、已知四类元数据、Sol、其他 Provider 和非 Responses 路由不受影响。
- 已分类请求不再输出 `unclassified_codex_luna` 日志。

### Reasoning 保真

- 含明文 summary 的 encrypted reasoning 删除密文后保留 summary、id 和其他兼容字段。
- 含明文 content 的 encrypted reasoning 同样保留。
- 只有密文、空 summary/content 的 reasoning item 被删除。
- 首次回退和已学习预清理收到完全一致的清洗 body。
- 受控 ModelHub 请求仅删除密文字段后返回 200。

### 429

- installer template、Golden config 和生成结果均不包含 `retry_429`。
- 普通 ModelHub 主请求连续 429 时最多访问上游 2 次。
- `Retry-After` 优先且被 30 秒上限截断。
- 所有明确 metadata/helper 请求收到 429 时只访问上游一次。
- 并发测试证明冷却窗口后只有一个恢复 probe；probe 再次 429 时其他请求不产生独立重试。
- probe 成功后等待请求恢复发送，5xx/transport 与 SSE 中断仍分别由 Codex request/stream retry 负责。

### 发布

- 前端 typecheck、format 和 unit tests 通过。
- Rust fmt、clippy 和全量 tests 通过。
- 安装器全量测试通过。
- 新 App arm64、版本、签名、SHA、Golden DB、实际安装、重复安装、回滚及远端回下载验收通过。
- 公开 Latest 安装入口解析到 R12。
