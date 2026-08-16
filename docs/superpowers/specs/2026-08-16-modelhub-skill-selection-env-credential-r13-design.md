# ModelHub Skill 选择与环境凭据复用 R13 设计

## 背景

R12 已将标题、描述、标题重考虑、活动摘要，以及活动摘要 helper thread 内的动态 Skill 选择请求映射到 Provider 配置的 `codexMetadataModel`。实机完整 Codex 回合仍出现两条 Luna 401：主任务和标题 helper 各自在 `build_skills_and_plugins` 阶段产生一条结构化 Skill 选择请求。它们使用与活动摘要 Skill 选择相同的协议结构，但正文不含活动摘要固定提示词，因此未命中 R12 的 `ActivitySummarySkillSelection` 分类。

R12 安装器始终要求用户通过 `/dev/tty` 无回显输入 `MODELHUB_AK`，即使启动安装器的进程环境已经包含非空凭据。当前实机已确认进程环境变量和 macOS Keychain 中的值均存在且精确一致；验证过程只比较长度和 SHA-256，没有输出凭据明文。用户要求 R13 可复用现有环境变量，同时必须保留输入新值的机会。

用户已批准实现并发布 R13。

## 目标

1. 精确识别 Codex 的通用动态 Skill 选择请求，将主任务、标题、活动摘要等 helper 的选择流量统一映射到 `codexMetadataModel`，消除完整回合中的 Luna 401。
2. 当安装器进程包含非空 `MODELHUB_AK` 时，明确询问用户是否复用；默认复用，但允许用户无回显输入新值。
3. 无论凭据来自环境还是交互输入，都继续同步并校验 macOS Keychain、CC Switch Provider 和当前 launchd 会话。
4. 发布安装器 `modelhub-installer-20260816-r13`，App 版本继续为 `3.19.2`。

## 非目标

- 不把所有结构化 Luna 请求统一映射到 Sol。
- 不映射普通用户主动选择的 Luna 主请求。
- 不在本地合成 Skill 选择响应；继续由配置的 metadata 模型执行真实选择。
- 不改变 R12 的 encrypted reasoning 清理、429 共享冷却、活动摘要模式或 Codex 2/3 重试配置。
- 不从 shell 初始化文件、历史文件或其他进程主动搜集凭据。
- 不在日志、命令行参数、进度文案或错误输出中显示凭据明文。

## 通用 Codex Skill 选择分类

### 请求类型

将 `ActivitySummarySkillSelection` 重命名为独立的通用类型 `CodexSkillSelection`。分类继续由纯函数完成，不依赖 session/thread ID、时间或日志指纹。

只有同时满足以下条件才命中：

1. 顶层模型精确为 `gpt-5.6-luna`；
2. `input` 精确为 3 个 item，角色顺序为 developer、assistant、user；
3. developer、assistant 和 user item 均是 message，且全请求只有一个 user message；
4. 请求包含结构化输出，schema 名称精确为 `skill_selection`；
5. user message 按顺序包含 Codex Skill 指令的稳定标记：
   - `A skill is a set of instructions provided through a \`SKILL.md\` source.`
   - `### How to use skills`
   - `- Trigger rules:`

分类不再要求活动摘要固定提示词，因此覆盖主任务、标题、活动摘要和其他使用同一稳定协议的 Codex helper。schema 名称、角色顺序和完整有序标记共同限制作用域，避免仅凭 item 数量或通用文本误映射。

### 路由语义

命中 `CodexSkillSelection` 后：

- 仅在 Codex `/responses`、ModelHub session adapter 已启用且不是 Copilot 时应用；
- 将顶层模型改为 Provider 的 `codexMetadataModel`；
- 设置 `skip_modelhub_429_retry = true`，该 helper 遇到 429 时只访问上游一次；
- 记录 `mapped Codex metadata request kind=CodexSkillSelection to configured model`；
- 不写入 `unclassified_codex_luna` 指纹集合。

普通 Luna、缺少或打乱角色结构、错误 schema 名称、缺少任一稳定标记、标记顺序错误、Sol 请求、其他 Provider 和非 Responses 路由全部保持原样。

## MODELHUB_AK 选择与同步

### 凭据来源与交互

安装器只读取自身进程继承的 `MODELHUB_AK`。选择规则为：

