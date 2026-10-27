# R29 explicit LaunchAgent start

The user approved formalizing the reviewed local R28 kickstart patch, merging its PR and publishing a new release. A reported macOS GUI domain kept RunAtLoad pending in on-demand-only mode, so registration alone never produced a first completion.

## Scope and approach

After bootstrap and successful direct helper execution, request launchctl kickstart for the registered job, without -k. Preserve strict signatures, 30-second completion checks, environment/credential readback and automatic rollback. Extending the timeout cannot start a demand-only job; skipping completion would accept unverified background setup.

R29 updates installer/resources and uses the byte-identical CC Switch 3.24.0 application archive. Do not alter live applications, config, AK or backups. The independent selected-backup rollback tool and login-domain policy redesign are out of scope. Login-time automatic behavior is not claimed from an install-time fix.

Acceptance: demand-only registration completes after an explicit request; request failure restores installation state; existing running helper is not killed; benign real launchd and packaged smoke checks pass; PR merged and published assets verified before latest changes.
