# ModelHub History Bucket R23 Design

## Goal

Release installer R23 so ModelHub and OpenAI Official can resume the same Codex history after switching providers.

## Scope

- Treat the legacy Codex provider id `modelhub` as a trusted CC Switch provider id.
- Re-run the third-party history and provider-template migrations for users whose R22 v1 markers are already complete.
- Rewrite ModelHub session JSONL metadata and Codex state DB rows from `modelhub` to the stable `custom` bucket, with the existing backup and atomic-write protections.
- Rewrite the saved ModelHub provider template from `modelhub` to `custom`, so switching back to ModelHub does not create new provider-bound sessions.
- Enable the existing unified-history behavior in the ModelHub installer and request migration of existing official `openai` history into the same `custom` bucket.
- Preserve application version `3.20.0`; publish installer tag `modelhub-installer-20260828-r23`.

## Non-goals

- Do not rewrite conversation content, encrypted reasoning, response ids, or tool payloads.
- Do not change the in-app consent flow outside this opinionated ModelHub installer profile.
- Do not change the general CC Switch `v3.20.0` release.

## Safety

- Migrations remain idempotent and back up JSONL, state DB, and provider templates before mutation.
- Existing v1 migration records remain readable. New v2 records are separate so already-installed R22 users receive the fix exactly once.
- Unknown custom provider ids and the built-in `openai` id are not swept into the third-party migration.
