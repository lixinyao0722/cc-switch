# ModelHub One-Click Installer Design

## Context

The current ModelHub delivery requires users to download several attachments, install a custom CC Switch build, copy Codex and CC Switch state by hand, and set process environment variables manually. The existing private configuration archive cannot be published: it contains `MODELHUB_AK`, Codex OAuth material, bearer tokens, user-specific paths, CC Switch request history, and a full user database.

This design replaces that flow with a public, versionless bootstrap command backed by a new GitHub Release. The installer preserves existing user configuration, asks for `MODELHUB_AK` only at the end, and stores that secret in macOS Keychain.

## Goals

- Provide this stable install command:

  ```bash
  curl -fsSL https://github.com/lixinyao0722/cc-switch/releases/latest/download/install.sh | bash -s
  ```

- Support Apple Silicon Macs running macOS 12 or later.
- Install the verified ModelHub-compatible CC Switch 3.18.0 app.
- Add the ModelHub Codex provider and local proxy settings without removing other providers or personal Codex settings.
- Resolve every local path from the installing user's actual home directory at runtime.
- Prompt for `MODELHUB_AK` through macOS Keychain after all non-secret files are installed.
- Preserve the user's ChatGPT-managed `~/.codex/auth.json` and use the installed ChatGPT App's OpenAI-signed Codex binary.
- Provide automatic failure recovery and an explicit `--rollback latest` command.
- Publish no user credentials, request history, or user-specific paths.

## Non-Goals

- Supporting Intel Macs, Windows, or Linux.
- Installing or signing ChatGPT App.
- Distributing the private Codex fallback binary.
- Distributing or restoring any Codex OAuth token, bearer token, `auth.json`, CC Switch request history, or full user database.
- Replacing unrelated CC Switch providers, plugins, project trust entries, desktop preferences, or Codex configuration sections.
- Deleting the old delivery files from the owner's Lark Drive. Their blocks will only be removed from the installation document.

## Git and Release Layout

Development starts from `origin/main` on branch `feat/modelhub-one-click-installer`.

The existing releases remain unchanged:

- `modelhub-v3.18.0-20260726`
- `modelhub-v3.18.0-20260727-fork-fix`

A new normal GitHub Release, not a prerelease, is published with tag `modelhub-installer-20260727`. It becomes the repository's first `/releases/latest` target. Future installer releases can replace the latest target without changing the user-facing command.

The new Release contains exactly these public assets:

- `install.sh`
- `CC-Switch-ModelHub-3.18.0-arm64.app.zip`
- `modelhub-installer-resources.tar.gz`
- `SHA256SUMS.txt`

`install.sh` contains the immutable tag `modelhub-installer-20260727`. Although users fetch the script through `/releases/latest`, that script downloads its remaining assets from its own exact tag. A newer Release therefore cannot change assets midway through an older installation.

## Repository Files

The feature adds a focused installer directory:

- `scripts/modelhub-installer/install.sh`: Bash 3.2-compatible bootstrap, installer, verifier, and rollback entry point.
- `scripts/modelhub-installer/package-release.sh`: builds the public resource archive and checksums from an explicit allowlist.
- `scripts/modelhub-installer/assets/models-modelhub-1m.json`: public ModelHub model catalog with no credentials or local paths.
- `scripts/modelhub-installer/templates/modelhub-provider.toml`: managed Codex provider fields with `__USER_HOME__` placeholder.
- `scripts/modelhub-installer/templates/modelhub-provider-meta.json`: `max_output_tokens`, ModelHub session adapter, and same-provider 429 retry metadata.
- `scripts/modelhub-installer/templates/com.ccswitch.modelhub-env.plist`: LaunchAgent template.
- `scripts/modelhub-installer/templates/load-modelhub-env.sh`: reads the AK from Keychain and injects `MODELHUB_AK` and `CODEX_CLI_PATH` into the user launchd domain.
- `tests/scripts/modelhub-installer.test.sh`: isolated installer regression suite.

The release packager never starts from the old private configuration archive. It packages only the tracked allowlisted files above. This prevents a future private-bundle field from bypassing a blacklist.

## Preflight and Download Flow

The installer runs with `set -euo pipefail` and disables command tracing. It depends only on macOS system tools, including `/bin/bash`, `curl`, `shasum`, `tar`, `ditto`, `codesign`, `plutil`, `sqlite3`, `security`, `launchctl`, `osascript`, `open`, `mktemp`, and `sudo`; it does not require Homebrew, Node.js, Python, `jq`, or `rg`.

