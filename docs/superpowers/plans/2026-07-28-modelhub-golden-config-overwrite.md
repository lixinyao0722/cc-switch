# ModelHub 黄金配置整体覆盖实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 ModelHub 一键安装器改为备份后整体覆盖清洗的 Codex/CC Switch 黄金配置，彻底避免接管态本地地址污染 Provider 上游。

**Architecture:** 仓库保存 portable TOML/JSON、固定 SQLite schema 和黄金 DB 构建器；打包器在私有临时目录生成全新 SQLite 快照并加入现有资源包。安装器只验证、渲染真实用户路径并原子覆盖三份目标配置，不再读取或合并目标机器的旧配置；现有事务负责失败回滚。

**Tech Stack:** macOS Bash 3.2、SQLite 3 JSON1/readfile、TOML/Codex parser、Tauri/Rust、现有 shell TDD、GitHub CLI、lark-cli。

## Global Constraints

- 目标平台固定为 macOS 12+、Apple Silicon `arm64`。
- Release tag 固定为 `modelhub-installer-20260728-r3`；旧 Releases 全部保留。
- 顶层 Release 仍精确包含 App ZIP、`install.sh`、资源 tar.gz、`SHA256SUMS.txt` 四项。
- 只覆盖 `~/.codex/config.toml`、`~/.cc-switch/cc-switch.db`、`~/.cc-switch/settings.json`，覆盖前必须备份。
- 不读取、打包或覆盖 `auth.json`、`codex_oauth_auth.json`、AK/OAuth/bearer token、日志、请求历史、用量、会话同步、备份或项目路径。
- `MODELHUB_AK` 只通过 Keychain 交互输入。
- 行为修改必须执行 RED→GREEN；手工文本编辑使用 `apply_patch`。

---

### Task 1: 添加 portable 黄金配置源

**Files:**
- Create: `scripts/modelhub-installer/golden/codex-config.toml`
- Create: `scripts/modelhub-installer/golden/settings.json`
- Create: `scripts/modelhub-installer/golden/cc-switch-schema.sql`
- Create: `scripts/modelhub-installer/build-golden-db.sh`
- Modify: `tests/scripts/modelhub-installer.test.sh`

**Interfaces:**
- Produces: `build-golden-db.sh --schema PATH --provider-config PATH --provider-meta PATH --output PATH`
- Produces: SQLite snapshot with stable Provider ID `bytedance-modelhub-official-cli`

- [ ] **Step 1: 写黄金配置构建失败测试**

新增 `test_golden_db_builder_creates_minimal_public_snapshot`，用真实 `sqlite3` 运行构建器并断言：

```bash
assert_sql "$golden_db" "PRAGMA integrity_check" 'ok'
assert_sql "$golden_db" "PRAGMA user_version" '16'
assert_sql "$golden_db" "SELECT count(*) FROM providers" '1'
assert_sql "$golden_db" "SELECT id FROM providers" 'bytedance-modelhub-official-cli'
assert_sql "$golden_db" \
  "SELECT instr(json_extract(settings_config, '$.config'), 'https://aidp.bytedance.net/api/modelhub/online') > 0 FROM providers" \
  '1'
assert_sql "$golden_db" \
  "SELECT instr(json_extract(settings_config, '$.config'), '127.0.0.1:15721') FROM providers" \
  '0'
assert_sql "$golden_db" "SELECT count(*) FROM proxy_request_logs" '0'
assert_sql "$golden_db" "SELECT count(*) FROM proxy_live_backup" '0'
```

同时断言 `codex-config.toml` 只有 `__USER_HOME__` 占位路径、ModelHub 真实上游，不含 `/Users/`、loopback、`experimental_bearer_token` 或凭据。

- [ ] **Step 2: 运行测试确认 RED**

```bash
pnpm test:installer -- 'golden DB builder creates minimal public snapshot'
```

Expected: FAIL，`build-golden-db.sh` 或黄金源文件不存在。

- [ ] **Step 3: 创建黄金 TOML/JSON 和固定 schema**

`codex-config.toml` 写入完整但 portable 的 ModelHub 配置，关键值为：

