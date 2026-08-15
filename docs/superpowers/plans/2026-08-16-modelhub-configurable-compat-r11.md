# ModelHub Configurable Compatibility R11 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose R10 ModelHub compatibility policies in the CC Switch Provider UI, map activity summaries to Sol by default with duplicate/429 protection, add privacy-safe observation for unclassified Luna requests, and publish installer R11.

**Architecture:** Extend `LocalProxyRequestOverrides` with an enum-backed activity-summary mode while retaining legacy boolean reads. Keep all policy Provider-scoped and gated by the existing ModelHub session-header adapter. Add small proxy-lifetime caches for activity-summary deduplication and unclassified-Luna fingerprint logging, then normalize the R11 Golden DB to the new policy.

**Tech Stack:** Rust, Tokio shared state, serde/serde_json, React, TypeScript, Vitest, Testing Library, Bash, SQLite, Tauri, GitHub Actions/Releases.

## Global Constraints

- Store all new behavior in CC Switch Provider metadata, never Codex `config.toml`.
- Keep App version `3.19.2` and publish tag `modelhub-installer-20260816-r11`.
- R11 installer defaults activity summaries to `map` and target model to `gpt-5.6-sol`.
- Activity-summary mappings never use same-provider 429 retries.
- Preserve ordinary Luna, main-task Sol, other providers, Copilot, and non-Responses routes.
- Never log prompt text, session/thread IDs, credentials, or complete request bodies.
- Do not map unclassified thread-coordination requests in R11; observe them by privacy-safe fingerprint only.

---

### Task 1: Provider policy model and UI controls

**Files:**
- Modify: `src-tauri/src/provider.rs`
- Modify: `src/types.ts`
- Modify: `src/lib/requestOverrides.ts`
- Modify: `src/components/providers/forms/ProviderForm.tsx`
- Modify: `src/components/providers/forms/CodexFormFields.tsx`
- Modify: `src/components/providers/forms/LocalProxyRequestOverridesField.tsx`
- Modify: `src/i18n/locales/zh.json`
- Modify: `src/i18n/locales/en.json`
- Modify: `src/i18n/locales/ja.json`
- Modify: `src/i18n/locales/zh-TW.json`
- Test: `tests/lib/requestOverrides.test.ts`
- Test: `tests/components/LocalProxyRequestOverridesField.test.tsx`

**Interfaces:**
- Produces: Rust enum `CodexActivitySummaryMode::{Passthrough, Block, Map}` serialized as lowercase strings.
- Produces: TypeScript type `CodexActivitySummaryMode = "passthrough" | "block" | "map"`.
- Produces: `LocalProxyRequestOverrides.codexActivitySummaryMode?: CodexActivitySummaryMode`.
- Consumes: legacy `blockCodexActivitySummaries?: boolean` for migration reads only.

- [ ] **Step 1: Write failing serialization and builder tests.** Add Rust tests proving the new enum serializes to `codexActivitySummaryMode: "map"`, and TypeScript tests proving legacy `blockCodexActivitySummaries: true` resolves to UI mode `block`, new mode wins over the legacy field, `map` requires a non-empty metadata model, and disabling the ModelHub adapter removes all ModelHub-only policy fields.
- [ ] **Step 2: Run the red tests.** Run `pnpm vitest run tests/lib/requestOverrides.test.ts` and `LZMA_API_STATIC=1 cargo test --lib provider::tests -- --nocapture`; confirm failures reference the missing enum/mode helpers rather than syntax errors.
- [ ] **Step 3: Implement the minimal shared policy types and migration helper.** Add `resolveCodexActivitySummaryMode(overrides)` in `src/lib/requestOverrides.ts`, add the enum/field in Rust and TypeScript, keep legacy deserialization, and make `buildLocalProxyRequestOverrides` write only the new field for edited providers.
- [ ] **Step 4: Run the builder/serialization tests and confirm green.** Re-run the commands from Step 2.
- [ ] **Step 5: Write failing UI tests.** Assert that ModelHub controls render metadata mapping switch/model input, the three activity-summary choices, and the encrypted-reasoning switch; assert legacy `true` displays `block`; assert disabling the session adapter clears all ModelHub policy callbacks.
- [ ] **Step 6: Run the UI red test.** Run `pnpm vitest run tests/components/LocalProxyRequestOverridesField.test.tsx`; confirm the new controls are absent.
- [ ] **Step 7: Implement the UI controls and translations.** Thread controlled state through `ProviderForm` and `CodexFormFields`; use a radio/select control for the three modes; default a newly enabled metadata mapping model to `gpt-5.6-sol`; keep advanced Header/Body and 429 controls unchanged.
- [ ] **Step 8: Run focused frontend verification.** Run both focused Vitest files, `pnpm typecheck`, and `pnpm format:check`.
- [ ] **Step 9: Commit.** Stage only Task 1 files and commit `feat(ui): 配置 ModelHub Codex 兼容策略`.

