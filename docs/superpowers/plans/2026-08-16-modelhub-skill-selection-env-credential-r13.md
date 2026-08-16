# ModelHub Skill Selection and Environment Credential R13 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Map every protocol-valid Codex dynamic Skill-selection helper to the configured metadata model, let users confirm reuse or replacement of an inherited `MODELHUB_AK`, and publish installer R13.

**Architecture:** Generalize the existing pure Luna metadata classifier from an activity-summary-specific predicate to one `CodexSkillSelection` protocol predicate that verifies the exact roles, structured schema name, and ordered Skill instruction markers. Keep credential selection inside the installer as a pre-write decision that yields one validated `MODELHUB_EXPECTED_AK`, then reuse the existing transactional Keychain, Provider, launchd, health, and rollback pipeline. Update only the release contract and user documentation needed for R13; preserve the R12 reasoning and 429 behavior.

**Tech Stack:** Rust/Serde JSON/Tokio/Axum, Bash 3.2-compatible installer, SQLite, Tauri macOS arm64 packaging, pnpm/Vitest, GitHub Releases.

## Global Constraints

- Keep App version `3.19.2` and asset name `CC-Switch-ModelHub-3.19.2-arm64.app.zip`.
- Publish tag `modelhub-installer-20260816-r13` with exactly four assets.
- Do not map ordinary user Luna or generic structured Luna requests.
- `CodexSkillSelection` requires Luna, exactly three developer/assistant/user message items, schema name `skill_selection`, and the three ordered stable Skill markers.
- Every explicit metadata/helper request bypasses CC Switch 429 retry; retain R12 main-request cooldown and retry defaults unchanged.
- Read only the installer's inherited `MODELHUB_AK`; do not search shell files, history, or unrelated processes.
- When inherited `MODELHUB_AK` is non-empty, ask whether to reuse it; default yes, `n` permits a new hidden value, and invalid choices re-prompt.
- Never emit credentials in logs, progress text, command arguments shown to the user, tests, or release assets.
- The final selected credential must be identical in Keychain, Provider `auth.OPENAI_API_KEY`, and launchd or the transaction fails and rolls back.
- Execute inline in this existing `feat/r13` worktree; no subagent dispatch.

---

### Task 1: General Codex Skill-selection classification and routing

**Files:**
- Modify: `src-tauri/src/proxy/modelhub_compat.rs`
- Modify: `src-tauri/src/proxy/forwarder.rs`

**Interfaces:**
- Produces: `CodexMetadataRequestKind::CodexSkillSelection`.
- Produces: private `is_codex_skill_selection(body: &Value, input: &[Value]) -> bool`.
- Consumes: `modelhub_codex_metadata_model`, `should_apply_modelhub_header_adapter`, and existing metadata zero-429 routing.

