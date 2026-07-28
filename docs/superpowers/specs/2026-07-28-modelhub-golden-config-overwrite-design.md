# ModelHub 黄金配置整体覆盖设计

> R4 补充：`modelhub-installer-20260729-r4` 使用清洗后的本机完整配置快照，保留 Provider、MCP、Prompt、模型价格、技能仓库和 UI 偏好；继续排除凭据、日志、请求/会话/用量记录与备份。所有本机用户路径转换为 `__USER_HOME__`，安装时渲染。安装过程增加 8 个中文进度步骤，自定义中文 AK 输入提示，并把 AK 同时写入 Keychain 和 ModelHub Provider API Key。

## 目标

把一键安装器从“读取新电脑现有 Codex/CC Switch 配置并增量合并”调整为“备份后整体覆盖一份经过清洗、可公开审计的黄金配置”，消除接管态 `base_url = "http://127.0.0.1:15721/v1"` 被反向固化进 Provider 配置而形成代理自环的风险。

## 已确认决策

- 新 Release tag 固定为 `modelhub-installer-20260728-r3`，发布为正常 Latest；R1、R2 和旧 Pre-release 全部保留。
- 用户命令保持不变：

  ```bash
  curl -fsSL https://github.com/lixinyao0722/cc-switch/releases/latest/download/install.sh | bash -s
  ```

- 整体覆盖仅包含：
  - `~/.codex/config.toml`
  - `~/.cc-switch/cc-switch.db`
  - `~/.cc-switch/settings.json`
- 覆盖前使用现有事务 manifest 完整备份这三个文件；安装失败、信号中断或 `--rollback latest` 恢复原文件。
- `~/.codex/auth.json`、ChatGPT 登录态、`~/.cc-switch/codex_oauth_auth.json`、`MODELHUB_AK`、OAuth/bearer token、日志、请求历史、用量聚合、会话同步状态、备份目录和项目路径不打包、不读取、不覆盖。
- `MODELHUB_AK` 仍在安装末尾通过 macOS Keychain 交互输入；公开配置仅保留 `env_key = "MODELHUB_AK"`。

## 方案比较

### 方案 A：清洗后的黄金快照整体覆盖（采用）

仓库保存可审计的 portable Codex 配置模板、最小 CC Switch 设置模板和固定 SQLite schema/seed。打包器每次从这些文本源构建全新的 `cc-switch.db`，而不是复制开发机数据库。安装器验证黄金快照后原子替换目标三文件。

优点是行为确定、无新电脑残留状态、可做完整敏感扫描和重复构建校验；代价是会替换新电脑已有的 CC Switch Provider/偏好，因此必须先备份并明确记录回滚方式。

### 方案 B：直接复制开发机配置（拒绝）

开发机 `config.toml` 含真实用户路径、项目信任、Hooks、MCP、插件状态；`cc-switch.db` 含多个 Provider、OAuth 状态、31,000 余条请求记录和个人设置。即使删除明显记录，SQLite 空闲页仍可能残留数据，不能公开发布。

### 方案 C：继续运行时增量合并（拒绝）

该方案会读取安装时的 live `config.toml`。当文件已处于接管态时，顶层或活动 Provider 的本地地址可能被合并进数据库 Provider 快照，导致 CC Switch 将 `/responses` 再发回自身。R3 不再以目标机器现有配置作为生成新配置的输入。

## 黄金 Codex 配置

新增 `scripts/modelhub-installer/golden/codex-config.toml`。内容从已实机验证配置提炼，但只保留 portable、与 ModelHub 使用直接相关的字段：

- `model`、`review_model`：`gpt-5.6-sol`
- `model_max_output_tokens`：`128_000`
- `model_provider`：`modelhub`
- reasoning、context、compact 和 model catalog 参数
- `approval_policy = "never"`、`sandbox_mode = "danger-full-access"`
- `[model_providers.modelhub]` 使用真实上游 `https://aidp.bytedance.net/api/modelhub/online`
- `wire_api = "responses"`、`requires_openai_auth = true`、`env_key = "MODELHUB_AK"`
- ModelHub 超时、重试和 429 配置

模板中的用户目录只允许出现 `__USER_HOME__`。不包含 live 接管地址、`experimental_bearer_token`、项目、Hooks、MCP、插件本地路径、marketplace 缓存路径或开发机偏好。CC Switch 启动后按正常接管流程把 live 文件改写为本地地址；数据库 Provider 始终保留真实 ModelHub 上游。

## 黄金 CC Switch 数据库

新增：

