#!/bin/bash

set -euo pipefail

PATH='/usr/bin:/bin:/usr/sbin:/sbin'
export PATH

readonly MODELHUB_SECTION='[model_providers.modelhub]'
readonly RELEASE_REPOSITORY='lixinyao0722/cc-switch'
readonly RELEASE_TAG='modelhub-installer-20260816-r13'
readonly INSTALLER_ASSET='install.sh'
readonly APP_ASSET='CC-Switch-ModelHub-3.19.2-arm64.app.zip'
readonly RESOURCES_ASSET='modelhub-installer-resources.tar.gz'
readonly CHECKSUM_ASSET='SHA256SUMS.txt'
readonly EXPECTED_CODEX_TEAM_ID='2DC432GLL2'
readonly CHATGPT_BUNDLE_ID='com.openai.codex'
readonly CHATGPT_DOWNLOAD_PAGE='https://openai.com/chatgpt/download/'
readonly CHATGPT_DMG_URL='https://persistent.oaistatic.com/codex-app-prod/ChatGPT.dmg'
readonly RENAME_HELPER_SHA256='__RENAME_HELPER_SHA256__'
readonly TRUSTED_HELPER_TEMPLATE='/private/var/tmp/.cc-switch-modelhub-helper.XXXXXX'
readonly MODELHUB_PROVIDER_ID='bytedance-modelhub-official-cli'
readonly MODELHUB_PROVIDER_NAME='Bytedance ModelHub - 官方CLI'
readonly KEYCHAIN_SERVICE='com.ccswitch.modelhub.ak'
readonly LAUNCH_AGENT_LABEL='com.ccswitch.modelhub-env'

INSTALL_USER_HOME=''
INSTALL_APPLICATIONS_DIR=''
CC_SWITCH_APP_PATH=''
CHATGPT_APP_PATH=''
CHATGPT_CODEX_PATH=''
CODEX_CONFIG_PATH=''
MODEL_CATALOG_PATH=''
CC_SWITCH_DATABASE_PATH=''
CC_SWITCH_SETTINGS_PATH=''
LAUNCH_AGENT_PATH=''
ENV_HELPER_PATH=''
LOCAL_INSTALLER_PATH=''
BACKUP_ROOT=''
ACTIVE_BACKUP_DIR=''
NEEDS_SUDO=0
MUTATION_STARTED=0
INSTALL_COMPLETED=0
KEYCHAIN_CREATED_BY_RUN=0
KEYCHAIN_UPDATED_BY_RUN=0
KEYCHAIN_PREVIOUS_AK=''
MODELHUB_EXPECTED_AK=''
LAUNCHD_ENVIRONMENT_SNAPSHOT_READY=0
LAUNCHD_MODELHUB_AK_EXISTED_BEFORE_RUN=0
LAUNCHD_MODELHUB_AK_BEFORE_RUN=''
LAUNCHD_CODEX_CLI_PATH_EXISTED_BEFORE_RUN=0
LAUNCHD_CODEX_CLI_PATH_BEFORE_RUN=''
TRANSACTION_GUARD_ACTIVE=0
TRANSACTION_ROLLBACK_RUNNING=0
TRANSACTION_STAGE_DIR=''
LAUNCHER_FAILURE_SNAPSHOT_READY=0
LAUNCHER_REPLACED_BY_RUN=0
CHATGPT_BOOTSTRAP_MOUNT_DIR=''
CHATGPT_BOOTSTRAP_MOUNT_STATE='none'
CHATGPT_BOOTSTRAP_TEMP_DIR=''
CHATGPT_BOOTSTRAP_STAGE_DIR=''
CHATGPT_TRUSTED_HELPER_DIR=''
CHATGPT_TRUSTED_HELPER_PATH=''
CHATGPT_INSTALLED_BY_RUN=0

die() {
  echo "error: $*" >&2
  return 1
}

progress() {
  local current="$1"
  local total="$2"
  shift 2
  printf '\n[%s/%s] %s\n' "$current" "$total" "$*" >&2
}

installer_tool_path() {
  local variable_name="$1"
  local default_path="$2"
  local override=''

  case "$variable_name" in
    CC_SWITCH_*_BIN) ;;
    *)
      die "invalid installer tool variable: $variable_name"
      return 1
      ;;
  esac
  if [[ "${CC_SWITCH_INSTALLER_TEST_MODE:-0}" == "1" ]]; then
    eval "override=\${$variable_name:-}"
  fi
  printf '%s' "${override:-$default_path}"
}

expected_rename_helper_sha256() {
  local expected_sha="$RENAME_HELPER_SHA256"

  if [[ "${CC_SWITCH_INSTALLER_TEST_MODE:-0}" == "1" \
    && -n "${CC_SWITCH_INSTALLER_TEST_RENAME_HELPER_SHA256:-}" ]]; then
    expected_sha="$CC_SWITCH_INSTALLER_TEST_RENAME_HELPER_SHA256"
  fi
  case "$expected_sha" in
    ''|*[!0-9a-f]*)
      die "exclusive rename helper pinned SHA-256 is invalid"
      return 1
      ;;
  esac
  if [[ "${#expected_sha}" -ne 64 ]]; then
    die "exclusive rename helper pinned SHA-256 must contain 64 lowercase hex characters"
    return 1
  fi
  printf '%s' "$expected_sha"
}

file_sha256() {
  local file_path="$1"
  local shasum_bin='/usr/bin/shasum'
  local digest

  if ! digest="$("$shasum_bin" -a 256 "$file_path" | awk '{ print $1 }')"; then
    return 1
  fi
  printf '%s' "$digest"
}

validate_non_root() {
  local effective_uid="$1"

  if [[ "$effective_uid" == "0" ]]; then
    die "do not run the entire installer with sudo; run it as your login user"
    return 1
  fi
}

validate_execution_identity() {
  local actual_uid="$1"
  local test_uid="${2:-$actual_uid}"

  validate_non_root "$actual_uid" || return 1
  if [[ "${CC_SWITCH_INSTALLER_TEST_MODE:-0}" == "1" ]]; then
    validate_non_root "$test_uid" || return 1
  fi
}

validate_platform() {
  local operating_system="$1"
  local architecture="$2"
  local major_version="$3"

  if [[ "$operating_system" != "Darwin" ]]; then
    die "unsupported operating system: $operating_system (macOS required)"
    return 1
  fi
  if [[ "$architecture" != "arm64" ]]; then
    die "unsupported architecture: $architecture (arm64 required)"
    return 1
  fi
  case "$major_version" in
    ""|*[!0-9]*)
      die "invalid macOS major version: $major_version"
      return 1
      ;;
  esac
  if [[ "$major_version" -lt 12 ]]; then
    die "unsupported macOS version: $major_version (12 or later required)"
    return 1
  fi
}

path_is_directory() {
  if [[ "$NEEDS_SUDO" == "1" ]]; then
    run_with_privilege /bin/test -d "$1"
  else
    [[ -d "$1" ]]
  fi
}

path_is_regular_file() {
  if [[ "$NEEDS_SUDO" == "1" ]]; then
    run_with_privilege /bin/test -f "$1"
  else
    [[ -f "$1" ]]
  fi
}

path_is_executable() {
  if [[ "$NEEDS_SUDO" == "1" ]]; then
    run_with_privilege /bin/test -x "$1"
  else
    [[ -x "$1" ]]
  fi
}

path_is_symlink() {
  if [[ "$NEEDS_SUDO" == "1" ]]; then
    run_with_privilege /bin/test -L "$1"
  else
    [[ -L "$1" ]]
  fi
}

path_exists() {
  if [[ "$NEEDS_SUDO" == "1" ]]; then
    run_with_privilege /bin/test -e "$1"
  else
    [[ -e "$1" ]]
  fi
}

validate_chatgpt_codex() {
  local codex_path="$1"
  local expected_team_id="$2"
  local codesign_bin="$(installer_tool_path CC_SWITCH_CODESIGN_BIN /usr/bin/codesign)"
  local details
  local team_id

  if ! path_is_executable "$codex_path"; then
    die "ChatGPT Codex executable not found: $codex_path"
    return 1
  fi
  if [[ ! -x "$codesign_bin" ]]; then
    die "codesign command not found: $codesign_bin"
    return 1
  fi
  if ! details="$(run_with_privilege "$codesign_bin" -dv --verbose=4 "$codex_path" 2>&1)"; then
    die "unable to inspect ChatGPT Codex signature"
    return 1
  fi
  team_id="$(printf '%s\n' "$details" | awk -F= '$1 == "TeamIdentifier" { print $2; exit }')"
  if [[ "$team_id" != "$expected_team_id" ]]; then
    die "unexpected ChatGPT Codex Team ID"
    return 1
  fi
}

validate_chatgpt_app() {
  local app_path="$1"
  local expected_team_id="$2"
  local expected_bundle_id="$3"
  local plutil_bin="$(installer_tool_path CC_SWITCH_PLUTIL_BIN /usr/bin/plutil)"
  local codesign_bin="$(installer_tool_path CC_SWITCH_CODESIGN_BIN /usr/bin/codesign)"
  local file_bin="$(installer_tool_path CC_SWITCH_FILE_BIN /usr/bin/file)"
  local info_plist="$app_path/Contents/Info.plist"
  local bundle_id
  local executable_name
  local executable_path
  local details
  local team_id
  local file_details

  if path_is_symlink "$app_path" \
    || ! path_is_directory "$app_path" \
    || ! path_is_regular_file "$info_plist"; then
    die "ChatGPT app bundle is missing or incomplete: $app_path"
    return 1
  fi
  if [[ ! -x "$plutil_bin" ]]; then
    die "plutil command not found: $plutil_bin"
    return 1
  fi
  if [[ ! -x "$codesign_bin" ]]; then
    die "codesign command not found: $codesign_bin"
    return 1
  fi
  if [[ ! -x "$file_bin" ]]; then
    die "file command not found: $file_bin"
    return 1
  fi

  if ! bundle_id="$(run_with_privilege "$plutil_bin" -extract CFBundleIdentifier raw -o - "$info_plist" 2>/dev/null)"; then
    die "unable to read the ChatGPT bundle identifier"
    return 1
  fi
  if [[ "$bundle_id" != "$expected_bundle_id" ]]; then
    die "unexpected ChatGPT bundle identifier"
    return 1
  fi
  if ! executable_name="$(run_with_privilege "$plutil_bin" -extract CFBundleExecutable raw -o - "$info_plist" 2>/dev/null)"; then
    die "unable to read the ChatGPT main executable name"
    return 1
  fi
  case "$executable_name" in
    ''|*/*|.|..)
      die "invalid ChatGPT main executable name"
      return 1
      ;;
  esac
  executable_path="$app_path/Contents/MacOS/$executable_name"
  if ! path_is_executable "$executable_path"; then
    die "ChatGPT main executable not found: $executable_path"
    return 1
  fi

  if ! details="$(run_with_privilege "$codesign_bin" -dv --verbose=4 "$app_path" 2>&1)"; then
    die "unable to inspect the ChatGPT app signature"
    return 1
  fi
  team_id="$(printf '%s\n' "$details" | awk -F= '$1 == "TeamIdentifier" { print $2; exit }')"
  if [[ "$team_id" != "$expected_team_id" ]]; then
    die "unexpected ChatGPT app Team ID"
    return 1
  fi
  if ! run_with_privilege "$codesign_bin" --verify --deep --strict "$app_path" >/dev/null 2>&1; then
    die "ChatGPT app strict signature verification failed"
    return 1
  fi
  if ! file_details="$(run_with_privilege "$file_bin" -b "$executable_path" 2>/dev/null)"; then
    die "unable to inspect the ChatGPT main executable architecture"
    return 1
  fi
  if ! printf '%s\n' "$file_details" | grep -Eq '(^|[^[:alnum:]_])arm64([^[:alnum:]_]|$)'; then
    die "ChatGPT main executable does not contain arm64"
    return 1
  fi

  validate_chatgpt_codex "$app_path/Contents/Resources/codex" "$expected_team_id"
}

download_chatgpt_dmg() {
  local output_path="$1"
  local curl_bin="${CC_SWITCH_CURL_BIN:-/usr/bin/curl}"

  if [[ ! -x "$curl_bin" ]]; then
    die "curl command not found: $curl_bin"
    return 1
  fi
  if ! "$curl_bin" \
    --fail \
    --location \
    --silent \
    --show-error \
    --retry 3 \
    --retry-all-errors \
    --output "$output_path" \
    "$CHATGPT_DMG_URL"; then
    die "failed to download ChatGPT from the official OpenAI URL"
    return 1
  fi
}

attach_chatgpt_dmg() {
  local dmg_path="$1"
  local mount_dir="$2"
  local hdiutil_bin="${CC_SWITCH_HDIUTIL_BIN:-/usr/bin/hdiutil}"

  if [[ ! -x "$hdiutil_bin" ]]; then
    die "hdiutil command not found: $hdiutil_bin"
    return 1
  fi
  if ! "$hdiutil_bin" attach -nobrowse -readonly -mountpoint "$mount_dir" "$dmg_path"; then
    die "failed to attach the official ChatGPT disk image"
    return 1
  fi
}

detach_chatgpt_dmg() {
  local mount_dir="$1"
  local hdiutil_bin="${CC_SWITCH_HDIUTIL_BIN:-/usr/bin/hdiutil}"

  if [[ ! -x "$hdiutil_bin" ]]; then
    die "hdiutil command not found: $hdiutil_bin"
    return 1
  fi
  if ! "$hdiutil_bin" detach "$mount_dir"; then
    die "failed to detach the ChatGPT disk image"
    return 1
  fi
}

canonical_directory() {
  (cd "$1" 2>/dev/null && /bin/pwd -P)
}

validate_mounted_chatgpt_source() {
  local source_app="$1"
  local mount_dir="$2"
  local canonical_source
  local canonical_mount
  local canonical_stage

  if path_is_symlink "$mount_dir" || path_is_symlink "$source_app"; then
    die "mounted ChatGPT app must not be a symlink"
    return 1
  fi
  canonical_stage="$(canonical_directory "$CHATGPT_BOOTSTRAP_STAGE_DIR")" || {
    die "unable to resolve the ChatGPT bootstrap stage"
    return 1
  }
  canonical_mount="$(canonical_directory "$mount_dir")" || {
    die "unable to resolve the ChatGPT mount directory"
    return 1
  }
  case "$canonical_mount" in
    "$canonical_stage"/chatgpt-mount.*) ;;
    *)
      die "ChatGPT mount directory escapes the private stage"
      return 1
      ;;
  esac
  canonical_source="$(canonical_directory "$source_app")" || {
    die "unable to resolve the mounted ChatGPT app"
    return 1
  }
  if [[ "$canonical_source" != "$canonical_mount/ChatGPT.app" ]]; then
    die "mounted ChatGPT app escapes its private mount directory"
    return 1
  fi
}

validate_staged_chatgpt_source() {
  local source_app="$1"

  if [[ -z "$CHATGPT_BOOTSTRAP_TEMP_DIR" \
    || "$source_app" != "$CHATGPT_BOOTSTRAP_TEMP_DIR/ChatGPT.app" ]]; then
    die "staged ChatGPT app is outside the tracked Applications directory"
    return 1
  fi
  if path_is_symlink "$source_app" || ! path_is_directory "$source_app"; then
    die "staged ChatGPT app must be a real directory"
    return 1
  fi
}

validate_rename_helper() {
  local helper_path="$1"
  local expected_sha="$2"
  local codesign_bin="$(installer_tool_path CC_SWITCH_HELPER_CODESIGN_BIN /usr/bin/codesign)"
  local lipo_bin="$(installer_tool_path CC_SWITCH_LIPO_BIN /usr/bin/lipo)"
  local architectures
  local actual_sha

  if [[ -z "$helper_path" || "$helper_path" != /* \
    || ! -f "$helper_path" || ! -x "$helper_path" || -L "$helper_path" ]]; then
    die "exclusive rename helper is missing or unsafe"
    return 1
  fi
  if [[ ! -x "$codesign_bin" || ! -x "$lipo_bin" ]]; then
    die "exclusive rename helper verification tool is unavailable"
    return 1
  fi
  if ! "$codesign_bin" --verify --strict --verbose=2 "$helper_path" >/dev/null 2>&1; then
    die "exclusive rename helper signature verification failed"
    return 1
  fi
  architectures="$("$lipo_bin" -archs "$helper_path")" || return 1
  if [[ "$architectures" != 'arm64' ]]; then
    die "exclusive rename helper must contain only arm64"
    return 1
  fi
  actual_sha="$(file_sha256 "$helper_path")" || return 1
  if [[ "$actual_sha" != "$expected_sha" ]]; then
    die "exclusive rename helper does not match the pinned SHA-256"
    return 1
  fi
}

validate_packaged_rename_helper() {
  local stage_dir="$1"
  local resources_dir="$2"
  local helper_path="$resources_dir/helpers/rename-exclusive"
  local canonical_stage
  local canonical_resources
  local expected_sha

  if [[ "$resources_dir" != "$stage_dir/resources/modelhub-installer" \
    || -L "$resources_dir" || -L "$resources_dir/helpers" ]]; then
    die "exclusive rename helper is outside verified packaged resources"
    return 1
  fi
  canonical_stage="$(canonical_directory "$stage_dir")" || return 1
  canonical_resources="$(canonical_directory "$resources_dir")" || return 1
  if [[ "$canonical_resources" != "$canonical_stage/resources/modelhub-installer" ]]; then
    die "exclusive rename helper resource path is not canonically contained"
    return 1
  fi
  expected_sha="$(expected_rename_helper_sha256)" || return 1
  validate_rename_helper "$helper_path" "$expected_sha"
}

chatgpt_path_identity() {
  run_with_privilege /usr/bin/stat -f '%d:%i' "$1"
}

chatgpt_mount_is_active() {
  local mount_dir="$1"
  local mount_bin="$(installer_tool_path CC_SWITCH_MOUNT_BIN /sbin/mount)"
  local mount_output

  if [[ ! -x "$mount_bin" ]]; then
    die "mount command not found: $mount_bin"
    return 1
  fi
  if ! mount_output="$("$mount_bin")"; then
    die "failed to inspect active mounts"
    return 2
  fi
  if printf '%s\n' "$mount_output" | /usr/bin/grep -Fq -- " on $mount_dir ("; then
    return 0
  fi
  return 1
}

cleanup_chatgpt_mount() {
  local rm_bin="$(installer_tool_path CC_SWITCH_RM_BIN /bin/rm)"
  local mount_status

  if [[ -z "$CHATGPT_BOOTSTRAP_MOUNT_DIR" ]]; then
    return 0
  fi
  case "$CHATGPT_BOOTSTRAP_MOUNT_DIR" in
    "$CHATGPT_BOOTSTRAP_STAGE_DIR"/chatgpt-mount.*) ;;
    *)
      die "refusing to remove an unsafe ChatGPT mount directory: $CHATGPT_BOOTSTRAP_MOUNT_DIR"
      return 1
      ;;
  esac
  case "$CHATGPT_BOOTSTRAP_MOUNT_STATE" in
    pending)
      if chatgpt_mount_is_active "$CHATGPT_BOOTSTRAP_MOUNT_DIR"; then
        CHATGPT_BOOTSTRAP_MOUNT_STATE='attached'
      else
        mount_status=$?
        if [[ "$mount_status" == "1" ]]; then
          CHATGPT_BOOTSTRAP_MOUNT_STATE='detached'
        else
          return 1
        fi
      fi
      ;;
    attached)
      ;;
    detached)
      ;;
    *)
      die "invalid ChatGPT mount lifecycle state: $CHATGPT_BOOTSTRAP_MOUNT_STATE"
      return 1
      ;;
  esac
  if [[ "$CHATGPT_BOOTSTRAP_MOUNT_STATE" == "attached" ]]; then
    if ! detach_chatgpt_dmg "$CHATGPT_BOOTSTRAP_MOUNT_DIR"; then
      return 1
    fi
    CHATGPT_BOOTSTRAP_MOUNT_STATE='detached'
  fi
  if [[ ! -x "$rm_bin" ]]; then
    die "rm command not found: $rm_bin"
    return 1
  fi
  if ! "$rm_bin" -rf -- "$CHATGPT_BOOTSTRAP_MOUNT_DIR"; then
    die "failed to remove the ChatGPT mount directory"
    return 1
  fi
  CHATGPT_BOOTSTRAP_MOUNT_DIR=''
  CHATGPT_BOOTSTRAP_MOUNT_STATE='none'
}

cleanup_chatgpt_temp() {
  local rm_bin="$(installer_tool_path CC_SWITCH_RM_BIN /bin/rm)"

  if [[ -z "$CHATGPT_BOOTSTRAP_TEMP_DIR" ]]; then
    return 0
  fi
  case "$CHATGPT_BOOTSTRAP_TEMP_DIR" in
    "$INSTALL_APPLICATIONS_DIR"/.chatgpt-modelhub.*) ;;
    *)
      die "refusing to remove an unsafe ChatGPT install directory: $CHATGPT_BOOTSTRAP_TEMP_DIR"
      return 1
      ;;
  esac
  if [[ ! -x "$rm_bin" ]]; then
    die "rm command not found: $rm_bin"
    return 1
  fi
  if ! run_with_privilege "$rm_bin" -rf -- "$CHATGPT_BOOTSTRAP_TEMP_DIR"; then
    die "failed to remove the ChatGPT install directory"
    return 1
  fi
  CHATGPT_BOOTSTRAP_TEMP_DIR=''
}

cleanup_trusted_rename_helper() {
  if [[ -z "$CHATGPT_TRUSTED_HELPER_DIR" ]]; then
    CHATGPT_TRUSTED_HELPER_PATH=''
    return 0
  fi
  validate_trusted_helper_directory "$CHATGPT_TRUSTED_HELPER_DIR" '500|700' || return 1
  if ! run_with_privilege /bin/rm -rf -- "$CHATGPT_TRUSTED_HELPER_DIR"; then
    die "failed to remove the trusted helper directory"
    return 1
  fi
  CHATGPT_TRUSTED_HELPER_DIR=''
  CHATGPT_TRUSTED_HELPER_PATH=''
}

validate_trusted_helper_parent() {
  local owner
  local permissions

  if [[ ! -d '/private/var/tmp' || -L '/private/var/tmp' ]]; then
    die "trusted helper parent must be a real directory"
    return 1
  fi
  owner="$(/usr/bin/stat -f '%u' /private/var/tmp)" || return 1
  permissions="$(/usr/bin/stat -f '%Sp' /private/var/tmp)" || return 1
  if [[ "$owner" != '0' || "$permissions" != *t ]]; then
    die "trusted helper parent must be root-owned and sticky"
    return 1
  fi
}

validate_trusted_helper_directory() {
  local directory="$1"
  local allowed_modes="$2"
  local parent="${directory%/*}"
  local name="${directory##*/}"
  local owner_mode

  if [[ "$parent" != '/private/var/tmp' ]]; then
    die "trusted helper directory has an unsafe parent"
    return 1
  fi
  case "$name" in
    .cc-switch-modelhub-helper.?*) ;;
    *)
      die "trusted helper directory has an unsafe name"
      return 1
      ;;
  esac
  if run_with_privilege /bin/test -L "$directory" \
    || ! run_with_privilege /bin/test -d "$directory"; then
    die "trusted helper directory must be a real directory"
    return 1
  fi
  owner_mode="$(run_with_privilege /usr/bin/stat -f '%u:%Lp' "$directory")" || return 1
  case "$owner_mode" in
    "0:${allowed_modes%%|*}") ;;
    "0:${allowed_modes#*|}") ;;
    *)
      die "trusted helper directory has unsafe ownership or permissions"
      return 1
      ;;
  esac
}

