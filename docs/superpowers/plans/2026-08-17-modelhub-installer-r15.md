# ModelHub Installer R15 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish ModelHub installer R15 with the approved GPT-5.5 window, clear macOS administrator-password guidance, and enabled Codex desktop and Computer Use settings.

**Architecture:** Extend the existing R14 Golden-file and release-asset pipeline without changing its transaction boundaries. Keep Codex settings portable by enabling the bundled Computer Use plugin instead of writing versioned runtime paths or duplicate MCP definitions, then package and publish the same four-asset release contract under the R15 tag.

**Tech Stack:** Bash 3.2-compatible installer and test harness, JSON/TOML assets, jq, SQLite, pnpm, Cargo, macOS codesign tooling, GitHub CLI and GitHub Releases.

## Global Constraints

- Application version remains `3.19.2` and the app asset remains `CC-Switch-ModelHub-3.19.2-arm64.app.zip`.
- Installer tag is `modelhub-installer-20260817-r15` and release name is `ModelHub Installer R15`.
- GPT-5.5 is `context_window = 1050000`, `max_context_window = 1050000`, and `effective_context_window_percent = 100` in both repository sources.
- `gpt-5.6-sol` remains `1050000 / 1050000 / 100`; `gpt-5.6-terra` and `gpt-5.6-luna` remain `272000 / 272000 / 95`.
- Golden Codex configuration sets `[desktop] show-context-window-usage = true`, `[desktop] preventSleepWhileRunning = true`, and `[plugins."computer-use@openai-bundled"] enabled = true`.
- Do not add `[mcp_servers.computer-use]`, modify `.codex-global-state.json`, or hardcode a ChatGPT build/plugin version.
- The privilege explanation appears only on a path that requires `sudo -v` and says the password is the current Mac login administrator password, not `MODELHUB_AK`, with no terminal echo.
- Preserve all R14 backup, rollback, managed config, credential, routing, allowlist, signature, and four-asset release guarantees.

---

### Task 1: R15 Golden Codex settings and GPT-5.5 catalog

**Files:**
- Modify: `tests/scripts/modelhub-installer.test.sh`
- Modify: `scripts/modelhub-installer/golden/codex-config.toml`
- Modify: `scripts/modelhub-installer/assets/models-modelhub-1m.json`
- Modify: `src-tauri/src/resources/gpt5_5_template.json`
- Modify: `scripts/modelhub-installer/install.sh`

**Interfaces:**
- Consumes: existing `validate_golden_codex_template`, `validate_merged_codex_config`, and Golden overwrite transaction.
- Produces: portable R15 Golden config and matching GPT-5.5 release catalogs.

- [ ] **Step 1: Add failing R15 defaults tests.** Rename the R14 defaults test to `test_r15_defaults_include_codex_settings_and_gpt55_window`; assert the Golden config contains each approved setting exactly once, lacks `[mcp_servers.computer-use]`, and use jq assertions for the four model entries in both catalog sources.
- [ ] **Step 2: Run the focused test and confirm the expected failure.**

Run: `pnpm test:installer -- "R15 defaults"`

Expected: FAIL because the Golden settings and GPT-5.5 values are not present.

- [ ] **Step 3: Implement the minimal Golden and catalog changes.** Add the two `[desktop]` keys and the enabled bundled plugin table, update only GPT-5.5's three numeric fields, and extend Golden validation to require the settings and reject a duplicate Computer Use MCP table.
- [ ] **Step 4: Run focused tests and JSON validation.**

Run: `pnpm test:installer -- "R15 defaults"`

Run: `jq empty scripts/modelhub-installer/assets/models-modelhub-1m.json src-tauri/src/resources/gpt5_5_template.json`

Expected: PASS and valid JSON.

- [ ] **Step 5: Commit the task.**

```bash
git add tests/scripts/modelhub-installer.test.sh scripts/modelhub-installer/golden/codex-config.toml scripts/modelhub-installer/assets/models-modelhub-1m.json src-tauri/src/resources/gpt5_5_template.json scripts/modelhub-installer/install.sh
git commit -m "feat(installer): 固化 R15 Codex 默认配置"
```

### Task 2: Clear macOS administrator-password guidance

**Files:**
- Modify: `tests/scripts/modelhub-installer.test.sh`
- Modify: `scripts/modelhub-installer/install.sh`

**Interfaces:**
- Consumes: `prepare_application_permissions`, `sudo_command`, and test-mode privilege stubs.
- Produces: `explain_administrator_password` output immediately before the first required `sudo -v`.

- [ ] **Step 1: Add failing privilege-message tests.** Add one test that forces `prepare_application_permissions` down the sudo path, captures stderr, and asserts the explanation contains `Mac 登录用户的管理员密码`, `不是 MODELHUB_AK`, `不会显示字符`, `/Applications`, and `/etc/codex`; add a second test proving the writable no-sudo path emits none of those lines.
- [ ] **Step 2: Run the focused test and confirm the expected failure.**

Run: `pnpm test:installer -- "administrator password guidance"`