Before changing the system, it:

1. Confirms `uname -s` is `Darwin`, `uname -m` is `arm64`, and macOS is at least 12.
2. Confirms `/Applications/ChatGPT.app/Contents/Resources/codex` exists and has Team ID `2DC432GLL2`.
3. Creates a private `mktemp -d` staging directory and installs a trap to remove it.
4. Downloads the app ZIP, resources archive, and checksum file from the immutable Release tag.
5. Verifies exact filenames and SHA-256 values before extracting anything.
6. Rejects absolute paths, `..` traversal, symlinks, unexpected files, and unexpected top-level directories in the resources archive.
7. Validates every tracked template and confirms no unresolved placeholder exists except the declared runtime placeholders.
8. Acquires administrator credentials with `sudo -v` only when `/Applications` is not writable.

No application, configuration, Keychain item, or launchd state is changed until all checks pass.

## Backup and Transaction Boundary

Before the first mutation, the installer quits ChatGPT and CC Switch and creates:

```text
~/.cc-switch/backups/modelhub-installer/<UTC timestamp>/
```

The directory is mode `0700`. It records a manifest describing whether each managed target existed and stores local copies of the targets the installer may modify:

- `/Applications/CC Switch.app`
- `~/.codex/config.toml`
- `~/.codex/models-modelhub-1m.json`
- `~/.cc-switch/cc-switch.db`
- `~/.cc-switch/settings.json`
- `~/Library/LaunchAgents/com.ccswitch.modelhub-env.plist`
- `~/.local/share/cc-switch-modelhub/load-modelhub-env.sh`

The installer does not read, copy, or modify `~/.codex/auth.json`.

After the backup exists, any failure in app installation, configuration merging, Keychain setup, launchd loading, or health verification invokes rollback from that manifest. Rollback restores prior files and removes targets that did not exist before installation. A Keychain item created by the failed run is removed; an item that already existed is left present rather than exporting its prior secret into a file.

The installer copies itself to `~/.local/share/cc-switch-modelhub/install.sh`, allowing:

```bash
~/.local/share/cc-switch-modelhub/install.sh --rollback latest
```

## Incremental Configuration Merge

### CC Switch App

The verified app ZIP is extracted into staging and checked with `codesign --verify --deep --strict`. The existing app is then replaced with `ditto`. The installer never modifies or re-signs ChatGPT App or its bundled Codex binary.

### Codex Configuration

The model catalog is installed at the runtime path:

```text
${HOME}/.codex/models-modelhub-1m.json
```

A section-aware transformer creates a new `config.toml` in staging, validates it, and atomically replaces the live file. It owns only these top-level keys:

- `model`
- `review_model`
- `model_provider`
- `model_reasoning_effort`
- `model_auto_compact_token_limit`
- `model_context_window`
- `model_catalog_json`

It also owns only the `[model_providers.modelhub]` table. All other top-level keys and sections, including plugins, MCP servers, project trust, hooks, memories, desktop preferences, and skills, remain byte-for-byte in their original relative order.

The template uses `__USER_HOME__`; the installer replaces it with the current absolute `$HOME` after escaping it for TOML. No `/Users/shopee` path is present in the repository or Release.

### CC Switch Provider and Proxy

If `~/.cc-switch/cc-switch.db` does not exist, the freshly installed app is launched hidden once to initialize its schema, then quit before configuration continues.

The installer runs one SQLite transaction that:

- Finds an existing Codex provider named `Bytedance ModelHub - 官方CLI`; if found, it preserves that provider ID and updates only its managed fields.
- Otherwise inserts provider ID `bytedance-modelhub-official-cli`.
- Stores `settings_config` with an empty `auth` object and the merged ModelHub TOML. It never stores OAuth or bearer material.
- Stores the exact `localProxyRequestOverrides` metadata from the public template.
- Marks the ModelHub provider current for Codex without changing providers for other app types.
- Upserts only the Codex `proxy_config` row with loopback address `127.0.0.1`, port `15721`, proxy and takeover enabled, logging enabled, and automatic failover disabled.
- Leaves request logs, other providers, pricing, profiles, prompts, skills, and all unrelated tables untouched.

The installer updates only these keys in `~/.cc-switch/settings.json`, preserving every other key:

- `currentProviderCodex`
- `enableLocalProxy`
- `preserveCodexOfficialAuthOnSwitch`

### Runtime Environment and Keychain

The LaunchAgent and helper contain no secret. Runtime placeholders resolve to the installing user's home path, UID, and the verified ChatGPT Codex path.

