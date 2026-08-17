# ModelHub Mobile Routing R14 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish installer R14 so desktop default sessions and mobile-created explicit `openai` sessions both route through CC Switch, while preserving rollback safety and the approved ModelHub defaults.

**Architecture:** Extend the Bash installer with a focused managed-config merger and one privileged system-file transaction that stages through `/private/var/tmp`, atomically installs `/etc/codex/managed_config.toml`, and integrates with the existing backup manifest. Keep runtime request behavior unchanged; update only Golden configuration defaults, packaging normalization, installer release metadata, tests, and documentation.

**Tech Stack:** Bash 3.2-compatible installer, macOS `sudo`/`stat`/`mktemp`/`cp`/`mv`/`chmod`/`chown`, Codex TOML parser, SQLite, pnpm installer test harness, GitHub Releases.

## Global Constraints

- App version remains `3.19.2`; installer tag is `modelhub-installer-20260817-r14`.
- `/etc/codex/managed_config.toml` must contain `model_provider = "modelhub"` and `openai_base_url = "http://127.0.0.1:15721/v1"`.
- Never define `[model_providers.openai]` or an equivalent quoted table.
- Preserve unrelated managed-config keys, tables, comments, and ordering.
- Privileged code must not read release assets or candidate config directly from Downloads; stage candidates under `/private/var/tmp`.
- Installed managed config must be `root:wheel 0644` and replaced atomically in `/etc/codex`.
- Rollback restores a pre-existing file with its original owner/mode, or deletes a newly created file and removes only an installer-created empty `/etc/codex` directory.
- Do not add app-server request/log verification, a separate takeover/port precheck, or a workaround for the mobile sidebar cwd display.
- Set `model_auto_compact_token_limit = 500000`.
- Set ModelHub main-request `retry429.maxRetries = 2`; explicit metadata/helper requests continue to bypass 429 retry.
- Golden Codex config contains `[desktop] git-branch-prefix = "feat/"`.

---

### Task 1: Golden Codex and Provider defaults

**Files:**
- Modify: `scripts/modelhub-installer/templates/modelhub-provider.toml`
- Modify: `scripts/modelhub-installer/golden/codex-config.toml`
- Modify: `scripts/modelhub-installer/templates/modelhub-provider-meta.json`
- Modify: `scripts/modelhub-installer/install.sh`
- Modify: `scripts/modelhub-installer/package-release.sh`
- Test: `tests/scripts/modelhub-installer.test.sh`

**Interfaces:**
- Produces Golden `model_auto_compact_token_limit = 500000`.
- Produces Golden `[desktop]` table with `git-branch-prefix = "feat/"`.
- Produces Provider metadata `localProxyRequestOverrides.retry429.maxRetries = 2`.

- [ ] **Step 1: Write failing Golden-default tests.** Update focused template, Golden DB, package normalization, install, and release-smoke assertions to require `500000`, `feat/`, and retry max `2`; include a merge fixture whose existing `[desktop]` table has another key and a stale branch prefix.
- [ ] **Step 2: Verify RED.** Run `CC_SWITCH_INSTALLER_TEST_FILTER='R14 defaults' pnpm test:installer`; expected assertions show `829_674`, missing `feat/`, or retry max `1`.
- [ ] **Step 3: Implement minimal default changes.** Update both Codex TOML sources and Provider metadata; teach the existing config merge to replace only `desktop.git-branch-prefix` while preserving other `[desktop]` keys and preventing duplicate `[desktop]` tables; change package retry temp suffix to `.r14-retry`.
- [ ] **Step 4: Verify GREEN.** Re-run the focused filter, `bash -n` on both scripts, and `git diff --check`.
- [ ] **Step 5: Commit.** Commit as `build(installer): 更新 R14 ModelHub 默认配置`.

### Task 2: Managed-config merge and validation

**Files:**
- Create: `scripts/modelhub-installer/templates/codex-managed-config.toml`
- Modify: `scripts/modelhub-installer/install.sh`
- Modify: `scripts/modelhub-installer/package-release.sh`
- Test: `tests/scripts/modelhub-installer.test.sh`

**Interfaces:**
- Produces `merge_codex_managed_config(source_file, template_file, output_file)`.
- Produces `validate_codex_managed_config(file)`.
- Produces exact root values for `model_provider` and `openai_base_url`.

- [ ] **Step 1: Write failing pure merge tests.** Cover missing/empty/comment-only files, replacement of stale root values, preservation of unrelated root keys/tables/comments, quoted equivalent root keys, duplicate managed keys, malformed TOML, table-local same-name keys, and rejection of any built-in openai Provider table.
- [ ] **Step 2: Verify RED.** Run `CC_SWITCH_INSTALLER_TEST_FILTER='managed config merge' pnpm test:installer`; expected failure because the merger is absent.
- [ ] **Step 3: Implement minimal parser-aware merge.** Add the two-line template; filter only equivalent root keys before the first table; insert rendered managed roots before the first table; count exact root keys; reject `model_providers.openai` and children; validate syntax with the bundled Codex parser using a private parser home and a temporary ModelHub Provider definition when necessary.
- [ ] **Step 4: Update packaging allowlists.** Require, copy, permission, archive, and validate the new template without expanding the release asset count.
- [ ] **Step 5: Verify GREEN.** Re-run focused merge and archive tests plus script syntax checks.
- [ ] **Step 6: Commit.** Commit as `feat(installer): 合并 Codex 系统托管配置`.

### Task 3: Privileged atomic install and rollback

**Files:**
- Modify: `scripts/modelhub-installer/install.sh`
- Test: `tests/scripts/modelhub-installer.test.sh`

