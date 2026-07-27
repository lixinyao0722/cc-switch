# ModelHub 一键安装器实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 构建并发布一个公开、安全、可回滚的 macOS arm64 ModelHub 一键安装器，通过无版本号命令安装 CC Switch、增量合并 Codex/代理配置，并在最后通过 Keychain 录入 `MODELHUB_AK`。

**Architecture:** `install.sh` 同时承担 bootstrap 和本机安装入口；它从自身固定的 GitHub Release tag 下载 App 与白名单资源包，完成预检、备份、增量合并、Keychain/LaunchAgent 配置和健康检查。资源包只从仓库内显式白名单生成，绝不从旧私密数据库或私密配置包做黑名单清洗。

**Tech Stack:** macOS Bash 3.2、系统 `curl`/`shasum`/`tar`/`ditto`/`codesign`/`plutil`/`sqlite3`/`security`/`launchctl`、GitHub CLI、lark-cli、现有 Rust/TypeScript 测试链路。

## Global Constraints

- 目标平台固定为 macOS 12+、Apple Silicon `arm64`。
- ChatGPT Codex 路径固定为 `/Applications/ChatGPT.app/Contents/Resources/codex`，Team ID 必须为 `2DC432GLL2`。
- 用户入口固定为 `curl -fsSL https://github.com/lixinyao0722/cc-switch/releases/latest/download/install.sh | bash -s`。
- 正式 Release tag 固定为 `modelhub-installer-20260727`；旧的两个 Pre-release 不修改。
- `MODELHUB_AK` 只能由 `security ... -U -w </dev/tty` 交互录入并持久化到 Keychain。
- 不提交或发布 `auth.json`、OAuth/bearer token、请求日志、完整用户数据库或 `/Users/shopee` 路径。
- 不修改用户现有 `~/.codex/auth.json`；只增量修改声明的 Codex 字段、ModelHub Provider、Codex 代理行和三个 settings 字段。
- 所有安装前检查先于系统写入；写入后的失败必须触发备份恢复。
- 所有手工文件编辑使用 `apply_patch`；复制已审计的模型目录属于机械资产复制。

---

### Task 0: 准备隔离工作区并确认基线

**Files:**
- No file changes expected

**Interfaces:**
- Produces: clean dependency state and baseline test evidence

- [ ] **Step 1: 确认当前 worktree 与分支状态**

```bash
git rev-parse --git-dir
git rev-parse --git-common-dir
git rev-parse --show-superproject-working-tree
git branch --show-current
git status --short --branch
```

Expected: 当前目录是 linked worktree，分支为 `feat/modelhub-one-click-installer`，除已提交设计/计划外没有未解释改动。

- [ ] **Step 2: 安装锁文件对应依赖**

```bash
pnpm install --frozen-lockfile
```

Expected: 退出码 0，`pnpm-lock.yaml` 不发生变化。

- [ ] **Step 3: 运行前端与 Rust 基线**

```bash
pnpm typecheck
pnpm test:unit
cd src-tauri
LZMA_API_STATIC=1 cargo test
```

Expected: 三条命令退出码均为 0；若出现基线失败，在修改实现前先定位并向用户报告。

---

### Task 1: 建立 Bash 测试基座与 Codex 配置合并器

**Files:**
- Create: `tests/scripts/modelhub-installer.test.sh`
- Create: `scripts/modelhub-installer/install.sh`
- Create: `scripts/modelhub-installer/templates/modelhub-provider.toml`
- Create: `scripts/modelhub-installer/templates/modelhub-provider-meta.json`
- Modify: `package.json`

**Interfaces:**
- Produces: `merge_codex_config SOURCE TEMPLATE OUTPUT USER_HOME`
- Produces: `validate_merged_codex_config FILE USER_HOME`
- Produces: `render_template SOURCE OUTPUT PLACEHOLDER VALUE`
- Produces: `run_test NAME FUNCTION` shell test harness
- Produces: optional first CLI argument as a substring test filter; no argument runs all cases

- [ ] **Step 1: 写配置合并失败测试**

在 `tests/scripts/modelhub-installer.test.sh` 中创建 Bash 3.2 测试基座，source 安装器，并加入以下核心用例：