validate_trusted_helper_file() {
  local helper_path="$1"
  local expected_directory="$2"
  local owner_mode

  if [[ "$helper_path" != "$expected_directory/rename-exclusive" ]] \
    || run_with_privilege /bin/test -L "$helper_path" \
    || ! run_with_privilege /bin/test -f "$helper_path" \
    || ! run_with_privilege /bin/test -x "$helper_path"; then
    die "trusted helper file is unsafe"
    return 1
  fi
  owner_mode="$(run_with_privilege /usr/bin/stat -f '%u:%Lp' "$helper_path")" || return 1
  if [[ "$owner_mode" != '0:500' ]]; then
    die "trusted helper file has unsafe ownership or permissions"
    return 1
  fi
}

privileged_file_sha256() {
  local file_path="$1"
  local digest

  if ! digest="$(run_with_privilege /usr/bin/shasum -a 256 "$file_path" | awk '{ print $1 }')"; then
    return 1
  fi
  printf '%s' "$digest"
}

prepare_trusted_rename_helper() {
  local source_helper="$1"
  local expected_sha="$2"
  local actual_sha

  if [[ "$NEEDS_SUDO" == "1" ]]; then
    validate_trusted_helper_parent || return 1
    if ! CHATGPT_TRUSTED_HELPER_DIR="$(
      run_with_privilege /usr/bin/mktemp -d "$TRUSTED_HELPER_TEMPLATE"
    )"; then
      CHATGPT_TRUSTED_HELPER_DIR=''
      die "failed to create the trusted helper directory"
      return 1
    fi
    validate_trusted_helper_directory "$CHATGPT_TRUSTED_HELPER_DIR" '700|700' || return 1
    CHATGPT_TRUSTED_HELPER_PATH="$CHATGPT_TRUSTED_HELPER_DIR/rename-exclusive"
    if ! run_with_privilege /bin/cp "$source_helper" "$CHATGPT_TRUSTED_HELPER_PATH" \
      || ! run_with_privilege /bin/chmod 0500 "$CHATGPT_TRUSTED_HELPER_PATH" \
      || ! run_with_privilege /bin/chmod 0500 "$CHATGPT_TRUSTED_HELPER_DIR"; then
      die "failed to protect the trusted helper copy"
      return 1
    fi
    validate_trusted_helper_directory "$CHATGPT_TRUSTED_HELPER_DIR" '500|500' || return 1
    validate_trusted_helper_file \
      "$CHATGPT_TRUSTED_HELPER_PATH" \
      "$CHATGPT_TRUSTED_HELPER_DIR" \
      || return 1
    actual_sha="$(privileged_file_sha256 "$CHATGPT_TRUSTED_HELPER_PATH")" || return 1
  else
    CHATGPT_TRUSTED_HELPER_PATH="$source_helper"
    actual_sha="$(file_sha256 "$CHATGPT_TRUSTED_HELPER_PATH")" || return 1
  fi
  if [[ "$actual_sha" != "$expected_sha" ]]; then
    die "trusted rename helper does not match the pinned SHA-256"
    return 1
  fi
}

cleanup_chatgpt_bootstrap() {
  local cleanup_status=0

  cleanup_chatgpt_mount || cleanup_status=1
  cleanup_trusted_rename_helper || cleanup_status=1
  cleanup_chatgpt_temp || cleanup_status=1
  if [[ -z "$CHATGPT_BOOTSTRAP_MOUNT_DIR" \
    && -z "$CHATGPT_BOOTSTRAP_TEMP_DIR" \
    && -z "$CHATGPT_TRUSTED_HELPER_DIR" ]]; then
    CHATGPT_BOOTSTRAP_STAGE_DIR=''
  fi
  return "$cleanup_status"
}

stage_verified_chatgpt_app() {
  local source_app="$1"
  local ditto_bin="$(installer_tool_path CC_SWITCH_DITTO_BIN /usr/bin/ditto)"
  local temp_app

  if [[ ! -x "$ditto_bin" ]]; then
    die "ditto command not found: $ditto_bin"
    return 1
  fi
  if ! CHATGPT_BOOTSTRAP_TEMP_DIR="$(
    run_with_privilege /usr/bin/mktemp -d "$INSTALL_APPLICATIONS_DIR/.chatgpt-modelhub.XXXXXX"
  )"; then
    CHATGPT_BOOTSTRAP_TEMP_DIR=''
    die "failed to create a same-volume ChatGPT install directory"
    return 1
  fi
  temp_app="$CHATGPT_BOOTSTRAP_TEMP_DIR/ChatGPT.app"
  if ! run_with_privilege "$ditto_bin" "$source_app" "$temp_app"; then
    die "failed to copy the verified ChatGPT app"
    return 1
  fi
  validate_staged_chatgpt_source "$temp_app" || return 1
  validate_chatgpt_app "$temp_app" "$EXPECTED_CODEX_TEAM_ID" "$CHATGPT_BUNDLE_ID"
}

install_verified_chatgpt_app() {
  local source_app="$1"
  local target_app="$2"
  local helper_path="$3"
  local helper_status
  local source_identity
  local source_device
  local source_inode
  local expected_sha
  local trusted_cleanup_status=0

  validate_staged_chatgpt_source "$source_app" || return 1
  if [[ "$target_app" != "$CHATGPT_APP_PATH" ]]; then
    die "refusing to install ChatGPT at an unexpected path: $target_app"
    return 1
  fi
  if path_exists "$target_app" || path_is_symlink "$target_app"; then
    die "ChatGPT appeared before the official app could be installed"
    return 1
  fi
  expected_sha="$(expected_rename_helper_sha256)" || return 1
  validate_rename_helper "$helper_path" "$expected_sha" || return 1
  source_identity="$(chatgpt_path_identity "$source_app")" || {
    die "unable to record the staged ChatGPT app identity"
    return 1
  }
  source_device="${source_identity%%:*}"
  source_inode="${source_identity#*:}"
  prepare_trusted_rename_helper "$helper_path" "$expected_sha" || return 1
  if run_with_privilege \
    "$CHATGPT_TRUSTED_HELPER_PATH" \
    "$source_app" \
    "$target_app" \
    "$source_device" \
    "$source_inode"; then
    helper_status=0
  else
    helper_status=$?
  fi
  cleanup_trusted_rename_helper || trusted_cleanup_status=1
  if [[ "$helper_status" != "0" ]]; then
    if [[ "$helper_status" == "17" ]]; then
      die "ChatGPT appeared during the exclusive app publication"
    elif [[ "$helper_status" == "18" ]]; then
      die "staged ChatGPT app identity changed before publication"
    else
      die "failed to atomically publish the verified ChatGPT app"
    fi
    return 1
  fi
  CHATGPT_INSTALLED_BY_RUN=1
  if ! validate_chatgpt_app "$target_app" "$EXPECTED_CODEX_TEAM_ID" "$CHATGPT_BUNDLE_ID"; then
    die "Install ChatGPT again from the official OpenAI download page: $CHATGPT_DOWNLOAD_PAGE"
    return 1
  fi
  if [[ "$trusted_cleanup_status" != "0" ]]; then
    return 1
  fi
  cleanup_chatgpt_temp
}

ensure_chatgpt_app() {
  local stage_dir="$1"
  local resources_dir="${2:-}"
  local helper_path="$resources_dir/helpers/rename-exclusive"
  local dmg_path="$stage_dir/ChatGPT.dmg"
  local mounted_app

  CHATGPT_INSTALLED_BY_RUN=0
  if [[ -e "$CHATGPT_APP_PATH" || -L "$CHATGPT_APP_PATH" ]]; then
    if validate_chatgpt_app "$CHATGPT_APP_PATH" "$EXPECTED_CODEX_TEAM_ID" "$CHATGPT_BUNDLE_ID"; then
      return 0
    fi
    die "Install ChatGPT again from the official OpenAI download page: $CHATGPT_DOWNLOAD_PAGE"
    return 1
  fi
  if [[ ! -d "$stage_dir" ]]; then
    die "ChatGPT bootstrap staging directory is missing: $stage_dir"
    return 1
  fi
  validate_packaged_rename_helper "$stage_dir" "$resources_dir" || return 1
  CHATGPT_BOOTSTRAP_STAGE_DIR="$stage_dir"
  download_chatgpt_dmg "$dmg_path" || {
    cleanup_chatgpt_bootstrap || true
    return 1
  }
  if ! CHATGPT_BOOTSTRAP_MOUNT_DIR="$(
    /usr/bin/mktemp -d "$stage_dir/chatgpt-mount.XXXXXX"
  )"; then
    CHATGPT_BOOTSTRAP_MOUNT_DIR=''
    cleanup_chatgpt_bootstrap || true
    die "failed to create the ChatGPT disk image mount directory"
    return 1
  fi
  CHATGPT_BOOTSTRAP_MOUNT_STATE='pending'
  mounted_app="$CHATGPT_BOOTSTRAP_MOUNT_DIR/ChatGPT.app"
  if ! attach_chatgpt_dmg "$dmg_path" "$CHATGPT_BOOTSTRAP_MOUNT_DIR"; then
    cleanup_chatgpt_bootstrap || true
    return 1
  fi
  CHATGPT_BOOTSTRAP_MOUNT_STATE='attached'
  if ! validate_mounted_chatgpt_source "$mounted_app" "$CHATGPT_BOOTSTRAP_MOUNT_DIR" \
    || ! validate_chatgpt_app "$mounted_app" "$EXPECTED_CODEX_TEAM_ID" "$CHATGPT_BUNDLE_ID" \
    || ! stage_verified_chatgpt_app "$mounted_app"; then
    cleanup_chatgpt_bootstrap || true
    return 1
  fi
  if ! cleanup_chatgpt_mount; then
    cleanup_chatgpt_bootstrap || true
    return 1
  fi
  if ! install_verified_chatgpt_app \
    "$CHATGPT_BOOTSTRAP_TEMP_DIR/ChatGPT.app" \
    "$CHATGPT_APP_PATH" \
    "$helper_path"; then
    cleanup_chatgpt_bootstrap || true
    return 1
  fi
  cleanup_chatgpt_bootstrap
}

download_release_assets() {
  local destination="$1"
  local curl_bin="${CC_SWITCH_CURL_BIN:-/usr/bin/curl}"
  local base_url="https://github.com/${RELEASE_REPOSITORY}/releases/download/${RELEASE_TAG}"
  local asset

  if [[ ! -x "$curl_bin" ]]; then
    die "curl command not found: $curl_bin"
    return 1
  fi
  if ! mkdir -p "$destination"; then
    die "failed to create release download directory: $destination"
    return 1
  fi
  for asset in "$INSTALLER_ASSET" "$APP_ASSET" "$RESOURCES_ASSET" "$CHECKSUM_ASSET"; do
    if ! "$curl_bin" \
      --fail \
      --location \
      --silent \
      --show-error \
      --retry 3 \
      --retry-all-errors \
      --output "$destination/$asset" \
      "$base_url/$asset"; then
      die "failed to download release asset: $asset"
      return 1
    fi
  done
}

