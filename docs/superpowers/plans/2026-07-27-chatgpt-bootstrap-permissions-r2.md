# ChatGPT Bootstrap 与 App 权限修复实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复 root-owned `CC Switch.app` 的权限误判，并在 ChatGPT App 缺失时从 OpenAI 官方 DMG 安装、验签和保留该应用。

**Architecture:** 权限修复扩展现有 `NEEDS_SUDO` 判定，使 CC Switch 的删除、安装、隔离属性清理和回滚恢复共享同一权限包装。ChatGPT bootstrap 位于 CC Switch 事务之前：已有 App 只验证，缺失时下载固定官方 DMG、只读挂载、完整验签并通过 `/Applications` 同卷临时目标原子安装；后续 CC Switch 失败或显式回滚均保留 ChatGPT。

**Tech Stack:** macOS Bash 3.2、`curl`、`hdiutil`、`codesign`、`plutil`、`file`、`ditto`、`sudo`、现有 shell TDD 测试、GitHub CLI、lark-cli。

## Global Constraints

- 目标平台固定为 macOS 12+、Apple Silicon `arm64`。
- 禁止以 root 身份运行整个安装器；用户命令固定为 `curl -fsSL https://github.com/lixinyao0722/cc-switch/releases/latest/download/install.sh | bash -s`，不得添加 `sudo`。
- OpenAI 官方下载页固定为 `https://openai.com/chatgpt/download/`，新版 ChatGPT DMG 固定为 `https://persistent.oaistatic.com/codex-app-prod/ChatGPT.dmg`。
- ChatGPT App 必须满足 Bundle ID `com.openai.codex`、Team ID `2DC432GLL2`、主程序含 `arm64`、严格 codesign 通过，且内置 Codex 存在、可执行并属于同一 Team ID。
- 已有 ChatGPT 校验失败时阻断，不覆盖；缺失时才下载和安装。
- 本次新安装的 ChatGPT 位于 CC Switch 事务之前，不进入失败回滚或 `--rollback latest`。
- ChatGPT DMG 不上传到 GitHub Release；R2 Release 仍只包含现有四项公开资产。
- R2 tag 固定为 `modelhub-installer-20260727-r2`；已有 `modelhub-installer-20260727` 和两个更早 Pre-release 保留不变。
- 不读取或修改 `~/.codex/auth.json`，不持久化或输出 `MODELHUB_AK`、OAuth/bearer token 或用户私有路径。
- 手工文件编辑使用 `apply_patch`，行为修改严格遵循 RED→GREEN。

---

### Task 0: 确认 follow-up 基线

**Files:**
- No repository file changes expected

**Interfaces:**
- Produces: clean worktree and baseline evidence

- [ ] **Step 1: 核对分支和已有 PR/Release**

```bash
git status --short --branch
git rev-parse HEAD
git rev-parse origin/feat/modelhub-one-click-installer
gh pr view 1 --repo lixinyao0722/cc-switch --json url,isDraft,state,headRefOid
gh release list --repo lixinyao0722/cc-switch --limit 5
```

Expected: 当前分支为 `feat/modelhub-one-click-installer`；PR #1 已合并且 `origin/main` 包含旧安装器 head `009a714`；当前分支相对 `origin/main` 只保留 R2 follow-up 提交；当前 Latest 是 `modelhub-installer-20260727`。

- [ ] **Step 2: 运行 focused 基线**

```bash
/bin/bash -n scripts/modelhub-installer/install.sh
pnpm test:installer
```

Expected: Bash 语法通过，现有 installer suite 46/46。

---

### Task 1: 修复 root-owned CC Switch 权限判定

**Files:**
- Modify: `scripts/modelhub-installer/install.sh`
- Modify: `tests/scripts/modelhub-installer.test.sh`

**Interfaces:**
- Produces: `validate_non_root EFFECTIVE_UID`
- Produces: `path_tree_requires_privilege TARGET`
- Extends: `prepare_application_permissions`
- Extends: `run_with_privilege`

