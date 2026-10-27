#!/bin/bash

set -euo pipefail

security_bin="${CC_SWITCH_SECURITY_BIN:-/usr/bin/security}"
launchctl_bin="${CC_SWITCH_LAUNCHCTL_BIN:-/bin/launchctl}"
codesign_bin='/usr/bin/codesign'
plutil_bin='/usr/bin/plutil'
app_path='/Applications/ChatGPT.app'
if [[ "${CC_SWITCH_INSTALLER_TEST_MODE:-0}" == '1' ]]; then
  app_path="${CC_SWITCH_INSTALLER_TEST_APPLICATIONS_DIR:-/Applications}/ChatGPT.app"
  codesign_bin="${CC_SWITCH_CODESIGN_BIN:-/usr/bin/codesign}"
  plutil_bin="${CC_SWITCH_PLUTIL_BIN:-/usr/bin/plutil}"
fi

resolve_codex_path() {
  local candidate parent
  [[ -d "$app_path" && ! -L "$app_path" && ! -L "$app_path/Contents/Info.plist" ]] || return 1
  [[ "$("$plutil_bin" -extract CFBundleIdentifier raw -o - "$app_path/Contents/Info.plist")" == 'com.openai.codex' ]] || return 1
  "$codesign_bin" --verify --deep --strict "$app_path" >/dev/null 2>&1 || return 1
  "$codesign_bin" -dv --verbose=4 "$app_path" 2>&1 \
    | /usr/bin/grep -qx 'TeamIdentifier=2DC432GLL2' || return 1
  for candidate in \
    "$app_path/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex" \
    "$app_path/Contents/Resources/codex"; do
    if [[ -e "$candidate" || -L "$candidate" ]]; then
      parent="$candidate"
      while [[ "$parent" != "$app_path" ]]; do
        [[ "$parent" != '/' && "$parent" != '.' ]] || return 1
        [[ ! -L "$parent" ]] || return 1
        parent="$(dirname "$parent")"
      done
      [[ ! -L "$app_path" && -f "$candidate" && -x "$candidate" ]] || return 1
      "$codesign_bin" -dv --verbose=4 "$candidate" 2>&1 \
        | /usr/bin/grep -qx 'TeamIdentifier=2DC432GLL2' || return 1
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

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

if ! codex_path="$(resolve_codex_path)"; then
  unset modelhub_ak
  "$launchctl_bin" unsetenv MODELHUB_AK
  "$launchctl_bin" unsetenv CODEX_CLI_PATH
  exit 1
fi
"$launchctl_bin" setenv MODELHUB_AK "$modelhub_ak"
"$launchctl_bin" setenv CODEX_CLI_PATH "$codex_path"
unset modelhub_ak
