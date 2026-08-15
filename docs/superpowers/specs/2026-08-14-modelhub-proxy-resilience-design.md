# ModelHub Codex Proxy Resilience Design

## Goal

Make the ModelHub Codex route fail fast on invalid requests, avoid streams that
remain alive without useful progress, and reduce rate-limit retry storms while
keeping every non-ModelHub provider unchanged.

## Scope

- Applies only when the request is a Codex Responses route and the provider has
  `codexSessionHeaderAdapter = "modelhub"`.
- Normalize an empty or whitespace-only namespace tool `description` to a stable
  non-empty description before forwarding. Child tool descriptions and existing
  non-empty descriptions are preserved byte-for-byte.
- Add a ten-minute total stream lifetime for ModelHub Codex SSE responses even
  when automatic failover is disabled.
- Track useful SSE progress separately from transport bytes. Comments,
  keep-alive frames, and metadata-only lifecycle events do not reset the useful
  progress timer; output, reasoning, tool-call, error, and terminal events do.
- Treat upstream authentication failures and ordinary invalid-request HTTP 400
  responses as non-retryable. The one-shot encrypted-reasoning compatibility
  retry remains limited to its specific recognized error code.
- Change the ModelHub same-provider 429 policy from ten retries to three. Keep
  exponential backoff and `Retry-After`, and add bounded random jitter to local
  backoff delays so concurrent tasks do not retry in lockstep.
- Synchronize these defaults into the portable Codex config, provider template,
  provider metadata, installer tests, and ModelHub compatibility guide.

## Architecture

### Request normalization

Add a focused ModelHub request sanitizer in `modelhub_compat.rs`. The forwarder
calls it only after provider selection has proved the request uses the ModelHub
adapter and before final serialization. It walks top-level tools and tools held
inside `additional_tools` input carriers, repairing only namespace descriptions.

### Stream watchdog

Extend `StreamingTimeoutConfig` with optional total-lifetime and useful-progress
limits. Normal providers retain the existing failover-coupled values. ModelHub
Codex responses receive a ten-minute total lifetime regardless of failover state
and a useful-progress limit derived from the existing stream-idle setting, with
a safe fallback when that setting is disabled.

The passthrough stream records its start time and last useful SSE event. Each
read is bounded by the earliest active deadline. On expiration it returns a
typed I/O error to the downstream Codex client, causing Codex's existing stream
recovery path to take over instead of leaving the task hung indefinitely.

### Retry policy

The same-provider retry helper remains responsible only for HTTP 429. Its retry
count is read from provider metadata, capped by the existing safety maximum, and
the installer default becomes three. Jitter is computed inside a small pure
helper so range and cap behavior can be tested deterministically.

## Error Handling

- Namespace normalization is deterministic and cannot fail the request.
- A stream deadline produces an explicit timeout diagnostic containing the
  timeout kind and configured seconds, without logging prompts, credentials, or
  response bodies.
- HTTP 400 and 401/403 return immediately unless the response matches an existing
  narrowly recognized compatibility error.
- Exhausted 429 retries return the last upstream 429 exactly as today.

## Tests

- Unit tests prove empty namespace descriptions are repaired in both top-level
  and `additional_tools` shapes while non-empty descriptions remain unchanged.
- Paused-time Tokio tests prove heartbeat-only streams hit useful-progress and
  total-lifetime deadlines, while real progress resets only the progress timer.
- Retry tests prove three attempts are emitted by the installer defaults and
  jitter stays bounded by the configured maximum.
- Installer tests prove tracked golden config and metadata match the intended
  local defaults and contain no local paths or credentials.
- Run targeted Rust tests, installer tests, formatting, Clippy, the full Rust
  suite, frontend typecheck/unit tests, and release-package verification.

## Release

Build a fresh arm64 app bundle from the feature branch, package it with the
tracked portable golden snapshot, verify signatures/checksums/allowlists, push
the branch, and open a draft MR against the fork's `main`. Release artifacts are
kept out of Git and reported by absolute path. A new remote Release is created
only if the existing release workflow's draft and asset-verification gates pass.