### Task 2: Activity-summary map, deduplication, and no-retry behavior

**Files:**
- Modify: `src-tauri/src/proxy/modelhub_compat.rs`
- Modify: `src-tauri/src/proxy/server.rs`
- Modify: `src-tauri/src/proxy/handler_context.rs`
- Modify: `src-tauri/src/proxy/response_processor.rs`
- Modify: `src-tauri/src/proxy/forwarder.rs`

**Interfaces:**
- Produces: `effective_activity_summary_mode(provider) -> CodexActivitySummaryMode` with legacy fallback.
- Produces: `activity_summary_fingerprint(provider_id, thread_header, body) -> Option<String>` using SHA-256 and no raw identity retention.
- Produces: proxy-lifetime `Arc<RwLock<HashMap<String, Instant>>>` dedup cache capped at 2048 entries and a five-second window.
- Consumes: `codex_metadata_request_kind`, `codexMetadataModel`, and existing ModelHub route gate.

- [ ] **Step 1: Add failing route tests for all three modes.** Extend forwarder tests so `block` reaches upstream zero times, `map` reaches upstream once as `gpt-5.6-sol`, `passthrough` reaches upstream once as `gpt-5.6-luna`, and legacy `blockCodexActivitySummaries=true` still blocks.
- [ ] **Step 2: Run the route red tests.** Run `LZMA_API_STATIC=1 cargo test --lib proxy::forwarder::tests::modelhub_activity_summary -- --nocapture`; confirm `map` is still blocked by R10.
- [ ] **Step 3: Implement mode resolution and route behavior.** Replace the boolean-only block gate with mode handling immediately before non-summary metadata mapping. Require a non-empty metadata target for `map`; return a clear local invalid-request error if stored data is inconsistent.
- [ ] **Step 4: Re-run route tests and confirm green.** Verify ordinary Luna, title mapping, other providers, and main-task Sol regressions in the same test module.
- [ ] **Step 5: Add failing duplicate-summary test.** Send two identical summary bodies with the same Provider/thread inside five seconds and assert only one upstream request; send different latest-message content and assert it is not deduplicated.
- [ ] **Step 6: Run the dedup red test.** Confirm both identical requests currently reach upstream.
- [ ] **Step 7: Thread the shared cache and implement privacy-safe deduplication.** Store only a SHA-256 fingerprint composed from Provider ID, thread identity, and the exact classified summary prompt; purge entries older than five seconds on access and clear at 2048 entries.
- [ ] **Step 8: Add and run a failing no-429-retry test.** Configure Provider retry429=3, have mapped summary upstream return 429, and assert one attempt; keep a control main-task request that retries according to policy.
- [ ] **Step 9: Implement retry bypass for classified activity summaries.** Pass a per-request flag into the final send path so only mapped activity summaries receive `None` retry config.
- [ ] **Step 10: Run all activity-summary and retry tests.** Run focused forwarder and `retry_429` tests plus `cargo fmt --check`.
- [ ] **Step 11: Commit.** Commit `feat(proxy): 支持活动摘要映射与削峰`.

### Task 3: Privacy-safe observation for unclassified Luna requests

**Files:**
- Modify: `src-tauri/src/proxy/modelhub_compat.rs`
- Modify: `src-tauri/src/proxy/server.rs`
- Modify: `src-tauri/src/proxy/handler_context.rs`
- Modify: `src-tauri/src/proxy/response_processor.rs`
- Modify: `src-tauri/src/proxy/forwarder.rs`

**Interfaces:**
- Produces: `unclassified_codex_luna_observation(body: &Value) -> Option<UnclassifiedCodexLunaObservation>` containing only truncated SHA-256 fingerprint and structural counts.
- Produces: proxy-lifetime `Arc<RwLock<HashSet<String>>>` seen-fingerprint cache capped at 256.
- Consumes: exact ModelHub route gate and `codex_metadata_request_kind(body).is_none()`.

- [ ] **Step 1: Write failing classifier-observation tests.** Use a synthetic unknown Luna prompt and assert a stable fingerprint, input count, user-message count, and schema-presence flag; assert known metadata, Sol, non-user-only input, and missing text return `None`; assert the fingerprint differs when prompt text changes.
- [ ] **Step 2: Run the red tests.** Run `LZMA_API_STATIC=1 cargo test --lib modelhub_compat::tests::unclassified -- --nocapture` and confirm the observation type/function is absent.
- [ ] **Step 3: Implement the pure observation helper.** Use the existing `sha2 = "0.10"` dependency and `sha2::{Digest, Sha256}`. Hash only normalized user-message text and emit the first 16 lowercase hexadecimal characters; never retain or return the source text.
- [ ] **Step 4: Run helper tests and confirm green.** Re-run Step 2.
- [ ] **Step 5: Write a failing log-dedup integration test.** Exercise the forwarder twice with the same unknown Luna prompt and assert the seen cache has one fingerprint; exercise a second prompt and assert two. Test cache state rather than global logger output.
- [ ] **Step 6: Thread the shared seen cache and log once per fingerprint.** Log `request_kind=unclassified_codex_luna`, fingerprint, counts, and schema boolean before forwarding; never log body or identities.
- [ ] **Step 7: Run focused and privacy regression tests.** Confirm all known metadata classifiers stay silent and ordinary Luna forwarding remains unchanged.
- [ ] **Step 8: Commit.** Commit `chore(proxy): 观测未分类 Codex Luna 请求`.