```bash
test_merge_codex_config_preserves_unmanaged_sections() {
  local case_dir="$TEST_TMP/merge-existing"
  mkdir -p "$case_dir"
  printf '%s\n' \
    'model = "old-model"' \
    'model_provider = "old-provider"' \
    '[plugins."browser@openai-bundled"]' \
    'enabled = true' \
    '[model_providers.modelhub]' \
    'base_url = "https://old.invalid"' \
    >"$case_dir/input.toml"

  merge_codex_config \
    "$case_dir/input.toml" \
    "$REPO_ROOT/scripts/modelhub-installer/templates/modelhub-provider.toml" \
    "$case_dir/output.toml" \
    '/Users/Test User'

  assert_contains "$case_dir/output.toml" 'model = "gpt-5.6-sol"'
  assert_contains "$case_dir/output.toml" 'model_catalog_json = "/Users/Test User/.codex/models-modelhub-1m.json"'
  assert_contains "$case_dir/output.toml" '[plugins."browser@openai-bundled"]'
  assert_contains "$case_dir/output.toml" 'enabled = true'
  assert_occurrences "$case_dir/output.toml" '[model_providers.modelhub]' 1
  assert_not_contains "$case_dir/output.toml" 'https://old.invalid'
}
```

`run_test` 读取 `TEST_FILTER="${1:-}"`，仅当测试名称包含该字符串时运行；空 filter 运行全部用例。同时覆盖空输入、新建配置、`$HOME` 包含空格、旧 ModelHub section 位于文件中部、未受管章节内容保持不变、残留 `__USER_HOME__` 被拒绝。

- [ ] **Step 2: 运行测试确认 RED**

Run:

```bash
/bin/bash tests/scripts/modelhub-installer.test.sh
```

Expected: FAIL，明确显示 `install.sh` 或 `merge_codex_config` 尚不存在，而不是测试脚本语法错误。

- [ ] **Step 3: 添加最小模板和合并实现**

`modelhub-provider.toml` 写入确定的受管值：

```toml
model = "gpt-5.6-sol"
review_model = "gpt-5.6-sol"
model_provider = "modelhub"
model_reasoning_effort = "max"
model_auto_compact_token_limit = 829674
model_context_window = 921860
model_catalog_json = "__USER_HOME__/.codex/models-modelhub-1m.json"

[model_providers.modelhub]
name = "modelhub"
wire_api = "responses"
requires_openai_auth = true
base_url = "https://aidp.bytedance.net/api/modelhub/online"
env_key = "MODELHUB_AK"
stream_idle_timeout_ms = 600000
request_max_retries = 10
stream_max_retries = 10
```

`modelhub-provider-meta.json` 写入：

```json
{
  "apiFormat": "responses",
  "endpointAutoSelect": false,
  "localProxyRequestOverrides": {
    "codexSessionHeaderAdapter": "modelhub",
    "body": { "max_output_tokens": 128000 },
    "retry429": {
      "maxRetries": 10,
      "baseDelayMs": 1000,
      "maxDelayMs": 30000,
      "honorRetryAfter": true
    }
  }
}
```

在 `install.sh` 中加入 source-safe main guard：

```bash
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
```

`merge_codex_config` 使用 `awk` 删除旧受管根字段和完整 `[model_providers.modelhub]` section，把受管根字段放在文件首部、ModelHub section 放在文件末尾；其他行只原样复制。`render_template` 对 TOML 双引号和反斜杠做转义后替换 `__USER_HOME__`。`validate_merged_codex_config` 确认七个受管根字段各出现一次、ModelHub section 只出现一次、目标 home 路径存在，且文件中不再包含 `__USER_HOME__` 或旧 ModelHub URL。

- [ ] **Step 4: 暴露统一测试命令**

在 `package.json` 中增加：

```json
"test:installer": "/bin/bash tests/scripts/modelhub-installer.test.sh"
```

- [ ] **Step 5: 运行测试确认 GREEN**

Run:

```bash
/bin/bash -n scripts/modelhub-installer/install.sh
pnpm test:installer
```

Expected: Bash 语法检查通过，配置合并用例全部通过且无 stderr 噪音。

- [ ] **Step 6: 提交本任务**

```bash
git add package.json scripts/modelhub-installer/install.sh scripts/modelhub-installer/templates/modelhub-provider.toml scripts/modelhub-installer/templates/modelhub-provider-meta.json tests/scripts/modelhub-installer.test.sh
git commit -m "feat(installer): 增加 ModelHub 配置合并器"
```

---

### Task 2: 实现平台预检、固定 Release 下载与资源校验

**Files:**
- Modify: `scripts/modelhub-installer/install.sh`
- Modify: `tests/scripts/modelhub-installer.test.sh`

**Interfaces:**
- Consumes: Task 1 test harness
- Produces: `validate_platform OS ARCH MAJOR_VERSION`
- Produces: `validate_chatgpt_codex CODEX_PATH EXPECTED_TEAM_ID`
- Produces: `download_release_assets DEST_DIR`
- Produces: `verify_release_assets ASSET_DIR`
- Produces: `validate_resource_archive ARCHIVE`

- [ ] **Step 1: 写前置检查和恶意归档失败测试**

新增表驱动测试，至少覆盖：

