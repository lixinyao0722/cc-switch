#!/bin/bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="$REPO_ROOT/scripts/modelhub-installer/install.sh"
PACKAGER="$REPO_ROOT/scripts/modelhub-installer/package-release.sh"
TEMPLATE="$REPO_ROOT/scripts/modelhub-installer/templates/modelhub-provider.toml"
META_TEMPLATE="$REPO_ROOT/scripts/modelhub-installer/templates/modelhub-provider-meta.json"
if [[ "${1:-}" == "--" ]]; then
  shift
fi
TEST_FILTER="${1:-}"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/cc-switch-installer-tests.XXXXXX")"
TESTS_RUN=0
TESTS_FAILED=0

cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

if [[ ! -f "$INSTALLER" ]]; then
  echo "not ok - installer script exists" >&2
  echo "missing: $INSTALLER" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$INSTALLER"

fail() {
  echo "$*" >&2
  return 1
}

assert_contains() {
  local file="$1"
  local expected="$2"
  grep -Fq -- "$expected" "$file" || fail "expected $file to contain: $expected"
}

assert_not_contains() {
  local file="$1"
  local unexpected="$2"
  [[ -e "$file" ]] || return 0
  if grep -Fq -- "$unexpected" "$file"; then
    fail "expected $file not to contain: $unexpected"
  fi
}

assert_occurrences() {
  local file="$1"
  local needle="$2"
  local expected="$3"
  local actual
  actual="$(awk -v needle="$needle" 'index($0, needle) { count += 1 } END { print count + 0 }' "$file")"
  [[ "$actual" == "$expected" ]] || fail "expected $expected occurrences of '$needle' in $file, got $actual"
}

assert_equals() {
  local actual="$1"
  local expected="$2"
  [[ "$actual" == "$expected" ]] || fail "expected '$expected', got '$actual'"
}

assert_sql() {
  local database="$1"
  local query="$2"
  local expected="$3"
  local actual
  actual="$(sqlite3 "$database" "$query")"
  assert_equals "$actual" "$expected"
}

assert_command_fails() {
  if "$@" >/dev/null 2>&1; then
    fail "expected command to fail: $*"
  fi
}

