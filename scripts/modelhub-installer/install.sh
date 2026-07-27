#!/bin/bash

set -euo pipefail

PATH='/usr/bin:/bin:/usr/sbin:/sbin'
export PATH

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
readonly KEYCHAIN_SERVICE='com.ccswitch.modelhub.ak'
readonly LAUNCH_AGENT_LABEL='com.ccswitch.modelhub-env'

INSTALL_USER_HOME=''
INSTALL_APPLICATIONS_DIR=''
CC_SWITCH_APP_PATH=''
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
  CHATGPT_CODEX_PATH="$INSTALL_APPLICATIONS_DIR/ChatGPT.app/Contents/Resources/codex"
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
  printf '%s\t%s\n' "$LOCAL_INSTALLER_PATH" 'install.sh'
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

run_with_privilege() {
  if [[ "$NEEDS_SUDO" == "1" ]]; then
    /usr/bin/sudo "$@"
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

create_backup() {
  local backup_root="$1"
  local timestamp="${CC_SWITCH_INSTALLER_TIMESTAMP:-$(date -u +%Y%m%dT%H%M%SZ)}"
  local backup_dir="$backup_root/$timestamp"
  local manifest
  local target
  local relative
  local counter=1
  local ditto_bin="${CC_SWITCH_DITTO_BIN:-/usr/bin/ditto}"

  while [[ -e "$backup_dir" ]]; do
    backup_dir="$backup_root/$timestamp-$counter"
    counter=$((counter + 1))
  done
  /bin/mkdir -p "$backup_dir/files"
  /bin/chmod 700 "$backup_dir"
  manifest="$backup_dir/manifest.tsv"
  : >"$manifest"

  while IFS=$'\t' read -r target relative; do
    if [[ -L "$target" ]]; then
      die "managed target must not be a symlink: $target"
      return 1
    fi
    if [[ -d "$target" ]]; then
      "$ditto_bin" "$target" "$backup_dir/files/$relative"
      printf '%s\t1\t%s\n' "$target" "files/$relative" >>"$manifest"
    elif [[ -f "$target" ]]; then
      /bin/cp -p "$target" "$backup_dir/files/$relative"
      printf '%s\t1\t%s\n' "$target" "files/$relative" >>"$manifest"
    else
      printf '%s\t0\t-\n' "$target" >>"$manifest"
    fi
  done < <(managed_targets)

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
  local ditto_bin="${CC_SWITCH_DITTO_BIN:-/usr/bin/ditto}"

  validate_backup_manifest "$backup_dir" || return 1

  unload_launch_agent
  clear_runtime_environment
  while IFS=$'\t' read -r target existed relative; do
    if ! is_managed_target "$target"; then
      die "backup manifest contains unmanaged target: $target"
      return 1
    fi
    remove_managed_target "$target" || return 1
    if [[ "$existed" == "1" ]]; then
      backup_path="$backup_dir/$relative"
      if [[ -d "$backup_path" ]]; then
        /bin/mkdir -p "$(dirname "$target")"
        if [[ "$target" == "$CC_SWITCH_APP_PATH" ]]; then
          run_with_privilege "$ditto_bin" "$backup_path" "$target"
        else
          "$ditto_bin" "$backup_path" "$target"
        fi
      elif [[ -f "$backup_path" ]]; then
        /bin/mkdir -p "$(dirname "$target")"
        /bin/cp -p "$backup_path" "$target"
      else
        die "backup payload is missing: $backup_path"
        return 1
      fi
    elif [[ "$existed" != "0" ]]; then
      die "backup manifest has invalid existence flag: $existed"
      return 1
    fi
  done <"$manifest"

  reload_restored_launch_agent
}

install_app() {
  local app_zip="$1"
  local ditto_bin="${CC_SWITCH_DITTO_BIN:-/usr/bin/ditto}"
  local codesign_bin="${CC_SWITCH_CODESIGN_BIN:-/usr/bin/codesign}"
  local xattr_bin="${CC_SWITCH_XATTR_BIN:-/usr/bin/xattr}"
  local work_dir
  local extracted_app

  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/cc-switch-app-install.XXXXXX")"
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
  /bin/mkdir -p "$INSTALL_APPLICATIONS_DIR"
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
  /bin/rm -rf "$work_dir"
}

install_runtime_files() {
  local resources_dir="$1"
  local verified_installer="$2"
  local provider_id
  local config_work_dir
  local config_work_file
  local plist_work_dir
  local plist_work_file
  local escaped_helper_path

  /bin/mkdir -p \
    "$INSTALL_USER_HOME/.codex" \
    "$INSTALL_USER_HOME/.cc-switch" \
    "$(dirname "$ENV_HELPER_PATH")" \
    "$(dirname "$LAUNCH_AGENT_PATH")"
  /bin/chmod 700 "$INSTALL_USER_HOME/.codex" "$INSTALL_USER_HOME/.cc-switch" "$(dirname "$ENV_HELPER_PATH")"

  /usr/bin/install -m 600 "$resources_dir/assets/models-modelhub-1m.json" "$MODEL_CATALOG_PATH"

  config_work_dir="$(mktemp -d "$INSTALL_USER_HOME/.codex/.modelhub-config.XXXXXX")"
  config_work_file="$config_work_dir/config.toml"
  merge_codex_config \
    "$CODEX_CONFIG_PATH" \
    "$resources_dir/templates/modelhub-provider.toml" \
    "$config_work_file" \
    "$INSTALL_USER_HOME"
  /bin/chmod 600 "$config_work_file"
  /bin/mv "$config_work_file" "$CODEX_CONFIG_PATH"
  /bin/rmdir "$config_work_dir"

  /usr/bin/install -m 700 "$resources_dir/templates/load-modelhub-env.sh" "$ENV_HELPER_PATH"
  plist_work_dir="$(mktemp -d "$(dirname "$LAUNCH_AGENT_PATH")/.modelhub-plist.XXXXXX")"
  plist_work_file="$plist_work_dir/com.ccswitch.modelhub-env.plist"
  escaped_helper_path="$(xml_escape "$ENV_HELPER_PATH")"
  render_template \
    "$resources_dir/templates/com.ccswitch.modelhub-env.plist" \
    "$plist_work_file" \
    '__HELPER_PATH__' \
    "$escaped_helper_path"
  if ! /usr/bin/plutil -lint "$plist_work_file" >/dev/null; then
    /bin/rm -rf "$plist_work_dir"
    die "rendered LaunchAgent is invalid"
    return 1
  fi
  /usr/bin/install -m 600 "$plist_work_file" "$LAUNCH_AGENT_PATH"
  /bin/rm -rf "$plist_work_dir"

  ensure_cc_switch_schema "$CC_SWITCH_DATABASE_PATH" "$CC_SWITCH_APP_PATH" || return 1
  provider_id="$(
    merge_provider_database \
      "$CC_SWITCH_DATABASE_PATH" \
      "$CODEX_CONFIG_PATH" \
      "$resources_dir/templates/modelhub-provider-meta.json"
  )" || return 1
  update_settings_json "$CC_SWITCH_SETTINGS_PATH" "$provider_id" || return 1
  /usr/bin/install -m 700 "$verified_installer" "$LOCAL_INSTALLER_PATH"
}