- [ ] **Step 1: Add failing classifier tests.** Replace the activity-summary-only positive fixture with three literal `skill_selection` bodies representing main-task, title-helper, and activity-summary user text. Assert all three return `Some(CodexSkillSelection)`. Add negative literals for role reorder, non-message input item, schema name `result`, absent schema, missing each marker, reversed markers, two user messages, Sol, and ordinary Luna.
- [ ] **Step 2: Run the classifier tests and verify RED.** Run `cargo test --manifest-path src-tauri/Cargo.toml proxy::modelhub_compat::tests::codex_skill_selection -- --nocapture`. Expected: compilation or assertion failure because `CodexSkillSelection` and the generalized classifier do not exist.
- [ ] **Step 3: Implement the minimal pure classifier.** Rename the enum variant and predicate; add helpers that require input roles `developer`, `assistant`, `user`, message types, exact schema name from `/text/format/name` or `/response_format/json_schema/name`, one user message, and ordered stable markers. Remove the activity-summary prompt requirement.
- [ ] **Step 4: Run classifier tests and verify GREEN.** Run the same focused test command plus `cargo test --manifest-path src-tauri/Cargo.toml proxy::modelhub_compat::tests -- --nocapture`; confirm known metadata and privacy-safe observation tests remain green.
- [ ] **Step 5: Add failing forwarder behavior tests.** Convert the existing helper test to use a generic main-task body and assert the mock upstream receives `gpt-5.6-sol` exactly once on 429. Add table-driven title/activity/main fixtures that all map once, and a negative ordinary Luna fixture that remains Luna.
- [ ] **Step 6: Run forwarder tests and verify RED.** Run `cargo test --manifest-path src-tauri/Cargo.toml modelhub_codex_skill_selection -- --nocapture`. Expected: the generic main/title fixtures are still forwarded as Luna.
- [ ] **Step 7: Route the generalized kind.** Preserve existing activity-summary block/map/passthrough handling; route `CodexSkillSelection` through the existing non-activity metadata branch so it maps to `codexMetadataModel` and sets `skip_modelhub_429_retry = true`.
- [ ] **Step 8: Verify routing and formatting.** Run the focused classifier/forwarder tests, `cargo fmt --manifest-path src-tauri/Cargo.toml --check`, and `git diff --check`.
- [ ] **Step 9: Commit Task 1.** Stage only the two Rust files and commit `fix(proxy): 补齐 Codex Skill 选择映射`.

### Task 2: Interactive environment credential selection

**Files:**
- Modify: `scripts/modelhub-installer/install.sh`
- Modify: `tests/scripts/modelhub-installer.test.sh`

**Interfaces:**
- Produces: `read_modelhub_ak() -> stdout credential`, selected from inherited environment or hidden input.
- Uses test controls: `CC_SWITCH_INSTALLER_TEST_INHERITED_MODELHUB_AK`, `CC_SWITCH_INSTALLER_TEST_REUSE_MODELHUB_AK_CHOICE`, and existing `CC_SWITCH_INSTALLER_TEST_MODELHUB_AK` as the replacement/manual value.
- Consumes: existing `validate_modelhub_ak`, `configure_keychain`, `MODELHUB_EXPECTED_AK`, and rollback snapshots.

- [ ] **Step 1: Add failing source-selection tests.** Add installer tests that call the real `read_modelhub_ak`: no inherited value returns the manual test value; inherited value plus empty/`Y`/`y` returns the inherited value; inherited value plus `N`/`n` returns the manual replacement; invalid choice followed by `y` re-prompts and returns the inherited value; invalid inherited value fails before returning a credential.
- [ ] **Step 2: Run focused selection tests and verify RED.** Run `CC_SWITCH_INSTALLER_TEST_FILTER='MODELHUB_AK source' pnpm test:installer`. Expected: inherited/reuse controls have no effect because R12 always returns the manual test value.
- [ ] **Step 3: Implement credential selection without mutation.** Split hidden input into `prompt_modelhub_ak()`. In `read_modelhub_ak`, obtain the inherited value from `CC_SWITCH_INSTALLER_TEST_INHERITED_MODELHUB_AK` in test mode or `${MODELHUB_AK:-}` in production; validate a non-empty inherited value; prompt `检测到当前环境已有 MODELHUB_AK，是否直接复用？[Y/n]` through `/dev/tty`; accept empty/`Y`/`y`, route `N`/`n` to hidden input, and loop on other choices. Test mode consumes the explicit choice without reading `/dev/tty`.
- [ ] **Step 4: Run source-selection tests and verify GREEN.** Re-run the filter and confirm no returned output contains the credential prompt or credential value beyond the test's captured return value.
- [ ] **Step 5: Add failing transaction tests.** Add full installer cases proving: inherited+default reuse synchronizes the environment value into Keychain, Provider, and launchd; inherited+`n` synchronizes the replacement; inherited value differing from an old Keychain overwrites all three on success; a post-write health failure restores the old Keychain and launchd values. Record the security stub input only in the existing protected test state, not stdout.
- [ ] **Step 6: Run transaction tests and verify RED.** Run `CC_SWITCH_INSTALLER_TEST_FILTER='environment MODELHUB_AK' pnpm test:installer`. Expected: R12 uses the manual test value and fails the inherited-value assertions.
- [ ] **Step 7: Integrate with the existing transaction.** Keep `configure_keychain` as the sole writer; ensure `MODELHUB_EXPECTED_AK` is the final user-selected value, existing snapshot/restore flags remain correct, and progress step 7 says `确认或输入 MODELHUB_AK，并同步凭据`.
- [ ] **Step 8: Verify focused and full installer behavior.** Run both focused filters, then `pnpm test:installer`, `bash -n scripts/modelhub-installer/install.sh`, and `git diff --check`.
- [ ] **Step 9: Commit Task 2.** Stage installer and installer tests only; commit `feat(installer): 支持确认复用环境 MODELHUB_AK`.