run_test() {
  local name="$1"
  local function_name="$2"
  local status

  if [[ -n "$TEST_FILTER" && "$name" != *"$TEST_FILTER"* ]]; then
    return 0
  fi

  TESTS_RUN=$((TESTS_RUN + 1))
  set +e
  (
    set -e
    "$function_name"
  )
  status=$?
  set -e

  if [[ "$status" -eq 0 ]]; then
    echo "ok - $name"
  else
    echo "not ok - $name" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

test_merge_preserves_unmanaged_sections() {
  local case_dir="$TEST_TMP/merge-existing"
  mkdir -p "$case_dir"
  printf '%s\n' \
    '# user heading' \
    'model = "old-model"' \
    'model_provider = "old-provider"' \
    '[plugins."browser@openai-bundled"]' \
    'enabled = true' \
    '[model_providers.modelhub]' \
    'base_url = "https://old.invalid"' \
    '[desktop]' \
    'followUpQueueMode = "queued"' \
    >"$case_dir/input.toml"

  merge_codex_config \
    "$case_dir/input.toml" \
    "$TEMPLATE" \
    "$case_dir/output.toml" \
    '/Users/Test User'

  assert_contains "$case_dir/output.toml" 'model = "gpt-5.6-sol"'
  assert_contains "$case_dir/output.toml" 'model_catalog_json = "/Users/Test User/.codex/models-modelhub-1m.json"'
  assert_contains "$case_dir/output.toml" '# user heading'
  assert_contains "$case_dir/output.toml" '[plugins."browser@openai-bundled"]'
  assert_contains "$case_dir/output.toml" 'enabled = true'
  assert_contains "$case_dir/output.toml" '[desktop]'
  assert_contains "$case_dir/output.toml" 'followUpQueueMode = "queued"'
  assert_occurrences "$case_dir/output.toml" '[model_providers.modelhub]' 1
  assert_not_contains "$case_dir/output.toml" 'https://old.invalid'
  assert_not_contains "$case_dir/output.toml" 'old-model'
  assert_not_contains "$case_dir/output.toml" 'old-provider'
}

test_merge_creates_config_from_empty_file() {
  local case_dir="$TEST_TMP/merge-empty"
  mkdir -p "$case_dir"
  : >"$case_dir/input.toml"

  merge_codex_config \
    "$case_dir/input.toml" \
    "$TEMPLATE" \
    "$case_dir/output.toml" \
    '/Users/Fresh User'

  assert_contains "$case_dir/output.toml" 'model_provider = "modelhub"'
  assert_contains "$case_dir/output.toml" '[model_providers.modelhub]'
  assert_contains "$case_dir/output.toml" 'model_catalog_json = "/Users/Fresh User/.codex/models-modelhub-1m.json"'
  validate_merged_codex_config "$case_dir/output.toml" '/Users/Fresh User'
}

test_merge_creates_config_when_source_is_missing() {
  local case_dir="$TEST_TMP/merge-missing"
  mkdir -p "$case_dir"

  merge_codex_config \
    "$case_dir/not-created.toml" \
    "$TEMPLATE" \
    "$case_dir/output.toml" \
    '/Users/Fresh User'

  assert_contains "$case_dir/output.toml" 'model_provider = "modelhub"'
  assert_contains "$case_dir/output.toml" 'model_catalog_json = "/Users/Fresh User/.codex/models-modelhub-1m.json"'
}

test_merge_replaces_only_active_modelhub_section() {
  local case_dir="$TEST_TMP/merge-middle"
  mkdir -p "$case_dir"
  printf '%s\n' \
    'approval_policy = "on-request"' \
    '[model_providers.modelhub]' \
    'name = "stale"' \
    '[model_providers.modelhub.http_headers]' \
    'x-stale-header = "remove-me"' \
    '[model_providers.keepme]' \
    'name = "keepme"' \
    'base_url = "https://keep.example/v1"' \
    'wire_api = "responses"' \
    'wire_api = "responses"' \
    >"$case_dir/input.toml"

  merge_codex_config \
    "$case_dir/input.toml" \
    "$TEMPLATE" \
    "$case_dir/output.toml" \
    '/Users/Test User'

  assert_contains "$case_dir/output.toml" 'approval_policy = "on-request"'
  assert_contains "$case_dir/output.toml" '[model_providers.keepme]'
  assert_contains "$case_dir/output.toml" 'base_url = "https://keep.example/v1"'
  assert_not_contains "$case_dir/output.toml" 'name = "stale"'
  assert_not_contains "$case_dir/output.toml" '[model_providers.modelhub.http_headers]'
  assert_not_contains "$case_dir/output.toml" 'x-stale-header = "remove-me"'
  assert_occurrences "$case_dir/output.toml" '[model_providers.modelhub]' 1
}

test_merge_replaces_equivalent_modelhub_headers() {
  local case_dir="$TEST_TMP/merge-equivalent-headers"
  local parser_home="$case_dir/parser-home"
  local user_home="$case_dir/user home"
  local codex_bin='/Applications/ChatGPT.app/Contents/Resources/codex'
  mkdir -p "$case_dir" "$parser_home" "$user_home/.codex"
  cp "$REPO_ROOT/scripts/modelhub-installer/assets/models-modelhub-1m.json" \
    "$user_home/.codex/models-modelhub-1m.json"
  [[ -x "$codex_bin" ]] || fail "Codex parser is unavailable: $codex_bin"
  printf '%s\n' \
    'approval_policy = "on-request"' \
    '[ "model_providers" . "modelhub" ] # legacy equivalent header' \
    'name = "stale-equivalent"' \
    '[ model_providers . "modelhub" . http_headers ] # stale child table' \
    'x-stale-header = "remove-me"' \
    "['model_providers'.'modelhub'] # second legal equivalent" \
    'name = "also-stale"' \
    '[model_providers.keepme]' \
    'name = "keepme"' \
    'base_url = "https://keep.example/v1"' \
    'wire_api = "responses"' \
    >"$case_dir/input.toml"

  merge_codex_config \
    "$case_dir/input.toml" \
    "$TEMPLATE" \
    "$case_dir/output.toml" \
    "$user_home"

  assert_not_contains "$case_dir/output.toml" 'stale-equivalent'
  assert_not_contains "$case_dir/output.toml" 'x-stale-header'
  assert_not_contains "$case_dir/output.toml" 'also-stale'
  assert_contains "$case_dir/output.toml" '[model_providers.keepme]'
  cp "$case_dir/output.toml" "$parser_home/config.toml"
  CODEX_HOME="$parser_home" "$codex_bin" features list >/dev/null
}

test_merge_validation_uses_real_toml_parser() {
  local case_dir="$TEST_TMP/merge-parser-validation"
  local codex_bin='/Applications/ChatGPT.app/Contents/Resources/codex'
  mkdir -p "$case_dir"
  [[ -x "$codex_bin" ]] || fail "Codex parser is unavailable: $codex_bin"
  create_merged_config_fixture "$case_dir/invalid.toml" '/Users/Test User'
  printf '%s\n' 'broken = [unterminated' >>"$case_dir/invalid.toml"

  CC_SWITCH_CODEX_CONFIG_VALIDATOR="$codex_bin" \
    assert_command_fails validate_merged_codex_config "$case_dir/invalid.toml" '/Users/Test User'
}

test_validate_rejects_unresolved_home_placeholder() {
  local case_dir="$TEST_TMP/validate-placeholder"
  mkdir -p "$case_dir"
  cp "$TEMPLATE" "$case_dir/unrendered.toml"

  assert_command_fails validate_merged_codex_config "$case_dir/unrendered.toml" '/Users/Test User'
}

test_preflight_rejects_unsupported_platforms() {
  assert_command_fails validate_platform Linux arm64 14
  assert_command_fails validate_platform Darwin x86_64 14
  assert_command_fails validate_platform Darwin arm64 11
  validate_platform Darwin arm64 12
  validate_platform Darwin arm64 15
}

test_preflight_validates_chatgpt_codex_team_id() {
  local case_dir="$TEST_TMP/preflight-team"
  local codex_path="$case_dir/ChatGPT.app/Contents/Resources/codex"
  local codesign_stub="$case_dir/codesign"
  mkdir -p "$(dirname "$codex_path")"
  : >"$codex_path"
  chmod +x "$codex_path"

  printf '%s\n' \
    '#!/bin/bash' \
    'echo "TeamIdentifier=${FAKE_TEAM_ID}" >&2' \
    >"$codesign_stub"
  chmod +x "$codesign_stub"

  FAKE_TEAM_ID='WRONGTEAM' CC_SWITCH_CODESIGN_BIN="$codesign_stub" \
    assert_command_fails validate_chatgpt_codex "$codex_path" '2DC432GLL2'
  FAKE_TEAM_ID='2DC432GLL2' CC_SWITCH_CODESIGN_BIN="$codesign_stub" \
    validate_chatgpt_codex "$codex_path" '2DC432GLL2'
}

create_chatgpt_app_fixture() {
  local app_path="$1"
  local executable_name="${2:-ChatGPT}"

  mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
  printf '%s\n' \
    'CFBundleIdentifier=com.openai.codex' \
    "CFBundleExecutable=$executable_name" \
    >"$app_path/Contents/Info.plist"
  : >"$app_path/Contents/MacOS/$executable_name"
  : >"$app_path/Contents/Resources/codex"
  chmod +x \
    "$app_path/Contents/MacOS/$executable_name" \
    "$app_path/Contents/Resources/codex"
}

create_chatgpt_validation_stubs() {
  local case_dir="$1"

  printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    '[[ "$1" == "-extract" && "$3" == "raw" && "$4" == "-o" && "$5" == "-" ]]' \
    'awk -F= -v key="$2" '\''$1 == key { print substr($0, index($0, "=") + 1); found = 1; exit } END { exit(found ? 0 : 1) }'\'' "$6"' \
    >"$case_dir/plutil"
  printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'target="${@: -1}"' \
    'if [[ "$1" == "--verify" ]]; then' \
    '  [[ "$2" == "--deep" && "$3" == "--strict" && "$#" == "4" ]]' \
    '  [[ "${FAKE_APP_STRICT:-pass}" == "pass" ]]' \
    'elif [[ "$1" == "-dv" ]]; then' \
    '  if [[ "$target" == */Contents/Resources/codex ]]; then' \
    '    echo "TeamIdentifier=${FAKE_CODEX_TEAM_ID:-2DC432GLL2}" >&2' \
    '  else' \
    '    echo "TeamIdentifier=${FAKE_APP_TEAM_ID:-2DC432GLL2}" >&2' \
    '  fi' \
    'else' \
    '  exit 64' \
    'fi' \
    >"$case_dir/codesign"
  printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'echo "Mach-O universal binary with architectures: [${FAKE_APP_ARCHS:-arm64}]"' \
    >"$case_dir/file"
  printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'echo curl >>"$FAKE_MUTATION_LOG"' \
    'exit 90' \
    >"$case_dir/curl"
  printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'echo hdiutil >>"$FAKE_MUTATION_LOG"' \
    'exit 91' \
    >"$case_dir/hdiutil"
  chmod +x \
    "$case_dir/plutil" \
    "$case_dir/codesign" \
    "$case_dir/file" \
    "$case_dir/curl" \
    "$case_dir/hdiutil"
}

test_validates_existing_chatgpt_app() {
  local case_dir="$TEST_TMP/chatgpt-validation"
  local app_path="$case_dir/ChatGPT.app"
  local info_plist="$app_path/Contents/Info.plist"
  local codex_path="$app_path/Contents/Resources/codex"
  mkdir -p "$case_dir"
  create_chatgpt_app_fixture "$app_path" 'OpenAI ChatGPT'
  create_chatgpt_validation_stubs "$case_dir"

  CC_SWITCH_PLUTIL_BIN="$case_dir/plutil" \
    CC_SWITCH_CODESIGN_BIN="$case_dir/codesign" \
    CC_SWITCH_FILE_BIN="$case_dir/file" \
    validate_chatgpt_app "$app_path" '2DC432GLL2' 'com.openai.codex'

  cp "$info_plist" "$case_dir/Info.plist.valid"
  printf '%s\n' \
    'CFBundleIdentifier=com.example.impostor' \
    'CFBundleExecutable=OpenAI ChatGPT' \
    >"$info_plist"
  CC_SWITCH_PLUTIL_BIN="$case_dir/plutil" CC_SWITCH_CODESIGN_BIN="$case_dir/codesign" \
    CC_SWITCH_FILE_BIN="$case_dir/file" \
    assert_command_fails validate_chatgpt_app "$app_path" '2DC432GLL2' 'com.openai.codex'
  cp "$case_dir/Info.plist.valid" "$info_plist"

  FAKE_APP_TEAM_ID='WRONGTEAM' CC_SWITCH_PLUTIL_BIN="$case_dir/plutil" \
    CC_SWITCH_CODESIGN_BIN="$case_dir/codesign" CC_SWITCH_FILE_BIN="$case_dir/file" \
    assert_command_fails validate_chatgpt_app "$app_path" '2DC432GLL2' 'com.openai.codex'
  FAKE_APP_ARCHS='x86_64' CC_SWITCH_PLUTIL_BIN="$case_dir/plutil" \
    CC_SWITCH_CODESIGN_BIN="$case_dir/codesign" CC_SWITCH_FILE_BIN="$case_dir/file" \
    assert_command_fails validate_chatgpt_app "$app_path" '2DC432GLL2' 'com.openai.codex'
  FAKE_APP_STRICT='fail' CC_SWITCH_PLUTIL_BIN="$case_dir/plutil" \
    CC_SWITCH_CODESIGN_BIN="$case_dir/codesign" CC_SWITCH_FILE_BIN="$case_dir/file" \
    assert_command_fails validate_chatgpt_app "$app_path" '2DC432GLL2' 'com.openai.codex'

  mv "$codex_path" "$case_dir/codex.saved"
  CC_SWITCH_PLUTIL_BIN="$case_dir/plutil" CC_SWITCH_CODESIGN_BIN="$case_dir/codesign" \
    CC_SWITCH_FILE_BIN="$case_dir/file" \
    assert_command_fails validate_chatgpt_app "$app_path" '2DC432GLL2' 'com.openai.codex'
  mv "$case_dir/codex.saved" "$codex_path"
  FAKE_CODEX_TEAM_ID='WRONGTEAM' CC_SWITCH_PLUTIL_BIN="$case_dir/plutil" \
    CC_SWITCH_CODESIGN_BIN="$case_dir/codesign" CC_SWITCH_FILE_BIN="$case_dir/file" \
    assert_command_fails validate_chatgpt_app "$app_path" '2DC432GLL2' 'com.openai.codex'
}

test_blocks_invalid_existing_chatgpt_without_mutation() {
  local case_dir="$TEST_TMP/chatgpt-invalid-existing"
  local app_path="$case_dir/Applications/ChatGPT.app"
  local mutation_log="$case_dir/mutations.log"
  local stderr_file="$case_dir/stderr.log"
  local before_digest
  local after_digest
  local status
  mkdir -p "$case_dir/Applications"
  create_chatgpt_app_fixture "$app_path"
  create_chatgpt_validation_stubs "$case_dir"
  before_digest="$(find "$app_path" -type f -exec shasum -a 256 {} + | LC_ALL=C sort | shasum -a 256)"

  set +e
  FAKE_APP_TEAM_ID='WRONGTEAM' FAKE_MUTATION_LOG="$mutation_log" \
    CC_SWITCH_PLUTIL_BIN="$case_dir/plutil" CC_SWITCH_CODESIGN_BIN="$case_dir/codesign" \
    CC_SWITCH_FILE_BIN="$case_dir/file" CC_SWITCH_CURL_BIN="$case_dir/curl" \
    CC_SWITCH_HDIUTIL_BIN="$case_dir/hdiutil" \
    ensure_chatgpt_app "$app_path" '2DC432GLL2' 'com.openai.codex' 2>"$stderr_file"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail 'invalid existing ChatGPT app was accepted'
  assert_contains "$stderr_file" 'https://openai.com/chatgpt/download/'
  assert_contains "$stderr_file" 'official OpenAI download page'
  [[ ! -e "$mutation_log" ]] || fail 'invalid existing ChatGPT app triggered curl or hdiutil'
  after_digest="$(find "$app_path" -type f -exec shasum -a 256 {} + | LC_ALL=C sort | shasum -a 256)"
  assert_equals "$after_digest" "$before_digest"
}

create_expected_resource_tree() {
  local root="$1/modelhub-installer"
  mkdir -p "$root/assets" "$root/templates"
  : >"$root/assets/models-modelhub-1m.json"
  : >"$root/templates/modelhub-provider.toml"
  : >"$root/templates/modelhub-provider-meta.json"
  : >"$root/templates/com.ccswitch.modelhub-env.plist"
  : >"$root/templates/load-modelhub-env.sh"
}

test_preflight_verifies_all_release_checksums() {
  local case_dir="$TEST_TMP/preflight-checksums"
  mkdir -p "$case_dir"
  printf 'installer\n' >"$case_dir/install.sh"
  printf 'app\n' >"$case_dir/CC-Switch-ModelHub-3.18.0-arm64.app.zip"
  printf 'resources\n' >"$case_dir/modelhub-installer-resources.tar.gz"
  (
    cd "$case_dir"
    shasum -a 256 \
      install.sh \
      CC-Switch-ModelHub-3.18.0-arm64.app.zip \
      modelhub-installer-resources.tar.gz \
      >SHA256SUMS.txt
  )

  verify_release_assets "$case_dir"
  printf 'tampered\n' >>"$case_dir/modelhub-installer-resources.tar.gz"
  MUTATION_STARTED=0
  assert_command_fails verify_release_assets "$case_dir"
  assert_equals "$MUTATION_STARTED" 0
}

test_preflight_rejects_unexpected_checksum_entries() {
  local case_dir="$TEST_TMP/preflight-extra-checksum"
  mkdir -p "$case_dir"
  printf 'installer\n' >"$case_dir/install.sh"
  printf 'app\n' >"$case_dir/CC-Switch-ModelHub-3.18.0-arm64.app.zip"
  printf 'resources\n' >"$case_dir/modelhub-installer-resources.tar.gz"
  printf 'extra\n' >"$case_dir/not-allowed.txt"
  (
    cd "$case_dir"
    shasum -a 256 \
      install.sh \
      CC-Switch-ModelHub-3.18.0-arm64.app.zip \
      modelhub-installer-resources.tar.gz \
      >SHA256SUMS.txt
  )

  verify_release_assets "$case_dir"
  (
    cd "$case_dir"
    shasum -a 256 not-allowed.txt >>SHA256SUMS.txt
  )

  assert_command_fails verify_release_assets "$case_dir"
}

test_preflight_accepts_exact_resource_archive() {
  local case_dir="$TEST_TMP/preflight-archive-ok"
  mkdir -p "$case_dir/tree"
  create_expected_resource_tree "$case_dir/tree"
  COPYFILE_DISABLE=1 tar -czf "$case_dir/resources.tar.gz" -C "$case_dir/tree" modelhub-installer

  validate_resource_archive "$case_dir/resources.tar.gz"
}

test_preflight_rejects_archive_symlink_and_extra_file() {
  local case_dir="$TEST_TMP/preflight-archive-bad"
  mkdir -p "$case_dir/safe-tree" "$case_dir/symlink-tree" "$case_dir/extra-tree"
  create_expected_resource_tree "$case_dir/safe-tree"
  COPYFILE_DISABLE=1 tar -czf "$case_dir/safe.tar.gz" -C "$case_dir/safe-tree" modelhub-installer
  validate_resource_archive "$case_dir/safe.tar.gz"

  create_expected_resource_tree "$case_dir/symlink-tree"
  ln -s /tmp "$case_dir/symlink-tree/modelhub-installer/templates/unsafe-link"
  COPYFILE_DISABLE=1 tar -czf "$case_dir/symlink.tar.gz" -C "$case_dir/symlink-tree" modelhub-installer
  assert_command_fails validate_resource_archive "$case_dir/symlink.tar.gz"

  create_expected_resource_tree "$case_dir/extra-tree"
  : >"$case_dir/extra-tree/modelhub-installer/unexpected.txt"
  COPYFILE_DISABLE=1 tar -czf "$case_dir/extra.tar.gz" -C "$case_dir/extra-tree" modelhub-installer
  assert_command_fails validate_resource_archive "$case_dir/extra.tar.gz"
}

test_preflight_rejects_archive_special_file_types() {
  local case_dir="$TEST_TMP/preflight-archive-special"
  mkdir -p "$case_dir/tree"
  create_expected_resource_tree "$case_dir/tree"
  rm "$case_dir/tree/modelhub-installer/templates/load-modelhub-env.sh"
  mkfifo "$case_dir/tree/modelhub-installer/templates/load-modelhub-env.sh"
  COPYFILE_DISABLE=1 tar -czf "$case_dir/special.tar.gz" -C "$case_dir/tree" modelhub-installer

  assert_command_fails validate_resource_archive "$case_dir/special.tar.gz"
}

test_preflight_rejects_unsafe_archive_entry_names() {
  assert_command_fails validate_archive_entry '../escape'
  assert_command_fails validate_archive_entry 'modelhub-installer/../../escape'
  assert_command_fails validate_archive_entry '/absolute/path'
  validate_archive_entry 'modelhub-installer/templates/modelhub-provider.toml'
}

test_preflight_downloads_from_immutable_release_tag() {
  local case_dir="$TEST_TMP/preflight-download"
  local remote_dir="$case_dir/remote"
  local output_dir="$case_dir/output"
  local curl_stub="$case_dir/curl"
  mkdir -p "$remote_dir" "$output_dir"
  printf 'installer\n' >"$remote_dir/install.sh"
  printf 'app\n' >"$remote_dir/CC-Switch-ModelHub-3.18.0-arm64.app.zip"
  printf 'resources\n' >"$remote_dir/modelhub-installer-resources.tar.gz"
  printf 'checksums\n' >"$remote_dir/SHA256SUMS.txt"
  printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'output=""' \
    'url=""' \
    'while [[ $# -gt 0 ]]; do' \
    '  case "$1" in' \
    '    --output) output="$2"; shift 2 ;;' \
    '    http*) url="$1"; shift ;;' \
    '    *) shift ;;' \
    '  esac' \
    'done' \
    '[[ "$url" == *"/releases/download/modelhub-installer-20260727/"* ]]' \
    'cp "$FAKE_RELEASE_DIR/${url##*/}" "$output"' \
    >"$curl_stub"
  chmod +x "$curl_stub"

  FAKE_RELEASE_DIR="$remote_dir" CC_SWITCH_CURL_BIN="$curl_stub" \
    download_release_assets "$output_dir"

  assert_contains "$output_dir/install.sh" 'installer'
  assert_contains "$output_dir/CC-Switch-ModelHub-3.18.0-arm64.app.zip" 'app'
  assert_contains "$output_dir/modelhub-installer-resources.tar.gz" 'resources'
  assert_contains "$output_dir/SHA256SUMS.txt" 'checksums'
}

create_provider_database() {
  local database="$1"
  sqlite3 "$database" <<'SQL'
CREATE TABLE providers (
  id TEXT NOT NULL,
  app_type TEXT NOT NULL,
  name TEXT NOT NULL,
  settings_config TEXT NOT NULL,
  website_url TEXT,
  category TEXT,
  created_at INTEGER,
  sort_index INTEGER,
  notes TEXT,
  icon TEXT,
  icon_color TEXT,
  meta TEXT NOT NULL DEFAULT '{}',
  is_current BOOLEAN NOT NULL DEFAULT 0,
  in_failover_queue BOOLEAN NOT NULL DEFAULT 0,
  cost_multiplier TEXT NOT NULL DEFAULT '1.0',
  limit_daily_usd TEXT,
  limit_monthly_usd TEXT,
  provider_type TEXT,
  PRIMARY KEY (id, app_type)
);
CREATE TABLE proxy_config (
  app_type TEXT PRIMARY KEY,
  proxy_enabled INTEGER NOT NULL DEFAULT 0,
  listen_address TEXT NOT NULL DEFAULT '127.0.0.1',
  listen_port INTEGER NOT NULL DEFAULT 15721,
  enable_logging INTEGER NOT NULL DEFAULT 1,
  enabled INTEGER NOT NULL DEFAULT 0,
  auto_failover_enabled INTEGER NOT NULL DEFAULT 0,
  max_retries INTEGER NOT NULL DEFAULT 3,
  streaming_first_byte_timeout INTEGER NOT NULL DEFAULT 60,
  streaming_idle_timeout INTEGER NOT NULL DEFAULT 120,
  non_streaming_timeout INTEGER NOT NULL DEFAULT 600,
  circuit_failure_threshold INTEGER NOT NULL DEFAULT 4,
  circuit_success_threshold INTEGER NOT NULL DEFAULT 2,
  circuit_timeout_seconds INTEGER NOT NULL DEFAULT 60,
  circuit_error_rate_threshold REAL NOT NULL DEFAULT 0.6,
  circuit_min_requests INTEGER NOT NULL DEFAULT 10,
  default_cost_multiplier TEXT NOT NULL DEFAULT '1',
  pricing_model_source TEXT NOT NULL DEFAULT 'response',
  live_takeover_active INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE TABLE sentinel (value TEXT NOT NULL);
INSERT INTO sentinel(value) VALUES ('keep-me');
INSERT INTO providers (
  id, app_type, name, settings_config, category, meta, is_current
) VALUES (
  'existing-provider', 'codex', 'Existing Provider',
  '{"auth":{"OPENAI_API_KEY":"keep-existing"},"config":"model = \"keep\""}',
  'third_party', '{}', 1
);
SQL
}

test_database_schema_requires_created_at_and_provider_identity_key() {
  local case_dir="$TEST_TMP/database-schema-contract"
  local database="$case_dir/cc-switch.db"
  mkdir -p "$case_dir"
  create_provider_database "$database"
  cc_switch_schema_ready "$database"

  sqlite3 "$database" <<'SQL'
ALTER TABLE providers RENAME TO providers_ready;
CREATE TABLE providers AS
SELECT id, app_type, name, settings_config, website_url, category,
       sort_index, notes, icon, icon_color, meta, is_current,
       in_failover_queue, cost_multiplier, limit_daily_usd,
       limit_monthly_usd, provider_type
FROM providers_ready;
DROP TABLE providers_ready;
SQL

  assert_command_fails cc_switch_schema_ready "$database"
}

create_merged_config_fixture() {
  local output="$1"
  local user_home="$2"
  local empty_source="$TEST_TMP/empty-config.toml"
  : >"$empty_source"
  merge_codex_config "$empty_source" "$TEMPLATE" "$output" "$user_home"
}

test_database_merge_is_idempotent_and_preserves_unrelated_rows() {
  local case_dir="$TEST_TMP/database-merge"
  local database="$case_dir/cc-switch.db"
  local config="$case_dir/config.toml"
  local provider_id
  mkdir -p "$case_dir"
  create_provider_database "$database"
  create_merged_config_fixture "$config" '/Users/Test User'

  provider_id="$(merge_provider_database "$database" "$config" "$META_TEMPLATE")"
  assert_equals "$provider_id" 'bytedance-modelhub-official-cli'
  provider_id="$(merge_provider_database "$database" "$config" "$META_TEMPLATE")"
  assert_equals "$provider_id" 'bytedance-modelhub-official-cli'

  assert_sql "$database" "select count(*) from providers where app_type='codex' and name='Bytedance ModelHub - 官方CLI'" '1'
  assert_sql "$database" "select count(*) from providers where id='existing-provider'" '1'
  assert_sql "$database" "select is_current from providers where id='existing-provider' and app_type='codex'" '0'
  assert_sql "$database" "select count(*) from sentinel where value='keep-me'" '1'
  assert_sql "$database" "select json_type(settings_config, '$.auth') from providers where id='bytedance-modelhub-official-cli'" 'object'
  assert_sql "$database" "select count(*) from providers, json_each(settings_config, '$.auth') where providers.id='bytedance-modelhub-official-cli'" '0'
  assert_sql "$database" "select json_extract(meta, '$.localProxyRequestOverrides.codexSessionHeaderAdapter') from providers where id='bytedance-modelhub-official-cli'" 'modelhub'
  assert_sql "$database" "select instr(settings_config, 'access_token') + instr(settings_config, 'refresh_token') + instr(settings_config, 'experimental_bearer_token') from providers where id='bytedance-modelhub-official-cli'" '0'
  assert_sql "$database" "select proxy_enabled || ':' || enabled || ':' || auto_failover_enabled || ':' || listen_address || ':' || listen_port from proxy_config where app_type='codex'" '1:1:0:127.0.0.1:15721'
}

test_database_merge_reuses_existing_modelhub_provider_id() {
  local case_dir="$TEST_TMP/database-reuse"
  local database="$case_dir/cc-switch.db"
  local config="$case_dir/config.toml"
  local provider_id
  mkdir -p "$case_dir"
  create_provider_database "$database"
  create_merged_config_fixture "$config" '/Users/Test User'
  sqlite3 "$database" <<'SQL'
INSERT INTO providers (
  id, app_type, name, settings_config, category, meta, is_current
) VALUES (
  'legacy-modelhub-id', 'codex', 'Bytedance ModelHub - 官方CLI',
  '{"auth":{"OPENAI_API_KEY":"remove-me"},"config":"stale"}',
  'third_party', '{}', 0
);
SQL

  provider_id="$(merge_provider_database "$database" "$config" "$META_TEMPLATE")"

  assert_equals "$provider_id" 'legacy-modelhub-id'
  assert_sql "$database" "select count(*) from providers where id='bytedance-modelhub-official-cli'" '0'
  assert_sql "$database" "select is_current from providers where id='legacy-modelhub-id'" '1'
  assert_sql "$database" "select count(*) from providers, json_each(settings_config, '$.auth') where providers.id='legacy-modelhub-id'" '0'
}

test_database_merge_rejects_fixed_id_conflict_without_mutation() {
  local case_dir="$TEST_TMP/database-fixed-id-conflict"
  local database="$case_dir/cc-switch.db"
  local config="$case_dir/config.toml"
  local before
  local after
  mkdir -p "$case_dir"
  create_provider_database "$database"
  create_merged_config_fixture "$config" '/Users/Test User'
  sqlite3 "$database" <<'SQL'
INSERT INTO providers (
  id, app_type, name, settings_config, category, meta, is_current
) VALUES (
  'bytedance-modelhub-official-cli', 'codex', 'Different Provider',
  '{"auth":{"OPENAI_API_KEY":"preserve-me"},"config":"model = \"other\""}',
  'third_party', '{}', 0
);
SQL
  before="$(shasum -a 256 "$database" | awk '{print $1}')"

  assert_command_fails merge_provider_database "$database" "$config" "$META_TEMPLATE"

  after="$(shasum -a 256 "$database" | awk '{print $1}')"
  assert_equals "$after" "$before"
  assert_sql "$database" "select name from providers where id='bytedance-modelhub-official-cli' and app_type='codex'" 'Different Provider'
  assert_sql "$database" "select json_extract(settings_config, '$.auth.OPENAI_API_KEY') from providers where id='bytedance-modelhub-official-cli' and app_type='codex'" 'preserve-me'
}

test_database_schema_initializes_missing_database_with_hidden_app() {
  local case_dir="$TEST_TMP/database-schema-init"
  local database="$case_dir/home/.cc-switch/cc-switch.db"
  local schema_source="$case_dir/schema-source.db"
  local app_path="$case_dir/Applications/CC Switch.app"
  local open_stub="$case_dir/open"
  local osascript_stub="$case_dir/osascript"
  mkdir -p "$(dirname "$database")" "$app_path"
  create_provider_database "$schema_source"
  printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'cp "$FAKE_SCHEMA_SOURCE" "$FAKE_DB_PATH"' \
    >"$open_stub"
  printf '%s\n' '#!/bin/bash' 'exit 0' >"$osascript_stub"
  chmod +x "$open_stub" "$osascript_stub"

  FAKE_SCHEMA_SOURCE="$schema_source" \
    FAKE_DB_PATH="$database" \
    CC_SWITCH_OPEN_BIN="$open_stub" \
    CC_SWITCH_OSASCRIPT_BIN="$osascript_stub" \
    ensure_cc_switch_schema "$database" "$app_path"

  assert_sql "$database" "select count(*) from pragma_table_info('providers') where name='meta'" '1'
  assert_sql "$database" "select count(*) from pragma_table_info('proxy_config') where name='auto_failover_enabled'" '1'
}

test_settings_merge_changes_only_managed_keys() {
  local case_dir="$TEST_TMP/settings-merge"
  local settings="$case_dir/settings.json"
  mkdir -p "$case_dir"
  printf '%s\n' \
    '{' \
    '  "language": "zh",' \
    '  "showInTray": false,' \
    '  "currentProviderCodex": "old-provider",' \
    '  "enableLocalProxy": false,' \
    '  "preserveCodexOfficialAuthOnSwitch": false' \
    '}' \
    >"$settings"

  update_settings_json "$settings" 'bytedance-modelhub-official-cli'

  assert_equals "$(plutil -extract language raw -o - "$settings")" 'zh'
  assert_equals "$(plutil -extract showInTray raw -o - "$settings")" 'false'
  assert_equals "$(plutil -extract currentProviderCodex raw -o - "$settings")" 'bytedance-modelhub-official-cli'
  assert_equals "$(plutil -extract enableLocalProxy raw -o - "$settings")" 'true'
  assert_equals "$(plutil -extract preserveCodexOfficialAuthOnSwitch raw -o - "$settings")" 'true'
}

test_settings_merge_rejects_invalid_json_without_overwrite() {
  local case_dir="$TEST_TMP/settings-invalid"
  local settings="$case_dir/settings.json"
  local before
  local after
  mkdir -p "$case_dir"
  printf '{invalid json\n' >"$settings"
  before="$(shasum -a 256 "$settings" | awk '{print $1}')"

  assert_command_fails update_settings_json "$settings" 'bytedance-modelhub-official-cli'

  after="$(shasum -a 256 "$settings" | awk '{print $1}')"
  assert_equals "$after" "$before"
}

test_settings_merge_creates_missing_file() {
  local case_dir="$TEST_TMP/settings-new"
  local settings="$case_dir/settings.json"
  mkdir -p "$case_dir"

  update_settings_json "$settings" 'bytedance-modelhub-official-cli'

  assert_equals "$(plutil -extract currentProviderCodex raw -o - "$settings")" 'bytedance-modelhub-official-cli'
  assert_equals "$(plutil -extract enableLocalProxy raw -o - "$settings")" 'true'
  assert_equals "$(plutil -extract preserveCodexOfficialAuthOnSwitch raw -o - "$settings")" 'true'
}

test_existing_nonwritable_app_requires_privilege() {
  local case_dir="$TEST_TMP/existing-nonwritable-app"
  local applications_dir="$case_dir/Applications"
  local sudo_bin="$case_dir/fake-sudo"
  local removal_status
  local needs_sudo
  mkdir -p "$applications_dir/CC Switch.app/Contents"
  chmod 0775 "$applications_dir"
  chmod -R 0555 "$applications_dir/CC Switch.app"
  write_executable_stub "$sudo_bin" \
    'printf "%s\n" "$*" >>"$FAKE_SUDO_LOG"' \
    'if [[ "${1:-}" == "-v" ]]; then exit 0; fi' \
    'chmod -R u+w "$FAKE_SUDO_APP_PATH"' \
    '"$@"'
  export CC_SWITCH_INSTALLER_TEST_MODE=1
  export CC_SWITCH_INSTALLER_TEST_HOME="$case_dir/home"
  export CC_SWITCH_INSTALLER_TEST_APPLICATIONS_DIR="$applications_dir"
  export CC_SWITCH_SUDO_BIN="$sudo_bin"
  export FAKE_SUDO_LOG="$case_dir/sudo.log"
  export FAKE_SUDO_APP_PATH="$applications_dir/CC Switch.app"
  configure_install_paths

  prepare_application_permissions
  needs_sudo="$NEEDS_SUDO"
  set +e
  remove_managed_target "$CC_SWITCH_APP_PATH"
  removal_status=$?
  set -e
  if [[ -d "$CC_SWITCH_APP_PATH" ]]; then
    chmod -R u+w "$CC_SWITCH_APP_PATH"
  fi

  assert_equals "$needs_sudo" '1'
  assert_equals "$removal_status" '0'
  assert_contains "$FAKE_SUDO_LOG" '-v'
  assert_contains "$FAKE_SUDO_LOG" "/bin/rm -rf -- $CC_SWITCH_APP_PATH"
}

test_rejects_root_execution_validation_contract() {
  assert_command_fails validate_non_root 0
  validate_non_root 501
}

test_rejects_root_execution_before_install_work() {
  local case_dir="$TEST_TMP/reject-root-execution"
  local output
  local status
  mkdir -p "$case_dir/tmp"
  export CC_SWITCH_INSTALLER_TEST_MODE=1
  export CC_SWITCH_INSTALLER_TEST_EUID=0
  export CC_SWITCH_INSTALLER_TEST_HOME="$case_dir/home"
  export CC_SWITCH_INSTALLER_TEST_APPLICATIONS_DIR="$case_dir/Applications"
  export CC_SWITCH_INSTALLER_ASSET_DIR="$case_dir/assets"
  export TMPDIR="$case_dir/tmp"

  set +e
  output="$(perform_install 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail 'root execution unexpectedly succeeded'
  [[ "$output" == *'do not run the entire installer with sudo'* ]] \
    || fail "root rejection was not explicit: $output"
  [[ ! -e "$case_dir/Applications" ]] || fail 'root execution wrote to Applications before rejection'
  [[ -z "$(find "$case_dir/tmp" -mindepth 1 -print -quit)" ]] \
    || fail 'root execution created a staging directory before rejection'
}

write_executable_stub() {
  local path="$1"
  shift
  printf '%s\n' '#!/bin/bash' 'set -euo pipefail' "$@" >"$path"
  chmod +x "$path"
}

create_transaction_stubs() {
  local case_dir="$1"
  local stub_dir="$case_dir/stubs"
  mkdir -p "$stub_dir"

  write_executable_stub "$stub_dir/codesign" \
    'if [[ "${1:-}" == "-dv" ]]; then echo "TeamIdentifier=2DC432GLL2" >&2; fi' \
    'exit 0'
  write_executable_stub "$stub_dir/plutil" \
    'if [[ "${6:-}" == */ChatGPT.app/Contents/Info.plist ]]; then' \
    '  [[ "$1" == "-extract" && "$3" == "raw" && "$4" == "-o" && "$5" == "-" ]]' \
    '  awk -F= -v key="$2" '\''$1 == key { print substr($0, index($0, "=") + 1); found = 1; exit } END { exit(found ? 0 : 1) }'\'' "$6"' \
    'else' \
    '  exec /usr/bin/plutil "$@"' \
    'fi'
  write_executable_stub "$stub_dir/file" \
    'echo "Mach-O 64-bit executable arm64"'
  write_executable_stub "$stub_dir/security" \
    'printf "%s\n" "${1:-}" >>"${FAKE_SECURITY_LOG:-/dev/null}"' \
    'case "${1:-}" in' \
    '  find-generic-password)' \
    '    if [[ -n "${FAKE_SECURITY_FIND_STATUS:-}" ]]; then exit "$FAKE_SECURITY_FIND_STATUS"; fi' \
    '    [[ -f "$FAKE_KEYCHAIN_STATE" ]] || exit 44' \
    '    printf "fake-modelhub-ak\n"' \
    '    ;;' \
    '  add-generic-password)' \
    '    [[ "${FAKE_SECURITY_MODE:-success}" != "cancel" ]] || exit 1' \
    '    : >"$FAKE_KEYCHAIN_STATE"' \
    '    ;;' \
    '  delete-generic-password)' \
    '    rm -f "$FAKE_KEYCHAIN_STATE"' \
    '    ;;' \
    'esac'
  write_executable_stub "$stub_dir/launchctl" \
    'mkdir -p "$FAKE_LAUNCHCTL_STATE_DIR"' \
    'case "${1:-}" in' \
    '  setenv) : >"$FAKE_LAUNCHCTL_STATE_DIR/env-$2" ;;' \
    '  unsetenv) rm -f "$FAKE_LAUNCHCTL_STATE_DIR/env-$2" ;;' \
    '  bootstrap)' \
    '    : >"$FAKE_LAUNCHCTL_STATE_DIR/job"' \
    '    if [[ "${FAKE_LAUNCHCTL_SIGNAL_TERM:-0}" == "1" ]]; then kill -TERM "$PPID"; fi' \
    '    ;;' \
    '  bootout) rm -f "$FAKE_LAUNCHCTL_STATE_DIR/job" ;;' \
    'esac'
  write_executable_stub "$stub_dir/osascript" 'exit 0'
  write_executable_stub "$stub_dir/pgrep" \
    'printf "%s\n" "$*" >>"${FAKE_PGREP_LOG:-/dev/null}"' \
    'if [[ "${FAKE_PGREP_MODE:-stopped}" == "once" && ! -f "$FAKE_PGREP_ONCE_STATE" ]]; then' \
    '  : >"$FAKE_PGREP_ONCE_STATE"' \
    '  exit 0' \
    'fi' \
    'exit 1'
  write_executable_stub "$stub_dir/open" 'exit 0'
  write_executable_stub "$stub_dir/xattr" 'exit 0'
  write_executable_stub "$stub_dir/sleep" 'exit 0'
  write_executable_stub "$stub_dir/curl" \
    'if [[ "${FAKE_HEALTH_MODE:-healthy}" == "healthy" ]]; then' \
    '  if [[ -n "${FAKE_COMPLETION_MARKER_DIR:-}" ]]; then chmod 500 "$FAKE_COMPLETION_MARKER_DIR"; fi' \
    '  printf "{\"status\":\"healthy\",\"timestamp\":\"test\"}\n"' \
    '  exit 0' \
    'fi' \
    'exit 22'

  export CC_SWITCH_CODESIGN_BIN="$stub_dir/codesign"
  export CC_SWITCH_PLUTIL_BIN="$stub_dir/plutil"
  export CC_SWITCH_FILE_BIN="$stub_dir/file"
  export CC_SWITCH_SECURITY_BIN="$stub_dir/security"
  export CC_SWITCH_LAUNCHCTL_BIN="$stub_dir/launchctl"
  export CC_SWITCH_OSASCRIPT_BIN="$stub_dir/osascript"
  export CC_SWITCH_PGREP_BIN="$stub_dir/pgrep"
  export CC_SWITCH_OPEN_BIN="$stub_dir/open"
  export CC_SWITCH_XATTR_BIN="$stub_dir/xattr"
  export CC_SWITCH_SLEEP_BIN="$stub_dir/sleep"
  export CC_SWITCH_CURL_BIN="$stub_dir/curl"
}

create_fake_app_zip() {
  local case_dir="$1"
  local app_dir="$case_dir/app-build/CC Switch.app"
  mkdir -p "$app_dir/Contents/MacOS"
  printf 'new-app\n' >"$app_dir/Contents/MacOS/cc-switch"
  chmod +x "$app_dir/Contents/MacOS/cc-switch"
  COPYFILE_DISABLE=1 /usr/bin/ditto -c -k --keepParent "$app_dir" "$case_dir/assets/CC-Switch-ModelHub-3.18.0-arm64.app.zip"
}

create_transaction_assets() {
  local case_dir="$1"
  local asset_dir="$case_dir/assets"
  local resource_root="$case_dir/resource-build/modelhub-installer"
  mkdir -p "$asset_dir" "$resource_root/assets" "$resource_root/templates"
  cp "$INSTALLER" "$asset_dir/install.sh"
  create_fake_app_zip "$case_dir"
  printf '{"models":{}}\n' >"$resource_root/assets/models-modelhub-1m.json"
  cp "$TEMPLATE" "$resource_root/templates/modelhub-provider.toml"
  cp "$META_TEMPLATE" "$resource_root/templates/modelhub-provider-meta.json"
  cp "$REPO_ROOT/scripts/modelhub-installer/templates/com.ccswitch.modelhub-env.plist" \
    "$resource_root/templates/com.ccswitch.modelhub-env.plist"
  cp "$REPO_ROOT/scripts/modelhub-installer/templates/load-modelhub-env.sh" \
    "$resource_root/templates/load-modelhub-env.sh"
  COPYFILE_DISABLE=1 tar -czf "$asset_dir/modelhub-installer-resources.tar.gz" \
    -C "$case_dir/resource-build" modelhub-installer
  (
    cd "$asset_dir"
    shasum -a 256 \
      install.sh \
      CC-Switch-ModelHub-3.18.0-arm64.app.zip \
      modelhub-installer-resources.tar.gz \
      >SHA256SUMS.txt
  )
}

create_transaction_state() {
  local case_dir="$1"
  local user_home="$case_dir/home"
  local applications_dir="$case_dir/Applications"
  mkdir -p \
    "$user_home/.codex" \
    "$user_home/.cc-switch" \
    "$user_home/.local/share/cc-switch-modelhub" \
    "$applications_dir/CC Switch.app/Contents/MacOS" \
    "$applications_dir"
  printf '%s\n' \
    'approval_policy = "on-request"' \
    '[plugins."browser@openai-bundled"]' \
    'enabled = true' \
    >"$user_home/.codex/config.toml"
  printf '{"auth_mode":"chatgpt","tokens":{"access_token":"user-owned"}}\n' \
    >"$user_home/.codex/auth.json"
  create_provider_database "$user_home/.cc-switch/cc-switch.db"
  printf '%s\n' \
    '{' \
    '  "language": "zh",' \
    '  "showInTray": false' \
    '}' \
    >"$user_home/.cc-switch/settings.json"
  printf 'old-app\n' >"$applications_dir/CC Switch.app/Contents/MacOS/cc-switch"
  create_chatgpt_app_fixture "$applications_dir/ChatGPT.app"
  printf '%s\n' '#!/bin/bash' '# old-local-installer' 'exit 70' \
    >"$user_home/.local/share/cc-switch-modelhub/install.sh"
  chmod +x "$user_home/.local/share/cc-switch-modelhub/install.sh"
}

managed_state_manifest() {
  local case_dir="$1"
  local user_home="$case_dir/home"
  local applications_dir="$case_dir/Applications"
  local path
  local relative
  local paths=(
    "$applications_dir/CC Switch.app"
    "$user_home/.codex/config.toml"
    "$user_home/.codex/auth.json"
    "$user_home/.codex/models-modelhub-1m.json"
    "$user_home/.cc-switch/cc-switch.db"
    "$user_home/.cc-switch/settings.json"
    "$user_home/Library/LaunchAgents/com.ccswitch.modelhub-env.plist"
    "$user_home/.local/share/cc-switch-modelhub/load-modelhub-env.sh"
  )

  for path in "${paths[@]}"; do
    printf 'PATH %s\n' "$path"
    if [[ -f "$path" ]]; then
      if [[ "$path" == "$user_home/.cc-switch/cc-switch.db" ]]; then
        sqlite3 "$path" .dump
      else
        shasum -a 256 "$path"
      fi
    elif [[ -d "$path" ]]; then
      while IFS= read -r relative; do
        printf 'FILE %s\n' "$relative"
        shasum -a 256 "$path/$relative"
      done < <(cd "$path" && find . -type f -print | LC_ALL=C sort)
    else
      printf 'ABSENT\n'
    fi
  done
}

managed_state_digest() {
  managed_state_manifest "$1" | shasum -a 256 | awk '{print $1}'
}

prepare_transaction_case() {
  local case_dir="$1"
  create_transaction_state "$case_dir"
  create_transaction_stubs "$case_dir"
  create_transaction_assets "$case_dir"
  export CC_SWITCH_INSTALLER_TEST_MODE=1
  export CC_SWITCH_INSTALLER_TEST_HOME="$case_dir/home"
  export CC_SWITCH_INSTALLER_TEST_APPLICATIONS_DIR="$case_dir/Applications"
  export CC_SWITCH_INSTALLER_ASSET_DIR="$case_dir/assets"
  export CC_SWITCH_INSTALLER_TIMESTAMP='20260727T120000Z'
  export CC_SWITCH_INSTALLER_HEALTH_TIMEOUT=1
  export FAKE_KEYCHAIN_STATE="$case_dir/keychain-state"
  export FAKE_SECURITY_LOG="$case_dir/security.log"
  export FAKE_LAUNCHCTL_STATE_DIR="$case_dir/launchctl-state"
  export FAKE_PGREP_LOG="$case_dir/pgrep.log"
  export FAKE_PGREP_ONCE_STATE="$case_dir/pgrep-once-state"
  export FAKE_SECURITY_MODE=success
  export FAKE_SECURITY_FIND_STATUS=''
  export FAKE_HEALTH_MODE=healthy
  export FAKE_COMPLETION_MARKER_DIR=''
  export FAKE_LAUNCHCTL_SIGNAL_TERM=0
  export FAKE_PGREP_MODE=stopped
}

test_transaction_backup_copy_failure_is_fail_closed() {
  local case_dir="$TEST_TMP/transaction-backup-copy-failure"
  mkdir -p "$case_dir"
  prepare_transaction_case "$case_dir"
  configure_install_paths
  MUTATION_STARTED=0

  CC_SWITCH_DITTO_BIN=/usr/bin/false \
    assert_command_fails create_backup "$BACKUP_ROOT"

  assert_equals "$MUTATION_STARTED" 0
  assert_contains "$case_dir/home/.local/share/cc-switch-modelhub/install.sh" 'old-local-installer'
}

test_transaction_real_write_failure_stops_before_keychain() {
  local case_dir="$TEST_TMP/transaction-real-write-failure"
  local before
  local after
  local result
  local resources_dir
  mkdir -p "$case_dir"
  prepare_transaction_case "$case_dir"
  configure_install_paths
  quit_apps
  printf 'old-model-catalog\n' >"$MODEL_CATALOG_PATH"
  ACTIVE_BACKUP_DIR="$(create_backup "$BACKUP_ROOT")"
  MUTATION_STARTED=1
  INSTALL_COMPLETED=0
  resources_dir="$case_dir/resource-build/modelhub-installer"
  before="$(managed_state_digest "$case_dir")"
  chmod +a 'everyone deny write,delete' "$MODEL_CATALOG_PATH"

  set +e
  run_install_transaction "$case_dir/assets" "$resources_dir"
  result=$?
  set -e
  chmod -N "$MODEL_CATALOG_PATH"
  rollback_failed_install || true

  after="$(managed_state_digest "$case_dir")"
  [[ "$result" -ne 0 ]] || fail 'a real model-catalog write failure was ignored'
  assert_equals "$after" "$before"
  assert_not_contains "$FAKE_SECURITY_LOG" 'add-generic-password'
  assert_contains "$case_dir/home/.local/share/cc-switch-modelhub/install.sh" 'old-local-installer'
}

test_transaction_signal_cancellation_rolls_back() {
  local case_dir="$TEST_TMP/transaction-signal-cancellation"
  local before
  local after
  local result
  mkdir -p "$case_dir"
  prepare_transaction_case "$case_dir"
  before="$(managed_state_digest "$case_dir")"
  export FAKE_LAUNCHCTL_SIGNAL_TERM=1

  set +e
  /bin/bash "$INSTALLER" >/dev/null 2>&1
  result=$?
  set -e

  [[ "$result" -ne 0 ]] || fail 'TERM cancellation unexpectedly succeeded'
  after="$(managed_state_digest "$case_dir")"
  assert_equals "$after" "$before"
  assert_contains "$case_dir/home/.local/share/cc-switch-modelhub/install.sh" 'old-local-installer'
  [[ ! -e "$FAKE_KEYCHAIN_STATE" ]] || fail 'TERM cancellation left a keychain item'
}

test_transaction_waits_for_cc_switch_exit_before_backup() {
  local case_dir="$TEST_TMP/transaction-waits-for-exit"
  local calls
  mkdir -p "$case_dir"
  prepare_transaction_case "$case_dir"
  export FAKE_PGREP_MODE=once

  perform_install

  [[ -f "$FAKE_PGREP_LOG" ]] || fail 'quit did not poll for CC Switch exit'
  assert_contains "$FAKE_PGREP_LOG" '-x cc-switch'
  calls="$(awk 'END { print NR + 0 }' "$FAKE_PGREP_LOG")"
  [[ "$calls" -ge 2 ]] || fail "expected CC Switch exit polling, got $calls calls"
}

test_transaction_wal_snapshot_restores_committed_sentinel_and_cleans_sidecars() {
  local case_dir="$TEST_TMP/transaction-wal-snapshot"
  local database
  local fifo
  local writer_pid
  local attempt=1
  mkdir -p "$case_dir"
  prepare_transaction_case "$case_dir"
  database="$case_dir/home/.cc-switch/cc-switch.db"
  fifo="$case_dir/sqlite-input"
  mkfifo "$fifo"
  sqlite3 "$database" <"$fifo" >"$case_dir/sqlite-output" 2>"$case_dir/sqlite-error" &
  writer_pid=$!
  exec 9>"$fifo"
  printf '%s\n' \
    'PRAGMA journal_mode=WAL;' \
    'PRAGMA wal_autocheckpoint=0;' \
    'CREATE TABLE wal_sentinel(value TEXT NOT NULL);' \
    "INSERT INTO wal_sentinel(value) VALUES ('committed-in-wal');" \
    >&9
  while [[ "$attempt" -le 100 ]]; do
    if [[ -f "$database-wal" ]] \
      && [[ "$(sqlite3 "$database" "SELECT count(*) FROM wal_sentinel WHERE value='committed-in-wal';" 2>/dev/null || true)" == "1" ]]; then
      break
    fi
    /bin/sleep 0.02
    attempt=$((attempt + 1))
  done
  [[ "$attempt" -le 100 ]] || fail 'failed to create an uncheckpointed WAL sentinel'

  perform_install
  exec 9>&-
  wait "$writer_pid"
  printf 'stale-wal\n' >"$database-wal"
  printf 'stale-shm\n' >"$database-shm"

  rollback_latest

  [[ ! -e "$database-wal" ]] || fail 'rollback left the database WAL sidecar'
  [[ ! -e "$database-shm" ]] || fail 'rollback left the database SHM sidecar'
  assert_sql "$database" "select count(*) from wal_sentinel where value='committed-in-wal'" '1'
}

test_transaction_same_second_backup_suffixes_sort_lexically() {
  local case_dir="$TEST_TMP/transaction-backup-suffix"
  local base
  local index=1
  local backup_dir
  mkdir -p "$case_dir"
  prepare_transaction_case "$case_dir"
  configure_install_paths
  base="$BACKUP_ROOT/$CC_SWITCH_INSTALLER_TIMESTAMP"
  mkdir -p "$base"
  while [[ "$index" -le 9 ]]; do
    mkdir -p "$(printf '%s-%04d' "$base" "$index")"
    index=$((index + 1))
  done

  backup_dir="$(create_backup "$BACKUP_ROOT")"

  assert_equals "$(basename "$backup_dir")" "${CC_SWITCH_INSTALLER_TIMESTAMP}-0010"
}

test_transaction_keychain_cancel_rolls_back_all_files() {
  local case_dir="$TEST_TMP/transaction-keychain-cancel"
  local before
  local after
  mkdir -p "$case_dir"
  prepare_transaction_case "$case_dir"
  before="$(managed_state_digest "$case_dir")"
  export FAKE_SECURITY_MODE=cancel

  assert_command_fails perform_install

  after="$(managed_state_digest "$case_dir")"
  assert_equals "$after" "$before"
  [[ ! -e "$FAKE_KEYCHAIN_STATE" ]] || fail 'cancelled keychain prompt left a keychain item'
  assert_contains "$case_dir/home/.local/share/cc-switch-modelhub/install.sh" 'old-local-installer'
}

test_transaction_health_timeout_rolls_back_all_files() {
  local case_dir="$TEST_TMP/transaction-health-timeout"
  local before
  local after
  mkdir -p "$case_dir"
  prepare_transaction_case "$case_dir"
  before="$(managed_state_digest "$case_dir")"
  export FAKE_HEALTH_MODE=timeout

  assert_command_fails perform_install

  after="$(managed_state_digest "$case_dir")"
  assert_equals "$after" "$before"
  [[ ! -e "$FAKE_KEYCHAIN_STATE" ]] || fail 'failed installation left a new keychain item'
  [[ ! -e "$FAKE_LAUNCHCTL_STATE_DIR/env-MODELHUB_AK" ]] || fail 'failed installation left MODELHUB_AK in launchd'
  [[ ! -e "$FAKE_LAUNCHCTL_STATE_DIR/env-CODEX_CLI_PATH" ]] || fail 'failed installation left CODEX_CLI_PATH in launchd'
  assert_contains "$case_dir/home/.local/share/cc-switch-modelhub/install.sh" 'old-local-installer'
}

test_transaction_post_launcher_failure_restores_previous_launcher() {
  local case_dir="$TEST_TMP/transaction-post-launcher-failure"
  local launcher="$case_dir/home/.local/share/cc-switch-modelhub/install.sh"
  local launcher_before
  local launcher_after
  local before
  local after
  local result
  mkdir -p "$case_dir"
  prepare_transaction_case "$case_dir"
  before="$(managed_state_digest "$case_dir")"
  launcher_before="$(shasum -a 256 "$launcher" | awk '{print $1}')"
  export FAKE_COMPLETION_MARKER_DIR="$case_dir/home/.cc-switch/backups/modelhub-installer/$CC_SWITCH_INSTALLER_TIMESTAMP"

  set +e
  perform_install
  result=$?
  set -e
  if [[ -n "$ACTIVE_BACKUP_DIR" && -d "$ACTIVE_BACKUP_DIR" ]]; then
    chmod 700 "$ACTIVE_BACKUP_DIR"
  fi

  [[ "$result" -ne 0 ]] || fail 'completion-marker fault unexpectedly succeeded'
  after="$(managed_state_digest "$case_dir")"
  launcher_after="$(shasum -a 256 "$launcher" | awk '{print $1}')"
  assert_equals "$after" "$before"
  assert_equals "$launcher_after" "$launcher_before"
  assert_contains "$launcher" 'old-local-installer'
  [[ ! -e "$ACTIVE_BACKUP_DIR/install-completed" ]] || fail 'failed install left a completion marker'
}

test_transaction_keychain_acl_error_aborts_without_write() {
  local case_dir="$TEST_TMP/transaction-keychain-acl-error"
  local before
  local after
  mkdir -p "$case_dir"
  prepare_transaction_case "$case_dir"
  before="$(managed_state_digest "$case_dir")"
  export FAKE_SECURITY_FIND_STATUS=36

  assert_command_fails perform_install

  after="$(managed_state_digest "$case_dir")"
  assert_equals "$after" "$before"
  assert_not_contains "$FAKE_SECURITY_LOG" 'add-generic-password'
  assert_not_contains "$FAKE_SECURITY_LOG" 'delete-generic-password'
  assert_contains "$case_dir/home/.local/share/cc-switch-modelhub/install.sh" 'old-local-installer'
}

test_transaction_success_and_repeat_are_idempotent() {
  local case_dir="$TEST_TMP/transaction success"
  local database
  mkdir -p "$case_dir"
  prepare_transaction_case "$case_dir"
  database="$case_dir/home/.cc-switch/cc-switch.db"

  /bin/bash -s <"$INSTALLER"
  export CC_SWITCH_INSTALLER_TIMESTAMP='20260727T120001Z'
  /bin/bash "$INSTALLER"

  assert_contains "$case_dir/home/.codex/config.toml" 'model_provider = "modelhub"'
  assert_contains "$case_dir/home/.codex/config.toml" 'approval_policy = "on-request"'
  assert_contains "$case_dir/Applications/CC Switch.app/Contents/MacOS/cc-switch" 'new-app'
  assert_contains "$case_dir/home/.codex/auth.json" 'user-owned'
  assert_sql "$database" "select count(*) from providers where name='Bytedance ModelHub - 官方CLI'" '1'
  [[ -f "$case_dir/home/Library/LaunchAgents/com.ccswitch.modelhub-env.plist" ]] || fail 'LaunchAgent was not installed'
  assert_equals \
    "$(plutil -extract ProgramArguments.0 raw -o - "$case_dir/home/Library/LaunchAgents/com.ccswitch.modelhub-env.plist")" \
    "$case_dir/home/.local/share/cc-switch-modelhub/load-modelhub-env.sh"
  [[ -f "$case_dir/home/.local/share/cc-switch-modelhub/install.sh" ]] || fail 'local installer was not saved'
  [[ -f "$FAKE_LAUNCHCTL_STATE_DIR/env-MODELHUB_AK" ]] || fail 'MODELHUB_AK was not loaded into launchd'
  [[ -f "$FAKE_LAUNCHCTL_STATE_DIR/env-CODEX_CLI_PATH" ]] || fail 'CODEX_CLI_PATH was not loaded into launchd'
}

test_transaction_rollback_latest_restores_and_removes_files() {
  local case_dir="$TEST_TMP/transaction-explicit-rollback"
  local before
  local after
  mkdir -p "$case_dir"
  prepare_transaction_case "$case_dir"
  before="$(managed_state_digest "$case_dir")"

  perform_install
  [[ -x "$case_dir/home/.local/share/cc-switch-modelhub/install.sh" ]] || fail 'durable rollback launcher was not installed'
  /bin/bash "$case_dir/home/.local/share/cc-switch-modelhub/install.sh" --rollback latest
  /bin/bash "$case_dir/home/.local/share/cc-switch-modelhub/install.sh" --rollback latest

  after="$(managed_state_digest "$case_dir")"
  assert_equals "$after" "$before"
  [[ ! -e "$case_dir/home/.codex/models-modelhub-1m.json" ]] || fail 'rollback kept a newly created model catalog'
  [[ ! -e "$case_dir/home/Library/LaunchAgents/com.ccswitch.modelhub-env.plist" ]] || fail 'rollback kept a newly created LaunchAgent'
  [[ -x "$case_dir/home/.local/share/cc-switch-modelhub/install.sh" ]] || fail 'rollback removed the durable launcher'
  assert_not_contains "$case_dir/home/.local/share/cc-switch-modelhub/install.sh" 'old-local-installer'
  [[ ! -e "$FAKE_LAUNCHCTL_STATE_DIR/env-MODELHUB_AK" ]] || fail 'rollback kept MODELHUB_AK in launchd'
  [[ ! -e "$FAKE_LAUNCHCTL_STATE_DIR/env-CODEX_CLI_PATH" ]] || fail 'rollback kept CODEX_CLI_PATH in launchd'
}

test_transaction_rollback_without_backup_reports_clear_error() {
  local case_dir="$TEST_TMP/transaction-no-backup"
  local output
  local status
  mkdir -p "$case_dir"
  create_transaction_state "$case_dir"
  create_transaction_stubs "$case_dir"
  export CC_SWITCH_INSTALLER_TEST_MODE=1
  export CC_SWITCH_INSTALLER_TEST_HOME="$case_dir/home"
  export CC_SWITCH_INSTALLER_TEST_APPLICATIONS_DIR="$case_dir/Applications"
  export FAKE_KEYCHAIN_STATE="$case_dir/keychain-state"
  export FAKE_LAUNCHCTL_STATE_DIR="$case_dir/launchctl-state"

  set +e
  output="$(/bin/bash "$INSTALLER" --rollback latest 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail 'rollback without a backup unexpectedly succeeded'
  [[ "$output" == *'no completed ModelHub installer backup is available'* ]] \
    || fail "rollback error was not actionable: $output"
}

test_transaction_cli_help_and_argument_validation() {
  local help_output
  help_output="$(/bin/bash "$INSTALLER" --help)"
  [[ "$help_output" == *'--rollback latest'* ]] || fail 'help output omits rollback usage'
  help_output="$(/bin/bash -s -- --help <"$INSTALLER")"
  [[ "$help_output" == *'--rollback latest'* ]] || fail 'stdin bootstrap did not execute main'
  assert_command_fails /bin/bash "$INSTALLER" --unknown
  assert_command_fails /bin/bash "$INSTALLER" --help extra
}

test_transaction_corrupt_backup_fails_before_restore_writes() {
  local case_dir="$TEST_TMP/transaction-corrupt-backup"
  local before
  local after
  mkdir -p "$case_dir"
  prepare_transaction_case "$case_dir"
  perform_install
  before="$(managed_state_digest "$case_dir")"
  rm "$ACTIVE_BACKUP_DIR/files/settings.json"

  assert_command_fails restore_backup "$ACTIVE_BACKUP_DIR"

  after="$(managed_state_digest "$case_dir")"
  assert_equals "$after" "$before"
}

create_packager_source() {
  local source_dir="$1"
  mkdir -p "$source_dir/assets" "$source_dir/templates"
  cp "$INSTALLER" "$source_dir/install.sh"
  cp "$TEMPLATE" "$source_dir/templates/modelhub-provider.toml"
  cp "$META_TEMPLATE" "$source_dir/templates/modelhub-provider-meta.json"
  cp "$REPO_ROOT/scripts/modelhub-installer/templates/com.ccswitch.modelhub-env.plist" \
    "$source_dir/templates/com.ccswitch.modelhub-env.plist"
  cp "$REPO_ROOT/scripts/modelhub-installer/templates/load-modelhub-env.sh" \
    "$source_dir/templates/load-modelhub-env.sh"
  printf '{"models":{}}\n' >"$source_dir/assets/models-modelhub-1m.json"
}

run_packager() {
  local source_dir="$1"
  local app_zip="$2"
  local output_dir="$3"
  CC_SWITCH_PACKAGE_SOURCE_DIR="$source_dir" \
    /bin/bash "$PACKAGER" --app-zip "$app_zip" --output-dir "$output_dir"
}

test_package_builds_exact_allowlisted_release_assets() {
  local case_dir="$TEST_TMP/package-success"
  local source_dir="$case_dir/source"
  local output_dir="$case_dir/output"
  local actual_files
  local expected_files
  mkdir -p "$case_dir"
  create_packager_source "$source_dir"
  printf 'verified-app-zip\n' >"$case_dir/app.zip"

  run_packager "$source_dir" "$case_dir/app.zip" "$output_dir"

  actual_files="$(find "$output_dir" -maxdepth 1 -type f -exec basename '{}' \; | LC_ALL=C sort)"
  expected_files="$(printf '%s\n' \
    'CC-Switch-ModelHub-3.18.0-arm64.app.zip' \
    'SHA256SUMS.txt' \
    'install.sh' \
    'modelhub-installer-resources.tar.gz' \
    | LC_ALL=C sort)"
  assert_equals "$actual_files" "$expected_files"
  verify_release_assets "$output_dir"
  validate_resource_archive "$output_dir/modelhub-installer-resources.tar.gz"
  assert_equals "$(awk 'NF { count += 1 } END { print count + 0 }' "$output_dir/SHA256SUMS.txt")" '3'
}

test_package_rejects_sensitive_content() {
  local case_dir="$TEST_TMP/package-sensitive-content"
  local source_dir
  local output_dir
  local index=0
  local secret
  local secrets=(
    '/Users/shopee/private/path'
    'access_token = "secret"'
    'refresh_token = "secret"'
    'id_token = "secret"'
    'experimental_bearer_token = "secret"'
    'OPENAI_API_KEY = "secret"'
    'MODELHUB_AK = "real-value"'
  )
  mkdir -p "$case_dir"
  printf 'verified-app-zip\n' >"$case_dir/app.zip"

  for secret in "${secrets[@]}"; do
    index=$((index + 1))
    source_dir="$case_dir/source-$index"
    output_dir="$case_dir/output-$index"
    create_packager_source "$source_dir"
    printf '\n%s\n' "$secret" >>"$source_dir/templates/modelhub-provider.toml"

    assert_command_fails run_packager "$source_dir" "$case_dir/app.zip" "$output_dir"
    [[ ! -e "$output_dir/modelhub-installer-resources.tar.gz" ]] \
      || fail "sensitive package case $index left a publishable tarball"
  done
}

test_package_rejects_generic_credential_key_shapes() {
  local case_dir="$TEST_TMP/package-generic-credentials"
  local source_dir
  local output_dir
  local index=0
  local secret
  local secrets=(
    'api_key = "secret-value"'
    '"api_key": "secret-value"'
    'bearer_token = "secret-value"'
    'client_secret: "secret-value"'
    '"client_secret": "secret-value"'
    'credential = "secret-value"'
    'Authorization = "Bearer secret-value"'
    '"Authorization": "Bearer secret-value"'
  )
  mkdir -p "$case_dir"
  printf 'verified-app-zip\n' >"$case_dir/app.zip"

  for secret in "${secrets[@]}"; do
    index=$((index + 1))
    source_dir="$case_dir/source-$index"
    output_dir="$case_dir/output-$index"
    create_packager_source "$source_dir"
    printf '\n%s\n' "$secret" >>"$source_dir/templates/modelhub-provider.toml"

    assert_command_fails run_packager "$source_dir" "$case_dir/app.zip" "$output_dir"
    [[ ! -e "$output_dir/modelhub-installer-resources.tar.gz" ]] \
      || fail "generic credential package case $index left a publishable tarball"
  done

  source_dir="$case_dir/source-safe-variable"
  create_packager_source "$source_dir"
  run_packager "$source_dir" "$case_dir/app.zip" "$case_dir/output-safe-variable"
}

test_package_rejects_sensitive_file_types() {
  local case_dir="$TEST_TMP/package-sensitive-files"
  local source_dir="$case_dir/source-auth"
  local output_dir="$case_dir/output-auth"
  mkdir -p "$case_dir"
  printf 'verified-app-zip\n' >"$case_dir/app.zip"
  create_packager_source "$source_dir"
  printf '{}\n' >"$source_dir/auth.json"
  assert_command_fails run_packager "$source_dir" "$case_dir/app.zip" "$output_dir"

  source_dir="$case_dir/source-db"
  output_dir="$case_dir/output-db"
  create_packager_source "$source_dir"
  sqlite3 "$source_dir/cc-switch.db" 'create table secret(value text);'
  assert_command_fails run_packager "$source_dir" "$case_dir/app.zip" "$output_dir"
}

test_package_rejects_output_inside_source_tree() {
  local case_dir="$TEST_TMP/package-output-scope"
  local source_dir="$case_dir/source"
  mkdir -p "$case_dir"
  printf 'verified-app-zip\n' >"$case_dir/app.zip"
  create_packager_source "$source_dir"

  assert_command_fails run_packager "$source_dir" "$case_dir/app.zip" "$source_dir"
  assert_command_fails run_packager "$source_dir" "$case_dir/app.zip" "$source_dir/nested-output"
  [[ ! -e "$source_dir/modelhub-installer-resources.tar.gz" ]] || fail 'unsafe package run wrote into source tree'
  [[ ! -e "$source_dir/nested-output" ]] || fail 'unsafe package run created nested output'
}

test_package_rejects_source_symlinks() {
  local case_dir="$TEST_TMP/package-source-symlink"
  local source_dir="$case_dir/source"
  mkdir -p "$case_dir"
  printf 'verified-app-zip\n' >"$case_dir/app.zip"
  create_packager_source "$source_dir"
  ln -s /tmp "$source_dir/unexpected-link"

  assert_command_fails run_packager "$source_dir" "$case_dir/app.zip" "$case_dir/output"
}

test_release_smoke_installs_repeats_and_rolls_back_packaged_assets() {
  local case_dir="$TEST_TMP/release-smoke"
  local asset_dir
  local database
  local first_install_digest
  local after_rollback_digest
  mkdir -p "$case_dir"
  create_transaction_state "$case_dir"
  create_transaction_stubs "$case_dir"

  if [[ -n "${CC_SWITCH_RELEASE_SMOKE_ASSET_DIR:-}" ]]; then
    asset_dir="$CC_SWITCH_RELEASE_SMOKE_ASSET_DIR"
  else
    mkdir -p "$case_dir/assets"
    create_fake_app_zip "$case_dir"
    asset_dir="$case_dir/publish"
    run_packager \
      "$REPO_ROOT/scripts/modelhub-installer" \
      "$case_dir/assets/CC-Switch-ModelHub-3.18.0-arm64.app.zip" \
      "$asset_dir"
  fi

  export CC_SWITCH_INSTALLER_TEST_MODE=1
  export CC_SWITCH_INSTALLER_TEST_HOME="$case_dir/home"
  export CC_SWITCH_INSTALLER_TEST_APPLICATIONS_DIR="$case_dir/Applications"
  export CC_SWITCH_INSTALLER_ASSET_DIR="$asset_dir"
  export CC_SWITCH_INSTALLER_TIMESTAMP='20260727T130000Z'
  export CC_SWITCH_INSTALLER_HEALTH_TIMEOUT=1
  export FAKE_KEYCHAIN_STATE="$case_dir/keychain-state"
  export FAKE_LAUNCHCTL_STATE_DIR="$case_dir/launchctl-state"
  export FAKE_SECURITY_MODE=success
  export FAKE_HEALTH_MODE=healthy
  database="$case_dir/home/.cc-switch/cc-switch.db"

  /bin/bash -s <"$asset_dir/install.sh"
  first_install_digest="$(managed_state_digest "$case_dir")"
  assert_contains "$case_dir/home/.codex/config.toml" 'approval_policy = "on-request"'
  assert_sql "$database" "select count(*) from providers where name='Bytedance ModelHub - 官方CLI'" '1'

  export CC_SWITCH_INSTALLER_TIMESTAMP='20260727T130001Z'
  /bin/bash "$asset_dir/install.sh"
  assert_sql "$database" "select count(*) from providers where name='Bytedance ModelHub - 官方CLI'" '1'

  /bin/bash "$case_dir/home/.local/share/cc-switch-modelhub/install.sh" --rollback latest
  after_rollback_digest="$(managed_state_digest "$case_dir")"
  assert_equals "$after_rollback_digest" "$first_install_digest"
}

run_test "merge preserves unmanaged sections" test_merge_preserves_unmanaged_sections
run_test "merge creates config from empty file" test_merge_creates_config_from_empty_file
run_test "merge creates config when source is missing" test_merge_creates_config_when_source_is_missing
run_test "merge replaces only modelhub section" test_merge_replaces_only_active_modelhub_section
run_test "merge replaces equivalent modelhub headers" test_merge_replaces_equivalent_modelhub_headers
run_test "merge validation uses real TOML parser" test_merge_validation_uses_real_toml_parser
run_test "merge validation rejects unresolved home placeholder" test_validate_rejects_unresolved_home_placeholder
run_test "preflight rejects unsupported platforms" test_preflight_rejects_unsupported_platforms
run_test "preflight validates ChatGPT Codex Team ID" test_preflight_validates_chatgpt_codex_team_id
run_test "validates existing ChatGPT" test_validates_existing_chatgpt_app
run_test "blocks invalid existing ChatGPT" test_blocks_invalid_existing_chatgpt_without_mutation
run_test "preflight verifies all release checksums" test_preflight_verifies_all_release_checksums
run_test "preflight rejects unexpected checksum entries" test_preflight_rejects_unexpected_checksum_entries
run_test "preflight accepts exact resource archive" test_preflight_accepts_exact_resource_archive
run_test "preflight rejects archive symlink and extra file" test_preflight_rejects_archive_symlink_and_extra_file
run_test "preflight rejects archive special file types" test_preflight_rejects_archive_special_file_types
run_test "preflight rejects unsafe archive entry names" test_preflight_rejects_unsafe_archive_entry_names
run_test "preflight downloads from immutable release tag" test_preflight_downloads_from_immutable_release_tag
run_test "database merge is idempotent and preserves unrelated rows" test_database_merge_is_idempotent_and_preserves_unrelated_rows
run_test "database merge reuses existing ModelHub provider ID" test_database_merge_reuses_existing_modelhub_provider_id
run_test "database merge rejects fixed ID conflict without mutation" test_database_merge_rejects_fixed_id_conflict_without_mutation
run_test "database schema requires created_at and provider identity key" test_database_schema_requires_created_at_and_provider_identity_key
run_test "database schema initializes missing database with hidden app" test_database_schema_initializes_missing_database_with_hidden_app
run_test "settings merge changes only managed keys" test_settings_merge_changes_only_managed_keys
run_test "settings merge rejects invalid JSON without overwrite" test_settings_merge_rejects_invalid_json_without_overwrite
run_test "settings merge creates missing file" test_settings_merge_creates_missing_file
run_test "existing nonwritable app requires privilege" test_existing_nonwritable_app_requires_privilege
run_test "rejects root execution validation contract" test_rejects_root_execution_validation_contract
run_test "rejects root execution before install work" test_rejects_root_execution_before_install_work
run_test "transaction keychain cancel rolls back all files" test_transaction_keychain_cancel_rolls_back_all_files
run_test "transaction keychain ACL error aborts without write" test_transaction_keychain_acl_error_aborts_without_write
run_test "transaction health timeout rolls back all files" test_transaction_health_timeout_rolls_back_all_files
run_test "transaction post-launcher failure restores previous launcher" test_transaction_post_launcher_failure_restores_previous_launcher
run_test "transaction backup copy failure is fail closed" test_transaction_backup_copy_failure_is_fail_closed
run_test "transaction real write failure stops before keychain" test_transaction_real_write_failure_stops_before_keychain
run_test "transaction signal cancellation rolls back" test_transaction_signal_cancellation_rolls_back
run_test "transaction waits for CC Switch exit before backup" test_transaction_waits_for_cc_switch_exit_before_backup
run_test "transaction WAL snapshot restores committed sentinel and cleans sidecars" test_transaction_wal_snapshot_restores_committed_sentinel_and_cleans_sidecars
run_test "transaction same-second backup suffixes sort lexically" test_transaction_same_second_backup_suffixes_sort_lexically
run_test "transaction success and repeat are idempotent" test_transaction_success_and_repeat_are_idempotent
run_test "transaction rollback latest restores and removes files" test_transaction_rollback_latest_restores_and_removes_files
run_test "transaction rollback without backup reports clear error" test_transaction_rollback_without_backup_reports_clear_error
run_test "transaction CLI help and argument validation" test_transaction_cli_help_and_argument_validation
run_test "transaction corrupt backup fails before restore writes" test_transaction_corrupt_backup_fails_before_restore_writes
run_test "package builds exact allowlisted release assets" test_package_builds_exact_allowlisted_release_assets
run_test "package rejects sensitive content" test_package_rejects_sensitive_content
run_test "package rejects generic credential key shapes" test_package_rejects_generic_credential_key_shapes
run_test "package rejects sensitive file types" test_package_rejects_sensitive_file_types
run_test "package rejects output inside source tree" test_package_rejects_output_inside_source_tree
run_test "package rejects source symlinks" test_package_rejects_source_symlinks
run_test "release-smoke installs repeats and rolls back packaged assets" test_release_smoke_installs_repeats_and_rolls_back_packaged_assets

if [[ "$TESTS_RUN" -eq 0 ]]; then
  echo "No tests matched filter: $TEST_FILTER" >&2
  exit 2
fi

if [[ "$TESTS_FAILED" -ne 0 ]]; then
  echo "$TESTS_FAILED of $TESTS_RUN tests failed" >&2
  exit 1
fi

echo "$TESTS_RUN tests passed"