### Task 4: R11 installer, guide, and release contract

**Files:**
- Modify: `scripts/modelhub-installer/templates/modelhub-provider-meta.json`
- Modify: `scripts/modelhub-installer/package-release.sh`
- Modify: `scripts/modelhub-installer/install.sh`
- Modify: `tests/scripts/modelhub-installer.test.sh`
- Modify: `docs/guides/modelhub-codex-proxy-compat-zh.md`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Produces: Golden DB `codexActivitySummaryMode = "map"` and removes legacy `blockCodexActivitySummaries`.
- Produces: release tag `modelhub-installer-20260816-r11`.
- Preserves: metadata model `gpt-5.6-sol`, encrypted-reasoning learning `true`, retry max `3`.

- [ ] **Step 1: Update installer tests first.** Expect the R11 tag, new mode `map`, absence of the legacy boolean in template/packaged/installed DB, and preservation of user source snapshot bytes.
- [ ] **Step 2: Run the installer red tests.** Run the focused R10/R11 policy cases in `bash tests/scripts/modelhub-installer.test.sh`; confirm failures show R10 tag and legacy block field.
- [ ] **Step 3: Update template and normalization.** Make packaging remove the legacy boolean and set the new mode/model/learning/retry defaults in the copied Golden DB only; update install preflight validation and progress copy.
- [ ] **Step 4: Update guide and changelog.** Document UI ownership, three activity modes, default mapping, duplicate suppression, no summary 429 retries, and unclassified Luna observation.
- [ ] **Step 5: Run complete installer verification.** Run `bash -n` for scripts, `jq empty` for JSON, and all installer tests.
- [ ] **Step 6: Commit.** Commit `build(installer): 升级 ModelHub R11 配置契约`.

### Task 5: Full verification, review, MR, and release

**Files:**
- Verify all changed files.
- Create ignored release directory: `release/modelhub-r11-20260816/`.

**Interfaces:**
- Produces: ready-for-review R11 PR from `feat/modelhub-configurable-compat-r11` to `main`.
- Produces: public Latest release `modelhub-installer-20260816-r11` with exactly four assets.

- [ ] **Step 1: Run full frontend verification.** Run `pnpm typecheck`, `pnpm format:check`, and `pnpm test:unit`; record test counts and exit codes.
- [ ] **Step 2: Run full Rust verification serially.** Run `LZMA_API_STATIC=1 cargo fmt --check`, `cargo clippy --all-targets --all-features -- -D warnings`, and full `cargo test` with the known toolchain PATH.
- [ ] **Step 3: Run complete installer suite and repository hygiene checks.** Run `bash tests/scripts/modelhub-installer.test.sh`, `git diff --check`, sensitive-data scan, and confirm no tracked release artifacts.
- [ ] **Step 4: Review `origin/main..HEAD`.** Check config migration, UI state ownership, summary false positives, dedup key privacy, retry isolation, cache bounds, logging privacy, and installer normalization. Fix every Critical/Important finding with a failing test first and re-run affected suites.
- [ ] **Step 5: Push branch and create Draft PR.** Include design decisions, default mapping rationale, 429/dedup safeguards, unclassified observation boundary, verification evidence, and rollback instructions.
- [ ] **Step 6: Wait for all CI checks and repair failures.** Do not publish while any required check is pending or failing; mark PR Ready only after green.
- [ ] **Step 7: Build fresh arm64 App with updater artifacts disabled.** Ad-hoc deep-sign if needed; verify architecture, bundle ID, version `3.19.2`, strict signature, dependencies, and binary hash differs from R10.
- [ ] **Step 8: Package exactly four R11 assets.** Generate App ZIP, portable snapshot, installer, and `SHA256SUMS`; verify Golden DB policy and sensitive-data allowlist.
- [ ] **Step 9: Test local and remote assets.** Perform installation, repeated installation, rollback, Draft Release upload, remote download, byte/digest comparison, App unpack verification, and another install/repeat/rollback from downloaded assets.
- [ ] **Step 10: Publish R11 as Latest.** Verify `/releases/latest` and `/releases/latest/download/install.sh` resolve to R11, then update the PR with the release link. Do not merge the R11 PR unless explicitly requested.