```toml
model = "gpt-5.6-sol"
review_model = "gpt-5.6-sol"
model_max_output_tokens = 128_000
model_provider = "modelhub"
model_reasoning_effort = "max"
model_auto_compact_token_limit = 829_674
model_context_window = 921_860
model_catalog_json = "__USER_HOME__/.codex/models-modelhub-1m.json"
approval_policy = "never"
sandbox_mode = "danger-full-access"

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

`settings.json` 只写入稳定 Provider ID、代理开关、认证保留和提示确认。schema 从当前 v16 数据库 `.schema` 固化，末尾显式 `PRAGMA user_version = 16;`，不得带任何 INSERT 数据。

- [ ] **Step 4: 实现黄金 DB 构建器**

构建器必须：验证输入为普通文件、输出不位于 source tree、在私有 `mktemp -d` 中创建 DB、执行 schema、插入精确 Provider/四条 proxy_config/三个公开初始化 flag、执行 `VACUUM` 与 `integrity_check`，最后原子复制到输出。Provider config 使用 `readfile(provider-config)`，auth 固定为空对象。

构建结束执行精确查询和 raw string 扫描，拒绝 `/Users/`、`127.0.0.1:15721`（Provider config）、`access_token`、`refresh_token`、`experimental_bearer_token`、`OPENAI_API_KEY` 或非 allowlist Provider。

- [ ] **Step 5: 运行 GREEN 与可复现性测试**

```bash
pnpm test:installer -- 'golden DB builder'
/bin/bash -n scripts/modelhub-installer/build-golden-db.sh
```

测试再构建两次并 `cmp` 两个 DB，必须逐字节一致。

- [ ] **Step 6: 提交黄金配置源**

```bash
git add scripts/modelhub-installer/golden \
  scripts/modelhub-installer/build-golden-db.sh \
  tests/scripts/modelhub-installer.test.sh