- [ ] **Step 1: 写 root 拒绝与 root-owned App 失败测试**

测试必须运行真实权限行为：父 `Applications` 为 `0775` 可写，既有 `CC Switch.app/Contents` 为 `0555` 不可写。通过 sudo stub 只模拟边界授权，断言：

```bash
prepare_application_permissions
assert_equals "$NEEDS_SUDO" '1'
remove_managed_target "$CC_SWITCH_APP_PATH"
assert_contains "$FAKE_SUDO_LOG" '-v'
assert_contains "$FAKE_SUDO_LOG" "/bin/rm -rf -- $CC_SWITCH_APP_PATH"
```

另加：`validate_non_root 0` 失败、`validate_non_root 501` 通过；`perform_install` 在任何下载或写入前拒绝测试 UID 0。

- [ ] **Step 2: 运行测试确认 RED**

```bash
pnpm test:installer -- 'existing nonwritable app'
pnpm test:installer -- 'rejects root execution'
```

Expected: 第一个用例显示 `NEEDS_SUDO` 仍为 0；第二个用例显示尚未阻断 root。

- [ ] **Step 3: 实现最小权限修复**

新增可测试 sudo 命令入口：

```bash
sudo_command() {
  printf '%s' "${CC_SWITCH_SUDO_BIN:-/usr/bin/sudo}"
}

run_with_privilege() {
  local sudo_bin
  if [[ "$NEEDS_SUDO" == "1" ]]; then
    sudo_bin="$(sudo_command)"
    "$sudo_bin" "$@"
  else
    "$@"
  fi
}
```

`path_tree_requires_privilege` 对不存在目标返回 false；目标存在时，只要目标本身或其目录树中的任一目录不可写即返回 true。`prepare_application_permissions` 在以下任一条件为真时设置 `NEEDS_SUDO=1` 并执行可注入的 `sudo -v`：

- `/Applications` 不可写；
- 已有 `CC Switch.app` 目录树不可替换；
- 后续 ChatGPT 缺失安装需要向不可写 `/Applications` 写入。

`validate_non_root` 在 `perform_install` 和 `rollback_latest` 的最前面检查 `${CC_SWITCH_INSTALLER_TEST_EUID:-$EUID}`；0 时给出“不应使用 sudo 运行整条脚本”的明确错误。

- [ ] **Step 4: 验证 GREEN 与回滚权限**

```bash
pnpm test:installer -- 'existing nonwritable app'
pnpm test:installer -- 'rejects root execution'
pnpm test:installer -- transaction
```

Expected: focused 用例通过；所有 transaction 测试保持通过，证明失败回滚同样走权限包装。

- [ ] **Step 5: 提交权限修复**

```bash
git add scripts/modelhub-installer/install.sh tests/scripts/modelhub-installer.test.sh
git commit -m "fix(installer): 处理已有 App 的管理员权限"
```

---

### Task 2: 验证已有 ChatGPT App

**Files:**
- Modify: `scripts/modelhub-installer/install.sh`
- Modify: `tests/scripts/modelhub-installer.test.sh`

**Interfaces:**
- Produces: `validate_chatgpt_app APP_PATH EXPECTED_TEAM_ID EXPECTED_BUNDLE_ID`
- Consumes: existing `validate_chatgpt_codex`

- [ ] **Step 1: 写有效与异常 App 的失败测试**

构造真实目录 fixture 和完整边界 stub，覆盖：

- Bundle ID `com.openai.codex` + Team ID `2DC432GLL2` + arm64 + strict codesign + 内置 Codex：通过；
- Bundle ID 错误、App Team ID 错误、主程序缺少 arm64、strict codesign 失败、内置 Codex 缺失/Team ID 错误：分别失败；
- 已有异常 ChatGPT 时 `ensure_chatgpt_app` 不调用 curl/hdiutil，也不覆盖 App。

