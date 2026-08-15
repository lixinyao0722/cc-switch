# ModelHub Codex Proxy Resilience Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden the ModelHub Codex proxy against invalid namespace metadata, stuck SSE streams, and synchronized 429 retry storms, then publish and package the verified branch.

**Architecture:** Keep every behavior behind the existing ModelHub Codex adapter gate. Add one request normalizer, extend the shared stream timeout value object with ModelHub-only watchdog limits, and retain the existing same-provider 429 retry loop with a smaller installer default and bounded jitter.

**Tech Stack:** Rust 1.85, Tokio, Axum, serde_json, shell installer tests, Tauri 2, pnpm.

## Global Constraints

- Only Codex Responses requests using `codexSessionHeaderAdapter = "modelhub"` change behavior.
- Total ModelHub SSE lifetime is 600 seconds even when automatic failover is disabled.
- Existing non-empty tool descriptions, non-ModelHub providers, and the narrowly recognized encrypted-reasoning compatibility retry remain unchanged.
- Same-provider ModelHub 429 retries default to 3 with bounded jitter; final 429 responses remain intact.
- Portable installer configuration contains no local absolute paths, credentials, or user-specific plugin/project/hook state.
- Production behavior is written only after its focused regression test has failed for the expected reason.

---

### Task 1: Normalize ModelHub Namespace Descriptions

**Files:**
- Modify: `src-tauri/src/proxy/modelhub_compat.rs`
- Modify: `src-tauri/src/proxy/forwarder.rs`

**Interfaces:**
- Produces: `normalize_namespace_descriptions(body: &mut serde_json::Value) -> usize`
- Consumes: `should_apply_modelhub_header_adapter(...) -> bool`

- [ ] **Step 1: Write failing request-normalization tests**

Add tests covering top-level namespace tools, `input[].type == "additional_tools"`, whitespace-only descriptions, preserved non-empty descriptions, and untouched function/custom tools.

- [ ] **Step 2: Verify the focused tests fail**

Run: `cd src-tauri && LZMA_API_STATIC=1 cargo test proxy::modelhub_compat::tests::namespace_description -- --nocapture`

Expected: compilation failure because `normalize_namespace_descriptions` does not exist.

- [ ] **Step 3: Implement the minimal normalizer**

Use the stable fallback `Tools in the <name> namespace.` when a namespace name exists, otherwise `Tools in this namespace.`. Walk only the two approved tool carriers and return the number changed.

- [ ] **Step 4: Gate and call the normalizer**

Call it in `RequestForwarder::forward` after request transformation/body overrides and before serialization, only when `should_apply_modelhub_header_adapter` is true. Log only the changed count.

- [ ] **Step 5: Verify focused tests pass**

Run the Task 1 command again and confirm all namespace tests pass.

- [ ] **Step 6: Commit Task 1**

Commit: `fix(proxy): 补齐 ModelHub namespace 描述`

### Task 2: Add ModelHub Stream Watchdog

**Files:**
- Modify: `src-tauri/src/proxy/handler_context.rs`
- Modify: `src-tauri/src/proxy/response_processor.rs`
- Modify: `src-tauri/src/proxy/handlers.rs`

**Interfaces:**
- Extends: `StreamingTimeoutConfig` with `total_timeout: u64` and `progress_timeout: u64`
- Produces: `StreamingTimeoutConfig::for_modelhub_codex(base) -> StreamingTimeoutConfig`
- Produces: `is_useful_sse_progress(event_text: &str) -> bool`

- [ ] **Step 1: Write failing watchdog tests**

Add pure classification tests for keepalive/comment/metadata versus output, reasoning, tool-call, error, and terminal events. Add paused-time stream tests proving total timeout fires despite heartbeat chunks and useful progress refreshes only the progress deadline.

- [ ] **Step 2: Verify watchdog tests fail**

Run: `cd src-tauri && LZMA_API_STATIC=1 cargo test proxy::response_processor::tests::modelhub_stream -- --nocapture`

Expected: compilation failure for the new timeout fields/helpers.

- [ ] **Step 3: Implement timeout value semantics**

Set ordinary providers' new fields to zero. For ModelHub Codex, set `total_timeout = 600` and `progress_timeout` to the configured stream idle timeout when non-zero, otherwise 120 seconds.

- [ ] **Step 4: Implement deadline enforcement**

In `create_logged_passthrough_stream`, bound each `stream.next()` by the earliest first-byte, byte-idle, progress, or total deadline. Parse completed SSE blocks for progress without logging content. Emit a distinct I/O timeout message and stop the stream when a deadline expires.

- [ ] **Step 5: Apply ModelHub timeout config at every Codex stream call site**

Centralize the choice on `RequestContext` so native passthrough, namespace restoration, Responses conversion, and Anthropic conversion use identical watchdog settings.

- [ ] **Step 6: Verify watchdog tests pass**

Run the Task 2 command again and confirm classification and paused-time cases pass.

- [ ] **Step 7: Commit Task 2**

Commit: `fix(proxy): 限制 ModelHub 流式请求生命周期`

### Task 3: Bound ModelHub 429 Retries

**Files:**
- Modify: `src-tauri/src/proxy/retry_429.rs`
- Modify: `scripts/modelhub-installer/templates/modelhub-provider-meta.json`
- Modify: `tests/scripts/modelhub-installer.test.sh`