- `scripts/modelhub-installer/golden/cc-switch-schema.sql`
- `scripts/modelhub-installer/build-golden-db.sh`

schema 固定为 CC Switch `3.18.0` 当前 `PRAGMA user_version = 16` 的公开表结构。构建脚本在私有临时目录创建全新 SQLite 文件，只写入：

- 一条稳定 ID 为 `bytedance-modelhub-official-cli` 的 Codex Provider；`settings_config.auth` 必须为空，`settings_config.config` 必须引用真实 ModelHub 上游且不得包含任何 loopback 地址。
- `proxy_config` 的四个应用默认行；仅 Codex 行设置 `proxy_enabled=1`、`enabled=1`、`auto_failover_enabled=0`、`127.0.0.1:15721` 和日志开关。
- `settings` 中仅写入公开的一次性初始化标记，禁止公共配置片段、代理 URL、token 或个人偏好。

以下表必须为空：`provider_health`、`provider_endpoints`、`proxy_live_backup`、`proxy_request_logs`、`usage_daily_rollups`、`session_log_sync`、`stream_check_logs`、`profiles`、`prompts`、`mcp_servers`、`skills`、`skill_repos`。构建后执行 `PRAGMA integrity_check`、`VACUUM` 和内容扫描，并验证文件中不存在 `/Users/`、AK、OAuth、token、loopback Provider 上游或非 allowlist Provider。

## 黄金 CC Switch 设置

新增 `scripts/modelhub-installer/golden/settings.json`，仅包含安装运行所需的公开字段：

- `currentProviderCodex = "bytedance-modelhub-official-cli"`
- `enableLocalProxy = true`
- `preserveCodexOfficialAuthOnSwitch = true`
- 已确认代理提示和首次运行提示

不复制开发机的可见应用、终端、启动项、插件、技能、目录或 UI 偏好。

## 打包与公开资产

仍只发布四项顶层资产：App ZIP、`install.sh`、`modelhub-installer-resources.tar.gz`、`SHA256SUMS.txt`。资源包新增：

- `modelhub-installer/golden/codex-config.toml`
- `modelhub-installer/golden/settings.json`
- `modelhub-installer/golden/cc-switch.db`

`build-golden-db.sh` 只在打包时执行，不进入运行期资源包。打包器必须验证资源包精确 allowlist、黄金 DB 查询结果和所有文件敏感扫描；两次构建的三个非 App 资产必须逐字节一致。

## 安装事务

安装顺序调整为：

1. 验证平台、权限、ChatGPT 和 Release 四资产。
2. 验证黄金 Codex TOML、settings JSON 和 SQLite 快照。
3. 退出 ChatGPT/CC Switch并创建备份 manifest。
4. 安装 CC Switch App、model catalog、环境 helper 和 LaunchAgent。
5. 将 Codex 模板中的 `__USER_HOME__` 替换为 TOML 转义后的真实主目录，解析验证后原子覆盖 `config.toml`。
6. 通过同目录临时文件原子覆盖 `cc-switch.db` 与 `settings.json`；不得打开或合并目标旧数据库。
7. 录入 Keychain AK、加载 LaunchAgent、启动 CC Switch 并等待健康检查。
8. 启动后验证数据库 Provider 上游仍为 ModelHub，live Codex 地址为本地代理；任何不一致触发事务回滚。

重复安装始终从同一黄金快照重建三文件，因此不会把接管后的 live 配置反写进 Provider。

## 测试与验收

- TDD 先证明当前安装器会保留新电脑的无关 Provider/设置并会从接管态 live 配置继承本地地址，再改为整体覆盖。
- 黄金 DB 构建测试覆盖精确 Provider、空历史表、无敏感数据、`integrity_check=ok` 和双构建一致。
- 安装事务覆盖：旧文件完整备份、三文件整体替换、真实用户路径渲染、失败回滚、重复安装、`auth.json` 保持字节不变。
- Release smoke 使用打包后的真实四资产完成首次安装、重复安装和回滚。
- 完整运行 Installer、TypeScript、Prettier、前端、Rust fmt/Clippy/test、安全扫描和 whole-branch review。
- 发布 R3 Draft，核对 GitHub digest 后发布为 Latest，再回下载四资产重复全部验证。

## GitHub 与文档

- 继续更新 Draft PR #2，不新建重复 PR。
- Release Notes 明确 R3 改为整体覆盖，并提醒安装前已有 Codex/CC Switch 配置会被替换但可回滚。
- 飞书安装指南同步整体覆盖范围、保留项和回滚说明，移除已失效的“增量合并”描述。