测试必须断言最终用户可见错误包含从 OpenAI 官方下载页重新安装的提示。

- [ ] **Step 2: 运行定向测试确认 RED**

```bash
pnpm test:installer -- 'validates existing ChatGPT'
pnpm test:installer -- 'blocks invalid existing ChatGPT'
```

Expected: FAIL，`validate_chatgpt_app` 或 `ensure_chatgpt_app` 尚不存在。

- [ ] **Step 3: 实现完整验证**

新增常量：

```bash
readonly CHATGPT_BUNDLE_ID='com.openai.codex'
readonly CHATGPT_DOWNLOAD_PAGE='https://openai.com/chatgpt/download/'
readonly CHATGPT_DMG_URL='https://persistent.oaistatic.com/codex-app-prod/ChatGPT.dmg'
```

`validate_chatgpt_app` 使用可注入的 `plutil` 读取 `CFBundleIdentifier` 和 `CFBundleExecutable`；使用可注入的 `codesign` 检查 App Team ID 与 strict verification；使用可注入的 `file` 检查 `${APP}/Contents/MacOS/${CFBundleExecutable}` 含 `arm64`；最后调用 `validate_chatgpt_codex`。

任何异常都返回非零且不修改 App。

- [ ] **Step 4: 运行测试确认 GREEN**

```bash
pnpm test:installer -- 'ChatGPT'
/bin/bash -n scripts/modelhub-installer/install.sh
```

Expected: 已有 App 正负向用例全部通过。

- [ ] **Step 5: 提交验证器**

```bash
git add scripts/modelhub-installer/install.sh tests/scripts/modelhub-installer.test.sh
git commit -m "feat(installer): 校验官方 ChatGPT 应用"
```

---

### Task 3: 从 OpenAI 官方 DMG bootstrap ChatGPT

**Files:**
- Modify: `scripts/modelhub-installer/install.sh`
- Modify: `tests/scripts/modelhub-installer.test.sh`

**Interfaces:**
- Produces: `download_chatgpt_dmg OUTPUT_PATH`
- Produces: `attach_chatgpt_dmg DMG_PATH MOUNT_DIR`
- Produces: `detach_chatgpt_dmg MOUNT_DIR`
- Produces: `install_verified_chatgpt_app SOURCE_APP TARGET_APP`
- Produces: `ensure_chatgpt_app STAGE_DIR`
- Produces: `cleanup_chatgpt_bootstrap`

- [ ] **Step 1: 写缺失 App bootstrap RED 测试**

测试用可注入 curl/hdiutil/codesign/plutil/file/ditto/sudo 桩模拟完整 DMG 边界，真实创建目标目录，覆盖：

- ChatGPT 缺失：只请求精确 `CHATGPT_DMG_URL`，参数包含 `--fail --location --retry 3 --retry-all-errors`；
- 使用 `hdiutil attach -nobrowse -readonly -mountpoint "$mount_dir"`，其中 `mount_dir` 来自私有 `mktemp -d`；成功/失败都调用 `detach`；
- 挂载 App 验证后，通过 `run_with_privilege mktemp -d '/Applications/.chatgpt-modelhub.XXXXXX'` 创建同卷 `temp_dir`，复制到 `$temp_dir/ChatGPT.app`，再次验证，再原子 `mv` 到目标；
- 下载失败、attach 失败、DMG 内 App 缺失或验签失败：目标不存在、mount/temp 均清理；
- 已有有效 App：不调用 curl/hdiutil；
- 后续 `run_install_transaction` 失败：新安装的 ChatGPT 仍存在，`rollback_latest` 也不删除。

- [ ] **Step 2: 运行 focused 测试确认 RED**

```bash
pnpm test:installer -- 'bootstraps missing ChatGPT'
pnpm test:installer -- 'keeps bootstrapped ChatGPT after failure'
```

