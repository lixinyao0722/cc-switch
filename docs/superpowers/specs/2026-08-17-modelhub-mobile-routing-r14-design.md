# ModelHub 移动端强制路由 R14 设计

## 背景

Codex 移动端新建线程会在 `thread/start` 显式传入 `modelProvider = "openai"`，并把 `model_provider: "openai"` 持久化到线程元数据。仅在普通 Codex 配置层设置 `model_provider = "modelhub"` 无法覆盖 app-server 的代码级 Provider override，因此移动端线程及其恢复、重试可能绕过 CC Switch。

实机已验证：保留内置 `openai` Provider，但在系统 managed config 中同时设置默认 Provider 和内置 OpenAI base URL，可以让桌面普通会话与移动端显式 `openai` 会话都经过 CC Switch。尝试定义 `[model_providers.openai]` 不可行，Codex 会拒绝覆盖保留的 built-in Provider ID。

## 目标

1. 安装器事务性维护 `/etc/codex/managed_config.toml`，确保默认会话使用 ModelHub，显式选择内置 `openai` 的会话也请求 CC Switch 本地代理。
2. 保留 managed config 中与 R14 无关的配置，并提供精确的失败回滚和显式回滚。
3. 通过不受 Downloads TCC 限制的安全 staging 完成管理员写入。
4. 将 ModelHub 自动压缩阈值固定为 `500000`，将主请求 429 `maxRetries` 固定为 `2`。
5. 发布 App 版本 `3.19.2`、安装器 tag `modelhub-installer-20260817-r14`。

## 非目标

- 不定义或覆盖 `[model_providers.openai]`。
- 不修改已有线程的 `session_meta`、Provider 字段或 Codex 状态数据库。
- 不增加安装后的 app-server 最小轮次或 `proxy_request_logs` 自动验真。
- 不增加 Codex takeover 或 `127.0.0.1:15721` 的独立前置检查；沿用 CC Switch 启动和既有健康/黄金路由检查。
- 不处理移动端线程同步到桌面后侧边栏显示 cwd 的 Codex Desktop 上游问题。
- 不修改 `codexMetadataModel`、活动摘要或 Skill 选择分类逻辑。

## Managed config

目标文件为 `/etc/codex/managed_config.toml`，必须包含以下顶层键：

```toml
model_provider = "modelhub"
openai_base_url = "http://127.0.0.1:15721/v1"
```

合并器只替换这两个顶层键，保留其他顶层键、表、注释和顺序。若键不存在，则在第一个 TOML table 前插入；若文件只有注释或为空，则追加。等价的 quoted key 可以规范化为上述未引用形式，但不得修改表内同名键。

候选文件必须通过真实 TOML parser 校验，并精确确认两个根键的最终值。任何 `[model_providers.openai]` 或等价 quoted table 都视为非法并拒绝安装。

## 权限、staging 与原子写入

安装器继续由登录用户运行，只对受控系统文件操作调用管理员权限。

1. 用户进程在 `/private/var/tmp` 创建仅当前用户可访问的随机 staging 目录，将合并后的候选文件写入其中；管理员进程不直接读取 Downloads 或下载目录。
2. 管理员侧验证 staging 路径、所有者、权限、普通文件类型且不是 symlink，再复制到 `/etc/codex` 内的随机临时文件。
3. 临时文件设置为 `root:wheel 0644`，重新校验内容后，通过同目录原子 rename 替换目标。
4. 所有管理员命令继续经过现有 allowlist，不允许任意 shell 或未验证路径。
5. 无论成功、失败或信号退出，都清理 staging 和残留临时文件。

## 备份与回滚

`/etc/codex/managed_config.toml` 加入安装器 managed targets 和备份 manifest。

- 安装前文件存在：备份完整原文件；失败回滚和 `--rollback latest` 均原样恢复，并恢复原所有者和权限。
- 安装前文件不存在：manifest 记录缺失；回滚删除本次创建的文件。
- 安装前 `/etc/codex` 不存在：回滚删除本次创建的文件后，仅当目录为空时删除 `/etc/codex`。
- 安装前目录已存在：无论回滚后是否为空都保留目录。
- 备份、写入、权限修正或恢复任一步失败均 fail closed，不留下已完成标记。

## ModelHub 参数调整

Golden Codex 配置和模板使用：

```toml
model_auto_compact_token_limit = 500000
```

该阈值在可用上下文长度和 TPM 限制引发的 429 风险之间取平衡，并参考历史成功请求 P50 下调。

Provider 元数据使用：

```json
{
  "retry429": {
    "maxRetries": 2,
    "baseDelayMs": 2000,
    "maxDelayMs": 30000,
    "honorRetryAfter": true
  }
}
```

`maxRetries = 2` 仅改变普通主请求的同 Provider 恢复次数。标题、描述、活动摘要、Skill 选择等明确 metadata/helper 请求继续跳过 429 重试。

## 安装流程与用户文案

R14 保持现有八步流程。系统 managed config 在完成用户目录 Golden 配置写入的同一事务阶段安装；最终步骤继续启动 CC Switch，并执行已有健康状态、Golden Provider、takeover 数据库状态和凭据同步检查，不新增真实模型请求。

成功文案说明桌面与移动端新会话已强制经过本地代理，并提醒 CC Switch 不可用时两类会话都会失败。旧的 openai 线程可重新请求，但发布验收重点是移动端新建全新会话。

## 测试与验收

### Managed config 单元与事务测试

- 从不存在、空文件、只有注释和已有复杂 TOML 创建或合并两个根键。
- 保留无关根键、表、注释和表内同名键。
- 拒绝非法 TOML、错误目标值、重复受管根键和 built-in openai Provider table。
- 验证管理员进程只读取 `/private/var/tmp` staging，不读取 Downloads 源路径。
- 验证最终文件为 `root:wheel 0644` 且通过同目录 rename 原子替换。
- 原文件存在时，安装失败及显式回滚恢复原内容和权限。
- 原文件不存在时，回滚删除文件；仅在安装器创建且为空时删除 `/etc/codex`。
- 重复安装幂等，不产生重复键或残留临时文件。

### 参数与发布测试

- Golden 配置、模板、打包资产和文档均为自动压缩阈值 `500000`。
- Provider 模板、Golden DB、打包归一化和安装后数据库均为 429 `maxRetries = 2`。
- Release tag 为 `modelhub-installer-20260817-r14`，App 版本及资产名继续为 `3.19.2`。
- Release 恰好包含 App ZIP、`install.sh`、资源压缩包和 checksum 四项资产。
- `pnpm test:installer`、前端检查和 Rust 检查全部通过；Release install/reinstall/rollback smoke 通过。

### 人工发布验收

- 桌面普通新会话正常经过 ModelHub。
- 移动端新建全新会话虽报告 Provider `openai`，实际请求经过 CC Switch / ModelHub 并成功返回。
- CC Switch 停止时两类会话均失败，重新启动后恢复，这是强制路由的预期边界。

