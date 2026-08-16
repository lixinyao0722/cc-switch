# ModelHub Auxiliary Resilience R12 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate activity-summary Skill helper Luna failures, preserve plaintext reasoning during encrypted-content recovery, and prevent ModelHub 429 retry storms before publishing installer R12.

**Architecture:** Extend the existing pure ModelHub classifier with one narrowly scoped helper kind and route every explicit metadata/helper kind without 429 retries. Replace whole-item encrypted reasoning deletion with one shared sanitizer. Add a proxy-lifetime Provider 429 gate that coordinates cooldown and one recovery probe across concurrent main requests, then update UI and installer defaults without adding Provider schema fields.

**Tech Stack:** Rust/Tokio/Axum, React/TypeScript/Vitest, Bash installer tests, SQLite Golden DB, Tauri macOS release packaging.

## Global Constraints

- Keep App version `3.19.2`.
- Publish tag `modelhub-installer-20260816-r12`.
- Keep all behavior gated to ModelHub Codex Responses routes and the existing session adapter.
- Do not map ordinary user Luna or generic structured Luna requests.
- All explicit metadata/helper requests bypass CC Switch 429 retry.
- Main requests default to one same-Provider 429 retry with 2000ms base delay, 30000ms cap, and `Retry-After` priority.
- Codex config uses `request_max_retries = 2` and `stream_max_retries = 3`; remove unsupported `retry_429`.
- Do not persist cooldown state or log prompt text, session/thread IDs, credentials, or encrypted content.
- Execute inline in this session; system policy forbids subagent dispatch.

---

### Task 1: Activity-summary Skill helper classification and routing

**Files:**
- Modify: `src-tauri/src/proxy/modelhub_compat.rs`
- Modify: `src-tauri/src/proxy/forwarder.rs`

**Interfaces:**
- Produces: `CodexMetadataRequestKind::ActivitySummarySkillSelection`.
- Produces: `codex_metadata_request_kind(body) -> Option<CodexMetadataRequestKind>` that recognizes the helper only when the fixed activity-summary prompt is embedded in the observed structured three-item request.
- Consumes: existing `modelhub_codex_metadata_model` and `should_apply_modelhub_header_adapter` routing gates.

- [ ] **Step 1: Add failing classifier tests.** Add literal bodies proving: a three-item structured Luna request whose sole user text begins with a selector wrapper and contains the full activity-summary prompt is `ActivitySummarySkillSelection`; direct activity summary remains `ActivitySummary`; ordinary structured Luna, similar text, Sol, and user-authored prompt quotations remain unclassified.
- [ ] **Step 2: Run the classifier tests and verify RED.** Run the exact `modelhub_compat` classifier tests with the R11 test binary or Cargo. Expected failure: the new enum variant/classification does not exist.
- [ ] **Step 3: Implement the minimal classifier.** Add the enum variant and a private predicate requiring model Luna, output schema, exactly three input items, exactly one user message, the complete fixed activity-summary prompt present after a non-empty prefix, and no existing metadata classification.
- [ ] **Step 4: Run classifier tests and verify GREEN.** Confirm the new tests and existing metadata/privacy tests pass.
- [ ] **Step 5: Add failing forwarder tests.** Use a mock upstream to prove the helper maps to `gpt-5.6-sol` once, does not retry a 429, and does not emit an unclassified observation; also prove ThreadTitle/ThreadDescription/ThreadTitleReconsideration now bypass 429 retry.
- [ ] **Step 6: Run forwarder tests and verify RED.** Expected failure: helper remains Luna and non-activity metadata still performs configured 429 retries.
- [ ] **Step 7: Implement routing.** For every explicit metadata/helper kind, set `skip_modelhub_429_retry = true`; map the helper and existing non-activity metadata to `codexMetadataModel`; preserve activity-summary block/map/passthrough behavior.
- [ ] **Step 8: Run focused classifier/forwarder tests and verify GREEN.** Include unclassified logging tests and `cargo fmt --check`.
- [ ] **Step 9: Commit.** Commit `feat(proxy): 映射活动摘要 Skill 辅助请求`.

### Task 2: Plaintext-preserving encrypted reasoning sanitizer

**Files:**
- Modify: `src-tauri/src/proxy/modelhub_compat.rs`
- Modify: `src-tauri/src/proxy/forwarder.rs`

**Interfaces:**
- Produces: `ReasoningSanitization { removed_encrypted_fields: usize, removed_empty_items: usize }`.
- Produces: `sanitize_encrypted_reasoning(body: &mut Value) -> ReasoningSanitization`.
- Replaces: `remove_encrypted_reasoning_items` in fallback and learned-session pre-clean paths.