verify_release_assets() {
  local asset_dir="$1"
  local checksum_file="$asset_dir/$CHECKSUM_ASSET"
  local shasum_bin="${CC_SWITCH_SHASUM_BIN:-/usr/bin/shasum}"
  local asset
  local line_count
  local count

  if [[ ! -f "$checksum_file" ]]; then
    die "release checksum file is missing"
    return 1
  fi
  if [[ ! -x "$shasum_bin" ]]; then
    die "shasum command not found: $shasum_bin"
    return 1
  fi

  line_count="$(awk 'NF { count += 1 } END { print count + 0 }' "$checksum_file")"
  if [[ "$line_count" != "3" ]]; then
    die "checksum file must contain exactly three entries"
    return 1
  fi

  if ! awk '
    NF != 2 { exit 1 }
    length($1) != 64 || $1 !~ /^[0-9a-f]+$/ { exit 1 }
    $2 ~ /\// { exit 1 }
  ' "$checksum_file"; then
    die "checksum file has an invalid entry"
    return 1
  fi

  for asset in "$INSTALLER_ASSET" "$APP_ASSET" "$RESOURCES_ASSET"; do
    if [[ ! -f "$asset_dir/$asset" ]]; then
      die "release asset is missing: $asset"
      return 1
    fi
    count="$(awk -v name="$asset" '$2 == name { count += 1 } END { print count + 0 }' "$checksum_file")"
    if [[ "$count" != "1" ]]; then
      die "checksum file must contain exactly one entry for $asset"
      return 1
    fi
  done

  if ! (
    cd "$asset_dir"
    "$shasum_bin" -a 256 -c "$CHECKSUM_ASSET" >/dev/null
  ); then
    die "release asset checksum verification failed"
    return 1
  fi
}

