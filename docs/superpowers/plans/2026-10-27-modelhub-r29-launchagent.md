# R29 LaunchAgent Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans inline and one read-only whole-change review.

**Goal:** Release R29 fixing pending on-demand LaunchAgent startup.
**Architecture:** Explicitly request the existing job after the direct helper succeeds; preserve current wait/readback/rollback. Stateful fixtures model a registered but never-started job.
**Tech Stack:** macOS Bash 3.2, launchctl, shell regression suite, GitHub release.
**Spec:** docs/superpowers/specs/2026-10-27-modelhub-r29-design.md

## Global Constraints

- Preserve OpenAI strict signatures, new/legacy CLI paths, exact launchd domain, timeout and rollback.
- No kickstart -k; no secret output, live credential read or installation mutation in tests.
- Fixed tag modelhub-installer-20261027-r29; app ZIP stays R28/R26 3.24.0 byte-identical.
- Create and merge a scoped PR before publication. Keep unrelated work untouched.

## Review Focus

- Pending RunAtLoad without a first exit must not be accepted as success.
- Explicit-start failure must propagate and restore prior state.
- Already-running helper must not be killed or accepted from stale exit status.
- Credential/environment checks and secret suppression must remain unchanged.
- Real launchd verification uses unique disposable jobs, never the live ModelHub job.

### Task 1: Startup patch and verification

**Files:** scripts/modelhub-installer/install.sh; tests/scripts/fixtures/modelhub-launchctl.sh; tests/scripts/modelhub-installer-r29-cases.sh; test registration; CHANGELOG.md and compatibility guide.
**Interfaces:** kickstart gui/<uid>/com.ccswitch.modelhub-env takes exactly two arguments and preserves an already-running job.

- [x] Extend launchd fixture and add demand-only transaction test; run RED against R28.
- [x] Apply the six-line local patch and R29 tag; add failure and already-running cases, run focused GREEN (3 groups).
- [x] Run complete pnpm test:installer (161 passed) and benign real-launchd characterization (exit 0, disposable job removed).
- [x] Package, check SHA256/app equality and run normal and demand-only packaged install/reinstall/rollback smoke (both passed).
- [ ] Review, commit/push, create/attach PR and merge with expected head. Expected: main includes tested diff.
- [ ] Publish draft from merged main, verify downloads then set latest; append Feishu release note. Expected: tag/latest match verified bytes.
