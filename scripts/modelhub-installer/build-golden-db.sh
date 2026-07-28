#!/bin/bash

set -euo pipefail

PATH='/usr/bin:/bin:/usr/sbin:/sbin'
export PATH

usage() {
  cat <<'EOF'
Usage: build-golden-db.sh --schema PATH --provider-config PATH --provider-meta PATH --output PATH
EOF
}

die() {
  echo "error: $*" >&2
  return 1
}

sql_quote() {
  local value="$1"
  local escaped
  case "$value" in
    *$'\n'*|*$'\r'*)
      die 'SQL path contains a newline'
      return 1
      ;;
  esac
  escaped="$(printf '%s' "$value" | /usr/bin/sed "s/'/''/g")"
  printf "'%s'" "$escaped"
}

validate_input_file() {
  local path="$1"
  local label="$2"
  if [[ ! -f "$path" || -L "$path" ]]; then
    die "$label is missing or unsafe: $path"
    return 1
  fi
}

main() {
  local schema=''
  local provider_config=''
  local provider_meta=''
  local output=''
  local work_dir
  local staged_db
  local output_parent
  local output_name
  local output_temp=''
  local config_sql
  local meta_sql
  local integrity
  local raw_strings

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --schema)
        [[ $# -ge 2 ]] || { die '--schema requires a path'; return 1; }
        schema="$2"
        shift 2
        ;;
      --provider-config)
        [[ $# -ge 2 ]] || { die '--provider-config requires a path'; return 1; }
        provider_config="$2"
        shift 2
        ;;
      --provider-meta)
        [[ $# -ge 2 ]] || { die '--provider-meta requires a path'; return 1; }
        provider_meta="$2"
        shift 2
        ;;
      --output)
        [[ $# -ge 2 ]] || { die '--output requires a path'; return 1; }
        output="$2"
        shift 2
        ;;
      --help|-h)
        usage
        return 0
        ;;
      *)
        die "unknown argument: $1"
        return 1
        ;;
    esac
  done

  [[ -n "$schema" && -n "$provider_config" && -n "$provider_meta" && -n "$output" ]] \
    || { die 'schema, provider config, provider meta, and output are required'; return 1; }
  validate_input_file "$schema" 'golden schema' || return 1
  validate_input_file "$provider_config" 'golden provider config' || return 1
  validate_input_file "$provider_meta" 'golden provider metadata' || return 1
  /usr/bin/jq empty "$provider_meta" || { die 'golden provider metadata is invalid'; return 1; }

  if ! /usr/bin/grep -Fq -- '__USER_HOME__/.codex/models-modelhub-1m.json' "$provider_config" \
    || ! /usr/bin/grep -Fq -- 'https://aidp.bytedance.net/api/modelhub/online' "$provider_config"; then
    die 'golden provider config is missing required portable ModelHub fields'
    return 1
  fi
  if LC_ALL=C /usr/bin/grep -E -i -q \
    '/Users/|127[.]0[.]0[.]1:15721|localhost:15721|experimental_bearer_token|OPENAI_API_KEY|access_token|refresh_token|id_token' \
    "$provider_config"; then
    die 'golden provider config contains a forbidden path, route, or credential field'
    return 1
  fi

  case "$output" in
    /*) ;;
    *) output="$(pwd -P)/$output" ;;
  esac
  output_parent="$(dirname "$output")"
  output_name="$(basename "$output")"
  /bin/mkdir -p "$output_parent"
  output_parent="$(cd "$output_parent" && pwd -P)"
  output="$output_parent/$output_name"
  if [[ -L "$output" || -d "$output" ]]; then
    die "golden database output is unsafe: $output"
    return 1
  fi

  work_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/cc-switch-golden-db.XXXXXX")"
  staged_db="$work_dir/cc-switch.db"
  trap '/bin/rm -rf -- "$work_dir"; if [[ -n "$output_temp" ]]; then /bin/rm -f -- "$output_temp"; fi' EXIT INT TERM

  /usr/bin/sqlite3 "$staged_db" <"$schema"
  config_sql="$(sql_quote "$provider_config")"
  meta_sql="$(sql_quote "$provider_meta")"

  /usr/bin/sqlite3 "$staged_db" <<SQL
PRAGMA foreign_keys = ON;
BEGIN IMMEDIATE;
INSERT INTO providers (
  id, app_type, name, settings_config, website_url, category, created_at,
  sort_index, notes, icon, meta, is_current, in_failover_queue, provider_type
) VALUES (
  'bytedance-modelhub-official-cli',
  'codex',
  'Bytedance ModelHub - 官方CLI',
  json_object('auth', json('{}'), 'config', CAST(readfile($config_sql) AS TEXT)),
  'https://aidp.bytedance.net',
  'third_party',
  0,
  0,
  'ModelHub Responses via official ChatGPT Codex CLI',
  'openai',
  CAST(readfile($meta_sql) AS TEXT),
  1,
  0,
  NULL
);
INSERT INTO proxy_config (app_type, created_at, updated_at)
VALUES
  ('claude', '1970-01-01 00:00:00', '1970-01-01 00:00:00'),
  ('gemini', '1970-01-01 00:00:00', '1970-01-01 00:00:00'),
  ('grokbuild', '1970-01-01 00:00:00', '1970-01-01 00:00:00');
INSERT INTO proxy_config (
  app_type, proxy_enabled, listen_address, listen_port, enable_logging,
  enabled, auto_failover_enabled, max_retries, streaming_first_byte_timeout,
  streaming_idle_timeout, non_streaming_timeout, circuit_failure_threshold,
  circuit_success_threshold, circuit_timeout_seconds,
  circuit_error_rate_threshold, circuit_min_requests,
  default_cost_multiplier, pricing_model_source, live_takeover_active,
  created_at, updated_at
) VALUES (
  'codex', 1, '127.0.0.1', 15721, 1,
  1, 0, 3, 60,
  120, 600, 4,
  2, 60,
  0.6, 10,
  '1', 'response', 0,
  '1970-01-01 00:00:00', '1970-01-01 00:00:00'
);
INSERT INTO settings (key, value) VALUES
  ('official_providers_seeded', 'true'),
  ('common_config_legacy_migrated_v1', 'true'),
  ('default_skill_repos_initialized', 'true');
COMMIT;
VACUUM;
SQL

  integrity="$(/usr/bin/sqlite3 -readonly "$staged_db" 'PRAGMA integrity_check;')"
  [[ "$integrity" == 'ok' ]] || { die 'golden database integrity check failed'; return 1; }
  [[ "$(/usr/bin/sqlite3 -readonly "$staged_db" 'PRAGMA user_version;')" == '16' ]] \
    || { die 'golden database user_version is not 16'; return 1; }
  [[ "$(/usr/bin/sqlite3 -readonly "$staged_db" 'SELECT count(*) FROM providers;')" == '1' ]] \
    || { die 'golden database must contain exactly one provider'; return 1; }
  [[ "$(/usr/bin/sqlite3 -readonly "$staged_db" "SELECT count(*) FROM proxy_request_logs")" == '0' ]] \
    || { die 'golden database contains request history'; return 1; }
  [[ "$(/usr/bin/sqlite3 -readonly "$staged_db" "SELECT count(*) FROM proxy_live_backup")" == '0' ]] \
    || { die 'golden database contains a live backup'; return 1; }
  [[ "$(/usr/bin/sqlite3 -readonly "$staged_db" "SELECT instr(json_extract(settings_config, '$.config'), '127.0.0.1:15721') FROM providers")" == '0' ]] \
    || { die 'golden provider points to the local proxy'; return 1; }

  raw_strings="$(/usr/bin/strings "$staged_db")"
  if printf '%s\n' "$raw_strings" | LC_ALL=C /usr/bin/grep -E -i -q \
    '/Users/|experimental_bearer_token|OPENAI_API_KEY|access_token|refresh_token|id_token'; then
    die 'golden database contains a forbidden path or credential field'
    return 1
  fi

  output_temp="$(/usr/bin/mktemp "$output_parent/.cc-switch-golden.XXXXXX")"
  /bin/cp "$staged_db" "$output_temp"
  /bin/chmod 0600 "$output_temp"
  /bin/mv -f "$output_temp" "$output"
  output_temp=''
  trap - EXIT INT TERM
  /bin/rm -rf -- "$work_dir"
  printf 'Golden CC Switch database written to %s\n' "$output"
}

main "$@"
