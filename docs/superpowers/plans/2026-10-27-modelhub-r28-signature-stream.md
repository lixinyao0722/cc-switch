# R28 Signature Stream Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans inline; one final read-only code review.

**Goal:** Publish R28 fixing valid OpenAI signatures being rejected by early pipe closure.
**Architecture:** Keep strict/deep signature verification and exact TeamIdentifier matching. Consume both signature-display streams to EOF so pipefail still rejects actual producer errors without SIGPIPE false negatives.
**Tech Stack:** macOS Bash 3.2, codesign, grep, shell installer tests, GitHub Release.
**Spec:** The confirmed diagnosis and user request in this chat: repair the R27 signature-pipeline bug and publish R28; do not mutate the live installation or credentials.

## Global Constraints

- Preserve new/legacy CLI layout selection, symlink rejection and OpenAI TeamIdentifier=2DC432GLL2.
- Keep CC Switch 3.24.0 app ZIP byte-identical; update only installer/resources.
- Keep live configuration, login state, AK and failure backups unchanged.
- Publish fixed tag modelhub-installer-20261027-r28 after draft asset readback; do not merge main.

## Review Focus

- Matching Team ID followed by output larger than a pipe buffer: helper succeeds and exports the exact selected CLI path.
- Both outer bundle and nested CLI streams: tests exercise them independently.
- Display command failure after matching Team ID: helper rejects it and clears fixture environment.
- Wrong signing team and strict verification failure: existing integrity cases continue to reject.
- Production signature output: repeat the real resolver read-only; no Keychain or launchctl mutation.

### Task 1: Signature fix and R28 release

**Files:** Modify templates/load-modelhub-env.sh and installer release tag; add tests/scripts/fixtures/modelhub-codesign-stream.sh and tests/scripts/modelhub-installer-r28-cases.sh; update test registration, changelog and compatibility guide.
**Interfaces:** Existing helper publishes MODELHUB_AK and CODEX_CLI_PATH only after successful verification; no new production interface.

- [x] Add two failing helper tests using real streaming beyond the Team ID match (outer bundle and payload independently).
- [x] Run R28 tests against R27 and verify the expected helper failure.
- [x] Remove grep quiet mode in both pipelines and discard grep output; keep pipefail.
- [x] Verify stream tests pass and real producer-error/integrity cases still fail closed, independently for app and payload.
- [x] Run the complete installer suite (158 passed), real resolver (20/20), and packaged helper with isolated credential/env boundaries (5/5).
- [x] Package assets, compare unchanged app ZIP hash, run packaged install/reinstall/rollback smoke, and obtain source review (no blockers).
- [ ] Commit/push a scoped branch and create/attach a new PR; publish draft then verify exact uploaded bytes before setting latest.
- [ ] Read back latest installer, tag commit, checksums; sync Feishu install date and append R28 changelog.
