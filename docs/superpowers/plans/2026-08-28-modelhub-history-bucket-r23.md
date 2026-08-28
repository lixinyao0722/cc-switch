# ModelHub History Bucket R23 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish installer R23 with a one-time v2 migration that moves legacy ModelHub history and templates into the shared Codex `custom` bucket.

**Architecture:** Extend the existing trusted legacy-provider migration instead of introducing a second history engine. Add v2 device-local markers so R22 installations rerun the idempotent migration once, then use the existing official-history toggle to make both switching directions converge on `custom`.

**Tech Stack:** Rust, rusqlite, serde, shell installer tests, Tauri macOS packaging, GitHub Releases

**Spec:** `docs/superpowers/specs/2026-08-28-modelhub-history-bucket-r23-design.md`

## Global Constraints

- Application version remains `3.20.0`.
- Installer tag is `modelhub-installer-20260828-r23`.
- History and template mutations must retain existing backups and idempotency.
- Built-in `openai` is handled only by the existing official-unify flow, which the R23 ModelHub installer enables.
- Unknown provider ids remain untouched.

---

### Task 1: Regression Coverage

**Files:**
- Modify: `src-tauri/src/codex_history_migration.rs`

**Interfaces:**
- Consumes: `collect_source_model_provider_ids`, `migrate_codex_jsonl_files`, `migrate_codex_state_db_provider_bucket`, `migrate_codex_provider_templates_to_custom`
- Produces: regression tests proving legacy ModelHub sessions and templates normalize to `custom` while official and unknown buckets remain controlled separately

- [ ] Add a failing end-to-end ModelHub fixture containing provider config, session JSONL, and a state DB row.
- [ ] Assert the ModelHub provider id is collected and all three stores are rewritten to `custom`.
- [ ] Assert an official `openai` session can then join the same bucket through the official migration, representing ModelHub to official switching.
- [ ] Assert switching back uses the migrated ModelHub template with `model_provider = "custom"`, representing official to ModelHub switching.
- [ ] Run the focused Rust test and confirm it fails because `modelhub` is not trusted yet.

### Task 2: V2 Migration Markers and Minimal Fix

**Files:**
- Modify: `src-tauri/src/codex_history_migration.rs`
- Modify: `src-tauri/src/settings.rs`
- Modify: `src-tauri/src/commands/settings.rs`

**Interfaces:**
- Consumes: existing v1 marker structs and startup migration calls
- Produces: `codexThirdPartyHistoryProviderBucketV2` and `codexProviderTemplateV2` device-local completion records

- [ ] Add `modelhub` to the trusted legacy provider id list.
- [ ] Add optional v2 marker fields to `LocalMigrations` without removing v1 fields.
- [ ] Point the migration gates and writes at v2 fields and change the backup generation name to v2.
- [ ] Update settings merge tests so backend-owned v1 and v2 markers are preserved.
- [ ] Run focused migration and settings tests until green.

### Task 3: R23 Release Contract

**Files:**
- Modify: `scripts/modelhub-installer/install.sh`
- Modify: `tests/scripts/modelhub-installer.test.sh`
- Modify: `docs/guides/modelhub-codex-proxy-compat-zh.md`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: R22 installer and package-release contract
- Produces: immutable R23 tag and documentation references while keeping the 3.20.0 app asset name

- [ ] Change release tag and user-facing release copy from R22 to R23.
- [ ] Add release notes describing the two-way shared-history fix and the official-history opt-in requirement.
- [ ] Update installer contract tests to require the R23 tag and copy.
- [ ] Run shell syntax and focused installer contract tests.

### Task 4: Verification, Packaging, and Publication

**Files:**
- Generated: `release/modelhub-installer-r23/publish/*`

**Interfaces:**
- Consumes: verified branch source and R23 packaging scripts
- Produces: signed arm64 app ZIP, installer, resource archive, checksums, Git tag, and GitHub Release

- [ ] Run formatting, frontend checks, Rust tests, clippy, and installer tests.
- [ ] Build and strict-verify the 3.20.0 arm64 app bundle.
- [ ] Package the exact R23 allowlisted assets and validate checksums and sensitive-data scans.
- [ ] Commit and push the feature branch.
- [ ] Create the annotated R23 tag and publish the GitHub Release with exactly the verified assets.
- [ ] Download remote assets and byte-compare/checksum them with local outputs.
- [ ] Report branch, commit, tag, release URL, checks, artifact hashes, and whether `main` changed.
