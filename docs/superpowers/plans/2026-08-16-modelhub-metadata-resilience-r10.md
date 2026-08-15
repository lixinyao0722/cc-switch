# ModelHub Metadata Resilience R10 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve Codex Desktop title/description metadata by mapping only recognized internal Luna requests to Sol, learn per-session ModelHub encrypted-reasoning incompatibility, and publish the changes as installer R10.

**Architecture:** Extend the existing ModelHub compatibility classifier to return a typed metadata kind. Apply route-scoped body rewriting for non-summary metadata while retaining R9 summary blocking. Add a proxy-lifetime shared `(provider, session)` compatibility cache so the first exact `invalid_encrypted_content` response teaches subsequent requests to remove encrypted reasoning before their first upstream attempt.

**Tech Stack:** Rust, Tokio shared state, serde_json, Axum mock upstreams, Bash installer tests, GitHub Actions and Releases.

## Global Constraints

- Activity summaries remain locally blocked and never map to Sol.
- Only exact Codex Desktop metadata prompts using `gpt-5.6-luna` map to `gpt-5.6-sol`.
- Ordinary Luna traffic remains unchanged.
- Encrypted reasoning is removed proactively only after the same Provider + client-provided session has produced exact `invalid_encrypted_content`.
- Compatibility state is process-local, bounded to 2048 keys, non-persistent, and never logs raw session IDs.
- Keep the application version at `3.19.2`; publish installer tag `modelhub-installer-20260816-r10`.

---

### Task 1: Typed Codex metadata classifier and model rewrite

**Files:**
- Modify: `src-tauri/src/proxy/modelhub_compat.rs`
- Modify: `src-tauri/src/provider.rs`
- Modify: `src-tauri/src/proxy/forwarder.rs`

**Interfaces:**
- Produces: `CodexMetadataRequestKind`
- Produces: `codex_metadata_request_kind(body: &Value) -> Option<CodexMetadataRequestKind>`
- Produces: `LocalProxyRequestOverrides.codex_metadata_model: Option<String>` serialized as `codexMetadataModel`
- Consumes: existing ModelHub Responses route predicate and R9 activity-summary guard

- [ ] **Step 1: Write failing classifier tests** with literal request bodies for new-thread title, existing-conversation title, description, durable-title reconsideration, voice title, activity summary, ordinary Luna, Sol, similar text, and developer messages.
- [ ] **Step 2: Run `cargo test --lib modelhub_compat`** with `LZMA_API_STATIC=1` and confirm failure because the typed classifier and metadata variants do not exist.
- [ ] **Step 3: Implement the minimal typed classifier** using exact model and prompt-prefix checks while preserving R9 activity-summary recognition.
- [ ] **Step 4: Add a failing route integration test** whose mock upstream asserts a recognized title request arrives exactly once with `model = gpt-5.6-sol`; add negative tests for disabled config and ordinary Luna.
- [ ] **Step 5: Run the targeted forwarder tests** and confirm the title request still reaches upstream as Luna before implementation.
- [ ] **Step 6: Add `codexMetadataModel` to Provider metadata and rewrite only non-summary recognized metadata immediately before upstream transmission.**
- [ ] **Step 7: Run the classifier and forwarder tests** and confirm activity summaries remain local 400, recognized metadata reaches Sol once, and ordinary Luna remains Luna.
- [ ] **Step 8: Commit** with `fix(proxy): 映射 Codex 元数据请求到 Sol`.

### Task 2: Session-learned encrypted reasoning pre-cleanup

**Files:**
- Modify: `src-tauri/src/provider.rs`
- Modify: `src-tauri/src/proxy/server.rs`
- Modify: `src-tauri/src/proxy/handler_context.rs`
- Modify: `src-tauri/src/proxy/forwarder.rs`

**Interfaces:**
- Produces: `LocalProxyRequestOverrides.remember_invalid_encrypted_reasoning: Option<bool>` serialized as `rememberInvalidEncryptedReasoning`
- Produces: shared `Arc<RwLock<HashSet<String>>>` compatibility state owned by `ProxyState`
- Consumes: `RequestForwarder.session_id`, `session_client_provided`, provider ID, and `remove_encrypted_reasoning_items`

