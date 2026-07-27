#!/bin/bash

set -euo pipefail

security_bin="${CC_SWITCH_SECURITY_BIN:-/usr/bin/security}"
launchctl_bin="${CC_SWITCH_LAUNCHCTL_BIN:-/bin/launchctl}"
account_name="$(/usr/bin/id -un)"
modelhub_ak="$(
  "$security_bin" find-generic-password \
    -a "$account_name" \
    -s 'com.ccswitch.modelhub.ak' \
    -w \
    2>/dev/null
)" || exit 0

if [[ -z "$modelhub_ak" ]]; then
  exit 0
fi

"$launchctl_bin" setenv MODELHUB_AK "$modelhub_ak"
"$launchctl_bin" setenv CODEX_CLI_PATH '/Applications/ChatGPT.app/Contents/Resources/codex'
unset modelhub_ak