**Interfaces:**
- Produces: `retry_delay_with_jitter(config, retry_number, retry_after, now, jitter_basis_points) -> Duration`
- Retains: `retry_delay(...) -> Duration` as the runtime wrapper using process randomness derived without a new dependency

- [ ] **Step 1: Write failing bounded-jitter tests**

Test zero jitter, upper-bound jitter, max-delay capping, unchanged `Retry-After`, and installer metadata default `maxRetries == 3`.

- [ ] **Step 2: Verify tests fail**

Run: `cd src-tauri && LZMA_API_STATIC=1 cargo test proxy::retry_429::tests::retry_429_jitter -- --nocapture`

Run: `pnpm test:installer -- "golden DB builder creates minimal public snapshot"`

Expected: missing helper and metadata still reporting 10.

- [ ] **Step 3: Implement bounded jitter**

Apply 0–25% positive jitter only to locally computed exponential backoff. Clamp after jitter to `max_delay_ms`; do not modify a valid upstream `Retry-After` value.

- [ ] **Step 4: Change installer metadata default to three retries**

Update the tracked provider metadata and assert the generated golden database contains `retry429.maxRetries = 3`.

- [ ] **Step 5: Verify focused retry and installer tests pass**

Repeat both Task 3 commands.

- [ ] **Step 6: Commit Task 3**

Commit: `fix(proxy): 收紧 ModelHub 429 重试策略`

### Task 4: Synchronize Portable Codex Defaults

**Files:**
- Modify: `scripts/modelhub-installer/templates/modelhub-provider.toml`
- Modify: `scripts/modelhub-installer/golden/codex-config.toml`
- Modify: `tests/scripts/modelhub-installer.test.sh`
- Modify: `docs/guides/modelhub-codex-proxy-compat-zh.md`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: the ModelHub-relevant portion of `/Users/shopee/.codex/config.toml`
- Produces: portable tracked defaults with `model_reasoning_effort = "high"`, output/context/catalog settings, and the existing ten-request/ten-stream Codex transport recovery values

- [ ] **Step 1: Add failing portable-default assertions**

Assert both tracked TOML files include the exact portable ModelHub routing values, high reasoning effort, 128K output limit, retry fields, and no local/user-only sections.

- [ ] **Step 2: Verify installer test fails**

Run: `pnpm test:installer -- "golden DB builder creates minimal public snapshot"`

Expected: tracked defaults still use `max` and the provider template omits local ModelHub fields.

- [ ] **Step 3: Synchronize portable defaults**

Copy only ModelHub-relevant values. Preserve `__USER_HOME__`, the direct upstream URL, and omit bearer tokens, plugins, projects, marketplaces, hook trust state, and desktop preferences.

- [ ] **Step 4: Update operational documentation and changelog**

Document namespace normalization, 600-second watchdog, 400/401 fail-fast semantics, three 429 retries with jitter, and the synchronized installer defaults.

- [ ] **Step 5: Verify installer tests pass**

Run: `pnpm test:installer`

- [ ] **Step 6: Commit Task 4**

Commit: `chore(installer): 同步 ModelHub 安全默认配置`

### Task 5: Verify, Review, and Package

**Files:**
- Generated, ignored: `release/modelhub-proxy-resilience/`

**Interfaces:**
- Consumes: all commits from Tasks 1–4
- Produces: verified arm64 app ZIP, installer resources, install script, checksums, and smoke-test evidence

- [ ] **Step 1: Run formatting and focused validation**

Run frontend typecheck, format check, unit tests, Rust fmt, Clippy, targeted Rust tests, full Rust tests, and full installer tests.

- [ ] **Step 2: Request independent code review**

Review `origin/main..HEAD` against the approved design; resolve every Critical or Important finding and rerun affected checks.

- [ ] **Step 3: Build the arm64 Tauri release app**

Run the repository's release build with `LZMA_API_STATIC=1`, verify the bundle identifier, arm64 architecture, and strict code signature, then create the fixed-name app ZIP.

- [ ] **Step 4: Package and smoke-test installer assets**

Run `scripts/modelhub-installer/package-release.sh`, verify `SHA256SUMS.txt`, resource allowlist, sensitive scan, and `CC_SWITCH_RELEASE_SMOKE_ASSET_DIR` installer test.

- [ ] **Step 5: Commit any review fixes**

Use a focused Chinese Conventional Commit message matching the actual fix.

### Task 6: Push and Open Draft MR

**Files:**
- No source changes expected

**Interfaces:**
- Consumes: verified branch `feat/modelhub-proxy-resilience`
- Produces: remote branch and draft MR targeting `lixinyao0722/cc-switch:main`

- [ ] **Step 1: Inspect final status and diff**

Confirm the working tree contains no tracked or untracked source changes and summarize `origin/main..HEAD`.

- [ ] **Step 2: Push the branch**

Run: `git push -u origin feat/modelhub-proxy-resilience`

- [ ] **Step 3: Open a draft MR**

Use `gh pr create --draft --repo lixinyao0722/cc-switch --base main --head feat/modelhub-proxy-resilience` with background, root cause, behavior changes, verification, packaging paths, risks, and rollback instructions.

- [ ] **Step 4: Report handoff**

Return branch, commit list, MR URL, verification evidence, package paths/checksums, and whether a remote Draft Release was created. Do not publish a final Release without an explicit version/tag decision.
