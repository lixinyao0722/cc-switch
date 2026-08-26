# ModelHub Installer R17 Design

## Goal

R17 combines the two approved workstreams into one release:

1. Make ModelHub and OpenAI Official selectable from CC Switch without losing the user's ChatGPT login.
2. Keep mobile-created Codex tasks on the selected route by updating the two system managed-config keys that R14 introduced.
3. Reduce ModelHub request amplification and repeated context transfer with capabilities verified against the live ModelHub Responses endpoint.

## Verified upstream capabilities

The live ModelHub route behind CC Switch was probed on 2026-08-27:

- `/v1/responses` accepts `store=true` and returns a standard `resp_...` ID.
- A second request containing only new input plus `previous_response_id` recovered an exact nonce from the first request.
- `/v1/responses/compact` returns a standard `response.compaction` object with opaque `compaction` output.
- Feeding the complete compact output into a later `/v1/responses` request recovered an exact pre-compaction nonce.
- A same-session request without the cursor did not recover the nonce, so the state was not an accidental session-header side effect.

Prompt caching remains enabled, but cached input still counts toward rate limits. Incremental continuation reduces payload transfer; remote compaction is the mechanism that reduces the active context presented in later requests.

## Managed route switching

The installer continues to own these root keys in `/etc/codex/managed_config.toml`:

```toml
model_provider = "modelhub"
openai_base_url = "http://127.0.0.1:15721/v1"
```

CC Switch applies two modes:

- **ModelHub**: atomically set both keys. Desktop defaults use ModelHub and mobile-created tasks that explicitly select built-in `openai` still enter the local CC Switch route.
- **OpenAI Official**: atomically remove both keys while preserving every other managed policy, comment, table, owner, and mode. Codex then uses its built-in provider and the user's existing ChatGPT login directly.

The normal app process never writes `/etc/codex` directly. It writes a private candidate file, validates it, and invokes one fixed administrator operation to copy, set `root:wheel 0644`, validate, and atomically rename it. Provider selection is committed only after the managed route succeeds. A failed or cancelled authorization leaves both provider selection and managed config unchanged.

Managed defaults are read at Codex startup. The switch result therefore carries a restart requirement. The UI offers an immediate restart action and otherwise instructs the user to restart Codex and create a new task. Existing task metadata is not rewritten.

## Context optimization

The feature is provider-scoped and enabled only for native ModelHub Responses routes with a real client session ID.

### Checkpoint identity

```text
provider id + session id + model
+ stable request-options hash
```

The stable hash covers the full outbound request except the changing conversation input, `previous_response_id`, `stream`, and `store`.

### Incremental continuation

After a successful `response.completed`, CC Switch records the response ID, hashes of the exact full input prefix, hashes of returned output items, the stable request-options hash, and creation time.

On the next request CC Switch sends only the exact suffix plus `previous_response_id` when every item hash and the stable hash match. Any mismatch, fork, concurrent generation, missing client session, explicit cursor, expired checkpoint, process restart, or malformed response sends the complete original input.

An upstream invalid-cursor response clears the checkpoint and retries once with the untouched full request. Context retry is independent from Provider failover and 429 retry.

### Remote compaction

When estimated input exceeds the configured threshold, CC Switch compacts only the stable prefix before the newest user turn. It preserves the complete opaque compact output and sends `compact output + newest original turn and following items`.

Later requests reuse the compact checkpoint only when the original prefix hashes still match. Compact failure is non-destructive: the full request is sent unchanged. Original transcripts remain in Codex local storage.

Checkpoint state is intentionally memory-only. Restarting CC Switch causes a safe full-history fallback rather than trusting stale remote state.

## Admission and retry control

- The gate is scoped by Provider and model.
- Requests estimated at or above 100,000 input tokens acquire the whole gate and run one at a time.
- Smaller requests use one slot from a four-slot gate.
- Metadata/helper requests do not receive same-provider 429 retries.
- ModelHub capacity error `-2004` receives at most one recovery attempt.
- Existing `Retry-After`, shared cooldown, and single recovery probe behavior remain active.
- Logs record only mode, estimated tokens, byte size, queue time, and presence of checkpoint fields. They never record prompts, session IDs, response IDs, compact output, or credentials.

## Release contract

- App version: `3.19.3`.
- Installer tag: `modelhub-installer-20260827-r17`.
- Exactly four public assets: `install.sh`, `CC-Switch-ModelHub-3.19.3-arm64.app.zip`, `modelhub-installer-resources.tar.gz`, and `SHA256SUMS.txt`.
- The release is published only after source tests, installer tests, release smoke tests, app signature/architecture checks, checksum verification, remote asset download verification, and merge-request review.