```bash
assert_command_fails validate_platform Linux arm64 14
assert_command_fails validate_platform Darwin x86_64 14
assert_command_fails validate_platform Darwin arm64 11
validate_platform Darwin arm64 12
```

使用测试命令桩模拟 `codesign`，验证 Team ID 不为 `2DC432GLL2` 时失败。分别构造 SHA 不匹配、绝对路径、`../escape`、symlink 和额外文件归档，断言在 `MUTATION_STARTED=0` 时退出。

- [ ] **Step 2: 运行定向测试确认 RED**

Run:

```bash
pnpm test:installer -- preflight
```

Expected: FAIL，缺少 `validate_platform`、`verify_release_assets` 或 `validate_resource_archive`。

- [ ] **Step 3: 实现最小预检与下载逻辑**

在 `install.sh` 固定以下常量：

```bash
readonly RELEASE_REPOSITORY="lixinyao0722/cc-switch"
readonly RELEASE_TAG="modelhub-installer-20260727"
readonly APP_ASSET="CC-Switch-ModelHub-3.18.0-arm64.app.zip"
readonly RESOURCES_ASSET="modelhub-installer-resources.tar.gz"
readonly CHECKSUM_ASSET="SHA256SUMS.txt"
readonly EXPECTED_CODEX_TEAM_ID="2DC432GLL2"
```

下载 URL 必须使用：

```text
https://github.com/${RELEASE_REPOSITORY}/releases/download/${RELEASE_TAG}/${asset}
```

`download_release_assets` 下载 App ZIP、资源 tarball、checksum，以及一份来自同一精确 tag 的 `install.sh`。`verify_release_assets` 只接受 `install.sh`、App ZIP 和资源 tarball 三条 checksum，并在临时目录中调用 `shasum -a 256 -c`。`validate_resource_archive` 比较精确归档白名单，并拒绝 tar verbose 类型为 symlink/hardlink 的条目。

- [ ] **Step 4: 运行测试确认 GREEN**

Run:

```bash
pnpm test:installer -- preflight
/bin/bash -n scripts/modelhub-installer/install.sh
```

Expected: 全部预检/归档测试通过。

- [ ] **Step 5: 提交本任务**

```bash
git add scripts/modelhub-installer/install.sh tests/scripts/modelhub-installer.test.sh
git commit -m "feat(installer): 校验固定 Release 资源"
```

---

### Task 3: 让 Codex Provider 从显式 env_key 读取密钥

**Files:**
- Modify: `src-tauri/src/proxy/providers/codex.rs`

**Interfaces:**
- Produces: `extract_codex_env_key(config_text: &str) -> Option<String>`
- Extends: `CodexAdapter::extract_key(&self, provider: &Provider) -> Option<String>`

- [ ] **Step 1: 写 env_key 解析失败测试**

在 `codex.rs` 的现有测试模块加入串行测试：

```rust
#[test]
#[serial_test::serial]
fn provider_without_stored_key_reads_active_env_key() {
    const ENV_NAME: &str = "CC_SWITCH_TEST_MODELHUB_AK";
    std::env::set_var(ENV_NAME, "ak-from-environment");

    let provider = create_provider(json!({
        "auth": {},
        "config": format!(
            "model_provider = \"modelhub\"\n\
             [model_providers.modelhub]\n\
             base_url = \"https://aidp.bytedance.net/api/modelhub/online\"\n\
             env_key = \"{ENV_NAME}\"\n"
        )
    }));

    let auth = CodexAdapter::new().extract_auth(&provider);
    std::env::remove_var(ENV_NAME);

    let auth = auth.expect("env_key should supply bearer auth");
    assert_eq!(auth.api_key, "ak-from-environment");
    assert_eq!(auth.strategy, AuthStrategy::Bearer);
}
```

另加两个负向测试：环境变量缺失时返回 `None`；`env_key` 只存在于非活跃 Provider section 时返回 `None`。已有 `auth.OPENAI_API_KEY` 或 `experimental_bearer_token` 仍优先于环境变量。

- [ ] **Step 2: 运行定向 Rust 测试确认 RED**

Run:

```bash
cd src-tauri
LZMA_API_STATIC=1 cargo test provider_without_stored_key_reads_active_env_key --lib
```

Expected: FAIL，`extract_auth` 返回 `None`。

- [ ] **Step 3: 实现最小 env_key 回退**

`extract_codex_env_key` 使用 `toml::Value` 解析 `config`，读取根字段 `model_provider`，再只读取对应 `[model_providers.<id>].env_key`。`extract_key` 保持现有四级持久化来源顺序，在它们全部为空后才执行：

```rust
if let Some(config_str) = provider.settings_config.get("config").and_then(Value::as_str) {
    if let Some(value) = extract_codex_env_key(config_str)
        .and_then(|name| std::env::var(name).ok())
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
    {
        return Some(value);
    }
}
```