**Interfaces:**
- Adds `CODEX_MANAGED_CONFIG_PATH` and `CODEX_MANAGED_CONFIG_DIR`, test-overridable to a case-local `/etc/codex` tree.
- Produces `install_codex_managed_config(template_file)` using `/private/var/tmp` staging.
- Extends backup/restore semantics for one privileged managed target and its parent-directory existence marker.

- [ ] **Step 1: Write failing privilege and install tests.** Require staging under `/private/var/tmp`, reject symlink or wrong-owner staging, prove the privileged copy never references Downloads/resource paths, require root:wheel 0644, verify same-directory atomic rename, repeat idempotence, and ensure no temporary files remain.
- [ ] **Step 2: Verify RED.** Run `CC_SWITCH_INSTALLER_TEST_FILTER='managed config install' pnpm test:installer`; expected failure because the system target is not installed.
- [ ] **Step 3: Implement controlled privileged helpers.** Add only required absolute commands to the allowlist; validate every system target, staging path, parent, owner, mode, and file type before privileged operations; copy candidate to a target-directory temp file, set owner/mode, compare SHA-256, then `/bin/mv -f` atomically.
- [ ] **Step 4: Write failing rollback tests.** Cover pre-existing file content/uid/gid/mode restoration, absent file deletion, installer-created empty directory removal, pre-existing empty directory retention, non-empty directory retention, backup failure fail-closed, post-write failure rollback, explicit `--rollback latest`, and corrupt metadata rejection before writes.
- [ ] **Step 5: Verify RED.** Run `CC_SWITCH_INSTALLER_TEST_FILTER='managed config rollback' pnpm test:installer`; expected failures show missing backup/restore behavior.
- [ ] **Step 6: Integrate system target into the transaction.** Snapshot target and parent existence before mutation; store original uid/gid/mode without secrets; stage privileged backup copies into the user-owned backup safely; restore atomically; remove the parent only when it did not exist before install and is empty.
- [ ] **Step 7: Install at step 6.** Invoke managed-config installation after Golden runtime files and before credential mutation, so any later health or credential failure restores it with the rest of the transaction.
- [ ] **Step 8: Verify GREEN.** Run focused tests, full `pnpm test:installer`, script syntax checks, and `git diff --check`.
- [ ] **Step 9: Commit.** Commit as `feat(installer): 原子安装并回滚 Codex managed config`.

### Task 4: R14 release contract and documentation

**Files:**
- Modify: `scripts/modelhub-installer/install.sh`
- Modify: `tests/scripts/modelhub-installer.test.sh`
- Modify: `docs/guides/modelhub-codex-proxy-compat-zh.md`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Produces immutable release tag `modelhub-installer-20260817-r14`.
- Preserves four release assets and App version `3.19.2`.

- [ ] **Step 1: Write failing R14 contract tests.** Change tag/download/package labels and assert the guide documents managed routing, forced-proxy failure behavior, `500000`, retry max `2`, `feat/`, rollback, and mobile-new-thread acceptance without documenting removed automatic verification or sidebar workarounds.
- [ ] **Step 2: Verify RED.** Run `CC_SWITCH_INSTALLER_TEST_FILTER='R14' pnpm test:installer`; expected failures reference R13 strings.
- [ ] **Step 3: Update installer and docs.** Change release tag/progress/success wording, add the R14 changelog entry, and update the Chinese guide with exact configuration, boundaries, rollback, and manual acceptance.
- [ ] **Step 4: Verify GREEN.** Run focused tests, full installer tests, stale active-string scans, syntax checks, and `git diff --check`.
- [ ] **Step 5: Commit.** Commit as `build(installer): 升级 ModelHub R14 发布契约`.

### Task 5: Full verification, build, publication, and PR

**Files:**
- Review: all R14 commits and release assets.

**Interfaces:**
- Produces tag/release `modelhub-installer-20260817-r14` with exactly four assets.
- Produces pushed branch `codex/r14-mobile-modelhub-routing` and a GitHub pull request to `main`.

- [ ] **Step 1: Run source gates.** Run `pnpm typecheck`, `pnpm format:check`, `pnpm test:unit`, `pnpm test:installer`, `cargo fmt --check`, `cargo clippy --all-targets --all-features -- -D warnings`, and `cargo test`, using `LZMA_API_STATIC=1` where required.
- [ ] **Step 2: Build release assets.** Use the verified `CC-Switch-ModelHub-3.19.2-arm64.app.zip` input and `scripts/modelhub-installer/package-release.sh`; verify the App signature/architecture, exact asset list, SHA256SUMS, resource archive allowlist, Golden DB, managed-config template, no secrets, and install/reinstall/rollback smoke against the built assets.
- [ ] **Step 3: Review requirements and diff.** Confirm every design requirement, Bash 3.2 compatibility, privileged path constraints, TCC-safe staging, rollback metadata, no openai Provider override, no removed auto-verification/precheck/sidebar scope, and no unrelated changes.
- [ ] **Step 4: Push branch and open PR.** Push `codex/r14-mobile-modelhub-routing`, open a draft PR to `main`, and include root cause, behavior, security/rollback design, parameter decisions, tests, and manual mobile acceptance note.
- [ ] **Step 5: Publish R14.** Create annotated tag `modelhub-installer-20260817-r14` at the verified commit, publish a non-draft GitHub Release with exactly the four built assets, mark it latest, then download all assets and byte-compare/checksum them against local outputs.
- [ ] **Step 6: Report.** Provide PR URL, release URL, tag/commit, checks and counts, asset hashes, and the remaining manual mobile-new-thread acceptance item if it cannot be executed locally.
