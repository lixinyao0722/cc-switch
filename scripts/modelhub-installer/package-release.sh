#!/bin/bash

set -euo pipefail

PATH='/usr/bin:/bin:/usr/sbin:/sbin'
export PATH

readonly OUTPUT_APP_NAME='CC-Switch-ModelHub-3.19.2-arm64.app.zip'
readonly OUTPUT_INSTALLER_NAME='install.sh'
readonly OUTPUT_RESOURCES_NAME='modelhub-installer-resources.tar.gz'
readonly OUTPUT_CHECKSUM_NAME='SHA256SUMS.txt'

usage() {
  cat <<'EOF'
Usage: package-release.sh --app-zip PATH --output-dir DIR

Build the allowlisted public assets for the CC Switch ModelHub installer.
EOF
}

die() {
  echo "error: $*" >&2
  return 1
}

scan_source_tree() {
  local source_dir="$1"
  local relative
  local forbidden_file
  local forbidden_link
  local required_files=(
    'install.sh'
    'build-golden-db.sh'
    'build-local-golden-snapshot.sh'
    'assets/models-modelhub-1m.json'
    'golden/cc-switch-schema.sql'
    'golden/codex-config.toml'
    'golden/settings.json'
    'helpers/rename-exclusive.c'
    'templates/modelhub-provider.toml'
    'templates/modelhub-provider-meta.json'
    'templates/codex-managed-config.toml'
    'templates/com.ccswitch.modelhub-env.plist'
    'templates/load-modelhub-env.sh'
  )
  local forbidden_content="/Users/shopee|-----BEGIN ([A-Z]+ )?PRIVATE KEY-----|gh[pousr]_[[:alnum:]_]{20,}|sk-[[:alnum:]]{20,}|MODELHUB_AK[[:space:]]*[:=][[:space:]]*['\"]?[[:alnum:]]"
  local sensitive_assignment="(^|[^[:alnum:]_])(access_token|refresh_token|id_token|experimental_bearer_token|OPENAI_API_KEY)[[:space:]]*[:=][[:space:]]*['\"]?[^[:space:]'\"$]{4}"
  local credential_key_shape="(^|[^[:alnum:]_])([[:alnum:]_]*(access|refresh|bearer|api|auth)[_-]?(token|key)|[[:alnum:]_]*(secret|password|credential)[[:alnum:]_-]*|authorization)['\"]?[[:space:]]*[:=][[:space:]]*['\"]?[^[:space:]'\"$]{4}"

  forbidden_file="$(
    find "$source_dir" -type f \
      \( -name 'auth.json' -o -name '*.db' -o -name '*.db-*' -o -name '*.sqlite' -o -name '*.sqlite3' -o -name '*.log' \) \
      -print -quit
  )"
  if [[ -n "$forbidden_file" ]]; then
    die "installer source contains a forbidden file type"
    return 1
  fi
  forbidden_link="$(find "$source_dir" -type l -print -quit)"
  if [[ -n "$forbidden_link" ]]; then
    die "installer source contains a symlink"
    return 1
  fi

  for relative in "${required_files[@]}"; do
    if [[ ! -f "$source_dir/$relative" || -L "$source_dir/$relative" ]]; then
      die "required allowlisted source is missing or unsafe: $relative"
      return 1
    fi
    if LC_ALL=C grep -E -i -q \
      "$forbidden_content|$sensitive_assignment|$credential_key_shape" \
      "$source_dir/$relative"; then
      die "allowlisted source contains forbidden content: $relative"
      return 1
    fi
  done
}