1. 环境变量不存在或为空：沿用现有 `/dev/tty` 无回显输入流程。
2. 环境变量非空且通过现有非空/无换行校验：向 `/dev/tty` 显示：

   ```text
   检测到当前环境已有 MODELHUB_AK，是否直接复用？[Y/n]
   ```

3. 用户回车、输入 `Y` 或 `y`：直接复用环境变量，不再次显示 AK 输入提示。
4. 用户输入 `N` 或 `n`：显示现有无回显 AK 输入提示，允许更新凭据。
5. 其他输入：给出简短提示并重新询问是否复用，不进入安装写入阶段。
6. 无法读取 `/dev/tty`、环境变量非法或新输入非法时，安装失败且不修改受管状态。

测试模式使用独立的显式测试输入控制复用选择和新 AK，不读取开发机真实凭据。

### 同步与事务

用户最终选择的值成为本次安装唯一的 `MODELHUB_EXPECTED_AK`。后续流程保持 R12 的事务边界：

- 在变更前快照已有 Keychain 与 launchd 状态；
- 使用最终值新增或更新 Keychain，并回读验证；
- 将回读值写入 Golden ModelHub Provider 的 `auth.OPENAI_API_KEY`；
- LaunchAgent 从 Keychain 加载同一值到当前登录会话的 `MODELHUB_AK`；
- CC Switch 启动前和黄金路由稳定后各校验一次 Keychain、Provider、launchd 与 `MODELHUB_EXPECTED_AK` 完全一致；
- 任一阶段失败时恢复安装前的 Keychain、launchd 和受管文件状态。

当环境变量与已有 Keychain 不同时：选择复用即以环境变量为本次明确选定值并同步覆盖；选择不复用则以用户新输入值同步覆盖。安装器不静默决定冲突值。

## 安装器与发布

- Release tag 固定为 `modelhub-installer-20260816-r13`。
- App 版本保持 `3.19.2`，资产名保持 `CC-Switch-ModelHub-3.19.2-arm64.app.zip`。
- 安装步骤 7 的文案改为“确认或输入 MODELHUB_AK，并同步凭据”，不承诺一定要求输入。
- 指南明确环境变量复用确认、新值输入、同步目标和冲突语义。
- CHANGELOG 增加 R13 条目。
- Release 仍恰好包含四项资产：App ZIP、`install.sh`、`modelhub-installer-resources.tar.gz`、`SHA256SUMS.txt`。
- 公开 `latest/download/install.sh` 在发布后必须解析到 R13。
- 回滚继续使用已保存安装器的 `--rollback latest`。

## 测试与验收

### Skill 选择分类与路由

- 主任务、标题和活动摘要的真实协议夹具均分类为 `CodexSkillSelection`。
- 三类请求均映射到 Sol，并且 429 时不执行 Provider 重试。
- 完整 Codex 实机回合中 `CodexSkillSelection` 映射命中，`unclassified_codex_luna` 为 0，ModelHub Luna 401 为 0。
- 错误角色顺序、错误 schema 名称、缺失/乱序标记、普通结构化 Luna、主动 Luna、Sol 和其他路由均不命中。

### 凭据交互

- 无环境变量时要求无回显输入，并完成三处同步。
- 有合法环境变量时，回车、`Y`、`y` 都复用且不读取第二次 AK 输入。
- 输入 `N` 或 `n` 时读取新 AK，并以新值完成三处同步。
- 其他选择会重新询问；读取失败或最终值非法时在 mutation 前失败。
- 选择复用且环境值不同于旧 Keychain 时，三处最终统一为环境值；安装失败则恢复旧值。
- 测试输出、安装日志和 Release 资产扫描均不包含真实或测试 AK。

### 全量与发布

- `pnpm typecheck`、`pnpm format:check`、`pnpm test:unit` 通过。
- `cargo fmt --check`、`cargo clippy --all-targets --all-features -- -D warnings`、`cargo test` 通过。
- `pnpm test:installer` 全量通过。
- 新 App 的版本、arm64 架构、签名和 SHA 经本机验证。
- 本地资产和 GitHub 回下载资产逐字节一致，checksum、Golden DB、配置与敏感信息扫描通过。
- install、reinstall、rollback smoke 通过。
- 使用已有进程环境变量执行一次真实安装，确认出现复用询问、选择默认复用后不要求重新输入 AK，安装后健康与凭据同步通过。
- R13 发布为 Latest；PR 保持可审查状态，不自动合并。

