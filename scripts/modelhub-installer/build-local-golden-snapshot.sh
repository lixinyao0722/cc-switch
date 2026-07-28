#!/bin/bash

set -euo pipefail

PATH='/usr/bin:/bin:/usr/sbin:/sbin'
export PATH

readonly STABLE_MODELHUB_PROVIDER_ID='bytedance-modelhub-official-cli'
readonly MODELHUB_PROVIDER_NAME='Bytedance ModelHub - 官方CLI'
readonly MODELHUB_UPSTREAM='https://aidp.bytedance.net/api/modelhub/online'

die() {
  echo "error: $*" >&2
  return 1
}

sql_quote() {
  local value="$1"
  case "$value" in
    *$'\n'*|*$'\r'*) die 'SQL value contains a newline'; return 1 ;;
  esac
  printf "'%s'" "$(printf '%s' "$value" | /usr/bin/sed "s/'/''/g")"
}

escape_sed_pattern() {
  printf '%s' "$1" | /usr/bin/sed 's/[][\.^$*#]/\\&/g'
}

main() {
  local source_home=''
  local codex_config=''
  local settings=''
  local database=''
  local output_dir=''
  local work_dir
  local portable_config
  local portable_settings
  local portable_database
  local escaped_home
  local source_home_sql
  local stable_id_sql
  local current_id
  local current_id_sql
  local portable_config_sql
  local table
  local column

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --source-home) source_home="$2"; shift 2 ;;
      --codex-config) codex_config="$2"; shift 2 ;;
      --settings) settings="$2"; shift 2 ;;
      --database) database="$2"; shift 2 ;;
      --output-dir) output_dir="$2"; shift 2 ;;
      *) die "unknown argument: $1"; return 1 ;;
    esac
  done
  [[ "$source_home" == /* && "$source_home" != '/' ]] \
    || { die 'source home must be an absolute non-root path'; return 1; }
  for file in "$codex_config" "$settings" "$database"; do
    [[ -f "$file" && ! -L "$file" ]] \
      || { die "snapshot input is missing or unsafe: $file"; return 1; }
  done
  [[ -n "$output_dir" ]] || { die 'output directory is required'; return 1; }
  case "$output_dir" in
    /*) ;;
    *) output_dir="$(pwd -P)/$output_dir" ;;
  esac
  [[ ! -e "$output_dir" ]] \
    || { die "snapshot output already exists: $output_dir"; return 1; }

  work_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/cc-switch-local-golden.XXXXXX")"
  trap '/bin/rm -rf -- "$work_dir"' EXIT INT TERM
  portable_config="$work_dir/codex-config.toml"
  portable_settings="$work_dir/settings.json"
  portable_database="$work_dir/cc-switch.db"
  escaped_home="$(escape_sed_pattern "$source_home")"

  /usr/bin/sed \
    -e "s#$escaped_home#__USER_HOME__#g" \
    -e "s#base_url = \"http://127.0.0.1:15721/v1\"#base_url = \"$MODELHUB_UPSTREAM\"#g" \
    -e '/^[[:space:]]*experimental_bearer_token[[:space:]]*=/d' \
    "$codex_config" >"$portable_config"
  if ! /usr/bin/grep -Fq -- "$MODELHUB_UPSTREAM" "$portable_config" \
    || /usr/bin/grep -Fq -- "$source_home" "$portable_config" \
    || LC_ALL=C /usr/bin/grep -E -i -q \
      'access_token[[:space:]]*=|refresh_token[[:space:]]*=|OPENAI_API_KEY[[:space:]]*=|experimental_bearer_token[[:space:]]*=' \
      "$portable_config"; then
    die 'portable Codex snapshot failed path or credential validation'
    return 1
  fi

  /usr/bin/jq \
    --arg source_home "$source_home" \
    --arg provider_id "$STABLE_MODELHUB_PROVIDER_ID" \
    'walk(if type == "string" then split($source_home) | join("__USER_HOME__") else . end)
     | .currentProviderCodex = $provider_id
     | .enableLocalProxy = true
     | .preserveCodexOfficialAuthOnSwitch = true
     | .proxyConfirmed = true
     | .firstRunNoticeConfirmed = true' \
    "$settings" >"$portable_settings"

  /usr/bin/sqlite3 "$database" ".backup '$portable_database'"
  current_id="$(/usr/bin/sqlite3 -readonly "$portable_database" \
    "SELECT id FROM providers WHERE app_type='codex' AND name='$MODELHUB_PROVIDER_NAME' AND is_current=1 LIMIT 1;")"
  [[ -n "$current_id" ]] || { die 'current ModelHub provider was not found'; return 1; }
  source_home_sql="$(sql_quote "$source_home")"
  stable_id_sql="$(sql_quote "$STABLE_MODELHUB_PROVIDER_ID")"
  current_id_sql="$(sql_quote "$current_id")"
  portable_config_sql="$(sql_quote "$portable_config")"

  /usr/bin/sqlite3 "$portable_database" <<SQL
PRAGMA foreign_keys = OFF;
BEGIN IMMEDIATE;
DELETE FROM provider_health;
DELETE FROM proxy_live_backup;
DELETE FROM proxy_request_logs;
DELETE FROM session_log_sync;
DELETE FROM stream_check_logs;
DELETE FROM usage_daily_rollups;
DELETE FROM providers
 WHERE id=$stable_id_sql AND app_type='codex' AND id<>$current_id_sql;
UPDATE provider_endpoints
   SET provider_id=$stable_id_sql
 WHERE provider_id=$current_id_sql AND app_type='codex';
UPDATE providers
   SET id=$stable_id_sql
 WHERE id=$current_id_sql AND app_type='codex';
UPDATE providers
   SET is_current=CASE WHEN id=$stable_id_sql THEN 1 ELSE 0 END
 WHERE app_type='codex';
UPDATE providers
   SET settings_config=json_set(settings_config, '$.auth', json('{}'))
 WHERE json_type(settings_config, '$.auth')='object';
UPDATE providers
   SET settings_config=json_remove(
     settings_config,
     '$.env.ANTHROPIC_AUTH_TOKEN', '$.env.ANTHROPIC_API_KEY',
     '$.env.OPENAI_API_KEY', '$.env.GEMINI_API_KEY', '$.env.GOOGLE_API_KEY',
     '$.apiKey', '$.api_key', '$.token', '$.password', '$.credential'
   );
UPDATE providers
   SET settings_config=json_set(
     settings_config,
     '$.auth', json('{}'),
     '$.config', CAST(readfile($portable_config_sql) AS TEXT)
   ),
       name='$MODELHUB_PROVIDER_NAME',
       website_url='https://aidp.bytedance.net',
       is_current=1,
       in_failover_queue=0
 WHERE id=$stable_id_sql AND app_type='codex';
UPDATE settings
   SET value=replace(replace(value, $source_home_sql, '__USER_HOME__'), $current_id_sql, $stable_id_sql);
UPDATE providers
   SET settings_config=replace(settings_config, $source_home_sql, '__USER_HOME__'),
       website_url=replace(COALESCE(website_url,''), $source_home_sql, '__USER_HOME__'),
       notes=replace(COALESCE(notes,''), $source_home_sql, '__USER_HOME__');
UPDATE provider_endpoints
   SET url=replace(url, $source_home_sql, '__USER_HOME__');
UPDATE mcp_servers
   SET server_config=replace(server_config, $source_home_sql, '__USER_HOME__'),
       homepage=replace(COALESCE(homepage,''), $source_home_sql, '__USER_HOME__'),
       docs=replace(COALESCE(docs,''), $source_home_sql, '__USER_HOME__');
UPDATE prompts
   SET content=replace(content, $source_home_sql, '__USER_HOME__'),
       description=replace(COALESCE(description,''), $source_home_sql, '__USER_HOME__');
UPDATE skills
   SET directory=replace(directory, $source_home_sql, '__USER_HOME__'),
       readme_url=replace(COALESCE(readme_url,''), $source_home_sql, '__USER_HOME__');
UPDATE profiles
   SET payload=replace(payload, $source_home_sql, '__USER_HOME__');
UPDATE proxy_config
   SET proxy_enabled=CASE WHEN app_type='codex' THEN 1 ELSE proxy_enabled END,
       enabled=CASE WHEN app_type='codex' THEN 1 ELSE 0 END,
       auto_failover_enabled=CASE WHEN app_type='codex' THEN 0 ELSE auto_failover_enabled END,
       listen_address=CASE WHEN app_type='codex' THEN '127.0.0.1' ELSE listen_address END,
       listen_port=CASE WHEN app_type='codex' THEN 15721 ELSE listen_port END,
       live_takeover_active=0,
       updated_at='1970-01-01 00:00:00';
COMMIT;
VACUUM;
SQL

  [[ "$(/usr/bin/sqlite3 -readonly "$portable_database" 'PRAGMA integrity_check;')" == 'ok' ]] \
    || { die 'portable database integrity check failed'; return 1; }
  for table in provider_health proxy_live_backup proxy_request_logs session_log_sync stream_check_logs usage_daily_rollups; do
    [[ "$(/usr/bin/sqlite3 -readonly "$portable_database" "SELECT count(*) FROM $table;")" == '0' ]] \
      || { die "portable database contains excluded rows in $table"; return 1; }
  done
  [[ "$(/usr/bin/sqlite3 -readonly "$portable_database" "SELECT count(*) FROM providers WHERE id=$stable_id_sql AND app_type='codex' AND is_current=1;")" == '1' ]] \
    || { die 'portable database ModelHub provider is invalid'; return 1; }
  if /usr/bin/strings "$portable_database" | /usr/bin/grep -Fq -- "$source_home"; then
    die 'portable database still contains the source home path'
    return 1
  fi
  if /usr/bin/strings "$portable_database" | LC_ALL=C /usr/bin/grep -E -i -q \
    'access_token.{0,80}[A-Za-z0-9_-]{20,}|refresh_token.{0,80}[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{20,}'; then
    die 'portable database still contains credential material'
    return 1
  fi

  /bin/mkdir -p "$(dirname "$output_dir")"
  /bin/mv "$work_dir" "$output_dir"
  trap - EXIT INT TERM
  printf 'Portable local golden snapshot written to %s\n' "$output_dir"
}

main "$@"