git commit -m "feat(installer): 构建可公开黄金配置快照"
```

---

### Task 2: 将黄金快照加入 Release 资源包

**Files:**
- Modify: `scripts/modelhub-installer/package-release.sh`
- Modify: `scripts/modelhub-installer/install.sh`
- Modify: `tests/scripts/modelhub-installer.test.sh`

**Interfaces:**
- Consumes: Task 1 `build-golden-db.sh`
- Produces: `modelhub-installer/golden/{codex-config.toml,settings.json,cc-switch.db}`

- [ ] **Step 1: 写资源 allowlist RED 测试**

扩展 `test_package_builds_exact_allowlisted_release_assets`，解包后断言三份黄金文件存在、DB 查询满足 Task 1 不变量，且 `validate_resource_archive` 接受精确新增清单。新增负向用例：额外 `.db`、被篡改 DB、Provider 自环、非空日志表、未解析 `__USER_HOME__` 以外路径均拒绝。

- [ ] **Step 2: 运行 RED**

```bash
pnpm test:installer -- 'package builds exact allowlisted release assets'
pnpm test:installer -- 'package rejects unsafe golden snapshot'
```

Expected: 资源包缺少 `golden/*` 或校验器拒绝/未检测篡改。

- [ ] **Step 3: 扩展打包器**

`scan_source_tree` 新增并扫描 Task 1 的文本源和构建脚本；`copy_allowlisted_resources` 调用构建器生成 `$package_root/golden/cc-switch.db`，复制 TOML/JSON。输出 tar 前查询 DB 不变量并扫描文本/SQLite strings。

资源 tar 的固定清单新增三项，不把 schema 或构建器放入运行期资源。

- [ ] **Step 4: 扩展安装器资源验证**

`expected_resource_archive_entries` 增加三项；`validate_resource_archive` 解包后调用：

```bash
validate_golden_codex_template FILE
validate_golden_settings FILE
validate_golden_database FILE
```

DB 校验要求 `integrity_check=ok`、精确一个 Provider、空历史/备份/健康表、Codex proxy 行正确、Provider 上游为 ModelHub 且无 loopback。

- [ ] **Step 5: 运行 GREEN 和双打包一致性**

```bash
pnpm test:installer -- package
pnpm test:installer -- 'preflight accepts exact resource archive'
```

两次打包后比较 `install.sh`、资源 tar、checksum；三者必须逐字节一致。

- [ ] **Step 6: 提交资源包支持**

```bash
git add scripts/modelhub-installer/package-release.sh \
  scripts/modelhub-installer/install.sh \
  tests/scripts/modelhub-installer.test.sh
git commit -m "feat(installer): 打包黄金配置资源"
```

---

### Task 3: 安装事务改为整体覆盖

**Files:**
- Modify: `scripts/modelhub-installer/install.sh`
- Modify: `tests/scripts/modelhub-installer.test.sh`

**Interfaces:**
- Produces: `install_golden_codex_config GOLDEN_FILE TARGET_FILE USER_HOME`
- Produces: `install_golden_database GOLDEN_DB TARGET_DB`
- Produces: `install_golden_settings GOLDEN_JSON TARGET_JSON`
- Produces: `verify_golden_routing_state`

- [ ] **Step 1: 写整体覆盖 RED 测试**

构造目标机器旧状态：Codex config 含本地接管字段和用户段、DB 含额外 Provider/请求日志/live backup、settings 含无关偏好、`auth.json` 含 sentinel。执行安装后断言：

```bash
assert_not_contains "$CODEX_CONFIG_PATH" 'old-user-section'
assert_contains "$CODEX_CONFIG_PATH" "model_catalog_json = \"$case_dir/home/.codex/models-modelhub-1m.json\""
assert_sql "$CC_SWITCH_DATABASE_PATH" "SELECT count(*) FROM providers" '1'
assert_sql "$CC_SWITCH_DATABASE_PATH" "SELECT count(*) FROM proxy_request_logs" '0'
assert_equals "$(shasum -a 256 "$case_dir/home/.codex/auth.json")" "$auth_before"
```

另外断言旧 DB/config/settings 均存在于备份 manifest，显式 rollback 完整恢复。

- [ ] **Step 2: 运行 RED**

```bash
pnpm test:installer -- 'transaction overwrites golden configuration'
```

Expected: 当前增量合并保留旧字段/历史，测试失败。

- [ ] **Step 3: 实现三文件原子覆盖**

`install_runtime_files` 不再调用 `merge_codex_config`、`ensure_cc_switch_schema`、`merge_provider_database`、`update_settings_json`。改为：

1. 渲染 `__USER_HOME__` 到同目录私有 TOML 临时文件；验证解析和 ModelHub 字段后 `mv`。
2. 将黄金 DB 复制到 `~/.cc-switch/.golden-db.XXXXXX/cc-switch.db`，执行完整查询校验、权限 `0600` 后 `mv`。
3. 将黄金 settings 复制到同目录临时文件，验证 JSON、稳定 Provider ID、代理开关后 `mv`。

整个流程只读资源包，不读目标旧三文件；旧文件仅由备份事务读取。

- [ ] **Step 4: 添加启动后路由验真**

健康检查后轮询至多 30 秒：

- DB Provider config 仅含 ModelHub upstream、没有 loopback。
- live `config.toml` 已由 CC Switch 接管为 `http://127.0.0.1:15721/v1`。
- 当前 Provider ID 是稳定 ID。

验真失败返回非零，触发既有自动回滚。

- [ ] **Step 5: 验证 GREEN、失败回滚和重复安装**

```bash
pnpm test:installer -- 'transaction overwrites golden configuration'
pnpm test:installer -- transaction
```

故障注入覆盖 TOML 渲染失败、DB 校验失败、settings 校验失败和启动后路由验真失败；每项都恢复旧三文件和 `auth.json` sentinel。

- [ ] **Step 6: 提交整体覆盖**

```bash
git add scripts/modelhub-installer/install.sh tests/scripts/modelhub-installer.test.sh
git commit -m "fix(installer): 整体覆盖黄金配置"
```

---

### Task 4: 完整验证、评审与仓库文档

**Files:**
- Modify: `docs/guides/modelhub-codex-proxy-compat-zh.md`
- Modify: `docs/superpowers/specs/2026-07-27-modelhub-one-click-installer-design.md`
- Modify: `docs/superpowers/plans/2026-07-27-chatgpt-bootstrap-permissions-r2.md`

**Interfaces:**
- Produces: reviewed branch head for R3

- [ ] **Step 1: 更新技术说明**

把“备份后增量合并”统一改为“备份后整体覆盖三份清洗配置”，明确排除 `auth.json`、AK/OAuth、日志和历史，并记录重复安装自环根因。

- [ ] **Step 2: 运行完整验证**

```bash
/bin/bash -n scripts/modelhub-installer/install.sh
/bin/bash -n scripts/modelhub-installer/package-release.sh
/bin/bash -n scripts/modelhub-installer/build-golden-db.sh
plutil -lint scripts/modelhub-installer/templates/com.ccswitch.modelhub-env.plist
jq empty scripts/modelhub-installer/golden/settings.json
pnpm test:installer
pnpm typecheck
pnpm format:check
pnpm test:unit
cd src-tauri
PATH="$HOME/.rustup/toolchains/1.95-aarch64-apple-darwin/bin:$PATH" LZMA_API_STATIC=1 cargo fmt --check
PATH="$HOME/.rustup/toolchains/1.95-aarch64-apple-darwin/bin:$PATH" LZMA_API_STATIC=1 cargo clippy --all-targets -- -D warnings
PATH="$HOME/.rustup/toolchains/1.95-aarch64-apple-darwin/bin:$PATH" LZMA_API_STATIC=1 cargo test
```

- [ ] **Step 3: 安全扫描和 whole-branch review**

扫描 `origin/main...HEAD`、资源 tar 和黄金 DB，确认没有 DMG、AK/OAuth、`auth.json`、用户路径、日志、请求/用量/会话记录。独立 review 必须关闭所有 Critical/Important。

- [ ] **Step 4: 提交文档并推送**

```bash
git add docs/guides/modelhub-codex-proxy-compat-zh.md \
  docs/superpowers/specs/2026-07-27-modelhub-one-click-installer-design.md \
  docs/superpowers/plans/2026-07-27-chatgpt-bootstrap-permissions-r2.md
git commit -m "docs(installer): 记录黄金配置覆盖流程"
git push origin feat/modelhub-one-click-installer
```

更新 Draft PR #2 标题/正文，加入整体覆盖、隐私边界、测试和回滚说明。

---

### Task 5: 发布 R3 并更新飞书指南

**Files:**
- Generated ignored assets: `release/modelhub-installer-r3/`
- External document: `https://bytedance.sg.larkoffice.com/docx/LPm1dcaQuogMRFx5UPMlf5KPg6P`

**Interfaces:**
- Produces: Latest Release `modelhub-installer-20260728-r3`
- Produces: updated four-section installation guide

- [ ] **Step 1: 双构建 R3**

使用已验证 App ZIP两次运行 `package-release.sh`；比较四项资产并执行 checksum、资源 allowlist、黄金 DB 查询、App/helper 验签和敏感扫描。

- [ ] **Step 2: 真实资产 release-smoke**

```bash
CC_SWITCH_RELEASE_SMOKE_ASSET_DIR="$PWD/release/modelhub-installer-r3/build-a" \
  pnpm test:installer -- release-smoke
```

必须覆盖首次整体覆盖、重复安装无自环、显式 rollback。

- [ ] **Step 3: Draft → Latest 发布**

创建 Draft Release，target 为远端 feature head；核对四个 GitHub digest 后发布为正常 Latest。旧 Release 不删除、不改资产。

- [ ] **Step 4: GitHub 回下载验证**

回下载四资产到 `release/modelhub-installer-r3/downloaded`，重新执行 checksum、逐字节比对、黄金 DB/资源/App/helper 和 release-smoke，确认 `/releases/latest/download/install.sh` 跳转到 R3。

- [ ] **Step 5: 精确更新飞书文档**

读取最新 revision 后只修改前置、安装、回滚相关 block：

- 安装会整体覆盖 Codex/CC Switch 三份配置，旧文件已备份。
- `auth.json`、ChatGPT 登录和 AK 不覆盖。
- 若需恢复个人 Provider/设置，运行 `--rollback latest`。

回读验证仍只有四个 h1、命令不变、不再出现“增量合并”。

---

## 执行方式

用户已预授权后续确认并要求直接执行。当前会话使用 `superpowers:executing-plans` 串行完成；所有任务共享同一安装器测试夹具，不并行修改。