keychain_account_name() {
  /usr/bin/id -un
}

configure_keychain() {
  local security_bin="${CC_SWITCH_SECURITY_BIN:-/usr/bin/security}"
  local account_name
  account_name="$(keychain_account_name)"
  KEYCHAIN_CREATED_BY_RUN=0

  if "$security_bin" find-generic-password -a "$account_name" -s "$KEYCHAIN_SERVICE" -w >/dev/null 2>&1; then
    printf '1\n' >"$ACTIVE_BACKUP_DIR/keychain-existed"
  else
    printf '0\n' >"$ACTIVE_BACKUP_DIR/keychain-existed"
    KEYCHAIN_CREATED_BY_RUN=1
  fi

  if [[ "${CC_SWITCH_INSTALLER_TEST_MODE:-0}" == "1" ]]; then
    if ! "$security_bin" add-generic-password -a "$account_name" -s "$KEYCHAIN_SERVICE" -U -w; then
      return 1
    fi
  else
    printf '%s\n' '请输入从管理员处获取的 MODELHUB_AK；输入内容将保存到 macOS Keychain。' >&2
    if ! "$security_bin" add-generic-password -a "$account_name" -s "$KEYCHAIN_SERVICE" -U -w </dev/tty; then
      return 1
    fi
  fi
}

delete_keychain_item() {
  local security_bin="${CC_SWITCH_SECURITY_BIN:-/usr/bin/security}"
  local account_name
  account_name="$(keychain_account_name)"
  "$security_bin" delete-generic-password -a "$account_name" -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1 || true
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
    "$sleep_bin" 1
    attempt=$((attempt + 1))
  done

  die "CC Switch health check timed out"
  return 1
}

