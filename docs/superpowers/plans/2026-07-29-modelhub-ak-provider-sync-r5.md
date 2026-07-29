# ModelHub AK Provider 同步 R5 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复安装器只具备 AK 写入动作、却未验证 Keychain、`MODELHUB_AK` 与 CC Switch 当前 ModelHub Provider 最终一致的问题，并发布 R5 安装资产与修复 PR。

**Architecture:** 将用户输入的 AK 作为单次安装事务内的唯一凭据源，写入 Keychain 后立即回读，再用回读值更新 `providers.settings_config.auth.OPENAI_API_KEY`。LaunchAgent 加载环境后、CC Switch 启动并健康后各执行一次不输出密钥的一致性校验，任何不一致均触发既有自动回滚。

**Tech Stack:** macOS Bash 3.2、SQLite 3 JSON1、macOS Keychain、launchctl、现有 shell 测试与 GitHub Release。

## Global Constraints

- Release tag 固定为 `modelhub-installer-20260729-r5`；R1-R4 全部保留。
- 用户仍通过 `/releases/latest/download/install.sh` 安装，且不得对整条管道使用 `sudo`。
- AK 不写入日志、Release、测试夹具的真实数据或命令输出。
- CC Switch 当前 ModelHub Provider 必须保存与 Keychain、`MODELHUB_AK` 完全一致的 `auth.OPENAI_API_KEY`。
- 任一写入或一致性校验失败时沿用现有事务回滚。
- 本机路径零命中门禁覆盖 `install.sh`、资源包与 portable golden 配置；R5 复用字节和签名均未改变的 R4 App ZIP，其 Rust 编译源路径元数据不属于用户配置渲染范围。

---

### Task 1: AK 单源写入与双阶段验真

**Files:**
- Modify: `scripts/modelhub-installer/install.sh`
- Modify: `tests/scripts/modelhub-installer.test.sh`

**Interfaces:**
- Consumes: `perform_install`、测试 security/launchctl stubs、Keychain service `com.ccswitch.modelhub.ak`、Provider ID `bytedance-modelhub-official-cli`。
- Produces: `read_modelhub_ak`、`store_modelhub_api_key_in_provider`、`verify_modelhub_credential_sync` 与对应回归用例。

- [ ] **Step 1: 扩展测试凭据桩**

让 fake Keychain 保存并回读 `CC_SWITCH_INSTALLER_TEST_MODELHUB_AK`，让 fake launchctl 保存并支持 `getenv` 返回实际值；测试数据固定为 `test-modelhub-ak-r5`。

- [ ] **Step 2: 写失败用例**

安装完成后分别读取 fake Keychain、Provider 的 `$.auth.OPENAI_API_KEY` 与 fake launchctl 状态，并断言三者均为 `test-modelhub-ak-r5`；再模拟 Provider 被启动过程改写为旧值，要求安装失败并回滚。

- [ ] **Step 3: 验证 RED**

Run:

```bash
pnpm test:installer -- 'transaction synchronizes ModelHub AK'
```

Expected: 当前 R4 测试模式未写 Provider，测试因 Provider AK 为空而失败。

- [ ] **Step 4: 统一生产与测试输入路径**

生产环境继续从 `/dev/tty` 隐藏读取；测试环境只允许从 `CC_SWITCH_INSTALLER_TEST_MODELHUB_AK` 注入。拒绝空值、换行和回车。

- [ ] **Step 5: Keychain 回读后写 Provider**

写入 Keychain 后使用 `security find-generic-password ... -w` 回读；仅使用回读值更新当前 ModelHub Provider 的 `auth.OPENAI_API_KEY`，随后从 SQLite 回读并比较，不输出实际值。

- [ ] **Step 6: 校验 launchd 与启动后 Provider**

LaunchAgent 加载后比较 `launchctl getenv MODELHUB_AK`、Keychain 与 Provider；CC Switch 健康后再次比较，阻止启动同步将 Provider 恢复为旧值。

- [ ] **Step 7: 验证 GREEN**

Run:

```bash
pnpm test:installer -- 'transaction synchronizes ModelHub AK'
pnpm test:installer -- transaction
/bin/bash -n scripts/modelhub-installer/install.sh
```

Expected: 定向用例与全部事务用例通过。

---

### Task 2: R5 固定版本与完整验证

**Files:**
- Modify: `scripts/modelhub-installer/install.sh`
- Modify: `tests/scripts/modelhub-installer.test.sh`
- Modify: `docs/guides/modelhub-codex-proxy-compat-zh.md`

**Interfaces:**
- Produces: 固定下载 tag `modelhub-installer-20260729-r5`。

- [ ] **Step 1: 先更新 tag 断言并验证 RED**

Run:

```bash
pnpm test:installer -- 'preflight downloads from immutable release tag'
```

Expected: R4 常量与 R5 断言不一致。

- [ ] **Step 2: 更新生产 tag 与用户说明**

将 `RELEASE_TAG` 改为 R5，并在技术指南说明安装器会同步并校验 Keychain、Provider API Key 与 launchd 环境。

- [ ] **Step 3: 完整验证**

Run:

```bash
/bin/bash -n scripts/modelhub-installer/install.sh
/bin/bash -n scripts/modelhub-installer/package-release.sh
plutil -lint scripts/modelhub-installer/templates/com.ccswitch.modelhub-env.plist
pnpm test:installer
```

Expected: 所有安装器测试通过且语法/模板校验退出码为 0。

---

### Task 3: 重建资产、提交并发布

**Files:**
- Generated ignored assets: `release/modelhub-installer-r5/`
- Commit: plan、installer、test、guide。

**Interfaces:**
- Produces: fix 分支、Git commit、Draft PR、Latest R5 Release。

- [ ] **Step 1: 生成脱敏完整快照与四资产**

使用本机 `config.toml`、`settings.json` 和 `cc-switch.db` 运行 `build-local-golden-snapshot.sh`；复用 R4 App ZIP，传入 `CC_SWITCH_GOLDEN_SNAPSHOT_DIR` 运行 `package-release.sh`。

- [ ] **Step 2: 校验发布字节**

核对 `SHA256SUMS.txt`、资源 allowlist、SQLite `integrity_check`、日志/会话/用量表为空，确认 `install.sh`、资源包和 portable golden 无 `/Users/shopee` 或真实凭据；同时验证复用 App/helper 的架构与签名，并对产物运行 `release-smoke`。

- [ ] **Step 3: 提交与推送**

仅暂存本计划声明的源码、测试和文档，提交：

```text
fix(installer): 同步并校验 ModelHub AK
```

普通 push `fix/modelhub-ak-provider-sync`，不强推。

- [ ] **Step 4: 创建 PR 与 R5 Release**

创建指向 `main` 的 Draft PR；创建并上传 R5 四资产，核对 GitHub digest 后发布为正常 Latest。最后从 GitHub 回下载重新执行 checksum、敏感扫描和 `release-smoke`。

## Self-Review

- Spec coverage: Provider 写入、Keychain/launchd/Provider 一致性、回滚、R5 打包、PR 与 Release 均有对应任务。
- Placeholder scan: 无 `TBD`、`TODO` 或未定义实现步骤。
- Interface consistency: Provider ID、Keychain service、测试注入变量和 R5 tag 在所有任务中一致。