- [ ] **Step 1: Add failing sanitizer tests.** Use literal items proving: non-empty `summary` survives with `id` and metadata; non-empty `content` survives; empty/whitespace-only summary/content removes the item; unencrypted reasoning and non-reasoning items are byte-for-byte unchanged; returned counts are exact.
- [ ] **Step 2: Run sanitizer tests and verify RED.** Expected failure: R11 removes the summary-bearing item and has no structured result counts.
- [ ] **Step 3: Implement the minimal sanitizer.** Remove `encrypted_content`; detect usable text recursively only inside `summary` and `content`; retain useful reasoning items; drop encrypted-only empty items; return both counts.
- [ ] **Step 4: Run sanitizer tests and verify GREEN.** Confirm no plaintext appears in logs or debug output.
- [ ] **Step 5: Update the integration test first.** Change the invalid-encrypted mock test to expect the retry and learned pre-clean bodies to retain `rs_parent_1` plus `parent reasoning`, remove `rs_parent_2`, and preserve assistant/tool/user items.
- [ ] **Step 6: Run the integration test and verify RED.** Expected failure: current retry body contains no reasoning items.
- [ ] **Step 7: Wire the sanitizer into both paths.** Retry only when either count is non-zero; log counts only; use identical code for first fallback and learned pre-clean.
- [ ] **Step 8: Run focused integration tests and verify GREEN.** Include scoped/configurable learning tests and error-shape detection.
- [ ] **Step 9: Commit.** Commit `fix(proxy): 保留可用 reasoning 明文上下文`.

### Task 3: Provider-wide 429 cooldown and safer defaults

**Files:**
- Modify: `src-tauri/src/proxy/retry_429.rs`
- Modify: `src-tauri/src/proxy/server.rs`
- Modify: `src-tauri/src/proxy/handler_context.rs`
- Modify: `src-tauri/src/proxy/forwarder.rs`
- Modify: `src-tauri/src/proxy/response_processor.rs`
- Modify: `src/components/providers/forms/LocalProxyRequestOverridesField.tsx`
- Modify: `tests/components/LocalProxyRequestOverridesField.test.tsx`
- Modify: `tests/lib/requestOverrides.test.ts`

**Interfaces:**
- Produces: `Provider429Cooldown`, shared by all `RequestForwarder` instances in one proxy process.
- Produces: `Provider429Scope { cooldown: Arc<Provider429Cooldown>, key: String }` passed only for main ModelHub requests with active retry config.
- Changes: `send_with_retry_429(config, scope, send)` coordinates shared waiting and one recovery probe.
- Changes UI default: `{ maxRetries: 1, baseDelayMs: 2000, maxDelayMs: 30000, honorRetryAfter: true }`.

- [ ] **Step 1: Add failing retry tests.** Add tests proving default configured main requests perform two total attempts; `Retry-After` remains capped at 30s; multiple waiters behind one recorded cooldown yield exactly one probe; a repeated probe 429 extends cooldown while other waiters make zero upstream calls; probe success releases waiters.
- [ ] **Step 2: Run retry tests and verify RED.** Expected failure: no shared gate types exist and concurrent calls each own a retry chain.
- [ ] **Step 3: Implement `Provider429Cooldown`.** Store bounded Provider states with deadline, probe flag, and `Notify`; wait without holding locks; remove expired unused entries; provide methods to acquire normal/probe permission, record 429, and finish a probe with non-429/error.
- [ ] **Step 4: Extend `send_with_retry_429`.** Record cooldown on every governed 429, use the shared gate instead of per-request sleep, preserve the no-scope behavior for existing generic tests, drain intermediate responses, and release probe state on all exits.
- [ ] **Step 5: Run retry tests and verify GREEN.** Confirm concurrency tests are deterministic and complete under bounded timeouts.
- [ ] **Step 6: Add failing forwarder plumbing tests.** Prove only main ModelHub Codex Responses requests receive a scope; metadata/helper, other routes/providers and Copilot do not.
- [ ] **Step 7: Wire one shared gate through proxy state.** Initialize in `ProxyState`, clone through `RequestContext`, `RequestForwarder`, and test constructors; key by app type plus Provider ID.
- [ ] **Step 8: Run focused Rust tests and verify GREEN.** Include all existing `retry_429`, forwarder scope, activity summary and helper tests.
- [ ] **Step 9: Add failing UI tests.** Toggle ModelHub retry on and assert defaults 1/2000/30000/true; update builder fixtures to the new recommended policy without weakening max-value validation.
- [ ] **Step 10: Run UI tests and verify RED.** Expected failure: UI still creates 10/1000 defaults.
- [ ] **Step 11: Update UI defaults and verify GREEN.** Run component tests, request override tests, typecheck and format check.
- [ ] **Step 12: Commit.** Commit `feat(proxy): 增加 ModelHub 429 共享冷却`.