### Task 3: R13 release contract and documentation

**Files:**
- Modify: `scripts/modelhub-installer/install.sh`
- Modify: `scripts/modelhub-installer/package-release.sh`
- Modify: `tests/scripts/modelhub-installer.test.sh`
- Modify: `docs/guides/modelhub-codex-proxy-compat-zh.md`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Produces: immutable release tag `modelhub-installer-20260816-r13` in packaged `install.sh`.
- Preserves: Golden Provider retry `1/2000/30000`, Codex retries `2/3`, no `retry_429`, activity summary `map`, reasoning learning enabled.

- [ ] **Step 1: Add failing R13 installer contract assertions.** Change release/tag/download tests to expect R13 and the updated step-7 wording. Extend package/release smoke assertions to exercise inherited environment default reuse rather than supplying only a manual credential.
- [ ] **Step 2: Run focused release tests and verify RED.** Run `CC_SWITCH_INSTALLER_TEST_FILTER='R13' pnpm test:installer`; expected failures reference the R12 tag or old wording.
- [ ] **Step 3: Update the release constants and package temporary suffix.** Set `RELEASE_TAG='modelhub-installer-20260816-r13'`, change download progress to R13, and rename the package normalizer temporary suffix from `.r12-retry` to `.r13-retry` without changing normalized values.
- [ ] **Step 4: Update human documentation.** Add a top CHANGELOG R13 bullet. Update the Chinese guide's version paragraphs, credential interaction, generic Skill-selection mapping, zero-Luna-401 expectation, and rollback/retry wording; preserve the stable public install command.
- [ ] **Step 5: Verify the complete release contract.** Run `pnpm test:installer`, `bash -n scripts/modelhub-installer/install.sh`, `bash -n scripts/modelhub-installer/package-release.sh`, `rg -n 'modelhub-installer-20260816-r12|下载并校验 R12|\.r12-retry' scripts/modelhub-installer tests/scripts/modelhub-installer.test.sh docs/guides/modelhub-codex-proxy-compat-zh.md CHANGELOG.md`, and `git diff --check`. Only historical R12 changelog/spec references may remain outside active R13 surfaces.
- [ ] **Step 6: Commit Task 3.** Stage the five release/docs files and commit `build(installer): 升级 ModelHub R13 发布契约`.

### Task 4: Full verification and review

**Files:**
- Review: every commit after `a52273f4`.

**Interfaces:**
- Produces: a clean, verified `feat/r13` branch ready for publication.

- [ ] **Step 1: Run frontend gates.** Run `pnpm typecheck`, `pnpm format:check`, and `pnpm test:unit`; capture exact test counts.
- [ ] **Step 2: Run Rust gates.** Resolve the repository's Rust/xz environment, then run `cargo fmt --manifest-path src-tauri/Cargo.toml --check`, `cargo clippy --manifest-path src-tauri/Cargo.toml --all-targets --all-features -- -D warnings`, and `cargo test --manifest-path src-tauri/Cargo.toml`; capture pass/ignored counts.
- [ ] **Step 3: Run installer gates.** Run `pnpm test:installer` and record the exact case count.
- [ ] **Step 4: Review the branch diff.** Inspect `git diff a52273f4...HEAD`, checking classifier false positives, schema variants, Bash 3.2 syntax, `/dev/tty` failure behavior, secret leakage, existing rollback state, R12 behavior preservation, active release strings, and unrelated files.
- [ ] **Step 5: Fix any Important finding with TDD.** For each real finding, add one failing regression test, run it RED, implement the minimal fix, rerun GREEN and affected suites, then commit a factual scoped fix.
- [ ] **Step 6: Verify branch cleanliness.** Run `git diff --check`, `git status --short --branch`, and `git log --oneline a52273f4..HEAD`.