- [ ] **Step 1: Add a failing two-request integration test**: the first request receives exact `invalid_encrypted_content` then succeeds after cleanup; the second request in the same provider/session must reach upstream once and already be clean.
- [ ] **Step 2: Run the targeted test** and confirm the second request still sends encrypted reasoning and requires two upstream attempts.
- [ ] **Step 3: Add negative failing tests** proving different sessions/providers, disabled config, and generated session IDs do not inherit learned compatibility.
- [ ] **Step 4: Thread a proxy-lifetime shared cache through `ProxyState`, `HandlerContext`, and `RequestForwarder`; bound it to 2048 keys.**
- [ ] **Step 5: On exact first failure with removed items, learn the provider/session key; before later requests, remove encrypted reasoning when the key is known.**
- [ ] **Step 6: Run all encrypted-reasoning tests** and confirm the same-session second request uses one clean attempt while negative cases retain one-time probing.
- [ ] **Step 7: Commit** with `perf(proxy): 记忆加密推理不兼容会话`.

### Task 3: R10 installer and documentation contract

**Files:**
- Modify: `scripts/modelhub-installer/templates/modelhub-provider-meta.json`
- Modify: `scripts/modelhub-installer/package-release.sh`
- Modify: `scripts/modelhub-installer/install.sh`
- Modify: `tests/scripts/modelhub-installer.test.sh`
- Modify: `docs/guides/modelhub-codex-proxy-compat-zh.md`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Produces: Golden DB metadata with `codexMetadataModel = "gpt-5.6-sol"` and `rememberInvalidEncryptedReasoning = true`
- Produces: release tag `modelhub-installer-20260816-r10`

- [ ] **Step 1: Update installer tests first** to expect the R10 tag and both new Provider metadata values in the template, source snapshot preservation, packaged Golden DB, and installed DB.
- [ ] **Step 2: Run `bash tests/scripts/modelhub-installer.test.sh`** and confirm contract failures against the R9 installer/template.
- [ ] **Step 3: Update the template, packaging normalization/validation, installer tag/progress copy, guide, and changelog.**
- [ ] **Step 4: Run the installer suite** and confirm every case passes.
- [ ] **Step 5: Commit** with `build(installer): 升级 ModelHub R10 发布契约`.

### Task 4: Full verification and review

**Files:**
- Verify all changed files.

**Interfaces:**
- Consumes: all R10 implementation and installer contracts
- Produces: fresh evidence suitable for MR and Release notes

- [ ] **Step 1: Run `pnpm typecheck`, `pnpm format:check`, and `pnpm test:unit`.**
- [ ] **Step 2: Run `LZMA_API_STATIC=1 cargo fmt --check`, `cargo clippy --all-targets --all-features -- -D warnings`, and full `cargo test`.**
- [ ] **Step 3: Run the complete installer suite and `git diff --check`.**
- [ ] **Step 4: Review `origin/main..HEAD` for route scope, prompt false positives, cache isolation/bounds, sensitive logging, and installer normalization; fix all Critical/Important findings.**
- [ ] **Step 5: Re-run every affected verification command after review fixes.**

### Task 5: R10 MR and release

**Files:**
- Create: ignored release directory `release/modelhub-r10-20260816/`

**Interfaces:**
- Produces: R10 MR from `feat/modelhub-metadata-resilience-r10` to `main`
- Produces: public Latest release `modelhub-installer-20260816-r10`

- [ ] **Step 1: Push the branch and create a ready-for-review R10 PR** describing the two root causes, exact mapping boundary, session cache semantics, test evidence, and rollback controls.
- [ ] **Step 2: Wait for all GitHub CI checks** and repair any failures before publishing.
- [ ] **Step 3: Build a fresh arm64 CC Switch 3.19.2 App and package exactly four R10 assets into a new ignored directory.**
- [ ] **Step 4: Verify App/helper signatures, arm64 architecture, bundle ID/version, SHA256, asset allowlist, Golden DB values, sensitive-data scan, installation, repeated installation, and rollback.**
- [ ] **Step 5: Create an R10 Draft Release, upload all assets, download them again, compare bytes/digests, and verify the unpacked App/resources.**
- [ ] **Step 6: Publish R10 as Latest, verify `/releases/latest/download/install.sh` resolves to R10, and update the PR with the release link.**
