# ModelHub Activity Summary Guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop unauthorized Codex Desktop Luna activity-summary traffic locally before it reaches ModelHub, then publish the change as ModelHub installer R9.

**Architecture:** Add a pure ModelHub compatibility predicate that recognizes the exact internal activity-summary request by model and prompt prefix. Invoke it only inside the existing ModelHub Codex Responses route before network transmission, returning `InvalidRequest` so the local proxy emits non-retryable HTTP 400. Keep all other Luna and non-ModelHub traffic unchanged.

**Tech Stack:** Rust, serde_json, CC Switch proxy pipeline, Bash installer tests, GitHub Actions and Releases.

## Global Constraints

- Do not route activity summaries to Sol.
- Do not block ordinary Luna requests.
- Do not modify Codex Desktop's `app.asar`.
- Do not send matching requests to ModelHub.
- Keep the application version at `3.19.2`; publish installer tag `modelhub-installer-20260815-r9`.

---

### Task 1: Activity summary request classifier

**Files:**
- Modify: `src-tauri/src/proxy/modelhub_compat.rs`

**Interfaces:**
- Produces: `is_unsupported_activity_summary_request(body: &serde_json::Value) -> bool`

- [ ] **Step 1: Write failing unit tests** for the exact Luna prompt, ordinary Luna, Sol, similar text, and supported Responses text carriers.
- [ ] **Step 2: Run the targeted Rust tests** and confirm failure because the classifier is absent.
- [ ] **Step 3: Implement the minimal pure classifier** with exact model and prefix checks.
- [ ] **Step 4: Run the targeted Rust tests** and confirm all classifier cases pass.
- [ ] **Step 5: Commit** with `fix(proxy): 本地阻止无权限活动摘要请求` after forwarder integration is complete.

### Task 2: ModelHub route fail-fast integration

**Files:**
- Modify: `src-tauri/src/proxy/forwarder.rs`

**Interfaces:**
- Consumes: `is_unsupported_activity_summary_request`
- Produces: local `ProxyError::InvalidRequest` before any HTTP request

- [ ] **Step 1: Add a failing forwarder regression test** using a mock upstream request counter.
- [ ] **Step 2: Run the targeted test** and confirm the mock receives the request before the fix.
- [ ] **Step 3: Add the route-scoped preflight guard** after body preparation and before request transmission.
- [ ] **Step 4: Run targeted tests** and confirm matching traffic returns 400 without touching upstream while ordinary Luna remains forwarded.
- [ ] **Step 5: Commit** the proxy tests and implementation.

### Task 3: R9 installer and documentation contract

**Files:**
- Modify: `scripts/modelhub-installer/install.sh`
- Modify: `tests/scripts/modelhub-installer.test.sh`
- Modify: `docs/guides/modelhub-codex-proxy-compat-zh.md`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Produces: fixed release tag `modelhub-installer-20260815-r9`

- [ ] **Step 1: Change installer tests to expect R9** and run them to verify a contract failure.
- [ ] **Step 2: Update installer tag and progress copy** to R9.
- [ ] **Step 3: Document local activity-summary fail-fast behavior** and its quota impact.
- [ ] **Step 4: Run the installer suite** and confirm all cases pass.
- [ ] **Step 5: Commit** with `build(installer): 升级 ModelHub R9 发布契约`.

### Task 4: Verification and review

**Files:**
- Verify all changed files.

- [ ] **Step 1: Run `cargo fmt --check` and `cargo clippy --all-targets --all-features -- -D warnings`.**
- [ ] **Step 2: Run the full Rust suite, frontend typecheck/format/unit suite, and installer suite.**
- [ ] **Step 3: Run `git diff --check` and inspect the final diff.**
- [ ] **Step 4: Dispatch an independent read-only code reviewer** against `origin/main..HEAD` and fix all Critical/Important findings.
- [ ] **Step 5: Re-run affected verification** after review fixes.

### Task 5: MR and R9 release

**Files:**
- Create: `release/modelhub-r9-20260815/` (ignored release artifacts)

- [ ] **Step 1: Push `feat/modelhub-activity-summary-guard` and open a draft PR** against `lixinyao0722/cc-switch:main`.
- [ ] **Step 2: Wait for all GitHub CI checks** and address failures before release.
- [ ] **Step 3: Build the arm64 3.19.2 App and package four R9 assets** into a fresh output directory.
- [ ] **Step 4: Verify SHA256, signatures, architecture, bundle identity/version, golden DB, sensitive content, and install/reinstall/rollback smoke tests.**
- [ ] **Step 5: Create an R9 Draft Release, upload assets, download and compare every asset and GitHub digest, then publish it as Latest.**
- [ ] **Step 6: Verify `/releases/latest` resolves to R9 and the public installer contains the fixed R9 tag.**
