#!/bin/bash

set -euo pipefail

readonly MODELHUB_SECTION='[model_providers.modelhub]'
readonly RELEASE_REPOSITORY='lixinyao0722/cc-switch'
readonly RELEASE_TAG='modelhub-installer-20260727'
readonly INSTALLER_ASSET='install.sh'
readonly APP_ASSET='CC-Switch-ModelHub-3.18.0-arm64.app.zip'
readonly RESOURCES_ASSET='modelhub-installer-resources.tar.gz'
readonly CHECKSUM_ASSET='SHA256SUMS.txt'
readonly EXPECTED_CODEX_TEAM_ID='2DC432GLL2'

die() {
  echo "error: $*" >&2
  return 1
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

validate_chatgpt_codex() {
  local codex_path="$1"
  local expected_team_id="$2"
  local codesign_bin="${CC_SWITCH_CODESIGN_BIN:-/usr/bin/codesign}"
  local details
  local team_id

  if [[ ! -x "$codex_path" ]]; then
    die "ChatGPT Codex executable not found: $codex_path"
    return 1
  fi
  if [[ ! -x "$codesign_bin" ]]; then
    die "codesign command not found: $codesign_bin"
    return 1
  fi
  if ! details="$("$codesign_bin" -dv --verbose=4 "$codex_path" 2>&1)"; then
    die "unable to inspect ChatGPT Codex signature"
    return 1
  fi
  team_id="$(printf '%s\n' "$details" | awk -F= '$1 == "TeamIdentifier" { print $2; exit }')"
  if [[ "$team_id" != "$expected_team_id" ]]; then
    die "unexpected ChatGPT Codex Team ID"
    return 1
  fi
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
  mkdir -p "$destination"
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
modelhub-installer/templates/
modelhub-installer/templates/com.ccswitch.modelhub-env.plist
modelhub-installer/templates/load-modelhub-env.sh
modelhub-installer/templates/modelhub-provider-meta.json
modelhub-installer/templates/modelhub-provider.toml
EOF
}

validate_resource_archive() {
  local archive="$1"
  local work_dir
  local listing
  local sorted_listing
  local expected_listing
  local verbose_listing
  local entry

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

  rm -rf "$work_dir"
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

  : >"$output_file"
  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s\n' "${line//$placeholder/$replacement}" >>"$output_file"
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

validate_merged_codex_config() {
  local file="$1"
  local user_home="$2"
  local escaped_home
  local key
  local count
  local section_count

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

  section_count="$(awk -v section="$MODELHUB_SECTION" '$0 == section { count += 1 } END { print count + 0 }' "$file")"
  if [[ "$section_count" != "1" ]]; then
    die "expected one $MODELHUB_SECTION section, found $section_count"
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

  if [[ ! -f "$template_file" ]]; then
    die "ModelHub template does not exist: $template_file"
    return 1
  fi
  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/cc-switch-config-merge.XXXXXX")"
  rendered_template="$work_dir/rendered-template.toml"
  filtered_source="$work_dir/filtered-source.toml"
  merged_file="$work_dir/merged.toml"
  escaped_home="$(toml_escape_basic_string "$user_home")"
  effective_source="$source_file"
  if [[ ! -f "$effective_source" ]]; then
    effective_source=/dev/null
  fi

  render_template "$template_file" "$rendered_template" '__USER_HOME__' "$escaped_home"

  awk '
    BEGIN { in_root = 1; skip_modelhub = 0 }

    /^[[:space:]]*\[/ {
      if ($0 == "[model_providers.modelhub]" || $0 ~ /^\[model_providers\.modelhub\./) {
        skip_modelhub = 1
        in_root = 0
        next
      }
      if (skip_modelhub) {
        skip_modelhub = 0
      }
      in_root = 0
    }

    skip_modelhub { next }

    in_root && $0 ~ /^[[:space:]]*(model|review_model|model_provider|model_reasoning_effort|model_auto_compact_token_limit|model_context_window|model_catalog_json)[[:space:]]*=/ {
      next
    }

    { print }
  ' "$effective_source" >"$filtered_source"

  awk -v section="$MODELHUB_SECTION" '$0 == section { exit } { print }' "$rendered_template" >"$merged_file"
  if [[ -s "$filtered_source" ]]; then
    printf '\n' >>"$merged_file"
    cat "$filtered_source" >>"$merged_file"
  fi
  printf '\n' >>"$merged_file"
  awk -v section="$MODELHUB_SECTION" '$0 == section { emit = 1 } emit { print }' "$rendered_template" >>"$merged_file"

  validate_merged_codex_config "$merged_file" "$user_home"
  mkdir -p "$(dirname "$output_file")"
  mv "$merged_file" "$output_file"
  rm -rf "$work_dir"
}

usage() {
  cat <<'EOF'
Usage: install.sh [--help]

Install the CC Switch ModelHub integration. The complete installation flow is
added in later implementation tasks.
EOF
}

main() {
  case "${1:-}" in
    --help|-h)
      usage
      ;;
    "")
      die "installation workflow is not implemented yet"
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