不记录环境变量名对应的值，不把值写回 Provider。

- [ ] **Step 4: 运行定向和模块测试确认 GREEN**

Run:

```bash
cd src-tauri
LZMA_API_STATIC=1 cargo test provider_without_stored_key_reads_active_env_key --lib
LZMA_API_STATIC=1 cargo test proxy::providers::codex::tests --lib
```

Expected: 新增正负向用例和原有 Codex adapter 用例全部通过。

- [ ] **Step 5: 提交本任务**

```bash
git add src-tauri/src/proxy/providers/codex.rs
git commit -m "feat(proxy): 支持从 Codex env_key 读取密钥"
```

---

### Task 4: 实现 CC Switch Provider、代理和 settings 增量合并

**Files:**
- Modify: `scripts/modelhub-installer/install.sh`
- Modify: `tests/scripts/modelhub-installer.test.sh`

**Interfaces:**
- Consumes: `merge_codex_config`
- Produces: `ensure_cc_switch_schema DB_PATH APP_PATH`
- Produces: `merge_provider_database DB_PATH CONFIG_PATH META_PATH`
- Produces: `update_settings_json SETTINGS_PATH PROVIDER_ID`

- [ ] **Step 1: 写 SQLite 增量合并失败测试**

测试创建最小 `providers`、`proxy_config` 和无关表，并插入一个非 ModelHub Provider 与哨兵行。调用 `merge_provider_database` 后断言：

```bash
assert_sql "$db" "select count(*) from providers where app_type='codex' and name='Bytedance ModelHub - 官方CLI'" "1"
assert_sql "$db" "select count(*) from providers where id='existing-provider'" "1"
assert_sql "$db" "select count(*) from sentinel where value='keep-me'" "1"
assert_sql "$db" "select enabled from proxy_config where app_type='codex'" "1"
assert_sql "$db" "select auto_failover_enabled from proxy_config where app_type='codex'" "0"
```

再执行第二次并断言 Provider 数量仍为 1。检查 `settings_config` 中 `auth` 是空对象、`config` 含 ModelHub 配置，`meta` 精确包含 `codexSessionHeaderAdapter=modelhub`，且没有 token 字段。

为 `update_settings_json` 准备带无关偏好的 JSON，断言只改变 `currentProviderCodex`、`enableLocalProxy` 和 `preserveCodexOfficialAuthOnSwitch`。

- [ ] **Step 2: 运行定向测试确认 RED**

Run:

```bash
pnpm test:installer -- database
```

Expected: FAIL，缺少数据库或 settings 合并函数。

- [ ] **Step 3: 实现 SQLite 事务**

`ensure_cc_switch_schema` 检查数据库是否存在，以及 `providers.meta`、`providers.is_current`、`proxy_config.enabled`、`proxy_config.auto_failover_enabled` 等必需列是否齐全。缺失时用 `open -gj` 隐藏启动已安装 App，最多等待 30 秒完成迁移，再通过 `osascript` 退出；二次检查仍缺列则失败。

`merge_provider_database` 先确认 SQLite JSON1 可用，再通过 `readfile()` 读取暂存 TOML/meta，使用一个 `BEGIN IMMEDIATE ... COMMIT` 事务：

```sql
UPDATE providers SET is_current = 0 WHERE app_type = 'codex';
INSERT INTO providers (
  id, app_type, name, settings_config, website_url, category,
  notes, icon, meta, is_current, in_failover_queue
) VALUES (
  :provider_id,
  'codex',
  'Bytedance ModelHub - 官方CLI',
  json_object('auth', json('{}'), 'config', CAST(readfile(:config_path) AS TEXT)),
  'https://aidp.bytedance.net',
  'third_party',
  'ModelHub Responses via official ChatGPT Codex CLI',
  'openai',
  CAST(readfile(:meta_path) AS TEXT),
  1,
  0
)
ON CONFLICT(id, app_type) DO UPDATE SET
  name = excluded.name,
  settings_config = excluded.settings_config,
  website_url = excluded.website_url,
  category = excluded.category,
  notes = excluded.notes,
  icon = excluded.icon,
  meta = excluded.meta,
  is_current = 1,
  in_failover_queue = 0;
```

Provider ID 优先复用同名现有记录；只允许 `[A-Za-z0-9._-]+`，否则失败。`proxy_config` 使用 `ON CONFLICT(app_type) DO UPDATE`，只修改 loopback、端口、启用状态、日志和自动故障转移字段。

- [ ] **Step 4: 实现 settings 精确更新**

对每个字段先执行 `plutil -replace`，键不存在时再执行 `plutil -insert`。新文件以 `{}` 初始化；无效 JSON 直接失败，不覆盖原文件。