build_rename_helper() {
  local source_path="$1"
  local output_path="$2"
  local xcrun_bin="${CC_SWITCH_XCRUN_BIN:-/usr/bin/xcrun}"
  local codesign_bin="${CC_SWITCH_CODESIGN_BIN:-/usr/bin/codesign}"
  local lipo_bin="${CC_SWITCH_LIPO_BIN:-/usr/bin/lipo}"
  local otool_bin="${CC_SWITCH_OTOOL_BIN:-/usr/bin/otool}"
  local architectures
  local minimum_version

  if [[ ! -x "$xcrun_bin" || ! -x "$codesign_bin" \
    || ! -x "$lipo_bin" || ! -x "$otool_bin" ]]; then
    die 'required macOS helper build tool is unavailable'
    return 1
  fi
  if ! "$xcrun_bin" clang \
    -arch arm64 \
    -mmacosx-version-min=12.0 \
    -Os \
    -Wall \
    -Wextra \
    -Werror \
    -o "$output_path" \
    "$source_path"; then
    die 'failed to build the exclusive rename helper'
    return 1
  fi
  if ! "$codesign_bin" \
    --force \
    --sign - \
    --timestamp=none \
    --identifier com.ccswitch.modelhub.rename-exclusive \
    "$output_path"; then
    die 'failed to ad-hoc sign the exclusive rename helper'
    return 1
  fi
  if ! "$codesign_bin" --verify --strict --verbose=2 "$output_path"; then
    die 'exclusive rename helper signature verification failed'
    return 1
  fi
  architectures="$("$lipo_bin" -archs "$output_path")" || return 1
  if [[ "$architectures" != 'arm64' ]]; then
    die "exclusive rename helper has unexpected architectures: $architectures"
    return 1
  fi
  minimum_version="$(
    "$otool_bin" -l "$output_path" \
      | awk '/LC_BUILD_VERSION/ { found = 1; next } found && $1 == "minos" { print $2; exit }'
  )" || return 1
  if [[ "$minimum_version" != '12.0' ]]; then
    die "exclusive rename helper has unexpected minimum macOS version: $minimum_version"
    return 1
  fi
}

render_installer_with_helper_hash() {
  local source_installer="$1"
  local helper_path="$2"
  local output_installer="$3"
  local helper_sha

  helper_sha="$(/usr/bin/shasum -a 256 "$helper_path" | awk '{ print $1 }')" || return 1
  case "$helper_sha" in
    ''|*[!0-9a-f]* )
      die 'exclusive rename helper SHA-256 is invalid'
      return 1
      ;;
  esac
  if [[ "${#helper_sha}" -ne 64 ]]; then
    die 'exclusive rename helper SHA-256 must contain 64 lowercase hex characters'
    return 1
  fi
  if ! awk -v sha="$helper_sha" '
    {
      replacements += gsub(/__RENAME_HELPER_SHA256__/, sha)
      print
    }
    END { if (replacements != 1) exit 1 }
  ' "$source_installer" >"$output_installer"; then
    die 'installer must contain exactly one rename helper SHA placeholder'
    return 1
  fi
  if grep -Fq -- '__RENAME_HELPER_SHA256__' "$output_installer"; then
    die 'rendered installer still contains the rename helper SHA placeholder'
    return 1
  fi
}

normalize_modelhub_codex_retry_policy() {
  local file="$1"
  local output="$file.r15-retry"

  if ! awk '
    function finish_modelhub() {
      if (!in_modelhub) return
      if (!saw_request) print "request_max_retries = 2"
      if (!saw_stream) print "stream_max_retries = 3"
    }
    /^\[[^]]+\][[:space:]]*$/ {
      finish_modelhub()
      in_modelhub = ($0 == "[model_providers.modelhub]")
      if (in_modelhub) {
        found_modelhub = 1
        saw_request = 0
        saw_stream = 0
      }
      print
      next
    }
    {
      if (in_modelhub && $0 ~ /^[[:space:]]*request_max_retries[[:space:]]*=/) {
        if (!saw_request) print "request_max_retries = 2"
        saw_request = 1
        next
      }
      if (in_modelhub && $0 ~ /^[[:space:]]*stream_max_retries[[:space:]]*=/) {
        if (!saw_stream) print "stream_max_retries = 3"
        saw_stream = 1
        next
      }
      if (in_modelhub && $0 ~ /^[[:space:]]*retry_429[[:space:]]*=/) next
      print
    }
    END {
      finish_modelhub()
      if (!found_modelhub) exit 1
    }
  ' "$file" >"$output"; then
    rm -f "$output"
    die 'failed to normalize ModelHub Codex retry policy'
    return 1
  fi
  mv "$output" "$file"
}

