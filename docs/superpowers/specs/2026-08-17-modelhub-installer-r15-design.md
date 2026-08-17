# ModelHub Installer R15 Design

## Background

R14 established transactional installation, managed Codex routing, rollback, and the four-asset release contract. R15 keeps those guarantees and addresses three configuration gaps found after the R14 release:

1. The packaged GPT-5.5 catalog still advertises a 272,000-token window at 95% effectiveness even though the runtime ModelHub catalog is expected to expose 1,050,000 tokens at 100%.
2. The first macOS privilege request displays only the system `Password:` prompt, so users cannot tell whether it expects their Mac administrator password or `MODELHUB_AK`.
3. The Golden Codex configuration does not record three approved post-install settings: prevent sleep while a task runs, show context-window usage, and enable the bundled Computer Use plugin.

## Goals

1. Publish installer R15 with tag `modelhub-installer-20260817-r15` while keeping the application version and application asset name at `3.19.2`.
2. Set packaged `gpt-5.5` catalog and template values to a 1,050,000-token maximum and 100% effective window.
3. Explain the macOS administrator-password request before the first `sudo -v` call.
4. Make the three approved Codex settings enabled after Golden configuration installation.
5. Preserve the R14 transaction, backup, rollback, routing, credential, and release-asset guarantees.

## Non-goals

- Do not change `gpt-5.6-sol`, `gpt-5.6-terra`, or `gpt-5.6-luna` catalog values.
- Do not claim that ModelHub accepts requests beyond 272,000 tokens without backend verification.
- Do not edit `~/.codex/.codex-global-state.json`; it contains unrelated application state and changes frequently while Codex is running.
- Do not hardcode a bundled plugin version, ChatGPT build number, marketplace cache path, or user-specific absolute home path.
- Do not manually duplicate the Computer Use MCP definition. The bundled plugin owns its `.mcp.json` server declaration and launcher.
- Do not change the CC Switch application version or create a general CC Switch `v*` release.

## Catalog changes

The repository has two release sources for GPT-5.5 and both must agree:

- `scripts/modelhub-installer/assets/models-modelhub-1m.json`
- `src-tauri/src/resources/gpt5_5_template.json`

For the `gpt-5.5` entry, R15 sets:

```json
{
  "context_window": 1050000,
  "max_context_window": 1050000,
  "effective_context_window_percent": 100
}
```

The installer asset uses the stable release slug `gpt-5.5`; the ModelHub runtime may resolve it to a dated slug such as `gpt-5.5-2026-04-24`. R15 validates the packaged stable slug and documents that the server-side mapping remains a backend contract.

## Codex settings

The Golden Codex template continues to overwrite the target `~/.codex/config.toml` inside the existing backup and rollback transaction. Add the following settings:

```toml
[desktop]
git-branch-prefix = "feat/"
show-context-window-usage = true
preventSleepWhileRunning = true

[plugins."computer-use@openai-bundled"]
enabled = true
```

The two desktop keys are the actual host-storage keys used by the current Codex application. The Computer Use plugin bundled with ChatGPT declares its own MCP server in `.mcp.json`, so enabling the plugin is the portable source of truth for the MCP toggle. The installer does not add a second `[mcp_servers.computer-use]` table.

The installed configuration remains parseable by the bundled Codex CLI. Reinstallation is idempotent because it writes the same Golden file, and rollback restores the pre-install configuration from the existing manifest.

The bundled Computer Use runtime may be installed or refreshed by Codex only after the application starts. The installer success text therefore tells users to restart Codex and open a new task if the plugin or the settings UI does not refresh immediately.

## Administrator-password prompt

`prepare_application_permissions` remains the centralized first privilege check. Immediately before the first `sudo -v`, the installer prints:

```text
接下来 macOS 会请求管理员权限。
请输入当前 Mac 登录用户的管理员密码（不是 MODELHUB_AK）。输入时终端不会显示字符，输完按回车。
该权限用于检查或写入 /Applications 和 /etc/codex 等系统位置。
```

The explanation is emitted only when privilege escalation is actually required. Test mode captures the same message without attempting a real password interaction. Later privileged operations reuse the validated sudo timestamp and do not repeat the explanation.

## Release contract

R15 uses:

- Branch: `feat/r15-modelhub-installer`
- Pull request base: `origin/main`
- Release tag: `modelhub-installer-20260817-r15`
- Release name: `ModelHub Installer R15`
- Application version: `3.19.2`

The release contains exactly four public assets:

1. `CC-Switch-ModelHub-3.19.2-arm64.app.zip`
2. `install.sh`
3. `modelhub-installer-resources.tar.gz`
4. `SHA256SUMS.txt`

The installer self-download URL, release tag checks, guide, changelog, packaging tests, and release smoke tests all move from R14 to R15. Packaging continues to scan allowlisted files for credentials and user-specific paths and generates checksums from the final files.

The R14 application ZIP may be reused only if its signature, application version, and SHA-256 are verified before R15 packaging. The other three assets are rebuilt from the R15 branch so they contain the new installer and resources.

## Error handling and rollback

- A malformed catalog or Golden configuration fails validation before any managed target is replaced.
- A failed `sudo -v` exits with the existing administrator-permission error after the explanatory text.
- Failure after backup creation follows the R14 rollback path and restores the previous Codex configuration and managed system configuration.
- Release packaging fails closed if the four-asset allowlist, checksum file, signature checks, or release metadata do not match R15.

## Testing and acceptance

Automated tests must prove:

- The installer asset and Rust template contain GPT-5.5 values `1050000 / 1050000 / 100`.
- The three GPT-5.6 entries remain unchanged at their approved values.
- Golden and installed Codex configuration contain the two desktop keys and the enabled Computer Use plugin exactly once.
- Golden configuration does not contain a manually duplicated `[mcp_servers.computer-use]` table.
- The first privilege path emits wording equivalent to “Mac 登录用户的管理员密码” and “不是 MODELHUB_AK” before invoking the sudo stub.
- A no-sudo path does not emit an unnecessary password explanation.
- Installer release metadata and all download URLs use R15.
- Packaging produces exactly the four allowlisted assets and valid SHA-256 entries.
- Reinstall and rollback smoke tests preserve the R14 transaction guarantees.

Release validation includes the focused installer suite, shell syntax checks, JSON parsing, Rust template tests, frontend checks, Rust checks, package-release smoke tests, and verification of the uploaded GitHub Release assets and checksums.

Manual acceptance after installing the formal R15 assets checks that Codex Settings shows all three approved toggles enabled after restarting Codex, and that a new task reports the GPT-5.5 catalog window as approximately 1.05M when the backend mapping supports it.