- [ ] **Step 5: 运行测试确认 GREEN**

Run:

```bash
pnpm test:installer -- database
pnpm test:installer -- settings
```

Expected: 增量合并、重复执行和哨兵保留全部通过。

- [ ] **Step 6: 提交本任务**

```bash
git add scripts/modelhub-installer/install.sh tests/scripts/modelhub-installer.test.sh
git commit -m "feat(installer): 增量配置 ModelHub Provider"
```

---

### Task 5: 实现备份、安装、Keychain、LaunchAgent 和回滚编排

**Files:**
- Create: `scripts/modelhub-installer/templates/com.ccswitch.modelhub-env.plist`
- Create: `scripts/modelhub-installer/templates/load-modelhub-env.sh`
- Modify: `scripts/modelhub-installer/install.sh`
- Modify: `tests/scripts/modelhub-installer.test.sh`

**Interfaces:**
- Produces: `create_backup BACKUP_ROOT`
- Produces: `restore_backup BACKUP_DIR`
- Produces: `install_app APP_ZIP`
- Produces: `install_runtime_files RESOURCES_DIR`
- Produces: `configure_keychain`
- Produces: `install_launch_agent`
- Produces: `wait_for_health URL TIMEOUT_SECONDS`
- Produces: `perform_install`
- Produces: CLI `--help` and `--rollback latest`

- [ ] **Step 1: 写事务与回滚失败测试**

测试设置 `CC_SWITCH_INSTALLER_TEST_MODE=1`、临时用户目录和临时 Applications 根目录，并用 PATH 命令桩替代 `codesign`、`ditto`、`security`、`launchctl`、`osascript`、`open` 和 `curl`。

覆盖以下行为：

```bash
test_keychain_cancel_rolls_back_all_files
test_health_timeout_rolls_back_all_files
test_successful_install_keeps_backup_and_installed_files
test_second_install_updates_without_duplicate_provider
test_rollback_latest_restores_previous_files
test_rollback_latest_removes_files_created_by_installer
```

每个失败测试都比较安装前后 App、Codex config、数据库、settings、LaunchAgent 和 helper 的 SHA-256。

- [ ] **Step 2: 运行事务测试确认 RED**

Run:

```bash
pnpm test:installer -- transaction
```

Expected: FAIL，缺少 `perform_install` 或 `restore_backup`。

- [ ] **Step 3: 实现备份 manifest 与错误 trap**

manifest 使用 tab 分隔的固定格式：

```text
target<TAB>existed<TAB>backup-relative-path
```

`create_backup` 对目录使用 `ditto`、对文件使用 `cp -p`，并把备份根目录设为 `0700`。首次写入前设置 `MUTATION_STARTED=1`；`ERR` trap 在 `INSTALL_COMPLETED=0` 时调用 `restore_backup`。

- [ ] **Step 4: 实现 App 与运行时文件安装**

App 在暂存目录解压并严格验签后替换。模板渲染到：

```text
~/.local/share/cc-switch-modelhub/load-modelhub-env.sh
~/Library/LaunchAgents/com.ccswitch.modelhub-env.plist
```

helper 权限 `0700`，plist `0600`，模型目录 `0600`。如果数据库缺失或缺少要求的列，隐藏启动 CC Switch，最长等待 30 秒完成 schema 初始化，然后退出。

- [ ] **Step 5: 实现 Keychain 与 launchd 流程**

Keychain 写入必须使用：

```bash
/usr/bin/security add-generic-password \
  -a "$USER" \
  -s "com.ccswitch.modelhub.ak" \
  -U -w </dev/tty
```

LaunchAgent 使用 `launchctl bootout` 清理旧 job（不存在时忽略），再执行 `bootstrap gui/$(id -u)`。环境 helper 通过 `security find-generic-password -w` 读取密钥，设置 `MODELHUB_AK` 和固定 `CODEX_CLI_PATH`，不打印或落盘密钥。`launchctl setenv` 要求 value 参数，因此 AK 会短暂存在于 helper 内存和 `launchctl` 瞬时参数中；测试必须确认脚本、plist 和日志均不包含实际 AK。

- [ ] **Step 6: 实现 CLI 编排和健康检查**

`main` 只接受无参数、`--help` 或 `--rollback latest`。正常安装顺序固定为：预检 → 下载 → 校验 → 退出应用 → 备份 → App/配置/DB/settings → 保存本地 installer → Keychain 提示 → LaunchAgent → 启动 CC Switch → 30 秒健康检查 → 标记完成。

- [ ] **Step 7: 运行测试确认 GREEN**

Run:

```bash
/bin/bash -n scripts/modelhub-installer/install.sh
plutil -lint scripts/modelhub-installer/templates/com.ccswitch.modelhub-env.plist
pnpm test:installer
```