copy_allowlisted_resources() {
  local source_dir="$1"
  local package_root="$2/modelhub-installer"
  local snapshot_dir="${CC_SWITCH_GOLDEN_SNAPSHOT_DIR:-}"

  mkdir -p \
    "$package_root/assets" \
    "$package_root/golden" \
    "$package_root/helpers" \
    "$package_root/templates"
  cp "$source_dir/assets/models-modelhub-1m.json" "$package_root/assets/models-modelhub-1m.json"
  if [[ -n "$snapshot_dir" ]]; then
    case "$snapshot_dir" in
      /*) ;;
      *) snapshot_dir="$(pwd -P)/$snapshot_dir" ;;
    esac
    if [[ ! -d "$snapshot_dir" || -L "$snapshot_dir" ]]; then
      die "portable golden snapshot directory is missing or unsafe: $snapshot_dir"
      return 1
    fi
    cp "$snapshot_dir/codex-config.toml" "$package_root/golden/codex-config.toml"
    normalize_modelhub_codex_retry_policy "$package_root/golden/codex-config.toml"
    cp "$snapshot_dir/settings.json" "$package_root/golden/settings.json"
    cp "$snapshot_dir/cc-switch.db" "$package_root/golden/cc-switch.db"
    local retry_max
    local retry_base_delay_ms
    local retry_max_delay_ms
    local retry_honor_after
    local activity_summary_mode
    local codex_metadata_model
    local remember_invalid_encrypted_reasoning
    retry_max="$(/usr/bin/jq -r '.localProxyRequestOverrides.retry429.maxRetries' \
      "$source_dir/templates/modelhub-provider-meta.json")"
    case "$retry_max" in
      ''|null|*[!0-9]*) die 'ModelHub retry429 default is invalid'; return 1 ;;
    esac
    retry_base_delay_ms="$(/usr/bin/jq -r '.localProxyRequestOverrides.retry429.baseDelayMs' \
      "$source_dir/templates/modelhub-provider-meta.json")"
    case "$retry_base_delay_ms" in
      ''|null|*[!0-9]*) die 'ModelHub retry429 base delay default is invalid'; return 1 ;;
    esac
    retry_max_delay_ms="$(/usr/bin/jq -r '.localProxyRequestOverrides.retry429.maxDelayMs' \
      "$source_dir/templates/modelhub-provider-meta.json")"
    case "$retry_max_delay_ms" in
      ''|null|*[!0-9]*) die 'ModelHub retry429 max delay default is invalid'; return 1 ;;
    esac
    retry_honor_after="$(/usr/bin/jq -r '.localProxyRequestOverrides.retry429.honorRetryAfter' \
      "$source_dir/templates/modelhub-provider-meta.json")"
    if [[ "$retry_honor_after" != 'true' ]]; then
      die 'ModelHub retry429 Retry-After default must be true'
      return 1
    fi
    activity_summary_mode="$(/usr/bin/jq -r \
      '.localProxyRequestOverrides.codexActivitySummaryMode' \
      "$source_dir/templates/modelhub-provider-meta.json")"
    if [[ "$activity_summary_mode" != 'map' ]]; then
      die 'ModelHub activity summary mode default must be map'
      return 1
    fi
    codex_metadata_model="$(/usr/bin/jq -r \
      '.localProxyRequestOverrides.codexMetadataModel' \
      "$source_dir/templates/modelhub-provider-meta.json")"
    if [[ "$codex_metadata_model" != 'gpt-5.6-sol' ]]; then
      die 'ModelHub Codex metadata model default must be gpt-5.6-sol'
      return 1
    fi
    remember_invalid_encrypted_reasoning="$(/usr/bin/jq -r \
      '.localProxyRequestOverrides.rememberInvalidEncryptedReasoning' \
      "$source_dir/templates/modelhub-provider-meta.json")"
    if [[ "$remember_invalid_encrypted_reasoning" != 'true' ]]; then
      die 'ModelHub encrypted reasoning memory default must be true'
      return 1
    fi
    /usr/bin/sqlite3 "$package_root/golden/cc-switch.db" \
      "UPDATE providers
          SET meta=json_set(
            json_remove(meta, '$.localProxyRequestOverrides.blockCodexActivitySummaries'),
            '$.localProxyRequestOverrides.retry429.maxRetries', $retry_max,
            '$.localProxyRequestOverrides.retry429.baseDelayMs', $retry_base_delay_ms,
            '$.localProxyRequestOverrides.retry429.maxDelayMs', $retry_max_delay_ms,
            '$.localProxyRequestOverrides.retry429.honorRetryAfter', json('true'),
            '$.localProxyRequestOverrides.codexActivitySummaryMode', '$activity_summary_mode',
            '$.localProxyRequestOverrides.codexMetadataModel', '$codex_metadata_model',
            '$.localProxyRequestOverrides.rememberInvalidEncryptedReasoning', json('true')
          )
        WHERE id='bytedance-modelhub-official-cli' AND app_type='codex';"
    if [[ "$(/usr/bin/sqlite3 -readonly "$package_root/golden/cc-switch.db" \
      "SELECT count(*) FROM providers
        WHERE id='bytedance-modelhub-official-cli'
          AND app_type='codex'
          AND json_extract(meta, '$.localProxyRequestOverrides.retry429.maxRetries')=$retry_max
          AND json_extract(meta, '$.localProxyRequestOverrides.retry429.baseDelayMs')=$retry_base_delay_ms
          AND json_extract(meta, '$.localProxyRequestOverrides.retry429.maxDelayMs')=$retry_max_delay_ms
          AND json_extract(meta, '$.localProxyRequestOverrides.retry429.honorRetryAfter')=1
          AND json_type(meta, '$.localProxyRequestOverrides.blockCodexActivitySummaries') IS NULL
          AND json_type(meta, '$.localProxyRequestOverrides.codexActivitySummaryMode')='text'
          AND json_extract(meta, '$.localProxyRequestOverrides.codexActivitySummaryMode')='$activity_summary_mode'
          AND json_type(meta, '$.localProxyRequestOverrides.codexMetadataModel')='text'
          AND json_extract(meta, '$.localProxyRequestOverrides.codexMetadataModel')='$codex_metadata_model'
          AND json_type(meta, '$.localProxyRequestOverrides.rememberInvalidEncryptedReasoning')='true'
          AND json_extract(meta, '$.localProxyRequestOverrides.rememberInvalidEncryptedReasoning')=1;")" != '1' ]]; then
      die 'failed to normalize ModelHub release metadata'
      return 1
    fi
  else
    cp "$source_dir/golden/codex-config.toml" "$package_root/golden/codex-config.toml"
    cp "$source_dir/golden/settings.json" "$package_root/golden/settings.json"
    /bin/bash "$source_dir/build-golden-db.sh" \
      --schema "$source_dir/golden/cc-switch-schema.sql" \
      --provider-config "$source_dir/golden/codex-config.toml" \
      --provider-meta "$source_dir/templates/modelhub-provider-meta.json" \
      --output "$package_root/golden/cc-switch.db"
  fi
  cp "$source_dir/templates/modelhub-provider.toml" "$package_root/templates/modelhub-provider.toml"
  cp "$source_dir/templates/modelhub-provider-meta.json" "$package_root/templates/modelhub-provider-meta.json"
  cp "$source_dir/templates/codex-managed-config.toml" "$package_root/templates/codex-managed-config.toml"
  cp "$source_dir/templates/com.ccswitch.modelhub-env.plist" "$package_root/templates/com.ccswitch.modelhub-env.plist"
  cp "$source_dir/templates/load-modelhub-env.sh" "$package_root/templates/load-modelhub-env.sh"
  build_rename_helper \
    "$source_dir/helpers/rename-exclusive.c" \
    "$package_root/helpers/rename-exclusive"
  chmod 644 \
    "$package_root/assets/models-modelhub-1m.json" \
    "$package_root/golden/codex-config.toml" \
    "$package_root/golden/settings.json" \
    "$package_root/golden/cc-switch.db" \
    "$package_root/templates/modelhub-provider.toml" \
    "$package_root/templates/modelhub-provider-meta.json" \
    "$package_root/templates/codex-managed-config.toml" \
    "$package_root/templates/com.ccswitch.modelhub-env.plist"
  chmod 755 "$package_root/templates/load-modelhub-env.sh"
  chmod 755 "$package_root/helpers/rename-exclusive"
}

build_reproducible_resource_archive() {
  local package_dir="$1"
  local output_path="$2"
  local tar_path="$3"

  find "$package_dir/modelhub-installer" -exec touch -t 197001010000 '{}' +
  COPYFILE_DISABLE=1 tar -cf "$tar_path" -C "$package_dir" modelhub-installer
  /usr/bin/gzip -n -9 -c "$tar_path" >"$output_path"
}

main() {
  local app_zip=''
  local output_dir=''
  local script_dir
  local source_dir
  local work_dir
  local package_dir
  local staged_output
  local output_parent
  local output_name

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --app-zip)
        [[ $# -ge 2 ]] || { die '--app-zip requires a path'; return 1; }
        app_zip="$2"
        shift 2
        ;;
      --output-dir)
        [[ $# -ge 2 ]] || { die '--output-dir requires a path'; return 1; }
        output_dir="$2"
        shift 2
        ;;
      --help|-h)
        [[ $# -eq 1 ]] || { die 'usage: package-release.sh --help'; return 1; }
        usage
        return 0
        ;;
      *)
        die "unknown argument: $1"
        return 1
        ;;
    esac
  done

  if [[ -z "$app_zip" || -z "$output_dir" ]]; then
    die 'both --app-zip and --output-dir are required'
    return 1
  fi
  if [[ ! -f "$app_zip" || -L "$app_zip" ]]; then
    die "app ZIP does not exist or is unsafe: $app_zip"
    return 1
  fi

  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source_dir="${CC_SWITCH_PACKAGE_SOURCE_DIR:-$script_dir}"
  if [[ ! -d "$source_dir" ]]; then
    die "installer source directory does not exist: $source_dir"
    return 1
  fi
  source_dir="$(cd "$source_dir" && pwd -P)"
  case "$output_dir" in
    /*) ;;
    *) output_dir="$(pwd -P)/$output_dir" ;;
  esac
  output_dir="$(printf '%s' "$output_dir" | sed 's#//*#/#g')"
  case "/$output_dir/" in
    */../*|*/./*)
      die "output directory must not contain dot path segments: $output_dir"
      return 1
      ;;
  esac
  output_dir="${output_dir%/}"
  output_parent="$(dirname "$output_dir")"
  output_name="$(basename "$output_dir")"
  if [[ -d "$output_parent" ]]; then
    output_dir="$(cd "$output_parent" && pwd -P)/$output_name"
  fi
  if [[ -d "$output_dir" ]]; then
    if [[ -L "$output_dir" ]]; then
      die "output directory must not be a symlink: $output_dir"
      return 1
    fi
    output_dir="$(cd "$output_dir" && pwd -P)"
    if find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
      die "output directory must be empty: $output_dir"
      return 1
    fi
  fi
  if [[ "$output_dir" == "/" \
    || "$output_dir" == "$source_dir" \
    || "${output_dir#"$source_dir/"}" != "$output_dir" \
    || "${source_dir#"$output_dir/"}" != "$source_dir" ]]; then
    die "output directory must be isolated from the installer source: $output_dir"
    return 1
  fi
  scan_source_tree "$source_dir" || return 1

  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/cc-switch-release-package.XXXXXX")"
  package_dir="$work_dir/package"
  staged_output="$work_dir/output"
  mkdir -p "$package_dir" "$staged_output"
  copy_allowlisted_resources "$source_dir" "$package_dir"

  build_reproducible_resource_archive \
    "$package_dir" \
    "$staged_output/$OUTPUT_RESOURCES_NAME" \
    "$work_dir/modelhub-installer-resources.tar"
  render_installer_with_helper_hash \
    "$source_dir/install.sh" \
    "$package_dir/modelhub-installer/helpers/rename-exclusive" \
    "$staged_output/$OUTPUT_INSTALLER_NAME"
  chmod 755 "$staged_output/$OUTPUT_INSTALLER_NAME"
  if ! CC_SWITCH_INSTALLER_TEST_MODE=1 /bin/bash -c \
    'source "$1"; validate_resource_archive "$2"' \
    _ \
    "$staged_output/$OUTPUT_INSTALLER_NAME" \
    "$staged_output/$OUTPUT_RESOURCES_NAME"; then
    rm -rf "$work_dir"
    die 'packaged ModelHub resources failed installer preflight validation'
    return 1
  fi
  cp "$app_zip" "$staged_output/$OUTPUT_APP_NAME"

  (
    cd "$staged_output"
    shasum -a 256 \
      "$OUTPUT_INSTALLER_NAME" \
      "$OUTPUT_APP_NAME" \
      "$OUTPUT_RESOURCES_NAME" \
      >"$OUTPUT_CHECKSUM_NAME"
    shasum -a 256 -c "$OUTPUT_CHECKSUM_NAME" >/dev/null
  )

  mkdir -p "$output_dir"
  cp "$staged_output/$OUTPUT_INSTALLER_NAME" "$output_dir/$OUTPUT_INSTALLER_NAME"
  cp "$staged_output/$OUTPUT_APP_NAME" "$output_dir/$OUTPUT_APP_NAME"
  cp "$staged_output/$OUTPUT_RESOURCES_NAME" "$output_dir/$OUTPUT_RESOURCES_NAME"
  cp "$staged_output/$OUTPUT_CHECKSUM_NAME" "$output_dir/$OUTPUT_CHECKSUM_NAME"
  rm -rf "$work_dir"

  printf 'Release assets written to %s\n' "$output_dir"
}

main "$@"