After all non-secret files are installed, the installer prints the administrator-contact instruction and invokes:

```bash
security add-generic-password \
  -a "$USER" \
  -s "com.ccswitch.modelhub.ak" \
  -U -w </dev/tty
```

`-w` is the final argument, so `security` prompts through `/dev/tty`; the AK is never stored in a shell variable, command argument, config file, plist, output, or log.

The environment helper reads the Keychain item at login and calls `launchctl setenv` for:

- `MODELHUB_AK`
- `CODEX_CLI_PATH=/Applications/ChatGPT.app/Contents/Resources/codex`

The installer bootstraps or refreshes the LaunchAgent in the current `gui/<uid>` domain, invokes the helper once for the current login session, starts CC Switch, and waits for `http://127.0.0.1:15721/health` to return `healthy`.

## Idempotency and Failure Behavior

- Re-running the same installer creates a new backup and updates the same managed provider rather than adding a duplicate.
- Existing unmanaged Codex settings and CC Switch rows remain unchanged.
- Downloads use bounded retries and fail closed on checksum or archive validation errors.
- An empty or cancelled Keychain prompt fails the installation and triggers rollback.
- Health verification has a bounded timeout and includes only non-secret diagnostics.
- The installer never prints the AK, OAuth material, full provider JSON, full Codex config, or database contents.
- `--rollback latest` is idempotent and reports when there is no completed backup to restore.

## Test Strategy

Development follows red-green-refactor. The shell tests run against a temporary home and application root with command stubs; they never touch the real `/Applications`, Keychain, launchd domain, or user configuration.

Automated cases cover:

- Rejecting non-macOS, non-arm64, an unsupported macOS version, and an invalid ChatGPT Team ID.
- Refusing a checksum mismatch, archive traversal, a symlink, an unexpected asset, or an unresolved placeholder before mutation.
- First installation with no CC Switch database or Codex config.
- Incrementally merging an existing Codex config while preserving unrelated sections.
- Updating an existing ModelHub provider without duplicating it.
- Preserving unrelated CC Switch providers, settings, and database rows.
- Replacing `__USER_HOME__` correctly when the home path contains spaces.
- Cancelling the Keychain prompt and automatically restoring the backup.
- A health timeout and automatic rollback.
- Re-running the installer successfully.
- `--rollback latest` restoring existing files and removing newly created files.
- Bash 3.2 syntax validation and installer help output.

Release verification additionally:

1. Runs the installer test suite and repository-appropriate format, type, frontend, and Rust checks.
2. Builds the resource archive from the explicit allowlist.
3. Scans repository changes and extracted Release assets for `/Users/shopee`, `auth.json`, token field names, `MODELHUB_AK` values, request logs, and unexpected SQLite databases.
4. Downloads every published asset back from GitHub.
5. Re-runs SHA-256, archive allowlist, placeholder, and credential scans against the downloaded bytes.
6. Executes a sandboxed installation and rollback using the downloaded assets.

## Pull Request and Release Flow

After fresh verification:

1. Commit the installer, templates, tests, packaging logic, and documentation on `feat/modelhub-one-click-installer`.
2. Push the branch and open a Draft GitHub PR targeting `main`.
3. Create a draft GitHub Release with tag `modelhub-installer-20260727` targeting the verified feature commit.
4. Upload the four declared assets and compare GitHub asset digests with local SHA-256 values.
5. Publish it as a normal Release so `/releases/latest/download/install.sh` resolves.
6. Download and verify the published assets and run the final sandboxed smoke test.

The Release notes state that the app is Apple Silicon-only, ad-hoc signed, not Apple-notarized, and that the installer prompts for an administrator-provided ModelHub AK stored in Keychain.

## Lark Installation Document

The document `LPm1dcaQuogMRFx5UPMlf5KPg6P` is reduced to four sections:

1. Prerequisites: Apple Silicon Mac, installed and logged-in ChatGPT App, and access to an administrator-provided ModelHub AK.
2. One-click installation: the versionless `curl | bash` command and the Keychain prompt expectation.
3. Acceptance: CC Switch health, a normal ModelHub request, fork/"接续自任务", Computer Use, Browser, and Chrome.
4. Rollback: the local `--rollback latest` command and reopening the prior app when needed.

The rewrite removes the manual copy commands, implementation details, old attachment table, private Codex fallback instructions, tier edge note, checksums already enforced by the installer, and all four old attachment blocks. Removing those blocks does not delete their source files from Lark Drive. A single link to the new GitHub Release and one link to the detailed technical manual remain.