Expected: 所有安装、失败恢复、幂等和回滚用例通过。

- [ ] **Step 8: 提交本任务**

```bash
git add scripts/modelhub-installer/install.sh scripts/modelhub-installer/templates/com.ccswitch.modelhub-env.plist scripts/modelhub-installer/templates/load-modelhub-env.sh tests/scripts/modelhub-installer.test.sh
git commit -m "feat(installer): 支持事务安装与回滚"
```

---

### Task 6: 构建安全白名单资源包与发布资产

**Files:**
- Create: `scripts/modelhub-installer/package-release.sh`
- Create: `scripts/modelhub-installer/assets/models-modelhub-1m.json`
- Modify: `tests/scripts/modelhub-installer.test.sh`

**Interfaces:**
- Produces: `package-release.sh --app-zip PATH --output-dir DIR`
- Produces exactly: `install.sh`, App ZIP, `modelhub-installer-resources.tar.gz`, `SHA256SUMS.txt`

- [ ] **Step 1: 写打包与凭据泄露失败测试**

测试复制安全源目录到临时目录，运行 packager 后断言资产名精确匹配四项、tar 清单精确匹配模板和模型目录、checksum 三项均通过。然后分别注入 `/Users/shopee`、`auth.json`、`access_token`、`refresh_token`、`id_token`、`experimental_bearer_token`、`OPENAI_API_KEY` 和 SQLite 文件，断言打包失败且输出目录没有可发布 tarball。

- [ ] **Step 2: 运行打包测试确认 RED**

Run:

```bash
pnpm test:installer -- package
```

Expected: FAIL，`package-release.sh` 尚不存在。

- [ ] **Step 3: 审计并复制公开模型目录**

对本机已下载的候选模型目录执行：

```bash
jq empty /tmp/cc-switch-install-audit.lVMU9f/ModelHub-Codex-Config-20260726/codex/models-modelhub-1m.json
! rg -n '/Users/shopee|access_token|refresh_token|id_token|experimental_bearer_token|OPENAI_API_KEY|MODELHUB_AK[[:space:]]*[:=][[:space:]]*[^"$]' /tmp/cc-switch-install-audit.lVMU9f/ModelHub-Codex-Config-20260726/codex/models-modelhub-1m.json
```

确认通过后，将该单一允许文件机械复制到 `scripts/modelhub-installer/assets/models-modelhub-1m.json`；不复制私密包中的任何其他文件。

- [ ] **Step 4: 实现白名单打包器**

`package-release.sh` 使用干净暂存目录，只复制以下相对路径：

```text
modelhub-installer/assets/models-modelhub-1m.json
modelhub-installer/templates/modelhub-provider.toml
modelhub-installer/templates/modelhub-provider-meta.json
modelhub-installer/templates/com.ccswitch.modelhub-env.plist
modelhub-installer/templates/load-modelhub-env.sh
```

先扫描暂存内容，再使用 `COPYFILE_DISABLE=1 tar -czf`。输出目录固定为已被仓库现有 `release/` 规则忽略的 `release/modelhub-installer/`。`SHA256SUMS.txt` 只包含 `install.sh`、App ZIP 和资源 tarball。

- [ ] **Step 5: 运行打包测试确认 GREEN**

Run:

```bash
pnpm test:installer -- package
jq empty scripts/modelhub-installer/assets/models-modelhub-1m.json
```

Expected: 打包和所有泄露阻断测试通过。

- [ ] **Step 6: 提交本任务**

```bash
git add scripts/modelhub-installer/package-release.sh scripts/modelhub-installer/assets/models-modelhub-1m.json tests/scripts/modelhub-installer.test.sh
git commit -m "build(installer): 生成脱敏 Release 资产"
```

---

### Task 7: 完成下载资产沙箱冒烟与仓库级验证

**Files:**
- Modify: `docs/guides/modelhub-codex-proxy-compat-zh.md`
- Modify: `tests/scripts/modelhub-installer.test.sh`

**Interfaces:**
- Consumes: Tasks 1-6 complete installer and packager
- Produces: repeatable local release directory `release/modelhub-installer/`

- [ ] **Step 1: 写本地 Release 资产端到端失败测试**

测试必须从 packager 输出而非源码目录取 `install.sh` 和资源 tarball，以本地 `file`/curl stub 模拟 Release 下载，完成首次安装、第二次安装和 `--rollback latest`。断言 Provider 不重复、非受管配置保留、回滚恢复原 hash。

- [ ] **Step 2: 运行端到端测试确认 RED**

Run:

```bash
pnpm test:installer -- release-smoke
```

Expected: 在未接入 packager 输出前失败。

- [ ] **Step 3: 接通本地 Release 沙箱并补充用户文档**