prepare_application_permissions() {
  NEEDS_SUDO=0
  /bin/mkdir -p "$INSTALL_APPLICATIONS_DIR" 2>/dev/null || true
  if [[ ! -w "$INSTALL_APPLICATIONS_DIR" ]]; then
    NEEDS_SUDO=1
    if ! /usr/bin/sudo -v; then
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
  quit_apps
  unload_launch_agent
  clear_runtime_environment
  if [[ "$KEYCHAIN_CREATED_BY_RUN" == "1" ]]; then
    delete_keychain_item
  fi
  if [[ -n "$ACTIVE_BACKUP_DIR" ]]; then
    restore_backup "$ACTIVE_BACKUP_DIR"
  fi
}

run_install_transaction() {
  local asset_dir="$1"
  local resources_dir="$2"
  local health_timeout="${CC_SWITCH_INSTALLER_HEALTH_TIMEOUT:-30}"

  install_app "$asset_dir/$APP_ASSET" || return 1
  install_runtime_files "$resources_dir" "$asset_dir/$INSTALLER_ASSET" || return 1
  configure_keychain || return 1
  install_launch_agent || return 1
  start_cc_switch || return 1
  wait_for_health 'http://127.0.0.1:15721/health' "$health_timeout" || return 1
}

perform_install() {
  local operating_system
  local architecture
  local major_version
  local stage_dir
  local asset_dir
  local resources_parent
  local resources_dir

  configure_install_paths || return 1
  operating_system="${CC_SWITCH_INSTALLER_TEST_OS:-$(/usr/bin/uname -s)}"
  architecture="${CC_SWITCH_INSTALLER_TEST_ARCH:-$(/usr/bin/uname -m)}"
  major_version="${CC_SWITCH_INSTALLER_TEST_MACOS_MAJOR:-$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d. -f1)}"
  validate_platform "$operating_system" "$architecture" "$major_version" || return 1
  validate_chatgpt_codex "$CHATGPT_CODEX_PATH" "$EXPECTED_CODEX_TEAM_ID" || return 1

  stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/cc-switch-modelhub-install.XXXXXX")"
  if [[ "${CC_SWITCH_INSTALLER_TEST_MODE:-0}" == "1" ]]; then
    asset_dir="${CC_SWITCH_INSTALLER_ASSET_DIR:?test asset directory is required}"
  else
    asset_dir="$stage_dir/assets"
    download_release_assets "$asset_dir" || {
      /bin/rm -rf "$stage_dir"
      return 1
    }
  fi
  verify_release_assets "$asset_dir" || {
    /bin/rm -rf "$stage_dir"
    return 1
  }
  validate_resource_archive "$asset_dir/$RESOURCES_ASSET" || {
    /bin/rm -rf "$stage_dir"
    return 1
  }

  resources_parent="$stage_dir/resources"
  /bin/mkdir -p "$resources_parent"
  extract_verified_resources "$asset_dir" "$resources_parent" || {
    /bin/rm -rf "$stage_dir"
    return 1
  }
  resources_dir="$resources_parent/modelhub-installer"

  prepare_application_permissions || {
    /bin/rm -rf "$stage_dir"
    return 1
  }
  quit_apps
  ACTIVE_BACKUP_DIR="$(create_backup "$BACKUP_ROOT")" || {
    /bin/rm -rf "$stage_dir"
    return 1
  }
  MUTATION_STARTED=1
  INSTALL_COMPLETED=0
  KEYCHAIN_CREATED_BY_RUN=0

  if ! run_install_transaction "$asset_dir" "$resources_dir"; then
    rollback_failed_install || true
    /bin/rm -rf "$stage_dir"
    return 1
  fi

  INSTALL_COMPLETED=1
  : >"$ACTIVE_BACKUP_DIR/install-completed"
  /bin/rm -rf "$stage_dir"
}

rollback_latest() {
  local latest_backup
  local keychain_existed

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
  quit_apps
  unload_launch_agent
  clear_runtime_environment
  keychain_existed="$(/bin/cat "$latest_backup/keychain-existed" 2>/dev/null || printf '1')"
  if [[ "$keychain_existed" == "0" ]]; then
    delete_keychain_item
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
  main "$@"
fi