Expected: FAIL，缺少 bootstrap 函数。

- [ ] **Step 3: 实现官方 DMG 下载和生命周期**

`download_chatgpt_dmg` 复用可注入 `CC_SWITCH_CURL_BIN`，但 URL 固定且不接受调用者输入。`attach_chatgpt_dmg` 使用可注入 `CC_SWITCH_HDIUTIL_BIN`。全局记录当前 mount/temp 路径，`cleanup_chatgpt_bootstrap` 可重复执行，并由 `EXIT/INT/TERM` 事务 guard 调用。

`install_verified_chatgpt_app`：

1. 通过 `run_with_privilege mktemp -d "$INSTALL_APPLICATIONS_DIR/.chatgpt-modelhub.XXXXXX"` 创建同卷临时目录；
2. `run_with_privilege ditto SOURCE "$temp_dir/ChatGPT.app"`；
3. 验证临时 App；
4. 目标仍不存在才执行 `run_with_privilege mv "$temp_dir/ChatGPT.app" "$CHATGPT_APP_PATH"`；若并发出现目标则失败并清理，不覆盖；
5. 验证最终目标并清理临时目录。

`ensure_chatgpt_app` 已存在时只验证；缺失时下载、挂载、安装、卸载并验证，设置 `CHATGPT_INSTALLED_BY_RUN=1` 仅用于报告，不加入 `managed_targets`。

- [ ] **Step 4: 接入 perform_install**

`configure_install_paths` 新增：

```bash
CHATGPT_APP_PATH="$INSTALL_APPLICATIONS_DIR/ChatGPT.app"
CHATGPT_CODEX_PATH="$CHATGPT_APP_PATH/Contents/Resources/codex"
```

`perform_install` 顺序调整为：root/platform 检查 → stage → `prepare_application_permissions` → `ensure_chatgpt_app "$stage_dir"` → `validate_chatgpt_codex` → Release 资产下载/校验 → 原有 CC Switch 事务。

ChatGPT 成功安装后，无论后续结果如何都不删除。

- [ ] **Step 5: 验证 GREEN**

```bash
pnpm test:installer -- 'ChatGPT'
pnpm test:installer -- transaction
pnpm test:installer -- release-smoke
```

Expected: ChatGPT bootstrap 全分支、事务和组合冒烟全部通过。

- [ ] **Step 6: 提交 bootstrap**

```bash
git add scripts/modelhub-installer/install.sh tests/scripts/modelhub-installer.test.sh
git commit -m "feat(installer): 自动安装官方 ChatGPT 应用"
```

---

### Task 4: 完整验证、follow-up PR 与 R2 Release

**Files:**
- Modify: `docs/guides/modelhub-codex-proxy-compat-zh.md`
- Generated ignored assets: `release/modelhub-installer-r2/`

**Interfaces:**
- Produces: updated remote branch and a new follow-up Draft PR targeting `main`
- Produces: normal Latest Release `modelhub-installer-20260727-r2`

- [ ] **Step 1: 更新仓库技术说明**

补充：ChatGPT 缺失时从 OpenAI 官方 DMG 自动安装；已有异常 App 会阻断；ChatGPT 不参与回滚；用户命令不得加 sudo；安装器会按需提示管理员密码。

