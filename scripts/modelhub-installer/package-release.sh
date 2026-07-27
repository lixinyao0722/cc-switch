#!/bin/bash

set -euo pipefail

PATH='/usr/bin:/bin:/usr/sbin:/sbin'
export PATH

readonly OUTPUT_APP_NAME='CC-Switch-ModelHub-3.18.0-arm64.app.zip'
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
    'assets/models-modelhub-1m.json'
    'templates/modelhub-provider.toml'
    'templates/modelhub-provider-meta.json'
    'templates/com.ccswitch.modelhub-env.plist'
    'templates/load-modelhub-env.sh'
  )
  local forbidden_content="/Users/shopee|access_token|refresh_token|id_token|experimental_bearer_token|OPENAI_API_KEY|MODELHUB_AK[[:space:]]*[:=][[:space:]]*['\"]?[[:alnum:]]"

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
    if LC_ALL=C grep -E -q "$forbidden_content" "$source_dir/$relative"; then
      die "allowlisted source contains forbidden content: $relative"
      return 1
    fi
  done
}

copy_allowlisted_resources() {
  local source_dir="$1"
  local package_root="$2/modelhub-installer"

  mkdir -p "$package_root/assets" "$package_root/templates"
  cp "$source_dir/assets/models-modelhub-1m.json" "$package_root/assets/models-modelhub-1m.json"
  cp "$source_dir/templates/modelhub-provider.toml" "$package_root/templates/modelhub-provider.toml"
  cp "$source_dir/templates/modelhub-provider-meta.json" "$package_root/templates/modelhub-provider-meta.json"
  cp "$source_dir/templates/com.ccswitch.modelhub-env.plist" "$package_root/templates/com.ccswitch.modelhub-env.plist"
  cp "$source_dir/templates/load-modelhub-env.sh" "$package_root/templates/load-modelhub-env.sh"
  chmod 644 \
    "$package_root/assets/models-modelhub-1m.json" \
    "$package_root/templates/modelhub-provider.toml" \
    "$package_root/templates/modelhub-provider-meta.json" \
    "$package_root/templates/com.ccswitch.modelhub-env.plist"
  chmod 755 "$package_root/templates/load-modelhub-env.sh"
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

  COPYFILE_DISABLE=1 tar -czf "$staged_output/$OUTPUT_RESOURCES_NAME" \
    -C "$package_dir" modelhub-installer
  cp "$source_dir/install.sh" "$staged_output/$OUTPUT_INSTALLER_NAME"
  chmod 755 "$staged_output/$OUTPUT_INSTALLER_NAME"
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
  rm -f \
    "$output_dir/$OUTPUT_INSTALLER_NAME" \
    "$output_dir/$OUTPUT_APP_NAME" \
    "$output_dir/$OUTPUT_RESOURCES_NAME" \
    "$output_dir/$OUTPUT_CHECKSUM_NAME"
  cp "$staged_output/$OUTPUT_INSTALLER_NAME" "$output_dir/$OUTPUT_INSTALLER_NAME"
  cp "$staged_output/$OUTPUT_APP_NAME" "$output_dir/$OUTPUT_APP_NAME"
  cp "$staged_output/$OUTPUT_RESOURCES_NAME" "$output_dir/$OUTPUT_RESOURCES_NAME"
  cp "$staged_output/$OUTPUT_CHECKSUM_NAME" "$output_dir/$OUTPUT_CHECKSUM_NAME"
  rm -rf "$work_dir"

  printf 'Release assets written to %s\n' "$output_dir"
}

main "$@"