在技术说明的安装章节加入稳定入口：

```bash
curl -fsSL https://github.com/lixinyao0722/cc-switch/releases/latest/download/install.sh | bash -s
```

说明 AK 在最后由 Keychain 提示录入，回滚命令为：

```bash
~/.local/share/cc-switch-modelhub/install.sh --rollback latest
```

- [ ] **Step 4: 构建本地发布资产**

从现有已验证 Release 下载 App ZIP，然后运行：

```bash
gh release download modelhub-v3.18.0-20260727-fork-fix \
  --repo lixinyao0722/cc-switch \
  --pattern 'CC-Switch-ModelHub-3.18.0-arm64.app.zip' \
  --dir release/modelhub-installer/source

/bin/bash scripts/modelhub-installer/package-release.sh \
  --app-zip release/modelhub-installer/source/CC-Switch-ModelHub-3.18.0-arm64.app.zip \
  --output-dir release/modelhub-installer/publish
```

- [ ] **Step 5: 运行完整本地验证**

Run:

```bash
/bin/bash -n scripts/modelhub-installer/install.sh
/bin/bash -n scripts/modelhub-installer/package-release.sh
plutil -lint scripts/modelhub-installer/templates/com.ccswitch.modelhub-env.plist
jq empty scripts/modelhub-installer/templates/modelhub-provider-meta.json
jq empty scripts/modelhub-installer/assets/models-modelhub-1m.json
pnpm test:installer
pnpm typecheck
pnpm format:check
pnpm test:unit
cd src-tauri
LZMA_API_STATIC=1 cargo fmt --check
LZMA_API_STATIC=1 cargo clippy --all-targets -- -D warnings
LZMA_API_STATIC=1 cargo test
```

Expected: 所有命令退出码 0；前端、Rust 和安装器测试均无失败。

- [ ] **Step 6: 提交本任务**

```bash
git add docs/guides/modelhub-codex-proxy-compat-zh.md tests/scripts/modelhub-installer.test.sh
git commit -m "docs(installer): 补充一键安装与回滚入口"
```

---

### Task 8: 推送分支、创建 Draft PR 并发布正式 Release

**Files:**
- No repository file changes expected
- Temporary: release notes under a private `mktemp -d` directory

**Interfaces:**
- Produces: remote branch `feat/modelhub-one-click-installer`
- Produces: Draft PR targeting `main`
- Produces: normal Release `modelhub-installer-20260727`

- [ ] **Step 1: 完成发布前范围与状态检查**

Run:

```bash
git status --short --branch
git diff origin/main...HEAD --check
git log --oneline origin/main..HEAD
gh auth status
gh repo view --json nameWithOwner,defaultBranchRef,visibility
```

Expected: 工作区干净、目标仓库为 `lixinyao0722/cc-switch`、默认分支为 `main`、仓库为 public。

- [ ] **Step 2: 推送 feature 分支**

```bash
git push -u origin feat/modelhub-one-click-installer
```

- [ ] **Step 3: 创建 Draft PR**

PR 标题使用：

```text
feat(installer): 新增 ModelHub 一键安装流程
```

PR 正文必须包含背景、安全边界、增量配置行为、Keychain、回滚、Release 资产和完整验证命令。创建后核对 base=`main`、head=`feat/modelhub-one-click-installer`、draft=true。

- [ ] **Step 4: 创建并核对 Draft Release**

创建 tag `modelhub-installer-20260727`，target 使用当前 feature commit，上传：

```text
release/modelhub-installer/publish/install.sh
release/modelhub-installer/publish/CC-Switch-ModelHub-3.18.0-arm64.app.zip
release/modelhub-installer/publish/modelhub-installer-resources.tar.gz
release/modelhub-installer/publish/SHA256SUMS.txt
```

Release title 使用 `CC Switch ModelHub 一键安装器（macOS arm64）`，先保持 draft。通过 `gh release view --json assets` 比对每个资产的 name、size 和 digest。

- [ ] **Step 5: 发布为 Latest 正式 Release**

确认资产摘要一致后执行：

```bash
gh release edit modelhub-installer-20260727 \
  --repo lixinyao0722/cc-switch \
  --draft=false \
  --prerelease=false \
  --latest
```

- [ ] **Step 6: 回下载并验证真实发布字节**

下载到新的 `mktemp -d` 目录，重新执行 checksum、tar allowlist、凭据/路径扫描和 `release-smoke`。最后确认：

```bash
curl -fsSLI https://github.com/lixinyao0722/cc-switch/releases/latest/download/install.sh
```

Expected: 最终跳转到 `modelhub-installer-20260727/download/install.sh`，所有回下载验证通过。

---

### Task 9: 精简飞书安装文档并回读验证