- [ ] **Step 2: 运行当前树完整验证**

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
PATH=/Users/shopee/.rustup/toolchains/1.95-aarch64-apple-darwin/bin:$PATH LZMA_API_STATIC=1 cargo fmt --check
PATH=/Users/shopee/.rustup/toolchains/1.95-aarch64-apple-darwin/bin:$PATH LZMA_API_STATIC=1 cargo clippy --all-targets -- -D warnings
PATH=/Users/shopee/.rustup/toolchains/1.95-aarch64-apple-darwin/bin:$PATH LZMA_API_STATIC=1 cargo test
```

Expected: 所有命令退出码 0；installer 新总数、前端 529/529、Rust 全量无失败。

- [ ] **Step 3: 安全复核和提交文档**

扫描仓库 diff 和打包资源，确认不包含 DMG、AK、OAuth、`auth.json`、数据库、日志或用户路径；提交技术说明后请求一次 whole-branch/scoped review，修复所有 Critical/Important finding。

- [ ] **Step 4: 推送并创建 follow-up Draft PR**

```bash
git push origin feat/modelhub-one-click-installer
pr_notes_dir="$(mktemp -d /tmp/cc-switch-pr-r2.XXXXXX)"
# 用 apply_patch 创建 "$pr_notes_dir/body.md" 后：
gh pr create \
  --repo lixinyao0722/cc-switch \
  --base main \
  --head feat/modelhub-one-click-installer \
  --title 'fix(installer): 支持新机权限与 ChatGPT bootstrap' \
  --body-file "$pr_notes_dir/body.md" \
  --draft
```

原 PR #1 已合并并保持历史不变。新 follow-up PR 只包含 `origin/main` 之后的 R2 提交，正文记录新机诊断根因、权限修复、ChatGPT 官方来源与保留边界、R2 验证结果。

- [ ] **Step 5: 构建并发布 R2**

用已验证 App ZIP 重新运行 `package-release.sh`，生成四资产；创建 Draft Release `modelhub-installer-20260727-r2`，target 为当前 feature commit。核对 GitHub digest 后发布为正常 Latest，旧 Releases 不删除、不改资产。

- [ ] **Step 6: 回下载真实发布资产**

回下载到固定的 ignored 目录 `release/modelhub-installer-r2/downloaded`，重新执行：三项 `SHA256SUMS.txt` 校验、四资产 SHA、资源 allowlist、敏感扫描、App arm64/codesign/Bundle/version，以及：

```bash
CC_SWITCH_RELEASE_SMOKE_ASSET_DIR="$PWD/release/modelhub-installer-r2/downloaded" \
  pnpm test:installer -- release-smoke
```

确认 `/releases/latest/download/install.sh` 跳转到 R2。

---

### Task 5: 更新飞书安装指南

**Files:**
- External document: `https://bytedance.sg.larkoffice.com/docx/LPm1dcaQuogMRFx5UPMlf5KPg6P`

**Interfaces:**
- Consumes: verified R2 Latest Release
- Produces: updated four-section guide

- [ ] **Step 1: 获取最新 revision 和目标章节**

```bash
LARKSUITE_CLI_NO_UPDATE_NOTIFIER=1 LARKSUITE_CLI_NO_SKILLS_NOTIFIER=1 \
lark-cli docs +fetch \
  --doc 'https://bytedance.sg.larkoffice.com/docx/LPm1dcaQuogMRFx5UPMlf5KPg6P' \
  --detail full --as user
```

- [ ] **Step 2: 精确修改前置与安装说明**

使用 `block_replace`/`block_insert_after`，不全文覆盖：

- 前置条件改为 Apple Silicon Mac + 管理员提供的 `MODELHUB_AK`，ChatGPT 缺失时自动从 OpenAI 官方来源安装；
- 安装节明确原命令保持不变，禁止 `sudo curl ... | bash` 和 `curl ... | sudo bash`；
- 说明安装器可能提示管理员密码，ChatGPT 安装后需用户自行登录；
- 回滚节说明新安装的 ChatGPT 会保留。

- [ ] **Step 3: 回读验证**

确认仍只有四个 h1；安装/回滚命令正确；出现 `persistent.oaistatic.com`、禁止 sudo 和 ChatGPT 保留说明；不存在旧附件、私有配置包或手工安装命令。

---

## 执行方式

用户已明确要求执行。当前会话采用 `superpowers:executing-plans` 串行实现；权限和 ChatGPT bootstrap 共享同一安装脚本与测试夹具，不并行修改。