validate_archive_entry() {
  local entry="$1"

  if [[ -z "$entry" || "$entry" == /* ]]; then
    die "unsafe archive entry: $entry"
    return 1
  fi
  case "/$entry/" in
    */../*)
      die "unsafe archive entry: $entry"
      return 1
      ;;
  esac
}

expected_resource_archive_entries() {
  cat <<'EOF'
modelhub-installer/
modelhub-installer/assets/
modelhub-installer/assets/models-modelhub-1m.json
modelhub-installer/golden/
modelhub-installer/golden/cc-switch.db
modelhub-installer/golden/codex-config.toml
modelhub-installer/golden/settings.json
modelhub-installer/helpers/
modelhub-installer/helpers/rename-exclusive
modelhub-installer/templates/
modelhub-installer/templates/com.ccswitch.modelhub-env.plist
modelhub-installer/templates/codex-managed-config.toml
modelhub-installer/templates/load-modelhub-env.sh
modelhub-installer/templates/modelhub-provider-meta.json
modelhub-installer/templates/modelhub-provider.toml
EOF
}

validate_golden_codex_template() {
  local file="$1"
  local placeholder_count

  if [[ ! -f "$file" || -L "$file" ]]; then
    die "golden Codex config is missing or unsafe: $file"
    return 1
  fi
  placeholder_count="$(awk '{ count += gsub(/__USER_HOME__/, "") } END { print count + 0 }' "$file")"
  if [[ "$placeholder_count" -lt 1 ]] \
    || ! grep -Fq -- 'model_provider = "modelhub"' "$file" \
    || ! grep -Fq -- 'base_url = "https://aidp.bytedance.net/api/modelhub/online"' "$file" \
    || ! grep -Fq -- 'env_key = "MODELHUB_AK"' "$file" \
    || ! grep -Fq -- 'request_max_retries = 2' "$file" \
    || ! grep -Fq -- 'stream_max_retries = 3' "$file"; then
    die 'golden Codex config does not match the portable ModelHub contract'
    return 1
  fi
  if LC_ALL=C grep -E -i -q \
    '/Users/|127[.]0[.]0[.]1:15721|localhost:15721|experimental_bearer_token|OPENAI_API_KEY|access_token|refresh_token|id_token|^[[:space:]]*retry_429[[:space:]]*=' \
    "$file"; then
    die 'golden Codex config contains a forbidden path, route, or credential field'
    return 1
  fi
}

validate_golden_settings() {
  local file="$1"
  local valid

  if [[ ! -f "$file" || -L "$file" ]]; then
    die "golden CC Switch settings are missing or unsafe: $file"
    return 1
  fi
  valid="$(/usr/bin/jq -r '
    .currentProviderCodex == "bytedance-modelhub-official-cli"
    and .enableLocalProxy == true
    and .preserveCodexOfficialAuthOnSwitch == true
    and .firstRunNoticeConfirmed == true
    and .proxyConfirmed == true
  ' "$file" 2>/dev/null)" || return 1
  if [[ "$valid" != 'true' ]]; then
    die 'golden CC Switch settings do not match the public allowlist'
    return 1
  fi
}

golden_sqlite_scalar() {
  local database="$1"
  local query="$2"
  /usr/bin/sqlite3 -readonly "$database" "$query" 2>/dev/null
}

validate_golden_database() {
  local database="$1"
  local raw_strings
  local table

  if [[ ! -f "$database" || -L "$database" ]]; then
    die "golden CC Switch database is missing or unsafe: $database"
    return 1
  fi
  [[ "$(golden_sqlite_scalar "$database" 'PRAGMA integrity_check;')" == 'ok' ]] \
    || { die 'golden CC Switch database integrity check failed'; return 1; }
  [[ "$(golden_sqlite_scalar "$database" 'PRAGMA user_version;')" == '16' ]] \
    || { die 'golden CC Switch database schema version is not 16'; return 1; }
  [[ "$(golden_sqlite_scalar "$database" "SELECT count(*) FROM providers WHERE id='bytedance-modelhub-official-cli' AND app_type='codex' AND is_current=1;")" == '1' ]] \
    || { die 'golden CC Switch database current provider is invalid'; return 1; }
  [[ "$(golden_sqlite_scalar "$database" "SELECT COALESCE(SUM(CASE WHEN json_type(settings_config, '$.auth')='object' THEN json_array_length(json_extract(settings_config, '$.auth')) ELSE 0 END),0) FROM providers;")" == '0' ]] \
    || { die 'golden CC Switch provider auth objects must be empty'; return 1; }
  [[ "$(golden_sqlite_scalar "$database" "SELECT instr(json_extract(settings_config, '$.config'), 'https://aidp.bytedance.net/api/modelhub/online') > 0 FROM providers WHERE id='bytedance-modelhub-official-cli' AND app_type='codex';")" == '1' ]] \
    || { die 'golden CC Switch provider omits the ModelHub upstream'; return 1; }
  [[ "$(golden_sqlite_scalar "$database" "SELECT instr(json_extract(settings_config, '$.config'), '127.0.0.1:15721') FROM providers WHERE id='bytedance-modelhub-official-cli' AND app_type='codex';")" == '0' ]] \
    || { die 'golden CC Switch provider points to the local proxy'; return 1; }
  [[ "$(golden_sqlite_scalar "$database" "SELECT count(*) FROM providers WHERE id='bytedance-modelhub-official-cli' AND app_type='codex' AND json_type(meta, '$.localProxyRequestOverrides.blockCodexActivitySummaries') IS NULL AND json_type(meta, '$.localProxyRequestOverrides.codexActivitySummaryMode')='text' AND json_extract(meta, '$.localProxyRequestOverrides.codexActivitySummaryMode')='map';")" == '1' ]] \
    || { die 'golden CC Switch provider activity summary mode is invalid'; return 1; }
  [[ "$(golden_sqlite_scalar "$database" "SELECT count(*) FROM providers WHERE id='bytedance-modelhub-official-cli' AND app_type='codex' AND json_type(meta, '$.localProxyRequestOverrides.codexMetadataModel')='text' AND json_extract(meta, '$.localProxyRequestOverrides.codexMetadataModel')='gpt-5.6-sol';")" == '1' ]] \
    || { die 'golden CC Switch provider metadata model is invalid'; return 1; }
  [[ "$(golden_sqlite_scalar "$database" "SELECT count(*) FROM providers WHERE id='bytedance-modelhub-official-cli' AND app_type='codex' AND json_type(meta, '$.localProxyRequestOverrides.rememberInvalidEncryptedReasoning')='true' AND json_extract(meta, '$.localProxyRequestOverrides.rememberInvalidEncryptedReasoning')=1;")" == '1' ]] \
    || { die 'golden CC Switch provider encrypted reasoning memory is invalid'; return 1; }
  [[ "$(golden_sqlite_scalar "$database" "SELECT count(*) FROM providers WHERE id='bytedance-modelhub-official-cli' AND app_type='codex' AND json_extract(meta, '$.localProxyRequestOverrides.retry429.maxRetries')=2 AND json_extract(meta, '$.localProxyRequestOverrides.retry429.baseDelayMs')=2000 AND json_extract(meta, '$.localProxyRequestOverrides.retry429.maxDelayMs')=30000 AND json_extract(meta, '$.localProxyRequestOverrides.retry429.honorRetryAfter')=1;")" == '1' ]] \
    || { die 'golden CC Switch provider 429 retry policy is invalid'; return 1; }
  [[ "$(golden_sqlite_scalar "$database" "SELECT proxy_enabled || ':' || enabled || ':' || auto_failover_enabled || ':' || listen_address || ':' || listen_port FROM proxy_config WHERE app_type='codex';")" == '1:1:0:127.0.0.1:15721' ]] \
    || { die 'golden CC Switch proxy state is invalid'; return 1; }
  for table in \
    provider_health proxy_live_backup proxy_request_logs session_log_sync \
    stream_check_logs usage_daily_rollups; do
    [[ "$(golden_sqlite_scalar "$database" "SELECT count(*) FROM $table;")" == '0' ]] \
      || { die "golden CC Switch database contains forbidden rows in $table"; return 1; }
  done
  raw_strings="$(/usr/bin/strings "$database")"
  if printf '%s\n' "$raw_strings" | LC_ALL=C grep -E -i -q \
    '/Users/|experimental_bearer_token|OPENAI_API_KEY|access_token|refresh_token|id_token'; then
    die 'golden CC Switch database contains a forbidden path or credential field'
    return 1
  fi
}

validate_resource_archive() {
  local archive="$1"
  local work_dir
  local listing
  local sorted_listing
  local expected_listing
  local verbose_listing
  local entry
  local extracted_dir

  if [[ ! -f "$archive" ]]; then
    die "resource archive does not exist: $archive"
    return 1
  fi

  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/cc-switch-archive-check.XXXXXX")"
  listing="$work_dir/listing.txt"
  sorted_listing="$work_dir/listing.sorted.txt"
  expected_listing="$work_dir/expected.sorted.txt"
  verbose_listing="$work_dir/verbose.txt"

  if ! tar -tzf "$archive" >"$listing"; then
    rm -rf "$work_dir"
    die "resource archive cannot be listed"
    return 1
  fi
  while IFS= read -r entry || [[ -n "$entry" ]]; do
    if ! validate_archive_entry "$entry"; then
      rm -rf "$work_dir"
      return 1
    fi
  done <"$listing"

  if ! tar -tvzf "$archive" >"$verbose_listing"; then
    rm -rf "$work_dir"
    die "resource archive metadata cannot be listed"
    return 1
  fi
  if awk '$1 !~ /^[d-]/ || / link to / { found = 1 } END { exit(found ? 0 : 1) }' "$verbose_listing"; then
    rm -rf "$work_dir"
    die "resource archive contains a link or special file"
    return 1
  fi

  LC_ALL=C sort "$listing" >"$sorted_listing"
  expected_resource_archive_entries | LC_ALL=C sort >"$expected_listing"
  if ! diff -u "$expected_listing" "$sorted_listing" >/dev/null; then
    rm -rf "$work_dir"
    die "resource archive does not match the public allowlist"
    return 1
  fi

  extracted_dir="$work_dir/extracted"
  if ! mkdir -p "$extracted_dir" \
    || ! tar -xzf "$archive" -C "$extracted_dir"; then
    rm -rf "$work_dir"
    die 'resource archive cannot be extracted for golden validation'
    return 1
  fi
  validate_golden_codex_template \
    "$extracted_dir/modelhub-installer/golden/codex-config.toml" \
    || { rm -rf "$work_dir"; return 1; }
  validate_golden_settings \
    "$extracted_dir/modelhub-installer/golden/settings.json" \
    || { rm -rf "$work_dir"; return 1; }
  validate_golden_database \
    "$extracted_dir/modelhub-installer/golden/cc-switch.db" \
    || { rm -rf "$work_dir"; return 1; }
  validate_codex_managed_config \
    "$extracted_dir/modelhub-installer/templates/codex-managed-config.toml" \
    || { rm -rf "$work_dir"; return 1; }

  rm -rf "$work_dir"
}

validate_provider_id() {
  local provider_id="$1"
  case "$provider_id" in
    ""|*[!A-Za-z0-9._-]*)
      die "unsafe provider ID: $provider_id"
      return 1
      ;;
  esac
}

sql_quote() {
  local value="$1"
  local escaped

  case "$value" in
    *$'\n'*|*$'\r'*)
      die "SQL value contains a newline"
      return 1
      ;;
  esac
  escaped="$(printf '%s' "$value" | sed "s/'/''/g")"
  printf "'%s'" "$escaped"
}

cc_switch_schema_ready() {
  local database="$1"
  local sqlite_bin="${CC_SWITCH_SQLITE3_BIN:-/usr/bin/sqlite3}"
  local table_name
  local column_name
  local count

  [[ -f "$database" && -x "$sqlite_bin" ]] || return 1

  while IFS=: read -r table_name column_name; do
    if ! count="$(
      "$sqlite_bin" "$database" \
        "SELECT count(*) FROM pragma_table_info('$table_name') WHERE name='$column_name';" \
        2>/dev/null
    )"; then
      return 1
    fi
    [[ "$count" == "1" ]] || return 1
  done <<'EOF'
providers:id
providers:app_type
providers:name
providers:settings_config
providers:website_url
providers:category
providers:created_at
providers:notes
providers:icon
providers:meta
providers:is_current
providers:in_failover_queue
proxy_config:app_type
proxy_config:proxy_enabled
proxy_config:enabled
proxy_config:auto_failover_enabled
proxy_config:listen_address
proxy_config:listen_port
proxy_config:enable_logging
proxy_config:updated_at
EOF

  if ! count="$(
    "$sqlite_bin" "$database" \
      "SELECT count(*)
         FROM pragma_index_list('providers') AS indexes
        WHERE indexes.\"unique\" = 1
          AND (SELECT group_concat(name, ',')
                 FROM pragma_index_info(indexes.name)) = 'id,app_type';" \
      2>/dev/null
  )"; then
    return 1
  fi
  [[ "$count" == "1" ]] || return 1
}

ensure_cc_switch_schema() {
  local database="$1"
  local app_path="$2"
  local open_bin="${CC_SWITCH_OPEN_BIN:-/usr/bin/open}"
  local osascript_bin="${CC_SWITCH_OSASCRIPT_BIN:-/usr/bin/osascript}"
  local sleep_bin="${CC_SWITCH_SLEEP_BIN:-/bin/sleep}"
  local attempt

  if cc_switch_schema_ready "$database"; then
    return 0
  fi
  if [[ ! -d "$app_path" ]]; then
    die "CC Switch app is unavailable for database initialization: $app_path"
    return 1
  fi
  if [[ ! -x "$open_bin" || ! -x "$osascript_bin" || ! -x "$sleep_bin" ]]; then
    die "required application initialization command is unavailable"
    return 1
  fi

  if ! "$open_bin" -gj "$app_path"; then
    die "failed to start CC Switch for database initialization"
    return 1
  fi

  attempt=1
  while [[ "$attempt" -le 30 ]]; do
    if cc_switch_schema_ready "$database"; then
      "$osascript_bin" -e 'quit app "CC Switch"' >/dev/null 2>&1 || true
      return 0
    fi
    "$sleep_bin" 1
    attempt=$((attempt + 1))
  done

  "$osascript_bin" -e 'quit app "CC Switch"' >/dev/null 2>&1 || true
  die "CC Switch database schema was not initialized within 30 seconds"
  return 1
}

merge_provider_database() {
  local database="$1"
  local config_path="$2"
  local meta_path="$3"
  local sqlite_bin="${CC_SWITCH_SQLITE3_BIN:-/usr/bin/sqlite3}"
  local provider_id
  local database_sql
  local config_sql
  local meta_sql
  local provider_id_sql
  local meta_valid
  local count

  if ! cc_switch_schema_ready "$database"; then
    die "CC Switch database schema is not ready: $database"
    return 1
  fi
  if [[ ! -f "$config_path" || ! -f "$meta_path" ]]; then
    die "ModelHub provider config or metadata is missing"
    return 1
  fi

  meta_sql="$(sql_quote "$meta_path")"
  if ! meta_valid="$(
    "$sqlite_bin" :memory: \
      "SELECT json_valid(CAST(readfile($meta_sql) AS TEXT));" \
      2>/dev/null
  )"; then
    die "unable to validate ModelHub provider metadata"
    return 1
  fi
  if [[ "$meta_valid" != "1" ]]; then
    die "ModelHub provider metadata is not valid JSON"
    return 1
  fi

  if ! provider_id="$(
    "$sqlite_bin" "$database" \
      "SELECT id FROM providers WHERE app_type='codex' AND name='$MODELHUB_PROVIDER_NAME' ORDER BY is_current DESC, created_at DESC LIMIT 1;"
  )"; then
    die "unable to query existing ModelHub provider"
    return 1
  fi
  if [[ -z "$provider_id" ]]; then
    if ! count="$(
      "$sqlite_bin" "$database" \
        "SELECT count(*) FROM providers WHERE id='$MODELHUB_PROVIDER_ID' AND app_type='codex';"
    )"; then
      die "unable to check the fixed ModelHub provider ID"
      return 1
    fi
    if [[ "$count" != "0" ]]; then
      die "the fixed ModelHub provider ID is already used by a different Codex provider"
      return 1
    fi
    provider_id="$MODELHUB_PROVIDER_ID"
  fi
  validate_provider_id "$provider_id" || return 1

  database_sql="$(sql_quote "$database")"
  config_sql="$(sql_quote "$config_path")"
  provider_id_sql="$(sql_quote "$provider_id")"

  if ! "$sqlite_bin" "$database" <<SQL
BEGIN IMMEDIATE;
UPDATE providers SET is_current = 0 WHERE app_type = 'codex';
INSERT INTO providers (
  id, app_type, name, settings_config, website_url, category,
  notes, icon, meta, is_current, in_failover_queue
) VALUES (
  $provider_id_sql,
  'codex',
  '$MODELHUB_PROVIDER_NAME',
  json_object('auth', json('{}'), 'config', CAST(readfile($config_sql) AS TEXT)),
  'https://aidp.bytedance.net',
  'third_party',
  'ModelHub Responses via official ChatGPT Codex CLI',
  'openai',
  CAST(readfile($meta_sql) AS TEXT),
  1,
  0
)
ON CONFLICT(id, app_type) DO UPDATE SET
  name = excluded.name,
  settings_config = excluded.settings_config,
  website_url = excluded.website_url,
  category = excluded.category,
  notes = excluded.notes,
  icon = excluded.icon,
  meta = excluded.meta,
  is_current = 1,
  in_failover_queue = 0;

INSERT INTO proxy_config (
  app_type, proxy_enabled, listen_address, listen_port,
  enable_logging, enabled, auto_failover_enabled
) VALUES (
  'codex', 1, '127.0.0.1', 15721, 1, 1, 0
)
ON CONFLICT(app_type) DO UPDATE SET
  proxy_enabled = 1,
  listen_address = '127.0.0.1',
  listen_port = 15721,
  enable_logging = 1,
  enabled = 1,
  auto_failover_enabled = 0,
  updated_at = datetime('now');
COMMIT;
SQL
  then
    die "failed to merge ModelHub provider into CC Switch database: $database_sql"
    return 1
  fi

  printf '%s' "$provider_id"
}

plutil_set_value() {
  local plutil_bin="$1"
  local file="$2"
  local key="$3"
  local type_flag="$4"
  local value="$5"

  if "$plutil_bin" -replace "$key" "$type_flag" "$value" "$file" >/dev/null 2>&1; then
    return 0
  fi
  "$plutil_bin" -insert "$key" "$type_flag" "$value" "$file" >/dev/null
}

update_settings_json() {
  local settings_path="$1"
  local provider_id="$2"
  local plutil_bin="${CC_SWITCH_PLUTIL_BIN:-/usr/bin/plutil}"
  local work_dir
  local work_file

  validate_provider_id "$provider_id" || return 1
  if [[ ! -x "$plutil_bin" ]]; then
    die "plutil command not found: $plutil_bin"
    return 1
  fi

  if ! mkdir -p "$(dirname "$settings_path")"; then
    die "failed to create the CC Switch settings directory"
    return 1
  fi
  if ! work_dir="$(mktemp -d "$(dirname "$settings_path")/.cc-switch-settings.XXXXXX")"; then
    die "failed to create the CC Switch settings staging directory"
    return 1
  fi
  work_file="$work_dir/settings.json"
  if [[ -f "$settings_path" ]]; then
    if ! "$plutil_bin" -convert xml1 -o /dev/null "$settings_path" >/dev/null 2>&1; then
      rm -rf "$work_dir"
      die "CC Switch settings file is not valid JSON: $settings_path"
      return 1
    fi
    if ! cp -p "$settings_path" "$work_file"; then
      rm -rf "$work_dir" || true
      die "failed to stage CC Switch settings"
      return 1
    fi
  else
    if ! printf '{\n  "currentProviderCodex": "%s",\n  "enableLocalProxy": true,\n  "preserveCodexOfficialAuthOnSwitch": true\n}\n' \
      "$provider_id" \
      >"$work_file"; then
      rm -rf "$work_dir" || true
      die "failed to stage new CC Switch settings"
      return 1
    fi
    if ! "$plutil_bin" -convert xml1 -o /dev/null "$work_file" >/dev/null 2>&1; then
      rm -rf "$work_dir"
      die "failed to create CC Switch settings"
      return 1
    fi
    if ! mv "$work_file" "$settings_path"; then
      rm -rf "$work_dir" || true
      die "failed to install new CC Switch settings"
      return 1
    fi
    if ! rmdir "$work_dir"; then
      die "failed to remove the CC Switch settings staging directory"
      return 1
    fi
    return 0
  fi

  if ! plutil_set_value "$plutil_bin" "$work_file" currentProviderCodex -string "$provider_id" \
    || ! plutil_set_value "$plutil_bin" "$work_file" enableLocalProxy -bool true \
    || ! plutil_set_value "$plutil_bin" "$work_file" preserveCodexOfficialAuthOnSwitch -bool true \
    || ! "$plutil_bin" -convert xml1 -o /dev/null "$work_file" >/dev/null 2>&1; then
    rm -rf "$work_dir"
    die "failed to update CC Switch settings"
    return 1
  fi

  if ! mv "$work_file" "$settings_path"; then
    rm -rf "$work_dir" || true
    die "failed to install updated CC Switch settings"
    return 1
  fi
  if ! rmdir "$work_dir"; then
    die "failed to remove the CC Switch settings staging directory"
    return 1
  fi
}

toml_escape_basic_string() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

render_template() {
  local source_file="$1"
  local output_file="$2"
  local placeholder="$3"
  local replacement="$4"
  local line

  if [[ ! -f "$source_file" ]]; then
    die "template does not exist: $source_file"
    return 1
  fi
  if [[ -z "$placeholder" ]]; then
    die "template placeholder must not be empty"
    return 1
  fi

  if ! : >"$output_file"; then
    die "failed to create rendered template: $output_file"
    return 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    if ! printf '%s\n' "${line//$placeholder/$replacement}" >>"$output_file"; then
      die "failed to render template: $source_file"
      return 1
    fi
  done <"$source_file"
}

managed_root_key_count() {
  local file="$1"
  local key="$2"

  awk -v key="$key" '
    BEGIN { in_root = 1; count = 0 }
    /^[[:space:]]*\[/ { in_root = 0 }
    in_root && $0 ~ ("^[[:space:]]*" key "[[:space:]]*=") { count += 1 }
    END { print count }
  ' "$file"
}

toml_header_kind() {
  awk '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }

    function without_comment(value,    output, position, char, quote, escaped) {
      output = ""
      quote = ""
      escaped = 0
      for (position = 1; position <= length(value); position += 1) {
        char = substr(value, position, 1)
        if (quote == "\"") {
          output = output char
          if (escaped) {
            escaped = 0
          } else if (char == "\\") {
            escaped = 1
          } else if (char == "\"") {
            quote = ""
          }
          continue
        }
        if (quote == "\047") {
          output = output char
          if (char == "\047") {
            quote = ""
          }
          continue
        }
        if (char == "#") {
          break
        }
        if (char == "\"" || char == "\047") {
          quote = char
        }
        output = output char
      }
      return output
    }

    function compact_unquoted(value,    output, position, char, quote, escaped) {
      output = ""
      quote = ""
      escaped = 0
      for (position = 1; position <= length(value); position += 1) {
        char = substr(value, position, 1)
        if (quote == "\"") {
          output = output char
          if (escaped) {
            escaped = 0
          } else if (char == "\\") {
            escaped = 1
          } else if (char == "\"") {
            quote = ""
          }
          continue
        }
        if (quote == "\047") {
          output = output char
          if (char == "\047") {
            quote = ""
          }
          continue
        }
        if (char == "\"" || char == "\047") {
          quote = char
          output = output char
        } else if (char !~ /[[:space:]]/) {
          output = output char
        }
      }
      return output
    }

    function unquote(value,    first, last) {
      first = substr(value, 1, 1)
      last = substr(value, length(value), 1)
      if ((first == "\"" && last == "\"") || (first == "\047" && last == "\047")) {
        return substr(value, 2, length(value) - 2)
      }
      return value
    }

    {
      header = trim(without_comment($0))
      if (substr(header, 1, 1) != "[") {
        print "none"
        exit
      }
      if (substr(header, 1, 2) == "[[" || substr(header, length(header), 1) != "]") {
        print "table"
        exit
      }
      header = compact_unquoted(substr(header, 2, length(header) - 2))
      count = split(header, parts, ".")
      if (count == 1 && unquote(parts[1]) == "desktop") {
        print "desktop"
      } else if (count >= 2 && unquote(parts[1]) == "model_providers" && unquote(parts[2]) == "modelhub") {
        if (count == 2) {
          print "modelhub"
        } else {
          print "modelhub-child"
        }
      } else if (count >= 2 && unquote(parts[1]) == "model_providers" && unquote(parts[2]) == "openai") {
        if (count == 2) {
          print "openai-provider"
        } else {
          print "openai-provider-child"
        }
      } else {
        print "table"
      }
    }
  '
}

modelhub_section_count() {
  local file="$1"
  local line
  local kind
  local count=0

  while IFS= read -r line || [[ -n "$line" ]]; do
    kind="$(printf '%s\n' "$line" | toml_header_kind)" || return 1
    if [[ "$kind" == "modelhub" ]]; then
      count=$((count + 1))
    fi
  done <"$file"
  printf '%s' "$count"
}

desktop_section_count() {
  local file="$1"
  local line
  local kind
  local count=0

  while IFS= read -r line || [[ -n "$line" ]]; do
    kind="$(printf '%s\n' "$line" | toml_header_kind)" || return 1
    if [[ "$kind" == "desktop" ]]; then
      count=$((count + 1))
    fi
  done <"$file"
  printf '%s' "$count"
}

managed_root_equivalent_key_count() {
  local file="$1"
  local key="$2"

  awk -v key="$key" '
    BEGIN { in_root = 1; count = 0 }
    /^[[:space:]]*\[/ { in_root = 0 }
    in_root {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      if (line ~ ("^" key "[[:space:]]*=") \
          || line ~ ("^\"" key "\"[[:space:]]*=") \
          || line ~ ("^\047" key "\047[[:space:]]*=")) {
        count += 1
      }
    }
    END { print count }
  ' "$file"
}

validate_codex_managed_config() {
  local file="$1"
  local line
  local kind

  if [[ ! -f "$file" ]]; then
    die "Codex managed config does not exist: $file"
    return 1
  fi
  if [[ "$(managed_root_equivalent_key_count "$file" model_provider)" != "1" ]] \
    || [[ "$(managed_root_equivalent_key_count "$file" openai_base_url)" != "1" ]]; then
    die 'Codex managed config must contain one entry for each managed root key'
    return 1
  fi
  if ! grep -Eq '^[[:space:]]*model_provider[[:space:]]*=[[:space:]]*"modelhub"[[:space:]]*$' "$file" \
    || ! grep -Eq '^[[:space:]]*openai_base_url[[:space:]]*=[[:space:]]*"http://127\.0\.0\.1:15721/v1"[[:space:]]*$' "$file"; then
    die 'Codex managed config contains an unexpected routing value'
    return 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    kind="$(printf '%s\n' "$line" | toml_header_kind)" || return 1
    case "$kind" in
      openai-provider|openai-provider-child)
        die 'Codex built-in openai provider must not be overridden'
        return 1
        ;;
    esac
  done <"$file"
  validate_codex_config_with_parser "$file"
}

merge_codex_managed_config() {
  local source_file="$1"
  local template_file="$2"
  local output_file="$3"
  local effective_source="$source_file"
  local work_dir
  local filtered_root
  local tables
  local merged
  local line
  local in_root=1

  if [[ ! -f "$template_file" ]]; then
    die "Codex managed config template does not exist: $template_file"
    return 1
  fi
  validate_codex_managed_config "$template_file" || return 1
  if [[ ! -f "$effective_source" ]]; then
    effective_source=/dev/null
  fi
  if ! work_dir="$(mktemp -d "${TMPDIR:-/tmp}/cc-switch-managed-config-merge.XXXXXX")"; then
    die 'failed to create the Codex managed config merge directory'
    return 1
  fi
  filtered_root="$work_dir/root.toml"
  tables="$work_dir/tables.toml"
  merged="$work_dir/managed_config.toml"
  : >"$filtered_root" || return 1
  : >"$tables" || return 1

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$in_root" == "1" && "$line" =~ ^[[:space:]]*\[ ]]; then
      in_root=0
    fi
    if [[ "$in_root" == "1" ]] \
      && [[ "$line" =~ ^[[:space:]]*(model_provider|\"model_provider\"|\'model_provider\')[[:space:]]*= \
        || "$line" =~ ^[[:space:]]*(openai_base_url|\"openai_base_url\"|\'openai_base_url\')[[:space:]]*= ]]; then
      continue
    fi
    if [[ "$in_root" == "1" ]]; then
      printf '%s\n' "$line" >>"$filtered_root" || return 1
    else
      printf '%s\n' "$line" >>"$tables" || return 1
    fi
  done <"$effective_source"

  if ! /bin/cp "$filtered_root" "$merged" \
    || ! /bin/cat "$template_file" >>"$merged"; then
    /bin/rm -rf "$work_dir" || true
    die 'failed to stage the Codex managed config roots'
    return 1
  fi
  if [[ -s "$tables" ]]; then
    printf '\n' >>"$merged" || return 1
    /bin/cat "$tables" >>"$merged" || return 1
  fi
  validate_codex_managed_config "$merged" || {
    /bin/rm -rf "$work_dir" || true
    return 1
  }
  /bin/mkdir -p "$(dirname "$output_file")" || return 1
  if ! /bin/mv "$merged" "$output_file"; then
    /bin/rm -rf "$work_dir" || true
    die 'failed to write the merged Codex managed config'
    return 1
  fi
  /bin/rm -rf "$work_dir" || return 1
}

validate_codex_config_with_parser() {
  local file="$1"
  local validator="${CC_SWITCH_CODEX_CONFIG_VALIDATOR:-${CHATGPT_CODEX_PATH:-}}"
  local parser_home

  [[ -n "$validator" ]] || return 0
  if [[ ! -x "$validator" ]]; then
    die "Codex config validator is unavailable: $validator"
    return 1
  fi
  if ! parser_home="$(mktemp -d "${TMPDIR:-/tmp}/cc-switch-codex-parse.XXXXXX")"; then
    die "failed to create a private Codex config validation directory"
    return 1
  fi
  if ! /bin/cp -p "$file" "$parser_home/config.toml"; then
    /bin/rm -rf "$parser_home" || true
    die "failed to stage Codex config for parser validation"
    return 1
  fi
  if ! CODEX_HOME="$parser_home" "$validator" features list >/dev/null 2>&1; then
    /bin/rm -rf "$parser_home" || true
    die "merged Codex config failed parser validation"
    return 1
  fi
  if ! /bin/rm -rf "$parser_home"; then
    die "failed to remove the Codex config validation directory"
    return 1
  fi
}

validate_merged_codex_config() {
  local file="$1"
  local user_home="$2"
  local escaped_home
  local key
  local count
  local section_count
  local desktop_count

  if [[ ! -f "$file" ]]; then
    die "merged Codex config does not exist: $file"
    return 1
  fi
  escaped_home="$(toml_escape_basic_string "$user_home")"

  for key in \
    model \
    review_model \
    model_provider \
    model_reasoning_effort \
    model_auto_compact_token_limit \
    model_context_window \
    model_catalog_json; do
    count="$(managed_root_key_count "$file" "$key")"
    if [[ "$count" != "1" ]]; then
      die "expected one top-level $key entry, found $count"
      return 1
    fi
  done

  section_count="$(modelhub_section_count "$file")" || return 1
  if [[ "$section_count" != "1" ]]; then
    die "expected one $MODELHUB_SECTION section, found $section_count"
    return 1
  fi
  desktop_count="$(desktop_section_count "$file")" || return 1
  if [[ "$desktop_count" != "1" ]]; then
    die "expected one [desktop] section, found $desktop_count"
    return 1
  fi
  if [[ "$(grep -Ec '^[[:space:]]*git-branch-prefix[[:space:]]*=[[:space:]]*"feat/"[[:space:]]*$' "$file")" != "1" ]]; then
    die 'merged Codex config must contain one feat/ Git branch prefix'
    return 1
  fi

  if grep -Fq -- '__USER_HOME__' "$file"; then
    die "unresolved __USER_HOME__ placeholder in merged Codex config"
    return 1
  fi
  if ! grep -Fq -- "model_catalog_json = \"$escaped_home/.codex/models-modelhub-1m.json\"" "$file"; then
    die "merged Codex config does not reference the target user's model catalog"
    return 1
  fi
  if ! grep -Fq -- 'base_url = "https://aidp.bytedance.net/api/modelhub/online"' "$file"; then
    die "merged Codex config does not contain the ModelHub endpoint"
    return 1
  fi
  validate_codex_config_with_parser "$file"
}

merge_codex_config() {
  local source_file="$1"
  local template_file="$2"
  local output_file="$3"
  local user_home="$4"
  local escaped_home
  local effective_source
  local work_dir
  local rendered_template
  local filtered_source
  local merged_file
  local line
  local header_kind
  local in_root=1
  local skip_modelhub=0
  local in_desktop=0
  local saw_desktop=0

  if [[ ! -f "$template_file" ]]; then
    die "ModelHub template does not exist: $template_file"
    return 1
  fi
  if ! work_dir="$(mktemp -d "${TMPDIR:-/tmp}/cc-switch-config-merge.XXXXXX")"; then
    die "failed to create the Codex config merge directory"
    return 1
  fi
  rendered_template="$work_dir/rendered-template.toml"
  filtered_source="$work_dir/filtered-source.toml"
  merged_file="$work_dir/merged.toml"
  escaped_home="$(toml_escape_basic_string "$user_home")"
  effective_source="$source_file"
  if [[ ! -f "$effective_source" ]]; then
    effective_source=/dev/null
  fi

  render_template "$template_file" "$rendered_template" '__USER_HOME__' "$escaped_home" || {
    /bin/rm -rf "$work_dir" || true
    return 1
  }

  if ! : >"$filtered_source"; then
    /bin/rm -rf "$work_dir" || true
    die "failed to stage filtered Codex config"
    return 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    header_kind="$(printf '%s\n' "$line" | toml_header_kind)" || {
      /bin/rm -rf "$work_dir" || true
      return 1
    }
    case "$header_kind" in
      modelhub|modelhub-child)
        if [[ "$in_desktop" == "1" ]]; then
          printf '%s\n' 'git-branch-prefix = "feat/"' >>"$filtered_source" || return 1
        fi
        skip_modelhub=1
        in_root=0
        in_desktop=0
        continue
        ;;
      desktop)
        if [[ "$in_desktop" == "1" ]]; then
          printf '%s\n' 'git-branch-prefix = "feat/"' >>"$filtered_source" || return 1
        fi
        skip_modelhub=0
        in_root=0
        in_desktop=1
        saw_desktop=1
        ;;
      table|openai-provider|openai-provider-child)
        if [[ "$in_desktop" == "1" ]]; then
          printf '%s\n' 'git-branch-prefix = "feat/"' >>"$filtered_source" || return 1
        fi
        skip_modelhub=0
        in_root=0
        in_desktop=0
        ;;
    esac
    if [[ "$skip_modelhub" == "1" ]]; then
      continue
    fi
    if [[ "$in_desktop" == "1" ]] \
      && [[ "$line" =~ ^[[:space:]]*git-branch-prefix[[:space:]]*= ]]; then
      continue
    fi
    if [[ "$in_root" == "1" ]] \
      && [[ "$line" =~ ^[[:space:]]*(model|review_model|model_provider|model_reasoning_effort|model_auto_compact_token_limit|model_context_window|model_catalog_json)[[:space:]]*= ]]; then
      continue
    fi
    if ! printf '%s\n' "$line" >>"$filtered_source"; then
      /bin/rm -rf "$work_dir" || true
      die "failed to filter the existing Codex config"
      return 1
    fi
  done <"$effective_source"
  if [[ "$in_desktop" == "1" ]]; then
    printf '%s\n' 'git-branch-prefix = "feat/"' >>"$filtered_source" || return 1
  fi
  if [[ "$saw_desktop" == "0" ]]; then
    printf '%s\n' '[desktop]' 'git-branch-prefix = "feat/"' >>"$filtered_source" || return 1
  fi

  if ! awk '/^[[:space:]]*\[/ { exit } { print }' "$rendered_template" >"$merged_file"; then
    /bin/rm -rf "$work_dir" || true
    die "failed to stage managed Codex root fields"
    return 1
  fi
  if [[ -s "$filtered_source" ]]; then
    if ! printf '\n' >>"$merged_file" || ! cat "$filtered_source" >>"$merged_file"; then
      /bin/rm -rf "$work_dir" || true
      die "failed to append the existing Codex config"
      return 1
    fi
  fi
  if ! printf '\n' >>"$merged_file" \
    || ! awk -v section="$MODELHUB_SECTION" '$0 == section { emit = 1 } emit { print }' "$rendered_template" >>"$merged_file"; then
    /bin/rm -rf "$work_dir" || true
    die "failed to append the managed ModelHub table"
    return 1
  fi

  validate_merged_codex_config "$merged_file" "$user_home" || {
    /bin/rm -rf "$work_dir" || true
    return 1
  }
  if ! mkdir -p "$(dirname "$output_file")"; then
    /bin/rm -rf "$work_dir" || true
    die "failed to create the Codex config output directory"
    return 1
  fi
  if ! mv "$merged_file" "$output_file"; then
    /bin/rm -rf "$work_dir" || true
    die "failed to write the merged Codex config"
    return 1
  fi
  if ! rm -rf "$work_dir"; then
    die "failed to remove the Codex config merge directory"
    return 1
  fi
}

xml_escape() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  value="${value//\"/&quot;}"
  value="${value//\'/&apos;}"
  printf '%s' "$value"
}

configure_install_paths() {
  if [[ "${CC_SWITCH_INSTALLER_TEST_MODE:-0}" == "1" ]]; then
    INSTALL_USER_HOME="${CC_SWITCH_INSTALLER_TEST_HOME:?test home is required}"
    INSTALL_APPLICATIONS_DIR="${CC_SWITCH_INSTALLER_TEST_APPLICATIONS_DIR:?test Applications directory is required}"
  else
    INSTALL_USER_HOME="$HOME"
    INSTALL_APPLICATIONS_DIR='/Applications'
  fi

  if [[ "$INSTALL_USER_HOME" != /* || "$INSTALL_USER_HOME" == "/" ]]; then
    die "unsafe installer home path: $INSTALL_USER_HOME"
    return 1
  fi
  if [[ "$INSTALL_APPLICATIONS_DIR" != /* || "$INSTALL_APPLICATIONS_DIR" == "/" ]]; then
    die "unsafe Applications directory: $INSTALL_APPLICATIONS_DIR"
    return 1
  fi

  CC_SWITCH_APP_PATH="$INSTALL_APPLICATIONS_DIR/CC Switch.app"
  CHATGPT_APP_PATH="$INSTALL_APPLICATIONS_DIR/ChatGPT.app"
  CHATGPT_CODEX_PATH="$CHATGPT_APP_PATH/Contents/Resources/codex"
  CODEX_CONFIG_PATH="$INSTALL_USER_HOME/.codex/config.toml"
  MODEL_CATALOG_PATH="$INSTALL_USER_HOME/.codex/models-modelhub-1m.json"
  CC_SWITCH_DATABASE_PATH="$INSTALL_USER_HOME/.cc-switch/cc-switch.db"
  CC_SWITCH_SETTINGS_PATH="$INSTALL_USER_HOME/.cc-switch/settings.json"
  LAUNCH_AGENT_PATH="$INSTALL_USER_HOME/Library/LaunchAgents/com.ccswitch.modelhub-env.plist"
  ENV_HELPER_PATH="$INSTALL_USER_HOME/.local/share/cc-switch-modelhub/load-modelhub-env.sh"
  LOCAL_INSTALLER_PATH="$INSTALL_USER_HOME/.local/share/cc-switch-modelhub/install.sh"
  BACKUP_ROOT="$INSTALL_USER_HOME/.cc-switch/backups/modelhub-installer"
}

managed_targets() {
  printf '%s\t%s\n' "$CC_SWITCH_APP_PATH" 'cc-switch-app'
  printf '%s\t%s\n' "$CODEX_CONFIG_PATH" 'codex-config.toml'
  printf '%s\t%s\n' "$MODEL_CATALOG_PATH" 'models-modelhub-1m.json'
  printf '%s\t%s\n' "$CC_SWITCH_DATABASE_PATH" 'cc-switch.db'
  printf '%s\t%s\n' "$CC_SWITCH_SETTINGS_PATH" 'settings.json'
  printf '%s\t%s\n' "$LAUNCH_AGENT_PATH" 'com.ccswitch.modelhub-env.plist'
  printf '%s\t%s\n' "$ENV_HELPER_PATH" 'load-modelhub-env.sh'
}

is_managed_target() {
  local candidate="$1"
  local target
  local relative

  while IFS=$'\t' read -r target relative; do
    if [[ "$candidate" == "$target" ]]; then
      return 0
    fi
  done < <(managed_targets)
  return 1
}

managed_relative_for_target() {
  local candidate="$1"
  local target
  local relative

  while IFS=$'\t' read -r target relative; do
    if [[ "$candidate" == "$target" ]]; then
      printf '%s' "$relative"
      return 0
    fi
  done < <(managed_targets)
  return 1
}

sudo_command() {
  printf '%s' '/usr/bin/sudo'
}

validate_privileged_command() {
  local command_path="$1"

  case "$command_path" in
    /bin/chmod|/bin/cp|/bin/rm|/bin/test \
      |/usr/bin/codesign|/usr/bin/ditto|/usr/bin/file|/usr/bin/mktemp \
      |/usr/bin/plutil|/usr/bin/shasum|/usr/bin/stat|/usr/bin/xattr)
      return 0
      ;;
  esac
  if [[ -n "$CHATGPT_TRUSTED_HELPER_PATH" \
    && "$command_path" == "$CHATGPT_TRUSTED_HELPER_PATH" ]]; then
    return 0
  fi
  die "refusing to run a non-allowlisted command with administrator permission"
}

run_with_privilege() {
  local sudo_bin

  if [[ "$NEEDS_SUDO" == "1" ]]; then
    sudo_bin="$(sudo_command)"
    validate_privileged_command "$1" || return 1
    "$sudo_bin" "$@"
  else
    "$@"
  fi
}

remove_managed_target() {
  local target="$1"

  if ! is_managed_target "$target"; then
    die "refusing to remove unmanaged target: $target"
    return 1
  fi
  if [[ "$target" == "$CC_SWITCH_APP_PATH" ]]; then
    run_with_privilege /bin/rm -rf -- "$target"
  else
    /bin/rm -rf -- "$target"
  fi
}

backup_sqlite_database() {
  local source="$1"
  local destination="$2"
  local sqlite_bin="${CC_SWITCH_SQLITE3_BIN:-/usr/bin/sqlite3}"
  local destination_sql
  local integrity
  local mode

  if [[ ! -x "$sqlite_bin" ]]; then
    die "sqlite3 command not found: $sqlite_bin"
    return 1
  fi
  destination_sql="$(sql_quote "$destination")" || return 1
  if ! "$sqlite_bin" "$source" ".backup $destination_sql" >/dev/null; then
    die "failed to create a consistent CC Switch database snapshot"
    return 1
  fi
  if ! integrity="$("$sqlite_bin" "$destination" 'PRAGMA integrity_check;' 2>/dev/null)" \
    || [[ "$integrity" != "ok" ]]; then
    die "CC Switch database snapshot failed integrity validation"
    return 1
  fi
  if ! mode="$(/usr/bin/stat -f '%Lp' "$source")"; then
    die "failed to read CC Switch database permissions"
    return 1
  fi
  if ! /bin/chmod "$mode" "$destination"; then
    die "failed to preserve CC Switch database snapshot permissions"
    return 1
  fi
}

create_backup() {
  local backup_root="$1"
  local timestamp
  local backup_dir
  local manifest
  local target
  local relative
  local counter=1
  local ditto_bin="$(installer_tool_path CC_SWITCH_DITTO_BIN /usr/bin/ditto)"

  if [[ -n "${CC_SWITCH_INSTALLER_TIMESTAMP:-}" ]]; then
    timestamp="$CC_SWITCH_INSTALLER_TIMESTAMP"
  elif ! timestamp="$(date -u +%Y%m%dT%H%M%SZ)"; then
    die "failed to create the backup timestamp"
    return 1
  fi
  backup_dir="$backup_root/$timestamp"

  while [[ -e "$backup_dir" ]]; do
    backup_dir="$(printf '%s/%s-%04d' "$backup_root" "$timestamp" "$counter")" || return 1
    counter=$((counter + 1))
  done
  if ! /bin/mkdir -p "$backup_dir/files"; then
    die "failed to create backup directory: $backup_dir"
    return 1
  fi
  if ! /bin/chmod 700 "$backup_dir"; then
    die "failed to protect backup directory: $backup_dir"
    return 1
  fi
  manifest="$backup_dir/manifest.tsv"
  if ! : >"$manifest"; then
    die "failed to create backup manifest: $manifest"
    return 1
  fi

  while IFS=$'\t' read -r target relative; do
    if [[ -L "$target" ]]; then
      die "managed target must not be a symlink: $target"
      return 1
    fi
    if [[ -d "$target" ]]; then
      if ! "$ditto_bin" "$target" "$backup_dir/files/$relative"; then
        die "failed to back up managed directory: $target"
        return 1
      fi
      if ! printf '%s\t1\t%s\n' "$target" "files/$relative" >>"$manifest"; then
        die "failed to record backup manifest entry: $target"
        return 1
      fi
    elif [[ -f "$target" ]]; then
      if [[ "$target" == "$CC_SWITCH_DATABASE_PATH" ]]; then
        backup_sqlite_database "$target" "$backup_dir/files/$relative" || return 1
      elif ! /bin/cp -p "$target" "$backup_dir/files/$relative"; then
        die "failed to back up managed file: $target"
        return 1
      fi
      if ! printf '%s\t1\t%s\n' "$target" "files/$relative" >>"$manifest"; then
        die "failed to record backup manifest entry: $target"
        return 1
      fi
    else
      if ! printf '%s\t0\t-\n' "$target" >>"$manifest"; then
        die "failed to record absent backup target: $target"
        return 1
      fi
    fi
  done < <(managed_targets)

  validate_backup_manifest "$backup_dir" || return 1
  printf '%s' "$backup_dir"
}

unload_launch_agent() {
  local launchctl_bin="${CC_SWITCH_LAUNCHCTL_BIN:-/bin/launchctl}"
  local user_id
  user_id="$(/usr/bin/id -u)"
  "$launchctl_bin" bootout "gui/$user_id/$LAUNCH_AGENT_LABEL" >/dev/null 2>&1 || true
}

validate_backup_manifest() {
  local backup_dir="$1"
  local manifest="$backup_dir/manifest.tsv"
  local target
  local existed
  local relative
  local expected_relative
  local backup_path
  local count

  if [[ ! -f "$manifest" ]]; then
    die "backup manifest does not exist: $manifest"
    return 1
  fi
  if ! awk -F '\t' 'NF != 3 { exit 1 }' "$manifest"; then
    die "backup manifest has an invalid row"
    return 1
  fi

  while IFS=$'\t' read -r target expected_relative; do
    count="$(awk -F '\t' -v target="$target" '$1 == target { count += 1 } END { print count + 0 }' "$manifest")"
    if [[ "$count" != "1" ]]; then
      die "backup manifest must contain exactly one entry for: $target"
      return 1
    fi
  done < <(managed_targets)

  while IFS=$'\t' read -r target existed relative; do
    if ! expected_relative="$(managed_relative_for_target "$target")"; then
      die "backup manifest contains unmanaged target: $target"
      return 1
    fi
    if [[ "$existed" == "0" ]]; then
      if [[ "$relative" != "-" ]]; then
        die "backup manifest has an invalid absent payload for: $target"
        return 1
      fi
      continue
    fi
    if [[ "$existed" != "1" || "$relative" != "files/$expected_relative" ]]; then
      die "backup manifest has an invalid payload mapping for: $target"
      return 1
    fi

    backup_path="$backup_dir/$relative"
    if [[ -L "$backup_path" ]]; then
      die "backup payload must not be a symlink: $backup_path"
      return 1
    fi
    if [[ "$expected_relative" == "cc-switch-app" ]]; then
      if [[ ! -d "$backup_path" ]]; then
        die "backup app payload is missing: $backup_path"
        return 1
      fi
    elif [[ ! -f "$backup_path" ]]; then
      die "backup file payload is missing: $backup_path"
      return 1
    fi
    if [[ "$expected_relative" == "cc-switch.db" ]]; then
      local sqlite_bin="${CC_SWITCH_SQLITE3_BIN:-/usr/bin/sqlite3}"
      local integrity
      if [[ ! -x "$sqlite_bin" ]] \
        || ! integrity="$("$sqlite_bin" "$backup_path" 'PRAGMA integrity_check;' 2>/dev/null)" \
        || [[ "$integrity" != "ok" ]]; then
        die "backup database payload failed integrity validation: $backup_path"
        return 1
      fi
    fi
  done <"$manifest"
}

clear_runtime_environment() {
  local launchctl_bin="${CC_SWITCH_LAUNCHCTL_BIN:-/bin/launchctl}"
  "$launchctl_bin" unsetenv MODELHUB_AK >/dev/null 2>&1 || true
  "$launchctl_bin" unsetenv CODEX_CLI_PATH >/dev/null 2>&1 || true
}

reload_restored_launch_agent() {
  local launchctl_bin="${CC_SWITCH_LAUNCHCTL_BIN:-/bin/launchctl}"
  local user_id

  [[ -f "$LAUNCH_AGENT_PATH" ]] || return 0
  user_id="$(/usr/bin/id -u)"
  if ! "$launchctl_bin" bootstrap "gui/$user_id" "$LAUNCH_AGENT_PATH" >/dev/null 2>&1; then
    die "failed to restore the previous LaunchAgent"
    return 1
  fi
  if [[ -x "$ENV_HELPER_PATH" ]]; then
    "$ENV_HELPER_PATH" || true
  fi
}

restore_backup() {
  local backup_dir="$1"
  local manifest="$backup_dir/manifest.tsv"
  local target
  local existed
  local relative
  local backup_path
  local ditto_bin="$(installer_tool_path CC_SWITCH_DITTO_BIN /usr/bin/ditto)"

  validate_backup_manifest "$backup_dir" || return 1

  unload_launch_agent
  clear_runtime_environment
  while IFS=$'\t' read -r target existed relative; do
    if ! is_managed_target "$target"; then
      die "backup manifest contains unmanaged target: $target"
      return 1
    fi
    if [[ "$target" == "$CC_SWITCH_DATABASE_PATH" ]]; then
      if ! /bin/rm -f -- "$CC_SWITCH_DATABASE_PATH-wal" "$CC_SWITCH_DATABASE_PATH-shm"; then
        die "failed to remove stale CC Switch database sidecars"
        return 1
      fi
    fi
    if [[ -e "$target" || -L "$target" ]]; then
      remove_managed_target "$target" || return 1
    fi
    if [[ "$existed" == "1" ]]; then
      backup_path="$backup_dir/$relative"
      if [[ -d "$backup_path" ]]; then
        if ! /bin/mkdir -p "$(dirname "$target")"; then
          die "failed to create restore parent directory: $target"
          return 1
        fi
        if [[ "$target" == "$CC_SWITCH_APP_PATH" ]]; then
          if ! run_with_privilege "$ditto_bin" "$backup_path" "$target"; then
            die "failed to restore CC Switch app"
            return 1
          fi
        elif ! "$ditto_bin" "$backup_path" "$target"; then
          die "failed to restore managed directory: $target"
          return 1
        fi
      elif [[ -f "$backup_path" ]]; then
        if ! /bin/mkdir -p "$(dirname "$target")"; then
          die "failed to create restore parent directory: $target"
          return 1
        fi
        if ! /bin/cp -p "$backup_path" "$target"; then
          die "failed to restore managed file: $target"
          return 1
        fi
      else
        die "backup payload is missing: $backup_path"
        return 1
      fi
    elif [[ "$existed" != "0" ]]; then
      die "backup manifest has invalid existence flag: $existed"
      return 1
    fi
  done <"$manifest"

  reload_restored_launch_agent || return 1
}

install_app() {
  local app_zip="$1"
  local ditto_bin="$(installer_tool_path CC_SWITCH_DITTO_BIN /usr/bin/ditto)"
  local codesign_bin="$(installer_tool_path CC_SWITCH_CODESIGN_BIN /usr/bin/codesign)"
  local xattr_bin="$(installer_tool_path CC_SWITCH_XATTR_BIN /usr/bin/xattr)"
  local work_dir
  local extracted_app

  if ! work_dir="$(mktemp -d "${TMPDIR:-/tmp}/cc-switch-app-install.XXXXXX")"; then
    die "failed to create CC Switch app staging directory"
    return 1
  fi
  if ! "$ditto_bin" -x -k "$app_zip" "$work_dir"; then
    /bin/rm -rf "$work_dir"
    die "failed to extract CC Switch app"
    return 1
  fi
  extracted_app="$work_dir/CC Switch.app"
  if [[ ! -d "$extracted_app" ]]; then
    /bin/rm -rf "$work_dir"
    die "CC Switch app archive has an unexpected layout"
    return 1
  fi
  if ! "$codesign_bin" --verify --deep --strict "$extracted_app" >/dev/null 2>&1; then
    /bin/rm -rf "$work_dir"
    die "CC Switch app signature verification failed"
    return 1
  fi

  remove_managed_target "$CC_SWITCH_APP_PATH" || {
    /bin/rm -rf "$work_dir"
    return 1
  }
  if ! /bin/mkdir -p "$INSTALL_APPLICATIONS_DIR"; then
    /bin/rm -rf "$work_dir" || true
    die "failed to create Applications directory"
    return 1
  fi
  if ! run_with_privilege "$ditto_bin" "$extracted_app" "$CC_SWITCH_APP_PATH"; then
    /bin/rm -rf "$work_dir"
    die "failed to install CC Switch app"
    return 1
  fi
  if ! "$codesign_bin" --verify --deep --strict "$CC_SWITCH_APP_PATH" >/dev/null 2>&1; then
    /bin/rm -rf "$work_dir"
    die "installed CC Switch app signature verification failed"
    return 1
  fi
  run_with_privilege "$xattr_bin" -dr com.apple.quarantine "$CC_SWITCH_APP_PATH" >/dev/null 2>&1 || true
  if ! /bin/rm -rf "$work_dir"; then
    die "failed to remove CC Switch app staging directory"
    return 1
  fi
}

install_golden_codex_config() {
  local golden_file="$1"
  local target_file="$2"
  local user_home="$3"
  local work_dir
  local rendered_file
  local escaped_home

  validate_golden_codex_template "$golden_file" || return 1
  escaped_home="$(toml_escape_basic_string "$user_home")"
  if ! work_dir="$(mktemp -d "$(dirname "$target_file")/.golden-codex.XXXXXX")"; then
    die 'failed to create the golden Codex staging directory'
    return 1
  fi
  rendered_file="$work_dir/config.toml"
  if ! render_template \
    "$golden_file" \
    "$rendered_file" \
    '__USER_HOME__' \
    "$escaped_home" \
    || ! /bin/chmod 0600 "$rendered_file" \
    || ! validate_merged_codex_config "$rendered_file" "$user_home"; then
    /bin/rm -rf "$work_dir" || true
    return 1
  fi
  if ! /bin/mv "$rendered_file" "$target_file" \
    || ! /bin/rmdir "$work_dir"; then
    /bin/rm -rf "$work_dir" || true
    die 'failed to atomically install the golden Codex config'
    return 1
  fi
}

install_golden_database() {
  local golden_database="$1"
  local target_database="$2"
  local user_home="$3"
  local work_dir
  local staged_database
  local placeholder_sql
  local home_sql

  validate_golden_database "$golden_database" || return 1
  if ! work_dir="$(mktemp -d "$(dirname "$target_database")/.golden-db.XXXXXX")"; then
    die 'failed to create the golden database staging directory'
    return 1
  fi
  staged_database="$work_dir/cc-switch.db"
  placeholder_sql="$(sql_quote '__USER_HOME__')"
  home_sql="$(sql_quote "$user_home")"
  if ! /bin/cp "$golden_database" "$staged_database" \
    || ! /bin/chmod 0600 "$staged_database"; then
    /bin/rm -rf "$work_dir" || true
    return 1
  fi
  if ! /usr/bin/sqlite3 "$staged_database" <<SQL
BEGIN IMMEDIATE;
UPDATE providers
   SET settings_config=replace(settings_config, $placeholder_sql, $home_sql),
       website_url=replace(COALESCE(website_url,''), $placeholder_sql, $home_sql),
       notes=replace(COALESCE(notes,''), $placeholder_sql, $home_sql);
UPDATE provider_endpoints SET url=replace(url, $placeholder_sql, $home_sql);
UPDATE mcp_servers
   SET server_config=replace(server_config, $placeholder_sql, $home_sql),
       homepage=replace(COALESCE(homepage,''), $placeholder_sql, $home_sql),
       docs=replace(COALESCE(docs,''), $placeholder_sql, $home_sql);
UPDATE prompts
   SET content=replace(content, $placeholder_sql, $home_sql),
       description=replace(COALESCE(description,''), $placeholder_sql, $home_sql);
UPDATE skills
   SET directory=replace(directory, $placeholder_sql, $home_sql),
       readme_url=replace(COALESCE(readme_url,''), $placeholder_sql, $home_sql);
UPDATE profiles SET payload=replace(payload, $placeholder_sql, $home_sql);
UPDATE settings SET value=replace(value, $placeholder_sql, $home_sql);
COMMIT;
VACUUM;
SQL
  then
    /bin/rm -rf "$work_dir" || true
    die 'failed to render user paths in the golden CC Switch database'
    return 1
  fi
  if [[ "$(golden_sqlite_scalar "$staged_database" 'PRAGMA integrity_check;')" != 'ok' ]] \
    || /usr/bin/strings "$staged_database" | /usr/bin/grep -Fq -- '__USER_HOME__'; then
    /bin/rm -rf "$work_dir" || true
    die 'installed golden database contains an unresolved user path placeholder'
    return 1
  fi
  if ! /bin/rm -f -- "$target_database-wal" "$target_database-shm" \
    || ! /bin/mv "$staged_database" "$target_database" \
    || ! /bin/rmdir "$work_dir"; then
    /bin/rm -rf "$work_dir" || true
    die 'failed to atomically install the golden CC Switch database'
    return 1
  fi
}

install_golden_settings() {
  local golden_settings="$1"
  local target_settings="$2"
  local user_home="$3"
  local work_dir
  local staged_settings

  validate_golden_settings "$golden_settings" || return 1
  if ! work_dir="$(mktemp -d "$(dirname "$target_settings")/.golden-settings.XXXXXX")"; then
    die 'failed to create the golden settings staging directory'
    return 1
  fi
  staged_settings="$work_dir/settings.json"
  if ! render_template \
    "$golden_settings" \
    "$staged_settings" \
    '__USER_HOME__' \
    "$user_home" \
    || ! /bin/chmod 0600 "$staged_settings" \
    || ! validate_golden_settings "$staged_settings"; then
    /bin/rm -rf "$work_dir" || true
    return 1
  fi
  if ! /bin/mv "$staged_settings" "$target_settings" \
    || ! /bin/rmdir "$work_dir"; then
    /bin/rm -rf "$work_dir" || true
    die 'failed to atomically install the golden CC Switch settings'
    return 1
  fi
}

install_runtime_files() {
  local resources_dir="$1"
  local plist_work_dir
  local plist_work_file
  local escaped_helper_path

  if ! /bin/mkdir -p \
    "$INSTALL_USER_HOME/.codex" \
    "$INSTALL_USER_HOME/.cc-switch" \
    "$(dirname "$ENV_HELPER_PATH")" \
    "$(dirname "$LAUNCH_AGENT_PATH")"; then
    die "failed to create ModelHub runtime directories"
    return 1
  fi
  if ! /bin/chmod 700 \
    "$INSTALL_USER_HOME/.codex" \
    "$INSTALL_USER_HOME/.cc-switch" \
    "$(dirname "$ENV_HELPER_PATH")"; then
    die "failed to protect ModelHub runtime directories"
    return 1
  fi

  if ! /usr/bin/install -m 600 \
    "$resources_dir/assets/models-modelhub-1m.json" \
    "$MODEL_CATALOG_PATH"; then
    die "failed to install the ModelHub model catalog"
    return 1
  fi

  install_golden_codex_config \
    "$resources_dir/golden/codex-config.toml" \
    "$CODEX_CONFIG_PATH" \
    "$INSTALL_USER_HOME" \
    || return 1
  install_golden_database \
    "$resources_dir/golden/cc-switch.db" \
    "$CC_SWITCH_DATABASE_PATH" \
    "$INSTALL_USER_HOME" \
    || return 1
  install_golden_settings \
    "$resources_dir/golden/settings.json" \
    "$CC_SWITCH_SETTINGS_PATH" \
    "$INSTALL_USER_HOME" \
    || return 1

  if ! /usr/bin/install -m 700 \
    "$resources_dir/templates/load-modelhub-env.sh" \
    "$ENV_HELPER_PATH"; then
    die "failed to install the ModelHub environment helper"
    return 1
  fi
  if ! plist_work_dir="$(mktemp -d "$(dirname "$LAUNCH_AGENT_PATH")/.modelhub-plist.XXXXXX")"; then
    die "failed to create the LaunchAgent staging directory"
    return 1
  fi
  plist_work_file="$plist_work_dir/com.ccswitch.modelhub-env.plist"
  escaped_helper_path="$(xml_escape "$ENV_HELPER_PATH")"
  if ! render_template \
    "$resources_dir/templates/com.ccswitch.modelhub-env.plist" \
    "$plist_work_file" \
    '__HELPER_PATH__' \
    "$escaped_helper_path"; then
    /bin/rm -rf "$plist_work_dir" || true
    return 1
  fi
  if ! /usr/bin/plutil -lint "$plist_work_file" >/dev/null; then
    /bin/rm -rf "$plist_work_dir"
    die "rendered LaunchAgent is invalid"
    return 1
  fi
  if ! /usr/bin/install -m 600 "$plist_work_file" "$LAUNCH_AGENT_PATH"; then
    /bin/rm -rf "$plist_work_dir" || true
    die "failed to install the ModelHub LaunchAgent"
    return 1
  fi
  if ! /bin/rm -rf "$plist_work_dir"; then
    die "failed to remove the LaunchAgent staging directory"
    return 1
  fi

}

prepare_launcher_failure_snapshot() {
  local backup_dir="$1"
  local snapshot_dir="$backup_dir/launcher-failure"
  local existed_file="$snapshot_dir/existed"
  local payload="$snapshot_dir/install.sh"

  LAUNCHER_FAILURE_SNAPSHOT_READY=0
  LAUNCHER_REPLACED_BY_RUN=0
  if [[ -L "$LOCAL_INSTALLER_PATH" || -d "$LOCAL_INSTALLER_PATH" ]]; then
    die "refusing to snapshot an unsafe local installer path: $LOCAL_INSTALLER_PATH"
    return 1
  fi
  if [[ -e "$LOCAL_INSTALLER_PATH" && ! -f "$LOCAL_INSTALLER_PATH" ]]; then
    die "local installer path is not a regular file: $LOCAL_INSTALLER_PATH"
    return 1
  fi
  if ! /bin/mkdir -p "$snapshot_dir" || ! /bin/chmod 700 "$snapshot_dir"; then
    die "failed to create the failure-only launcher snapshot directory"
    return 1
  fi
  if [[ -f "$LOCAL_INSTALLER_PATH" ]]; then
    if ! /bin/cp -p "$LOCAL_INSTALLER_PATH" "$payload" \
      || ! printf '1\n' >"$existed_file"; then
      die "failed to snapshot the previous local installer"
      return 1
    fi
  elif ! printf '0\n' >"$existed_file"; then
    die "failed to record the absent local installer"
    return 1
  fi
  LAUNCHER_FAILURE_SNAPSHOT_READY=1
}

restore_launcher_after_failed_install() {
  local backup_dir="$1"
  local snapshot_dir="$backup_dir/launcher-failure"
  local existed
  local payload="$snapshot_dir/install.sh"
  local launcher_parent
  local work_dir
  local staged_launcher

  if [[ "$LAUNCHER_FAILURE_SNAPSHOT_READY" != "1" \
    || "$LAUNCHER_REPLACED_BY_RUN" != "1" ]]; then
    return 0
  fi
  if ! existed="$(/bin/cat "$snapshot_dir/existed" 2>/dev/null)"; then
    die "failure-only launcher snapshot metadata is missing"
    return 1
  fi
  case "$existed" in
    0)
      if [[ -L "$LOCAL_INSTALLER_PATH" || -d "$LOCAL_INSTALLER_PATH" ]]; then
        die "refusing to remove an unsafe failed-install launcher path"
        return 1
      fi
      if ! /bin/rm -f -- "$LOCAL_INSTALLER_PATH"; then
        die "failed to remove the launcher created by the failed install"
        return 1
      fi
      ;;
    1)
      if [[ ! -f "$payload" || -L "$payload" ]]; then
        die "failure-only launcher snapshot payload is missing or unsafe"
        return 1
      fi
      if [[ -L "$LOCAL_INSTALLER_PATH" || -d "$LOCAL_INSTALLER_PATH" ]]; then
        die "refusing to overwrite an unsafe failed-install launcher path"
        return 1
      fi
      launcher_parent="$(dirname "$LOCAL_INSTALLER_PATH")"
      if ! /bin/mkdir -p "$launcher_parent" \
        || ! work_dir="$(mktemp -d "$launcher_parent/.launcher-restore.XXXXXX")"; then
        die "failed to create the launcher recovery staging directory"
        return 1
      fi
      staged_launcher="$work_dir/install.sh"
      if ! /bin/cp -p "$payload" "$staged_launcher" \
        || ! /bin/mv -f "$staged_launcher" "$LOCAL_INSTALLER_PATH"; then
        /bin/rm -rf "$work_dir" || true
        die "failed to restore the previous local installer"
        return 1
      fi
      if ! /bin/rmdir "$work_dir"; then
        die "failed to remove the launcher recovery staging directory"
        return 1
      fi
      ;;
    *)
      die "failure-only launcher snapshot metadata is invalid"
      return 1
      ;;
  esac
  LAUNCHER_REPLACED_BY_RUN=0
}

cleanup_launcher_failure_snapshot() {
  local backup_dir="$1"
  if ! /bin/rm -rf "$backup_dir/launcher-failure"; then
    return 1
  fi
  LAUNCHER_FAILURE_SNAPSHOT_READY=0
  LAUNCHER_REPLACED_BY_RUN=0
}

install_durable_launcher() {
  local verified_installer="$1"
  local launcher_parent
  local work_dir
  local staged_launcher

  launcher_parent="$(dirname "$LOCAL_INSTALLER_PATH")"
  if [[ -L "$LOCAL_INSTALLER_PATH" || -d "$LOCAL_INSTALLER_PATH" ]]; then
    die "refusing to overwrite an unsafe local installer path: $LOCAL_INSTALLER_PATH"
    return 1
  fi
  if ! /bin/mkdir -p "$launcher_parent"; then
    die "failed to create the local installer directory"
    return 1
  fi
  if ! /bin/chmod 700 "$launcher_parent"; then
    die "failed to protect the local installer directory"
    return 1
  fi
  if ! work_dir="$(mktemp -d "$launcher_parent/.installer.XXXXXX")"; then
    die "failed to create the local installer staging directory"
    return 1
  fi
  staged_launcher="$work_dir/install.sh"
  if ! /usr/bin/install -m 700 "$verified_installer" "$staged_launcher"; then
    /bin/rm -rf "$work_dir" || true
    die "failed to stage the durable rollback launcher"
    return 1
  fi
  if ! /bin/mv -f "$staged_launcher" "$LOCAL_INSTALLER_PATH"; then
    /bin/rm -rf "$work_dir" || true
    die "failed to install the durable rollback launcher"
    return 1
  fi
  LAUNCHER_REPLACED_BY_RUN=1
  if ! /bin/rmdir "$work_dir"; then
    die "failed to remove the local installer staging directory"
    return 1
  fi
}

keychain_account_name() {
  /usr/bin/id -un
}

validate_modelhub_ak() {
  local modelhub_ak="$1"

  if [[ -z "$modelhub_ak" ]]; then
    die 'MODELHUB_AK 不能为空'
    return 1
  fi
  case "$modelhub_ak" in
    *$'\n'*|*$'\r'*)
      die 'MODELHUB_AK 不能包含换行符'
      return 1
      ;;
  esac
}

prompt_modelhub_ak() {
  local modelhub_ak=''

  if [[ "${CC_SWITCH_INSTALLER_TEST_MODE:-0}" == "1" ]]; then
    modelhub_ak="${CC_SWITCH_INSTALLER_TEST_MODELHUB_AK:-}"
  else
    printf '%s' '请输入 MODELHUB_AK（向管理员获取，输入内容不会显示）：' >/dev/tty
    if ! IFS= read -r -s modelhub_ak </dev/tty; then
      printf '\n' >/dev/tty
      die '读取 MODELHUB_AK 失败'
      return 1
    fi
    printf '\n' >/dev/tty
  fi
  validate_modelhub_ak "$modelhub_ak" || return 1
  printf '%s' "$modelhub_ak"
}

read_modelhub_ak() {
  local inherited_modelhub_ak=''
  local reuse_choice=''
  local test_choices=''

  if [[ "${CC_SWITCH_INSTALLER_TEST_MODE:-0}" == "1" ]]; then
    inherited_modelhub_ak="${CC_SWITCH_INSTALLER_TEST_INHERITED_MODELHUB_AK:-}"
    test_choices="${CC_SWITCH_INSTALLER_TEST_REUSE_MODELHUB_AK_CHOICE:-}"
  else
    inherited_modelhub_ak="${MODELHUB_AK:-}"
  fi
  if [[ -z "$inherited_modelhub_ak" ]]; then
    prompt_modelhub_ak
    return
  fi
  validate_modelhub_ak "$inherited_modelhub_ak" || return 1

  while true; do
    if [[ "${CC_SWITCH_INSTALLER_TEST_MODE:-0}" == "1" ]]; then
      if [[ "$test_choices" == *$'\n'* ]]; then
        reuse_choice="${test_choices%%$'\n'*}"
        test_choices="${test_choices#*$'\n'}"
      else
        reuse_choice="$test_choices"
        test_choices=''
      fi
    else
      printf '%s' '检测到当前环境已有 MODELHUB_AK，是否直接复用？[Y/n] ' >/dev/tty
      if ! IFS= read -r reuse_choice </dev/tty; then
        die '读取 MODELHUB_AK 复用选择失败'
        return 1
      fi
    fi
    case "$reuse_choice" in
      ''|Y|y)
        printf '%s' "$inherited_modelhub_ak"
        return
        ;;
      N|n)
        prompt_modelhub_ak
        return
        ;;
      *)
        if [[ "${CC_SWITCH_INSTALLER_TEST_MODE:-0}" != "1" ]]; then
          printf '%s\n' '请输入 Y 或 n。' >/dev/tty
        elif [[ -z "$test_choices" ]]; then
          die '测试模式缺少后续 MODELHUB_AK 复用选择'
          return 1
        fi
        ;;
    esac
  done
}

store_modelhub_api_key_in_provider() {
  local database="$1"
  local modelhub_ak="$2"
  local expected_modelhub_ak="${3:-$modelhub_ak}"
  local ak_sql
  local changed
  local provider_ak

  ak_sql="$(sql_quote "$modelhub_ak")" || return 1
  changed="$(/usr/bin/sqlite3 "$database" <<SQL
BEGIN IMMEDIATE;
UPDATE providers
SET settings_config=json_set(
  settings_config,
  '$.auth',
  json_object('OPENAI_API_KEY', $ak_sql)
)
WHERE id='$MODELHUB_PROVIDER_ID'
  AND app_type='codex';
SELECT changes();
COMMIT;
SQL
)" || return 1
  if [[ "$changed" != '1' ]]; then
    die 'failed to store MODELHUB_AK in the CC Switch ModelHub Provider'
    return 1
  fi
  provider_ak="$(/usr/bin/sqlite3 "$database" \
    "SELECT json_extract(settings_config, '$.auth.OPENAI_API_KEY') FROM providers WHERE id='$MODELHUB_PROVIDER_ID' AND app_type='codex';")" \
    || return 1
  if [[ -z "$expected_modelhub_ak" \
    || "$provider_ak" != "$modelhub_ak" \
    || "$provider_ak" != "$expected_modelhub_ak" ]]; then
    provider_ak=''
    die 'failed to verify MODELHUB_AK in the CC Switch ModelHub Provider'
    return 1
  fi
  provider_ak=''
}

verify_modelhub_credential_sync() {
  local database="$1"
  local expected_modelhub_ak="${2:-$MODELHUB_EXPECTED_AK}"
  local security_bin="${CC_SWITCH_SECURITY_BIN:-/usr/bin/security}"
  local launchctl_bin="${CC_SWITCH_LAUNCHCTL_BIN:-/bin/launchctl}"
  local account_name
  local keychain_ak=''
  local provider_ak=''
  local launchd_ak=''

  account_name="$(keychain_account_name)"
  if ! keychain_ak="$("$security_bin" find-generic-password \
    -a "$account_name" \
    -s "$KEYCHAIN_SERVICE" \
    -w 2>/dev/null)"; then
    die 'failed to read MODELHUB_AK from Keychain during credential verification'
    return 1
  fi
  if ! provider_ak="$(/usr/bin/sqlite3 "$database" \
    "SELECT json_extract(settings_config, '$.auth.OPENAI_API_KEY') FROM providers WHERE id='$MODELHUB_PROVIDER_ID' AND app_type='codex';")"; then
    keychain_ak=''
    die 'failed to read MODELHUB_AK from the CC Switch ModelHub Provider'
    return 1
  fi
  if ! launchd_ak="$("$launchctl_bin" getenv MODELHUB_AK 2>/dev/null)"; then
    keychain_ak=''
    provider_ak=''
    die 'failed to read MODELHUB_AK from launchd'
    return 1
  fi
  if [[ -z "$expected_modelhub_ak" \
    || "$keychain_ak" != "$expected_modelhub_ak" \
    || "$provider_ak" != "$expected_modelhub_ak" \
    || "$launchd_ak" != "$expected_modelhub_ak" ]]; then
    keychain_ak=''
    provider_ak=''
    launchd_ak=''
    die 'ModelHub credential synchronization verification failed'
    return 1
  fi
  keychain_ak=''
  provider_ak=''
  launchd_ak=''
}

snapshot_launchd_environment() {
  local launchctl_bin="${CC_SWITCH_LAUNCHCTL_BIN:-/bin/launchctl}"
  local launchd_status

  LAUNCHD_ENVIRONMENT_SNAPSHOT_READY=0
  LAUNCHD_MODELHUB_AK_EXISTED_BEFORE_RUN=0
  LAUNCHD_MODELHUB_AK_BEFORE_RUN=''
  LAUNCHD_CODEX_CLI_PATH_EXISTED_BEFORE_RUN=0
  LAUNCHD_CODEX_CLI_PATH_BEFORE_RUN=''
  if LAUNCHD_MODELHUB_AK_BEFORE_RUN="$("$launchctl_bin" getenv MODELHUB_AK 2>/dev/null)"; then
    launchd_status=0
  else
    launchd_status=$?
  fi
  case "$launchd_status" in
    0)
      LAUNCHD_MODELHUB_AK_EXISTED_BEFORE_RUN=1
      ;;
    1)
      LAUNCHD_MODELHUB_AK_BEFORE_RUN=''
      ;;
    *)
      LAUNCHD_MODELHUB_AK_BEFORE_RUN=''
      die "unable to inspect the existing launchd MODELHUB_AK state"
      return 1
      ;;
  esac
  if LAUNCHD_CODEX_CLI_PATH_BEFORE_RUN="$("$launchctl_bin" getenv CODEX_CLI_PATH 2>/dev/null)"; then
    launchd_status=0
  else
    launchd_status=$?
  fi
  case "$launchd_status" in
    0)
      LAUNCHD_CODEX_CLI_PATH_EXISTED_BEFORE_RUN=1
      ;;
    1)
      LAUNCHD_CODEX_CLI_PATH_BEFORE_RUN=''
      ;;
    *)
      LAUNCHD_MODELHUB_AK_EXISTED_BEFORE_RUN=0
      LAUNCHD_MODELHUB_AK_BEFORE_RUN=''
      LAUNCHD_CODEX_CLI_PATH_BEFORE_RUN=''
      die "unable to inspect the existing launchd CODEX_CLI_PATH state"
      return 1
      ;;
  esac
  LAUNCHD_ENVIRONMENT_SNAPSHOT_READY=1
}

restore_keychain_after_failed_install() {
  local security_bin="${CC_SWITCH_SECURITY_BIN:-/usr/bin/security}"
  local account_name

  if [[ "$KEYCHAIN_UPDATED_BY_RUN" != "1" ]]; then
    return 0
  fi
  if [[ "$KEYCHAIN_CREATED_BY_RUN" == "1" ]]; then
    delete_keychain_item
    return
  fi
  account_name="$(keychain_account_name)"
  if ! "$security_bin" add-generic-password \
    -a "$account_name" \
    -s "$KEYCHAIN_SERVICE" \
    -U \
    -w "$KEYCHAIN_PREVIOUS_AK" >/dev/null 2>&1; then
    die 'failed to restore the previous ModelHub Keychain item'
    return 1
  fi
}

restore_launchd_environment_after_failed_install() {
  local launchctl_bin="${CC_SWITCH_LAUNCHCTL_BIN:-/bin/launchctl}"

  if [[ "$LAUNCHD_ENVIRONMENT_SNAPSHOT_READY" != "1" ]]; then
    return 0
  fi
  if [[ "$LAUNCHD_MODELHUB_AK_EXISTED_BEFORE_RUN" == "1" ]]; then
    if ! "$launchctl_bin" setenv MODELHUB_AK "$LAUNCHD_MODELHUB_AK_BEFORE_RUN" >/dev/null 2>&1; then
      die 'failed to restore the previous launchd MODELHUB_AK state'
      return 1
    fi
  elif ! "$launchctl_bin" unsetenv MODELHUB_AK >/dev/null 2>&1; then
    die 'failed to restore the previous empty launchd MODELHUB_AK state'
    return 1
  fi
  if [[ "$LAUNCHD_CODEX_CLI_PATH_EXISTED_BEFORE_RUN" == "1" ]]; then
    if ! "$launchctl_bin" setenv CODEX_CLI_PATH "$LAUNCHD_CODEX_CLI_PATH_BEFORE_RUN" >/dev/null 2>&1; then
      die 'failed to restore the previous launchd CODEX_CLI_PATH state'
      return 1
    fi
  elif ! "$launchctl_bin" unsetenv CODEX_CLI_PATH >/dev/null 2>&1; then
    die 'failed to restore the previous empty launchd CODEX_CLI_PATH state'
    return 1
  fi
}

clear_modelhub_credential_transaction_state() {
  KEYCHAIN_UPDATED_BY_RUN=0
  KEYCHAIN_PREVIOUS_AK=''
  MODELHUB_EXPECTED_AK=''
  LAUNCHD_ENVIRONMENT_SNAPSHOT_READY=0
  LAUNCHD_MODELHUB_AK_EXISTED_BEFORE_RUN=0
  LAUNCHD_MODELHUB_AK_BEFORE_RUN=''
  LAUNCHD_CODEX_CLI_PATH_EXISTED_BEFORE_RUN=0
  LAUNCHD_CODEX_CLI_PATH_BEFORE_RUN=''
}

configure_keychain() {
  local security_bin="${CC_SWITCH_SECURITY_BIN:-/usr/bin/security}"
  local account_name
  local find_status
  local modelhub_ak=''
  account_name="$(keychain_account_name)"
  KEYCHAIN_CREATED_BY_RUN=0
  KEYCHAIN_UPDATED_BY_RUN=0
  KEYCHAIN_PREVIOUS_AK=''

  if KEYCHAIN_PREVIOUS_AK="$("$security_bin" find-generic-password \
    -a "$account_name" \
    -s "$KEYCHAIN_SERVICE" \
    -w 2>/dev/null)"; then
    find_status=0
  else
    find_status=$?
  fi
  case "$find_status" in
    0)
      if ! printf '1\n' >"$ACTIVE_BACKUP_DIR/keychain-existed"; then
        die "failed to record existing Keychain state"
        return 1
      fi
      ;;
    44)
      KEYCHAIN_PREVIOUS_AK=''
      if ! printf '0\n' >"$ACTIVE_BACKUP_DIR/keychain-existed"; then
        die "failed to record absent Keychain state"
        return 1
      fi
      KEYCHAIN_CREATED_BY_RUN=1
      ;;
    *)
      KEYCHAIN_PREVIOUS_AK=''
      die "unable to inspect the ModelHub Keychain item (security status $find_status)"
      return 1
      ;;
  esac

  if [[ "$find_status" == "0" ]]; then
    KEYCHAIN_CREATED_BY_RUN=0
  fi

  if ! modelhub_ak="$(read_modelhub_ak)"; then
    return 1
  fi
  MODELHUB_EXPECTED_AK="$modelhub_ak"
  KEYCHAIN_UPDATED_BY_RUN=1
  if ! "$security_bin" add-generic-password \
    -a "$account_name" \
    -s "$KEYCHAIN_SERVICE" \
    -U \
    -w "$modelhub_ak"; then
    modelhub_ak=''
    return 1
  fi
  modelhub_ak=''
  if ! modelhub_ak="$("$security_bin" find-generic-password \
    -a "$account_name" \
    -s "$KEYCHAIN_SERVICE" \
    -w 2>/dev/null)"; then
    die 'failed to read MODELHUB_AK back from Keychain'
    return 1
  fi
  if ! validate_modelhub_ak "$modelhub_ak"; then
    modelhub_ak=''
    return 1
  fi
  if [[ "$modelhub_ak" != "$MODELHUB_EXPECTED_AK" ]]; then
    modelhub_ak=''
    die 'Keychain MODELHUB_AK does not match the requested credential'
    return 1
  fi
  if ! store_modelhub_api_key_in_provider \
    "$CC_SWITCH_DATABASE_PATH" \
    "$modelhub_ak" \
    "$MODELHUB_EXPECTED_AK"; then
    modelhub_ak=''
    return 1
  fi
  modelhub_ak=''
}

delete_keychain_item() {
  local security_bin="${CC_SWITCH_SECURITY_BIN:-/usr/bin/security}"
  local account_name
  local delete_status
  account_name="$(keychain_account_name)"
  if "$security_bin" delete-generic-password -a "$account_name" -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1; then
    delete_status=0
  else
    delete_status=$?
  fi
  case "$delete_status" in
    0|44)
      return 0
      ;;
    *)
      die "failed to delete the ModelHub Keychain item (security status $delete_status)"
      return 1
      ;;
  esac
}

install_launch_agent() {
  local launchctl_bin="${CC_SWITCH_LAUNCHCTL_BIN:-/bin/launchctl}"
  local user_id
  user_id="$(/usr/bin/id -u)"

  unload_launch_agent
  if ! "$launchctl_bin" bootstrap "gui/$user_id" "$LAUNCH_AGENT_PATH" >/dev/null; then
    die "failed to bootstrap ModelHub environment LaunchAgent"
    return 1
  fi
  if ! "$ENV_HELPER_PATH"; then
    die "failed to load ModelHub environment for the current login session"
    return 1
  fi
}

quit_apps() {
  local osascript_bin="${CC_SWITCH_OSASCRIPT_BIN:-/usr/bin/osascript}"
  "$osascript_bin" -e 'quit app "ChatGPT"' >/dev/null 2>&1 || true
  "$osascript_bin" -e 'quit app "CC Switch"' >/dev/null 2>&1 || true
  wait_for_cc_switch_exit
}

wait_for_cc_switch_exit() {
  local pgrep_bin="${CC_SWITCH_PGREP_BIN:-/usr/bin/pgrep}"
  local sleep_bin="${CC_SWITCH_SLEEP_BIN:-/bin/sleep}"
  local attempt=1
  local pgrep_status

  if [[ ! -x "$pgrep_bin" || ! -x "$sleep_bin" ]]; then
    die "required CC Switch process-wait command is unavailable"
    return 1
  fi
  while [[ "$attempt" -le 30 ]]; do
    if "$pgrep_bin" -x 'cc-switch' >/dev/null 2>&1; then
      pgrep_status=0
    else
      pgrep_status=$?
    fi
    case "$pgrep_status" in
      0)
        "$sleep_bin" 1 || {
          die "failed while waiting for CC Switch to quit"
          return 1
        }
        ;;
      1)
        return 0
        ;;
      *)
        die "unable to inspect the CC Switch process state"
        return 1
        ;;
    esac
    attempt=$((attempt + 1))
  done
  die "CC Switch did not quit within 30 seconds"
  return 1
}

start_cc_switch() {
  local open_bin="${CC_SWITCH_OPEN_BIN:-/usr/bin/open}"
  "$open_bin" "$CC_SWITCH_APP_PATH"
}

wait_for_health() {
  local url="$1"
  local timeout_seconds="$2"
  local curl_bin="${CC_SWITCH_CURL_BIN:-/usr/bin/curl}"
  local sleep_bin="${CC_SWITCH_SLEEP_BIN:-/bin/sleep}"
  local attempt=1
  local response

  while [[ "$attempt" -le "$timeout_seconds" ]]; do
    if response="$("$curl_bin" --fail --silent --show-error --max-time 2 "$url" 2>/dev/null)"; then
      if [[ "$response" == "healthy" ]] \
        || printf '%s' "$response" | /usr/bin/grep -Eq '"status"[[:space:]]*:[[:space:]]*"healthy"'; then
        return 0
      fi
    fi
    if ! "$sleep_bin" 1; then
      die "failed while waiting for CC Switch health"
      return 1
    fi
    attempt=$((attempt + 1))
  done

  die "CC Switch health check timed out"
  return 1
}

wait_for_golden_routing_state() {
  local database="$1"
  local live_config="$2"
  local timeout_seconds="$3"
  local sleep_bin="${CC_SWITCH_SLEEP_BIN:-/bin/sleep}"
  local attempt=1
  local provider_ready
  local live_ready

  case "$timeout_seconds" in
    ''|*[!0-9]*)
      die "invalid golden routing timeout: $timeout_seconds"
      return 1
      ;;
  esac
  if [[ "$timeout_seconds" -lt 1 || ! -x "$sleep_bin" ]]; then
    die 'golden routing verification requires a positive timeout and sleep command'
    return 1
  fi

  while [[ "$attempt" -le "$timeout_seconds" ]]; do
    provider_ready="$(golden_sqlite_scalar "$database" "
      SELECT count(*)
      FROM providers
      WHERE id='bytedance-modelhub-official-cli'
        AND app_type='codex'
        AND is_current=1
        AND instr(json_extract(settings_config, '$.config'),
                  'https://aidp.bytedance.net/api/modelhub/online') > 0
        AND instr(json_extract(settings_config, '$.config'),
                  '127.0.0.1:15721') = 0;
    " || true)"
    if [[ -f "$live_config" ]] \
      && grep -Fq -- 'base_url = "http://127.0.0.1:15721/v1"' "$live_config"; then
      live_ready=1
    else
      live_ready=0
    fi
    if [[ "$provider_ready" == '1' && "$live_ready" == '1' ]]; then
      return 0
    fi
    "$sleep_bin" 1 || return 1
    attempt=$((attempt + 1))
  done

  die 'golden routing verification failed: Provider must use ModelHub upstream while live Codex uses the local proxy'
  return 1
}

path_tree_requires_privilege() {
  local target="$1"

  [[ -e "$target" ]] || return 1
  [[ -w "$target" ]] || return 0
  if /usr/bin/find "$target" -type d -print0 2>/dev/null \
    | while IFS= read -r -d '' directory; do
      [[ -w "$directory" && -x "$directory" ]] || exit 1
    done; then
    return 1
  fi
  return 0
}

prepare_application_permissions() {
  local sudo_bin

  NEEDS_SUDO=0
  /bin/mkdir -p "$INSTALL_APPLICATIONS_DIR" 2>/dev/null || true
  if [[ ! -w "$INSTALL_APPLICATIONS_DIR" ]] \
    || path_tree_requires_privilege "$CC_SWITCH_APP_PATH" \
    || { [[ ! -d "$INSTALL_APPLICATIONS_DIR/ChatGPT.app" ]] \
      && [[ ! -w "$INSTALL_APPLICATIONS_DIR" ]]; }; then
    NEEDS_SUDO=1
    sudo_bin="$(sudo_command)"
    if ! "$sudo_bin" -v; then
      die "administrator permission is required to install CC Switch"
      return 1
    fi
  fi
}

extract_verified_resources() {
  local asset_dir="$1"
  local output_dir="$2"
  if ! tar -xzf "$asset_dir/$RESOURCES_ASSET" -C "$output_dir"; then
    die "failed to extract verified ModelHub resources"
    return 1
  fi
}

rollback_failed_install() {
  local rollback_status=0
  local restore_allowed=1

  if [[ "$TRANSACTION_ROLLBACK_RUNNING" == "1" ]]; then
    return 1
  fi
  TRANSACTION_ROLLBACK_RUNNING=1
  if ! quit_apps; then
    rollback_status=1
    restore_allowed=0
  fi
  unload_launch_agent
  clear_runtime_environment
  restore_keychain_after_failed_install || rollback_status=1
  if [[ -n "$ACTIVE_BACKUP_DIR" && "$restore_allowed" == "1" ]]; then
    restore_backup "$ACTIVE_BACKUP_DIR" || rollback_status=1
  fi
  restore_launchd_environment_after_failed_install || rollback_status=1
  if [[ -n "$ACTIVE_BACKUP_DIR" && "$LAUNCHER_REPLACED_BY_RUN" == "1" ]]; then
    restore_launcher_after_failed_install "$ACTIVE_BACKUP_DIR" || rollback_status=1
  fi
  clear_modelhub_credential_transaction_state
  TRANSACTION_ROLLBACK_RUNNING=0
  return "$rollback_status"
}

cleanup_transaction_stage() {
  if ! cleanup_chatgpt_bootstrap; then
    return 1
  fi
  if [[ -n "$TRANSACTION_STAGE_DIR" && -d "$TRANSACTION_STAGE_DIR" ]]; then
    if ! /bin/rm -rf "$TRANSACTION_STAGE_DIR"; then
      die "failed to remove the installer staging directory"
      return 1
    fi
  fi
  TRANSACTION_STAGE_DIR=''
}

transaction_exit_guard() {
  local exit_status=$?

  trap - EXIT INT TERM
  if [[ "$TRANSACTION_GUARD_ACTIVE" == "1" \
    && "$MUTATION_STARTED" == "1" \
    && "$INSTALL_COMPLETED" == "0" \
    && "$TRANSACTION_ROLLBACK_RUNNING" == "0" ]]; then
    rollback_failed_install || exit_status=1
  fi
  cleanup_chatgpt_bootstrap || exit_status=1
  cleanup_transaction_stage || exit_status=1
  exit "$exit_status"
}

transaction_signal_guard() {
  local exit_status="$1"

  trap - EXIT INT TERM
  if [[ "$TRANSACTION_GUARD_ACTIVE" == "1" \
    && "$MUTATION_STARTED" == "1" \
    && "$INSTALL_COMPLETED" == "0" \
    && "$TRANSACTION_ROLLBACK_RUNNING" == "0" ]]; then
    rollback_failed_install || exit_status=1
  fi
  cleanup_chatgpt_bootstrap || exit_status=1
  cleanup_transaction_stage || exit_status=1
  exit "$exit_status"
}

run_install_transaction() {
  local asset_dir="$1"
  local resources_dir="$2"
  local health_timeout="${CC_SWITCH_INSTALLER_HEALTH_TIMEOUT:-30}"
  local routing_timeout="${CC_SWITCH_INSTALLER_ROUTING_TIMEOUT:-30}"

  progress 6 8 '安装 CC Switch，并覆盖本机完整配置快照'
  install_app "$asset_dir/$APP_ASSET" || return 1
  install_runtime_files "$resources_dir" || return 1
  progress 7 8 '确认或输入 MODELHUB_AK，并同步凭据'
  configure_keychain || return 1
  progress 8 8 '启动 CC Switch，检查健康状态和 ModelHub 路由'
  install_launch_agent || return 1
  verify_modelhub_credential_sync "$CC_SWITCH_DATABASE_PATH" "$MODELHUB_EXPECTED_AK" || return 1
  start_cc_switch || return 1
  wait_for_health 'http://127.0.0.1:15721/health' "$health_timeout" || return 1
  wait_for_golden_routing_state \
    "$CC_SWITCH_DATABASE_PATH" \
    "$CODEX_CONFIG_PATH" \
    "$routing_timeout" \
    || return 1
  verify_modelhub_credential_sync "$CC_SWITCH_DATABASE_PATH" "$MODELHUB_EXPECTED_AK" || return 1
}

perform_install() {
  local operating_system
  local architecture
  local major_version
  local stage_dir
  local asset_dir
  local resources_parent
  local resources_dir
  local rollback_status

  progress 1 8 '检查 macOS、Apple Silicon 和当前用户权限'
  validate_execution_identity \
    "$EUID" \
    "${CC_SWITCH_INSTALLER_TEST_EUID:-$EUID}" \
    || return 1
  LAUNCHER_FAILURE_SNAPSHOT_READY=0
  LAUNCHER_REPLACED_BY_RUN=0

  configure_install_paths || return 1
  operating_system="${CC_SWITCH_INSTALLER_TEST_OS:-$(/usr/bin/uname -s)}"
  architecture="${CC_SWITCH_INSTALLER_TEST_ARCH:-$(/usr/bin/uname -m)}"
  major_version="${CC_SWITCH_INSTALLER_TEST_MACOS_MAJOR:-$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d. -f1)}"
  validate_platform "$operating_system" "$architecture" "$major_version" || return 1

  if ! stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/cc-switch-modelhub-install.XXXXXX")"; then
    die "failed to create the installer staging directory"
    return 1
  fi
  TRANSACTION_STAGE_DIR="$stage_dir"
  progress 2 8 '检查 Applications 权限和现有 ChatGPT 应用'
  prepare_application_permissions || {
    cleanup_transaction_stage || true
    return 1
  }
  if [[ -e "$CHATGPT_APP_PATH" || -L "$CHATGPT_APP_PATH" ]]; then
    ensure_chatgpt_app "$stage_dir" || {
      cleanup_transaction_stage || true
      return 1
    }
  fi
  progress 3 8 '下载并校验 R13 安装器、CC Switch 和配置资源'
  if [[ "${CC_SWITCH_INSTALLER_TEST_MODE:-0}" == "1" ]]; then
    asset_dir="${CC_SWITCH_INSTALLER_ASSET_DIR:?test asset directory is required}"
  else
    asset_dir="$stage_dir/assets"
    download_release_assets "$asset_dir" || {
      /bin/rm -rf "$stage_dir"
      TRANSACTION_STAGE_DIR=''
      return 1
    }
  fi
  verify_release_assets "$asset_dir" || {
    /bin/rm -rf "$stage_dir"
    TRANSACTION_STAGE_DIR=''
    return 1
  }
  validate_resource_archive "$asset_dir/$RESOURCES_ASSET" || {
    /bin/rm -rf "$stage_dir"
    TRANSACTION_STAGE_DIR=''
    return 1
  }

  resources_parent="$stage_dir/resources"
  if ! /bin/mkdir -p "$resources_parent"; then
    cleanup_transaction_stage || true
    die "failed to create the resource staging directory"
    return 1
  fi
  extract_verified_resources "$asset_dir" "$resources_parent" || {
    cleanup_transaction_stage || true
    return 1
  }
  resources_dir="$resources_parent/modelhub-installer"

  progress 4 8 '验证 ChatGPT；缺失时从 OpenAI 官方来源安装'
  ensure_chatgpt_app "$stage_dir" "$resources_dir" || {
    cleanup_transaction_stage || true
    return 1
  }
  validate_chatgpt_codex "$CHATGPT_CODEX_PATH" "$EXPECTED_CODEX_TEAM_ID" || {
    cleanup_transaction_stage || true
    return 1
  }

  progress 5 8 '退出应用并备份现有 Codex、CC Switch 配置'
  quit_apps || {
    cleanup_transaction_stage || true
    return 1
  }
  ACTIVE_BACKUP_DIR="$(create_backup "$BACKUP_ROOT")" || {
    cleanup_transaction_stage || true
    return 1
  }
  prepare_launcher_failure_snapshot "$ACTIVE_BACKUP_DIR" || {
    cleanup_transaction_stage || true
    return 1
  }
  KEYCHAIN_CREATED_BY_RUN=0
  clear_modelhub_credential_transaction_state
  snapshot_launchd_environment || {
    cleanup_transaction_stage || true
    return 1
  }
  MUTATION_STARTED=1
  INSTALL_COMPLETED=0
  TRANSACTION_GUARD_ACTIVE=1

  if ! run_install_transaction "$asset_dir" "$resources_dir"; then
    rollback_status=0
    rollback_failed_install || rollback_status=$?
    TRANSACTION_GUARD_ACTIVE=0
    cleanup_transaction_stage || rollback_status=1
    if [[ "$rollback_status" != "0" ]]; then
      die "installation failed and automatic rollback was incomplete"
    fi
    return 1
  fi

  if ! install_durable_launcher "$asset_dir/$INSTALLER_ASSET"; then
    rollback_status=0
    rollback_failed_install || rollback_status=$?
    TRANSACTION_GUARD_ACTIVE=0
    cleanup_transaction_stage || rollback_status=1
    if [[ "$rollback_status" != "0" ]]; then
      die "local launcher installation failed and automatic rollback was incomplete"
    fi
    return 1
  fi

  if ! : >"$ACTIVE_BACKUP_DIR/install-completed"; then
    rollback_status=0
    rollback_failed_install || rollback_status=$?
    TRANSACTION_GUARD_ACTIVE=0
    cleanup_transaction_stage || rollback_status=1
    die "failed to mark the installer backup as completed"
    return 1
  fi
  INSTALL_COMPLETED=1
  TRANSACTION_GUARD_ACTIVE=0
  clear_modelhub_credential_transaction_state
  cleanup_launcher_failure_snapshot "$ACTIVE_BACKUP_DIR" || true
  cleanup_transaction_stage || return 1
  printf '\n安装完成：CC Switch 已启动，ModelHub 路由检查通过。\n' >&2
}

rollback_latest() {
  local latest_backup
  local keychain_existed

  validate_execution_identity \
    "$EUID" \
    "${CC_SWITCH_INSTALLER_TEST_EUID:-$EUID}" \
    || return 1
  configure_install_paths || return 1
  latest_backup="$(
    { /usr/bin/find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -exec test -f '{}/install-completed' \; -print \
      2>/dev/null || true; } \
      | LC_ALL=C /usr/bin/sort \
      | /usr/bin/tail -n 1
  )"
  if [[ -z "$latest_backup" ]]; then
    die "no completed ModelHub installer backup is available"
    return 1
  fi

  prepare_application_permissions || return 1
  quit_apps || return 1
  unload_launch_agent
  clear_runtime_environment
  keychain_existed="$(/bin/cat "$latest_backup/keychain-existed" 2>/dev/null || printf '1')"
  if [[ "$keychain_existed" == "0" ]]; then
    delete_keychain_item || return 1
  fi
  restore_backup "$latest_backup" || return 1
}

usage() {
  cat <<'EOF'
Usage: install.sh [--help | --rollback latest]

Install the CC Switch ModelHub integration, or restore the most recent
completed installer backup.
EOF
}

main() {
  case "${1:-}" in
    --help|-h)
      if [[ $# -ne 1 ]]; then
        die "usage: install.sh --help"
        return 1
      fi
      usage
      ;;
    "")
      perform_install
      ;;
    --rollback)
      if [[ "${2:-}" != "latest" || $# -ne 2 ]]; then
        die "usage: install.sh --rollback latest"
        return 1
      fi
      rollback_latest
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
}

SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
if [[ -z "$SCRIPT_SOURCE" || "$SCRIPT_SOURCE" == "$0" ]]; then
  trap transaction_exit_guard EXIT
  trap 'transaction_signal_guard 130' INT
  trap 'transaction_signal_guard 143' TERM
  main "$@"
fi