**Files:**
- External document: `https://bytedance.sg.larkoffice.com/docx/LPm1dcaQuogMRFx5UPMlf5KPg6P`

**Interfaces:**
- Consumes: published Latest Release and rollback command
- Produces: four-section installation document with no old attachment blocks

- [ ] **Step 1: 获取最新 revision 和完整 block 结构**

```bash
LARKSUITE_CLI_NO_UPDATE_NOTIFIER=1 \
LARKSUITE_CLI_NO_SKILLS_NOTIFIER=1 \
lark-cli docs +fetch \
  --doc 'https://bytedance.sg.larkoffice.com/docx/LPm1dcaQuogMRFx5UPMlf5KPg6P' \
  --detail full \
  --as user
```

预期当前 `revision_id` 为 24。若已变化，先重新读取最新全文，并基于新内容重新确认四章节改写不会覆盖新的必要信息。

- [ ] **Step 2: 写入已批准的四章节正文**

使用 XML 全文改写，正文固定包含：

```xml
<title>Codex 使用 ModelHub：一键安装指南</title>
<h1>1. 前置条件</h1>
<p>准备 Apple Silicon Mac、已安装并登录的正式 ChatGPT App，以及从管理员处获取的 ModelHub AK。</p>
<h1>2. 一键安装</h1>
<pre lang="bash"><code>curl -fsSL https://github.com/lixinyao0722/cc-switch/releases/latest/download/install.sh | bash -s</code></pre>
<p>安装器完成下载、校验、备份和配置后，会在最后通过 macOS Keychain 提示输入 ModelHub AK。</p>
<h1>3. 验收</h1>
<p>确认 CC Switch 健康检查正常，并依次验证普通 ModelHub 对话、fork/“接续自任务”、Computer Use、Browser 和 Chrome。</p>
<h1>4. 回滚</h1>
<pre lang="bash"><code>~/.local/share/cc-switch-modelhub/install.sh --rollback latest</code></pre>
<p><a href="https://github.com/lixinyao0722/cc-switch/releases/latest">GitHub Release</a> · <cite type="doc" doc-id="Atuod3Mlxonsf1x7r1Ol5UXMgTb"></cite></p>
```

该全篇改写已由用户批准；它移除旧手工命令、旧附件表和四个附件块，但不删除飞书云盘源文件。

实际命令使用 stdin 传入 XML：

```bash
LARKSUITE_CLI_NO_UPDATE_NOTIFIER=1 \
LARKSUITE_CLI_NO_SKILLS_NOTIFIER=1 \
lark-cli docs +update \
  --doc 'https://bytedance.sg.larkoffice.com/docx/LPm1dcaQuogMRFx5UPMlf5KPg6P' \
  --command overwrite \
  --content - \
  --as user <<'EOF'
<title>Codex 使用 ModelHub：一键安装指南</title>
<h1>1. 前置条件</h1>
<p>准备 Apple Silicon Mac、已安装并登录的正式 ChatGPT App，以及从管理员处获取的 ModelHub AK。</p>
<h1>2. 一键安装</h1>
<pre lang="bash"><code>curl -fsSL https://github.com/lixinyao0722/cc-switch/releases/latest/download/install.sh | bash -s</code></pre>
<p>安装器完成下载、校验、备份和配置后，会在最后通过 macOS Keychain 提示输入 ModelHub AK。</p>
<h1>3. 验收</h1>
<p>确认 CC Switch 健康检查正常，并依次验证普通 ModelHub 对话、fork/“接续自任务”、Computer Use、Browser 和 Chrome。</p>
<h1>4. 回滚</h1>
<pre lang="bash"><code>~/.local/share/cc-switch-modelhub/install.sh --rollback latest</code></pre>
<p><a href="https://github.com/lixinyao0722/cc-switch/releases/latest">GitHub Release</a> · <cite type="doc" doc-id="Atuod3Mlxonsf1x7r1Ol5UXMgTb"></cite></p>
EOF
```

- [ ] **Step 3: 回读并验证**

再次 `docs +fetch --detail full`，确认：

- 仅保留四个 `h1` 章节。
- 安装命令和回滚命令完全匹配发布资产。
- 不再出现 `<source>`、`ModelHub-Codex-Config-20260726.tar.gz`、私有 Codex ZIP、旧 SHA 表或手工复制命令。
- GitHub Latest Release 链接和技术手册引用存在。

- [ ] **Step 4: 最终状态核对**

核对远端分支、Draft PR、Latest Release tag、资产 digest 和飞书 revision；整理最终交付链接与验证计数。

---

## 执行方式

用户已明确要求按方案执行。当前会话采用 `superpowers:subagent-driven-development` 串行派发各任务，并在每个任务后执行规格与质量复核；实现任务不并行修改共享文件。