### Task 5: PR, R13 assets, live installation, and release

**Files:**
- Create ignored artifacts under: `release/modelhub-r13-20260816/`

**Interfaces:**
- Produces: GitHub PR from `feat/r13` to `main`, left unmerged and Ready after CI passes.
- Produces: public Latest Release `modelhub-installer-20260816-r13` with exactly four verified assets.

- [ ] **Step 1: Push and create a Draft PR.** Confirm `gh auth status`, push `feat/r13`, and create a Draft PR targeting `main` with root cause, behavior, security boundaries, tests, rollback, and release plan.
- [ ] **Step 2: Wait for all PR checks.** Use `gh pr checks --watch`; if a check fails, inspect logs, reproduce locally, fix with TDD, push, and wait again. Mark Ready only when every required check is green and merge state is clean.
- [ ] **Step 3: Build a fresh arm64 App from the reviewed HEAD.** Run the repository Tauri release build; verify `CFBundleShortVersionString=3.19.2`, Bundle ID `com.ccswitch.desktop`, `file` reports arm64, `codesign --verify --deep --strict` succeeds, and record the executable SHA-256.
- [ ] **Step 4: Package exactly four local assets.** Run `scripts/modelhub-installer/package-release.sh` into `release/modelhub-r13-20260816/`; verify `SHA256SUMS.txt`, exact asset names, Golden SQLite integrity and Provider values, Codex 2/3/no-`retry_429`, immutable R13 tag, and the sensitive-content allowlist.
- [ ] **Step 5: Run local release smoke.** Set `CC_SWITCH_RELEASE_SMOKE_ASSET_DIR` to the packaged directory and run the release-smoke installer test, covering install, repeated install, and rollback.
- [ ] **Step 6: Create a Draft GitHub Release.** Tag the reviewed PR HEAD as `modelhub-installer-20260816-r13`, upload exactly the four local assets, and keep it draft until remote verification and live install finish.
- [ ] **Step 7: Download and re-verify remote assets.** Download the Draft Release assets into a new temporary directory, compare every SHA byte-for-byte with local assets, rerun checksum/App/Golden config/sensitive scans, and repeat release smoke against the downloaded directory.
- [ ] **Step 8: Perform the real interactive R13 install.** Run the downloaded installer from a terminal that inherits the existing non-empty `MODELHUB_AK`; accept the default reuse choice without supplying the credential again. Verify App SHA/signature, `/health`, Keychain/Provider/launchd equality using only length and SHA-256, and R13 managed config.
- [ ] **Step 9: Trigger and inspect a fresh complete Codex turn.** Record the installed-process start time, run a fresh task that creates main/title/activity helper traffic, then prove logs since that time contain `CodexSkillSelection` mappings and zero `unclassified_codex_luna`, zero ModelHub Luna 401, and zero helper 429 retries.
- [ ] **Step 10: Publish R13 as Latest.** Change the Draft Release to published/non-prerelease/latest, verify the tag targets the PR HEAD, verify exactly four public assets, and fetch `releases/latest/download/install.sh` to confirm its immutable tag is R13.
- [ ] **Step 11: Backfill PR evidence and final state.** Comment the checksums, CI, local/remote smoke, interactive credential reuse, credential equality hashes, and zero-Luna-401 live result on the PR. Confirm PR remains Ready/unmerged, release is Latest, and the local branch/worktree is clean.
