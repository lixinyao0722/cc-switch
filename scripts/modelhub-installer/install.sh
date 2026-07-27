#!/bin/bash

set -euo pipefail

readonly MODELHUB_SECTION='[model_providers.modelhub]'

die() {
  echo "error: $*" >&2
  return 1
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