### Task 4: R12 installer, documentation, and release contract

**Files:**
- Modify: `scripts/modelhub-installer/install.sh`
- Modify: `scripts/modelhub-installer/package-release.sh`
- Modify: `scripts/modelhub-installer/templates/modelhub-provider-meta.json`
- Modify: `scripts/modelhub-installer/templates/modelhub-provider.toml`
- Modify: `scripts/modelhub-installer/golden/codex-config.toml`
- Modify: `tests/scripts/modelhub-installer.test.sh`
- Modify: `docs/guides/modelhub-codex-proxy-compat-zh.md`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Produces: release tag `modelhub-installer-20260816-r12`.
- Produces: Golden Provider retry policy `1 / 2000 / 30000 / honor=true`.
- Produces: Codex config `request_max_retries = 2`, `stream_max_retries = 3`, with no `retry_429` key.

- [ ] **Step 1: Update installer tests first.** Expect R12 tag/text, new Provider retry defaults, Codex request/stream values, absence of `retry_429`, and unchanged activity-summary/encrypted-reasoning defaults.
- [ ] **Step 2: Run installer tests and verify RED.** Expected failures must point to R11 tag, 10/10 Codex retries, unsupported `retry_429`, or old Provider retry values.
- [ ] **Step 3: Update installer/templates/package checks.** Change tag and progress text; normalize packaged DB to the R12 retry policy; update template and Golden Codex config; make preflight reject unsupported `retry_429` and wrong request/stream values.
- [ ] **Step 4: Update guide and changelog.** Document retry ownership, shared cooldown, helper mapping and plaintext reasoning retention; retain rollback instructions.
- [ ] **Step 5: Run installer tests and verify GREEN.** Run all installer cases, not only focused filters.
- [ ] **Step 6: Commit.** Commit `build(installer): 升级 ModelHub R12 发布契约`.

### Task 5: Full verification, review, MR, and release

**Files:**
- Review all R12 diffs.
- Create ignored release directory: `release/modelhub-r12-20260816/`.

**Interfaces:**
- Produces: clean R12 branch and Ready MR against `main`.
- Produces: public Latest R12 release with exactly four assets.

- [ ] **Step 1: Run frontend gates.** Run `pnpm typecheck`, `pnpm format:check`, and `pnpm test:unit`.
- [ ] **Step 2: Run Rust gates.** Run `cargo fmt --check`, `cargo clippy --all-targets --all-features -- -D warnings`, and full `cargo test` using the repository's arm64 xz environment.
- [ ] **Step 3: Run installer gates.** Run `pnpm test:installer` and release smoke against packaged assets.
- [ ] **Step 4: Review the complete diff.** Check classification scope, gate races/deadlocks, secrets, retry ownership, cache bounds, installer source preservation and unrelated changes; fix Important findings and rerun affected tests.
- [ ] **Step 5: Commit review fixes if needed.** Use a factual scoped commit; keep the worktree clean.
- [ ] **Step 6: Push and create a Draft MR.** Target `main`; include behavior, evidence, rollback, OpenAI Docs config boundary and verification results. Do not merge automatically.
- [ ] **Step 7: Wait for CI and mark Ready when green.** Keep release target equal to the reviewed MR HEAD.
- [ ] **Step 8: Build and sign a fresh arm64 App.** Verify version `3.19.2`, Bundle ID, strict signature, architecture, dependencies and a binary SHA different from R11.
- [ ] **Step 9: Package exactly four R12 assets.** Verify `SHA256SUMS`, Golden DB retry policy, Codex config values, no unsupported `retry_429`, and sensitive-data allowlist.
- [ ] **Step 10: Test local assets.** Perform install, repeated install and rollback using the release smoke harness.
- [ ] **Step 11: Create a Draft Release and upload assets.** Tag the MR HEAD as `modelhub-installer-20260816-r12`.
- [ ] **Step 12: Download remote assets and re-verify.** Compare bytes, validate checksums/App/Golden config, then repeat install/reinstall/rollback.
- [ ] **Step 13: Publish R12 as Latest.** Verify the public installer resolves to R12 and comment the release evidence on the MR.