Expected: FAIL because only the sudo stub's prompt behavior exists.

- [ ] **Step 3: Implement the centralized explanation.** Add `explain_administrator_password` and call it once immediately before `"$sudo_bin" -v` when `NEEDS_SUDO=1`.
- [ ] **Step 4: Run the focused tests.**

Run: `pnpm test:installer -- "administrator password guidance"`

Expected: both sudo and no-sudo cases PASS.

- [ ] **Step 5: Commit the task.**

```bash
git add tests/scripts/modelhub-installer.test.sh scripts/modelhub-installer/install.sh
git commit -m "fix(installer): 说明管理员密码输入要求"
```

### Task 3: R15 release contract and documentation

**Files:**
- Modify: `tests/scripts/modelhub-installer.test.sh`
- Modify: `scripts/modelhub-installer/install.sh`
- Modify: `scripts/modelhub-installer/package-release.sh`
- Modify: `docs/guides/modelhub-codex-proxy-compat-zh.md`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: immutable release URL checks and exact four-asset packaging tests.
- Produces: all installer/download/documentation references for `modelhub-installer-20260817-r15`.

- [ ] **Step 1: Convert release-contract assertions to R15.** Rename R14 release tests and labels, require the R15 tag and step-three text, require an R15 changelog entry and guide wording for the new settings and password explanation, and reject remaining active R14 release URLs.
- [ ] **Step 2: Run the focused release-contract tests and confirm failure.**

Run: `pnpm test:installer -- "R15 release contract"`

Run: `pnpm test:installer -- "R15 preflight downloads"`

Expected: FAIL on existing R14 constants and documentation.

- [ ] **Step 3: Update release metadata and user documentation.** Change the installer tag and progress text, rename the packaging normalization temporary suffix from `.r14-retry` to `.r15-retry`, add the R15 changelog entry, and update the guide's current-release section while retaining relevant historical R14 behavior descriptions.
- [ ] **Step 4: Run release-contract and package tests.**

Run: `pnpm test:installer -- "R15 release contract"`

Run: `pnpm test:installer -- "R15 preflight downloads"`

Run: `pnpm test:installer -- "R15 package builds"`

Expected: PASS.

- [ ] **Step 5: Commit the task.**

```bash
git add tests/scripts/modelhub-installer.test.sh scripts/modelhub-installer/install.sh scripts/modelhub-installer/package-release.sh docs/guides/modelhub-codex-proxy-compat-zh.md CHANGELOG.md
git commit -m "build(installer): 升级 R15 发布契约"
```

### Task 4: Full verification, PR, and formal release

**Files:**
- Modify if verification requires fixes: files already listed in Tasks 1-3.
- Create locally, do not commit: release output directory containing the four assets.

**Interfaces:**
- Consumes: green branch, verified R14 app ZIP, `package-release.sh`, authenticated `gh`.
- Produces: pushed feature branch, ready-for-review PR to `main`, annotated R15 tag, and non-draft non-prerelease GitHub Release with exactly four assets.

- [ ] **Step 1: Run complete repository gates.**

Run: `bash -n scripts/modelhub-installer/install.sh scripts/modelhub-installer/package-release.sh`

Run: `pnpm test:installer`

Run: `pnpm test`

Run: `pnpm lint`

Run: `pnpm build`

Run: `cargo test --manifest-path src-tauri/Cargo.toml`

Run: `cargo fmt --manifest-path src-tauri/Cargo.toml -- --check`

Run: `cargo clippy --manifest-path src-tauri/Cargo.toml --all-targets -- -D warnings`

Expected: all commands exit 0.

- [ ] **Step 2: Request independent code review.** Compare the branch against `origin/main`, fix every Critical or Important finding, and rerun affected focused tests plus the complete installer suite.
- [ ] **Step 3: Commit verification-driven fixes and plan completion.** Mark completed plan checkboxes, run `git diff --check`, and commit only genuine final corrections or documentation state.
- [ ] **Step 4: Push and open the PR.** Push `feat/r15-modelhub-installer`, create a ready-for-review PR against `main`, and include the design, behavior changes, checks, release tag, and rollback notes.
- [ ] **Step 5: Reuse and verify the signed R14 app ZIP.** Download `CC-Switch-ModelHub-3.19.2-arm64.app.zip` from the R14 release into a temporary directory, verify its GitHub digest and embedded app signature/version, then pass it to `package-release.sh`.
- [ ] **Step 6: Build and smoke-test formal assets.** Package into a new empty temporary output directory, verify `SHA256SUMS.txt`, confirm exactly four files, run the packaged release-smoke test, and inspect the resource archive for the R15 catalog and Golden settings.
- [ ] **Step 7: Tag and publish R15.** Create and push annotated tag `modelhub-installer-20260817-r15` at the reviewed branch head, publish `ModelHub Installer R15` as a non-draft non-prerelease release, and upload exactly the four verified files.
- [ ] **Step 8: Verify the public release.** Query GitHub for tag, release state, asset names, sizes, and digests; download the public checksum and verify all three content assets again.
