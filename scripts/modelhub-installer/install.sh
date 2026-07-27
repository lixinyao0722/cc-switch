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
readonly MODELHUB_PROVIDER_ID='bytedance-modelhub-official-cli'
readonly MODELHUB_PROVIDER_NAME='Bytedance ModelHub - 官方CLI'

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
  provider_id="${provider_id:-$MODELHUB_PROVIDER_ID}"
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

  mkdir -p "$(dirname "$settings_path")"
  work_dir="$(mktemp -d "$(dirname "$settings_path")/.cc-switch-settings.XXXXXX")"
  work_file="$work_dir/settings.json"
  if [[ -f "$settings_path" ]]; then
    if ! "$plutil_bin" -convert xml1 -o /dev/null "$settings_path" >/dev/null 2>&1; then
      rm -rf "$work_dir"
      die "CC Switch settings file is not valid JSON: $settings_path"
      return 1
    fi
    cp -p "$settings_path" "$work_file"
  else
    printf '{\n  "currentProviderCodex": "%s",\n  "enableLocalProxy": true,\n  "preserveCodexOfficialAuthOnSwitch": true\n}\n' \
      "$provider_id" \
      >"$work_file"
    if ! "$plutil_bin" -convert xml1 -o /dev/null "$work_file" >/dev/null 2>&1; then
      rm -rf "$work_dir"
      die "failed to create CC Switch settings"
      return 1
    fi
    mv "$work_file" "$settings_path"
    rmdir "$work_dir"
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

  mv "$work_file" "$settings_path"
  rmdir "$work_dir"
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
