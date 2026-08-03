#!/bin/bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="$REPO_ROOT/scripts/modelhub-installer/install.sh"
PACKAGER="$REPO_ROOT/scripts/modelhub-installer/package-release.sh"
TEMPLATE="$REPO_ROOT/scripts/modelhub-installer/templates/modelhub-provider.toml"
META_TEMPLATE="$REPO_ROOT/scripts/modelhub-installer/templates/modelhub-provider-meta.json"
RENAME_HELPER_SOURCE="$REPO_ROOT/scripts/modelhub-installer/helpers/rename-exclusive.c"
GOLDEN_DB_BUILDER="$REPO_ROOT/scripts/modelhub-installer/build-golden-db.sh"
LOCAL_GOLDEN_SNAPSHOT_BUILDER="$REPO_ROOT/scripts/modelhub-installer/build-local-golden-snapshot.sh"
GOLDEN_DB_SCHEMA="$REPO_ROOT/scripts/modelhub-installer/golden/cc-switch-schema.sql"
GOLDEN_CODEX_CONFIG="$REPO_ROOT/scripts/modelhub-installer/golden/codex-config.toml"
GOLDEN_SETTINGS="$REPO_ROOT/scripts/modelhub-installer/golden/settings.json"
if [[ "${1:-}" == "--" ]]; then
  shift
fi
TEST_FILTER="${1:-}"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/cc-switch-installer-tests.XXXXXX")"
TEST_RENAME_HELPER="$TEST_TMP/rename-exclusive"
TESTS_RUN=0
TESTS_FAILED=0

cleanup() {
  local state_file
  local trusted_dir
  while IFS= read -r state_file; do
    trusted_dir="$(/bin/cat "$state_file" 2>/dev/null || true)"
    case "$trusted_dir" in
      /private/var/tmp/.cc-switch-modelhub-helper.*)
        if [[ -e "$trusted_dir" ]]; then
          /bin/chmod -R u+w "$trusted_dir" 2>/dev/null || true
          /bin/rm -rf -- "$trusted_dir" 2>/dev/null || true
        fi
        ;;
    esac
  done < <(find "$TEST_TMP" -type f -name 'trusted-dir.state' 2>/dev/null)
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

activate_fake_privilege_runner() {
  TEST_FAKE_SUDO_BIN="$1"
  sudo_command() {
    printf '%s' "$TEST_FAKE_SUDO_BIN"
  }
  run_with_privilege() {
    "$TEST_FAKE_SUDO_BIN" "$@"
  }
}

build_test_rename_helper() {
  local output_path="$1"

  /usr/bin/xcrun clang \
    -arch arm64 \
    -mmacosx-version-min=12.0 \
    -Os \
    -Wall \
    -Wextra \
    -Werror \
    -o "$output_path" \
    "$RENAME_HELPER_SOURCE"
  /usr/bin/codesign \
    --force \
    --sign - \
    --timestamp=none \
    --identifier com.ccswitch.modelhub.rename-exclusive \
    "$output_path"
  /usr/bin/codesign --verify --strict --verbose=2 "$output_path"
}

ensure_test_rename_helper() {
  if [[ ! -x "$TEST_RENAME_HELPER" ]]; then
    build_test_rename_helper "$TEST_RENAME_HELPER"
  fi
}

test_helper_exclusive_rename_preserves_exact_collision() {
  local case_dir="$TEST_TMP/rename-helper-collision"
  local helper="$case_dir/rename-exclusive"
  local source="$case_dir/ChatGPT.app"
  local competitor="$case_dir/Applications/ChatGPT.app"
  local status
  local source_dev
  local source_ino
  mkdir -p "$source" "$(dirname "$competitor")" "$competitor"
  printf 'staged\n' >"$source/owner"
  printf 'competitor\n' >"$competitor/owner"

  build_test_rename_helper "$helper"
  source_dev="$(/usr/bin/stat -f '%d' "$source")"
  source_ino="$(/usr/bin/stat -f '%i' "$source")"
  set +e
  "$helper" "$source" "$competitor" "$source_dev" "$source_ino" >/dev/null 2>&1
  status=$?
  set -e

  assert_equals "$status" '17'
  assert_contains "$source/owner" 'staged'
  assert_contains "$competitor/owner" 'competitor'
  assert_equals "$(/usr/bin/lipo -archs "$helper")" 'arm64'
  /usr/bin/codesign --verify --strict --verbose=2 "$helper"

  set +e
  "$helper" >/dev/null 2>&1
  status=$?
  set -e
  assert_equals "$status" '64'
  set +e
  "$helper" "$case_dir/missing-source" "$case_dir/new-target" 0 0 >/dev/null 2>&1
  status=$?
  set -e
  assert_equals "$status" '1'

  mkdir "$case_dir/identity-source"
  set +e
  "$helper" \
    "$case_dir/identity-source" \
    "$case_dir/identity-target" \
    "$source_dev" \
    "$source_ino" \
    >/dev/null 2>&1
  status=$?
  set -e
  assert_equals "$status" '18'
  [[ -d "$case_dir/identity-source" ]] || fail 'identity mismatch moved the source'
  [[ ! -e "$case_dir/identity-target" ]] || fail 'identity mismatch created the target'
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
  export CC_SWITCH_INSTALLER_TEST_MODE=1

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
    'if [[ "$6" == */.chatgpt-modelhub.*/ChatGPT.app/* && "${FAKE_REQUIRE_PRIVILEGED_STAGING:-0}" == "1" && "${FAKE_PRIVILEGED:-0}" != "1" ]]; then exit 77; fi' \
    'awk -F= -v key="$2" '\''$1 == key { print substr($0, index($0, "=") + 1); found = 1; exit } END { exit(found ? 0 : 1) }'\'' "$6"' \
    >"$case_dir/plutil"
  printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'target="${@: -1}"' \
    'if [[ "$target" == */.chatgpt-modelhub.*/ChatGPT.app* && "${FAKE_REQUIRE_PRIVILEGED_STAGING:-0}" == "1" && "${FAKE_PRIVILEGED:-0}" != "1" ]]; then exit 77; fi' \
    'if [[ "$1" == "--verify" ]]; then' \
    '  [[ "$2" == "--deep" && "$3" == "--strict" && "$#" == "4" ]]' \
    '  if [[ "$target" == */.chatgpt-modelhub.*/ChatGPT.app && "${FAKE_TEMP_APP_STRICT:-pass}" != "pass" ]]; then exit 1; fi' \
    '  if [[ -n "${FAKE_FINAL_TARGET:-}" && "$target" == "$FAKE_FINAL_TARGET" && "${FAKE_FINAL_APP_STRICT:-pass}" != "pass" ]]; then exit 1; fi' \
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
    'target="${@: -1}"' \
    'if [[ "$target" == */.chatgpt-modelhub.*/ChatGPT.app/* && "${FAKE_REQUIRE_PRIVILEGED_STAGING:-0}" == "1" && "${FAKE_PRIVILEGED:-0}" != "1" ]]; then exit 77; fi' \
    'printf "%s\n" "$*" >>"${FAKE_FILE_LOG:-/dev/null}"' \
    'if [[ "${1:-}" == "-b" ]]; then' \
    '  echo "Mach-O universal binary with architectures: [${FAKE_APP_ARCHS:-arm64}]"' \
    'else' \
    '  echo "$1: Mach-O universal binary with architectures: [${FAKE_APP_ARCHS:-arm64}]"' \
    'fi' \
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
  local misleading_app_path="$case_dir/misleading/ChatGPT.app"
  local file_log="$case_dir/file.log"
  local info_plist="$app_path/Contents/Info.plist"
  local codex_path="$app_path/Contents/Resources/codex"
  mkdir -p "$case_dir"
  export CC_SWITCH_INSTALLER_TEST_MODE=1
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

  create_chatgpt_app_fixture "$misleading_app_path" 'arm64'
  FAKE_APP_ARCHS='x86_64' FAKE_FILE_LOG="$file_log" \
    CC_SWITCH_PLUTIL_BIN="$case_dir/plutil" CC_SWITCH_CODESIGN_BIN="$case_dir/codesign" \
    CC_SWITCH_FILE_BIN="$case_dir/file" \
    assert_command_fails validate_chatgpt_app "$misleading_app_path" '2DC432GLL2' 'com.openai.codex'
  assert_contains "$file_log" "-b $misleading_app_path/Contents/MacOS/arm64"
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
  export CC_SWITCH_INSTALLER_TEST_MODE=1
  export CC_SWITCH_INSTALLER_TEST_HOME="$case_dir/home"
  export CC_SWITCH_INSTALLER_TEST_APPLICATIONS_DIR="$case_dir/Applications"
  configure_install_paths
  before_digest="$(find "$app_path" -type f -exec shasum -a 256 {} + | LC_ALL=C sort | shasum -a 256)"

  set +e
  FAKE_APP_TEAM_ID='WRONGTEAM' FAKE_MUTATION_LOG="$mutation_log" \
    CC_SWITCH_PLUTIL_BIN="$case_dir/plutil" CC_SWITCH_CODESIGN_BIN="$case_dir/codesign" \
    CC_SWITCH_FILE_BIN="$case_dir/file" CC_SWITCH_CURL_BIN="$case_dir/curl" \
    CC_SWITCH_HDIUTIL_BIN="$case_dir/hdiutil" \
    ensure_chatgpt_app "$case_dir/stage" 2>"$stderr_file"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail 'invalid existing ChatGPT app was accepted'
  assert_contains "$stderr_file" 'https://openai.com/chatgpt/download/'
  assert_contains "$stderr_file" 'official OpenAI download page'
  [[ ! -e "$mutation_log" ]] || fail 'invalid existing ChatGPT app triggered curl or hdiutil'
  after_digest="$(find "$app_path" -type f -exec shasum -a 256 {} + | LC_ALL=C sort | shasum -a 256)"
  assert_equals "$after_digest" "$before_digest"
}

test_blocks_invalid_existing_chatgpt_symlink_without_download() {
  local case_dir="$TEST_TMP/chatgpt-invalid-symlink"
  local mutation_log="$case_dir/mutations.log"
  local status
  mkdir -p "$case_dir/Applications" "$case_dir/stage"
  ln -s "$case_dir/missing-ChatGPT.app" "$case_dir/Applications/ChatGPT.app"
  create_chatgpt_validation_stubs "$case_dir"
  export CC_SWITCH_INSTALLER_TEST_MODE=1
  export CC_SWITCH_INSTALLER_TEST_HOME="$case_dir/home"
  export CC_SWITCH_INSTALLER_TEST_APPLICATIONS_DIR="$case_dir/Applications"
  configure_install_paths

  set +e
  FAKE_MUTATION_LOG="$mutation_log" \
    CC_SWITCH_PLUTIL_BIN="$case_dir/plutil" CC_SWITCH_CODESIGN_BIN="$case_dir/codesign" \
    CC_SWITCH_FILE_BIN="$case_dir/file" CC_SWITCH_CURL_BIN="$case_dir/curl" \
    CC_SWITCH_HDIUTIL_BIN="$case_dir/hdiutil" \
    ensure_chatgpt_app "$case_dir/stage" >/dev/null 2>&1
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail 'invalid ChatGPT symlink was accepted'
  [[ -L "$CHATGPT_APP_PATH" ]] || fail 'invalid ChatGPT symlink was replaced'
  [[ ! -e "$mutation_log" ]] || fail 'invalid ChatGPT symlink triggered curl or hdiutil'
}

test_preflight_blocks_invalid_existing_chatgpt_before_release_assets() {
  local case_dir="$TEST_TMP/chatgpt-invalid-before-release"
  local app_path="$case_dir/Applications/ChatGPT.app"
  local output
  local status
  mkdir -p "$case_dir/Applications" "$case_dir/tmp"
  create_chatgpt_app_fixture "$app_path"
  create_chatgpt_validation_stubs "$case_dir"
  export CC_SWITCH_INSTALLER_TEST_MODE=1
  export CC_SWITCH_INSTALLER_TEST_EUID=501
  export CC_SWITCH_INSTALLER_TEST_HOME="$case_dir/home"
  export CC_SWITCH_INSTALLER_TEST_APPLICATIONS_DIR="$case_dir/Applications"
  export CC_SWITCH_INSTALLER_ASSET_DIR="$case_dir/missing-release-assets"
  export CC_SWITCH_INSTALLER_TEST_OS=Darwin
  export CC_SWITCH_INSTALLER_TEST_ARCH=arm64
  export CC_SWITCH_INSTALLER_TEST_MACOS_MAJOR=15
  export CC_SWITCH_PLUTIL_BIN="$case_dir/plutil"
  export CC_SWITCH_CODESIGN_BIN="$case_dir/codesign"
  export CC_SWITCH_FILE_BIN="$case_dir/file"
  export FAKE_APP_TEAM_ID=WRONGTEAM
  export TMPDIR="$case_dir/tmp"

  set +e
  output="$(perform_install 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail 'invalid existing ChatGPT app passed top-level preflight'
  [[ "$output" == *'official OpenAI download page'* ]] \
    || fail "release assets were accessed before ChatGPT preflight: $output"
  [[ "$output" != *'release asset'* ]] \
    || fail "invalid ChatGPT preflight reported a release asset error: $output"
}

create_chatgpt_bootstrap_stubs() {
  local case_dir="$1"

  create_chatgpt_validation_stubs "$case_dir"
  write_executable_stub "$case_dir/curl" \
    'printf "%s\n" "$*" >>"$FAKE_CHATGPT_CURL_LOG"' \
    'if [[ "$*" != *"--output"* ]]; then' \
    '  if [[ "${FAKE_HEALTH_MODE:-healthy}" == "healthy" ]]; then' \
    '    if [[ -n "${FAKE_LIVE_CONFIG_PATH:-}" && -f "$FAKE_LIVE_CONFIG_PATH" ]]; then' \
    '      /usr/bin/sed '\''s#https://aidp.bytedance.net/api/modelhub/online#http://127.0.0.1:15721/v1#g'\'' "$FAKE_LIVE_CONFIG_PATH" >"$FAKE_LIVE_CONFIG_PATH.next"' \
    '      /bin/mv "$FAKE_LIVE_CONFIG_PATH.next" "$FAKE_LIVE_CONFIG_PATH"' \
    '    fi' \
    '    printf "{\"status\":\"healthy\"}\n"' \
    '    exit 0' \
    '  fi' \
    '  exit 22' \
    'fi' \
    '[[ "${FAKE_CHATGPT_BOOTSTRAP_MODE:-success}" != "download-fail" ]] || exit 81' \
    'output_path=""' \
    'while [[ "$#" -gt 0 ]]; do' \
    '  if [[ "$1" == "--output" ]]; then output_path="$2"; shift 2; else shift; fi' \
    'done' \
    '[[ -n "$output_path" ]] || exit 64' \
    'printf "fake-dmg\n" >"$output_path"'
  write_executable_stub "$case_dir/hdiutil" \
    'printf "%s\n" "$*" >>"$FAKE_CHATGPT_HDIUTIL_LOG"' \
    'case "$1" in' \
    '  attach)' \
    '    [[ "$2" == "-nobrowse" && "$3" == "-readonly" && "$4" == "-mountpoint" && "$#" == "6" ]]' \
    '    [[ "${FAKE_CHATGPT_BOOTSTRAP_MODE:-success}" != "attach-fail" ]] || exit 82' \
    '    if [[ "${FAKE_CHATGPT_BOOTSTRAP_MODE:-success}" == "partial-attach-fail" ]]; then printf "%s\n" "$5" >"$FAKE_CHATGPT_MOUNT_STATE"; exit 82; fi' \
    '    if [[ "${FAKE_CHATGPT_BOOTSTRAP_MODE:-success}" == "mount-symlink" ]]; then' \
    '      /bin/rmdir "$5"' \
    '      ln -s "$FAKE_CHATGPT_MOUNT_ESCAPE" "$5"' \
    '    elif [[ "${FAKE_CHATGPT_BOOTSTRAP_MODE:-success}" == "source-symlink" ]]; then' \
    '      ln -s "$FAKE_CHATGPT_DMG_SOURCE" "$5/ChatGPT.app"' \
    '    elif [[ "${FAKE_CHATGPT_BOOTSTRAP_MODE:-success}" != "app-missing" ]]; then' \
    '      /usr/bin/ditto "$FAKE_CHATGPT_DMG_SOURCE" "$5/ChatGPT.app"' \
    '    fi' \
    '    ;;' \
    '  detach)' \
    '    [[ "$#" == "2" ]]' \
    '    printf "detach\n" >>"$FAKE_CHATGPT_EVENT_LOG"' \
    '    if [[ "${FAKE_CHATGPT_BOOTSTRAP_MODE:-success}" == "detach-fail-always" ]]; then exit 83; fi' \
    '    if [[ "${FAKE_CHATGPT_BOOTSTRAP_MODE:-success}" == "detach-fail-once" && ! -e "$FAKE_CHATGPT_DETACH_STATE" ]]; then : >"$FAKE_CHATGPT_DETACH_STATE"; exit 83; fi' \
    '    /bin/rm -f "$FAKE_CHATGPT_MOUNT_STATE"' \
    '    ;;' \
    '  *) exit 64 ;;' \
    'esac'
  write_executable_stub "$case_dir/ditto" \
    'printf "%s\n" "$*" >>"$FAKE_CHATGPT_DITTO_LOG"' \
    'if [[ "${FAKE_CHATGPT_BOOTSTRAP_MODE:-success}" == "staging-symlink" ]]; then ln -s "$1" "$2"; exit 0; fi' \
    'exec /usr/bin/ditto "$@"'
  write_executable_stub "$case_dir/mount" \
    'if [[ "${FAKE_MOUNT_CHECK_FAIL:-0}" == "1" ]]; then exit 85; fi' \
    'if [[ -e "$FAKE_CHATGPT_MOUNT_STATE" ]]; then printf "/dev/disk-test on %s (apfs, read-only)\n" "$(/bin/cat "$FAKE_CHATGPT_MOUNT_STATE")"; else exec /sbin/mount "$@"; fi'
  write_executable_stub "$case_dir/rm" \
    'printf "%s\n" "$*" >>"$FAKE_CHATGPT_RM_LOG"' \
    'if [[ "${FAKE_CHATGPT_BOOTSTRAP_MODE:-success}" == "rm-fail-once" && ! -e "$FAKE_CHATGPT_RM_STATE" ]]; then : >"$FAKE_CHATGPT_RM_STATE"; exit 84; fi' \
    'exec /bin/rm "$@"'
  write_executable_stub "$case_dir/sudo" \
    'printf "%s\n" "$*" >>"$FAKE_CHATGPT_SUDO_LOG"' \
    'if [[ "${1:-}" == "-v" ]]; then exit 0; fi' \
    'if [[ "${1:-}" == "/usr/bin/mktemp" && "${2:-}" == "-d" && "${3:-}" == "/private/var/tmp/.cc-switch-modelhub-helper.XXXXXX" ]]; then' \
    '  trusted_dir="$("$@")"' \
    '  printf "%s\n" "$trusted_dir" >"$FAKE_TRUSTED_DIR_STATE"' \
    '  printf "%s\n" "$trusted_dir"' \
    '  exit 0' \
    'fi' \
    'if [[ "${1:-}" == */rename-exclusive ]]; then' \
    '  printf "publish\n" >>"$FAKE_CHATGPT_EVENT_LOG"' \
    'fi' \
    'if [[ "${1:-}" == */rename-exclusive && -n "${FAKE_RACE_TARGET:-}" && ! -e "$FAKE_RACE_TARGET" ]]; then' \
    '  mkdir -p "$FAKE_RACE_TARGET"' \
    '  printf "competitor\n" >"$FAKE_RACE_TARGET/owner"' \
    'fi' \
    'if [[ "${1:-}" == "/bin/cp" && "${FAKE_CHATGPT_BOOTSTRAP_MODE:-success}" == "trusted-copy-tamper" ]]; then' \
    '  "$@"' \
    '  printf "tamper\n" >>"${@: -1}"' \
    '  /usr/bin/codesign --force --sign - --timestamp=none --identifier com.ccswitch.modelhub.rename-exclusive "${@: -1}" >/dev/null' \
    '  exit 0' \
    'fi' \
    'if [[ "${1:-}" == "/bin/rm" && "${@: -1}" == */.chatgpt-helper.* ]]; then' \
    '  /bin/chmod -R u+w "${@: -1}"' \
    'fi' \
    'if [[ "${1:-}" == "/bin/rm" && "${@: -1}" == /private/var/tmp/.cc-switch-modelhub-helper.* ]]; then' \
    '  /bin/chmod -R u+w "${@: -1}"' \
    'fi' \
    'if [[ "${1:-}" == "/usr/bin/stat" && "${2:-}" == "-f" && "${3:-}" == "%u:%Lp" && "${4:-}" == /private/var/tmp/.cc-switch-modelhub-helper.* ]]; then' \
    '  printf "0:%s\n" "$(/usr/bin/stat -f %Lp "$4")"' \
    '  exit 0' \
    'fi' \
    'if [[ "${1:-}" == "/usr/bin/shasum" && "${FAKE_TRUSTED_PARENT_ATTACK:-0}" == "1" ]]; then' \
    '  hash_output="$("$@")"' \
    '  hash_status=$?' \
    '  trusted_helper="${@: -1}"' \
    '  trusted_dir="$(dirname "$trusted_helper")"' \
    '  printf "attack-attempt\n" >>"$FAKE_CHATGPT_EVENT_LOG"' \
    '  if [[ "$trusted_dir" == /private/var/tmp/.cc-switch-modelhub-helper.* && "$(/usr/bin/stat -f %u /private/var/tmp)" == "0" && "$(/usr/bin/stat -f %Sp /private/var/tmp)" == *t ]]; then' \
    '    printf "attack-blocked\n" >>"$FAKE_CHATGPT_EVENT_LOG"' \
    '  else' \
    '    /bin/mv "$trusted_dir" "$trusted_dir.attacker-old"' \
    '    /bin/chmod -R u+w "$trusted_dir.attacker-old"' \
    '    /bin/mkdir "$trusted_dir"' \
    '    /bin/cp /usr/bin/false "$trusted_helper"' \
    '    /bin/chmod 0500 "$trusted_helper" "$trusted_dir"' \
    '    printf "attacker-executed\n" >>"$FAKE_CHATGPT_EVENT_LOG"' \
    '  fi' \
    '  printf "%s\n" "$hash_output"' \
    '  exit "$hash_status"' \
    'fi' \
    'set +e' \
    'FAKE_PRIVILEGED=1 "$@"' \
    'command_status=$?' \
    'set -e' \
    'if [[ "${1:-}" == */rename-exclusive && "$command_status" == "0" && "${FAKE_SIGNAL_AFTER_PUBLISH:-0}" == "1" ]]; then' \
    '  kill -TERM "$PPID"' \
    'fi' \
    'exit "$command_status"'

  export CC_SWITCH_PLUTIL_BIN="$case_dir/plutil"
  export CC_SWITCH_CODESIGN_BIN="$case_dir/codesign"
  export CC_SWITCH_FILE_BIN="$case_dir/file"
  export CC_SWITCH_CURL_BIN="$case_dir/curl"
  export CC_SWITCH_HDIUTIL_BIN="$case_dir/hdiutil"
  export CC_SWITCH_DITTO_BIN="$case_dir/ditto"
  export CC_SWITCH_RM_BIN="$case_dir/rm"
  export CC_SWITCH_MOUNT_BIN="$case_dir/mount"
  export FAKE_CHATGPT_CURL_LOG="$case_dir/curl.log"
  export FAKE_CHATGPT_HDIUTIL_LOG="$case_dir/hdiutil.log"
  export FAKE_CHATGPT_DITTO_LOG="$case_dir/ditto.log"
  export FAKE_CHATGPT_SUDO_LOG="$case_dir/sudo.log"
  export FAKE_CHATGPT_RM_LOG="$case_dir/rm.log"
  export FAKE_CHATGPT_EVENT_LOG="$case_dir/events.log"
  export FAKE_CHATGPT_DETACH_STATE="$case_dir/detach.state"
  export FAKE_CHATGPT_RM_STATE="$case_dir/rm.state"
  export FAKE_CHATGPT_MOUNT_STATE="$case_dir/mount.state"
  export FAKE_TRUSTED_DIR_STATE="$case_dir/trusted-dir.state"
  export FAKE_MOUNT_CHECK_FAIL=0
  export FAKE_TRUSTED_PARENT_ATTACK=0
  activate_fake_privilege_runner "$case_dir/sudo"
}

prepare_chatgpt_bootstrap_case() {
  local case_dir="$1"

  mkdir -p "$case_dir/Applications" "$case_dir/stage" "$case_dir/dmg-source"
  create_chatgpt_app_fixture "$case_dir/dmg-source/ChatGPT.app"
  printf 'installed-from-official-dmg\n' \
    >"$case_dir/dmg-source/ChatGPT.app/Contents/Resources/bootstrap-marker"
  mkdir -p "$case_dir/mount-escape"
  /usr/bin/ditto \
    "$case_dir/dmg-source/ChatGPT.app" \
    "$case_dir/mount-escape/ChatGPT.app"
  create_chatgpt_bootstrap_stubs "$case_dir"
  export CC_SWITCH_INSTALLER_TEST_MODE=1
  export CC_SWITCH_INSTALLER_TEST_HOME="$case_dir/home"
  export CC_SWITCH_INSTALLER_TEST_APPLICATIONS_DIR="$case_dir/Applications"
  export FAKE_CHATGPT_DMG_SOURCE="$case_dir/dmg-source/ChatGPT.app"
  export FAKE_CHATGPT_MOUNT_ESCAPE="$case_dir/mount-escape"
  export FAKE_CHATGPT_BOOTSTRAP_MODE=success
  export FAKE_APP_TEAM_ID=2DC432GLL2
  export FAKE_APP_STRICT=pass
  export FAKE_TEMP_APP_STRICT=pass
  export FAKE_FINAL_APP_STRICT=pass
  export FAKE_FINAL_TARGET="$case_dir/Applications/ChatGPT.app"
  export FAKE_REQUIRE_PRIVILEGED_STAGING=0
  export FAKE_SIGNAL_AFTER_PUBLISH=0
  export FAKE_RACE_TARGET=''
  configure_install_paths
  NEEDS_SUDO=1
  ensure_test_rename_helper
  export FAKE_CHATGPT_RESOURCE_DIR="$case_dir/stage/resources/modelhub-installer"
  mkdir -p "$FAKE_CHATGPT_RESOURCE_DIR/helpers"
  cp "$TEST_RENAME_HELPER" "$FAKE_CHATGPT_RESOURCE_DIR/helpers/rename-exclusive"
  export CC_SWITCH_INSTALLER_TEST_RENAME_HELPER_SHA256="$(
    /usr/bin/shasum -a 256 "$FAKE_CHATGPT_RESOURCE_DIR/helpers/rename-exclusive" \
      | awk '{ print $1 }'
  )"
}

assert_chatgpt_bootstrap_scratch_clean() {
  local case_dir="$1"

  [[ -z "$(find "$case_dir/stage" -mindepth 1 -maxdepth 1 -type d -name 'chatgpt-mount.*' -print -quit)" ]] \
    || fail 'ChatGPT mount directory was not cleaned'
  [[ -z "$(find "$case_dir/Applications" -mindepth 1 -maxdepth 1 -type d -name '.chatgpt-modelhub.*' -print -quit)" ]] \
    || fail 'ChatGPT same-volume temporary directory was not cleaned'
  [[ -z "$(find "$case_dir/Applications" -mindepth 1 -maxdepth 1 -type d -name '.chatgpt-helper.*' -print -quit)" ]] \
    || fail 'trusted ChatGPT helper directory was not cleaned'
  if [[ -e "$case_dir/trusted-dir.state" ]]; then
    [[ ! -e "$(/bin/cat "$case_dir/trusted-dir.state")" ]] \
      || fail 'private var tmp trusted helper directory was not cleaned'
  fi
}

test_bootstraps_missing_chatgpt_from_official_dmg() {
  local case_dir="$TEST_TMP/chatgpt-bootstrap-success"
  local curl_count
  local attach_count
  prepare_chatgpt_bootstrap_case "$case_dir"

  ensure_chatgpt_app "$case_dir/stage" "$FAKE_CHATGPT_RESOURCE_DIR"

  [[ -d "$CHATGPT_APP_PATH" ]] || fail 'ChatGPT was not installed'
  assert_equals "$CHATGPT_INSTALLED_BY_RUN" '1'
  assert_contains "$CHATGPT_APP_PATH/Contents/Resources/bootstrap-marker" 'installed-from-official-dmg'
  assert_contains "$FAKE_CHATGPT_CURL_LOG" '--fail --location --silent --show-error --retry 3 --retry-all-errors'
  assert_contains "$FAKE_CHATGPT_CURL_LOG" "--output $case_dir/stage/ChatGPT.dmg $CHATGPT_DMG_URL"
  assert_occurrences "$FAKE_CHATGPT_CURL_LOG" "$CHATGPT_DMG_URL" 1
  assert_contains "$FAKE_CHATGPT_HDIUTIL_LOG" "attach -nobrowse -readonly -mountpoint $case_dir/stage/chatgpt-mount."
  assert_occurrences "$FAKE_CHATGPT_HDIUTIL_LOG" 'attach -nobrowse -readonly -mountpoint' 1
  assert_occurrences "$FAKE_CHATGPT_HDIUTIL_LOG" 'detach ' 1
  assert_contains "$FAKE_CHATGPT_DITTO_LOG" "/ChatGPT.app $case_dir/Applications/.chatgpt-modelhub."
  assert_contains "$FAKE_CHATGPT_SUDO_LOG" "/usr/bin/mktemp -d $case_dir/Applications/.chatgpt-modelhub.XXXXXX"
  assert_contains "$FAKE_CHATGPT_SUDO_LOG" "/usr/bin/mktemp -d /private/var/tmp/.cc-switch-modelhub-helper.XXXXXX"
  assert_contains "$FAKE_CHATGPT_SUDO_LOG" "/bin/cp $FAKE_CHATGPT_RESOURCE_DIR/helpers/rename-exclusive"
  assert_contains "$FAKE_CHATGPT_SUDO_LOG" "/bin/chmod 0500"
  assert_contains "$FAKE_CHATGPT_SUDO_LOG" "/usr/bin/shasum -a 256 /private/var/tmp/.cc-switch-modelhub-helper."
  assert_contains "$FAKE_CHATGPT_SUDO_LOG" "/private/var/tmp/.cc-switch-modelhub-helper."
  assert_equals "$(sed -n '1p' "$FAKE_CHATGPT_EVENT_LOG")" 'detach'
  assert_equals "$(sed -n '2p' "$FAKE_CHATGPT_EVENT_LOG")" 'publish'
  assert_chatgpt_bootstrap_scratch_clean "$case_dir"

  curl_count="$(wc -l <"$FAKE_CHATGPT_CURL_LOG" | tr -d ' ')"
  attach_count="$(grep -c '^attach ' "$FAKE_CHATGPT_HDIUTIL_LOG")"
  ensure_chatgpt_app "$case_dir/stage" "$FAKE_CHATGPT_RESOURCE_DIR"
  assert_equals "$(wc -l <"$FAKE_CHATGPT_CURL_LOG" | tr -d ' ')" "$curl_count"
  assert_equals "$(grep -c '^attach ' "$FAKE_CHATGPT_HDIUTIL_LOG")" "$attach_count"
}

test_bootstraps_missing_chatgpt_cleans_all_failure_paths() {
  local mode
  local case_dir
  local status

  for mode in download-fail attach-fail partial-attach-fail app-missing signature-fail temp-signature-fail mount-symlink source-symlink staging-symlink; do
    case_dir="$TEST_TMP/chatgpt-bootstrap-$mode"
    prepare_chatgpt_bootstrap_case "$case_dir"
    export FAKE_CHATGPT_BOOTSTRAP_MODE="$mode"
    if [[ "$mode" == "signature-fail" ]]; then
      export FAKE_APP_TEAM_ID=WRONGTEAM
    elif [[ "$mode" == "temp-signature-fail" ]]; then
      export FAKE_TEMP_APP_STRICT=fail
    fi

    set +e
    ensure_chatgpt_app "$case_dir/stage" "$FAKE_CHATGPT_RESOURCE_DIR" >/dev/null 2>&1
    status=$?
    set -e

    [[ "$status" -ne 0 ]] || fail "ChatGPT bootstrap unexpectedly succeeded for $mode"
    [[ ! -e "$CHATGPT_APP_PATH" ]] || fail "ChatGPT target exists after $mode"
    assert_chatgpt_bootstrap_scratch_clean "$case_dir"
    if [[ "$mode" == "download-fail" ]]; then
      [[ ! -e "$FAKE_CHATGPT_HDIUTIL_LOG" ]] || fail 'download failure unexpectedly invoked hdiutil'
    elif [[ "$mode" == "attach-fail" ]]; then
      assert_occurrences "$FAKE_CHATGPT_HDIUTIL_LOG" 'detach ' 0
    else
      assert_occurrences "$FAKE_CHATGPT_HDIUTIL_LOG" 'detach ' 1
    fi
  done
}

test_bootstraps_missing_chatgpt_rejects_final_target_race() {
  local case_dir="$TEST_TMP/chatgpt-bootstrap-race"
  local status
  prepare_chatgpt_bootstrap_case "$case_dir"
  export FAKE_RACE_TARGET="$CHATGPT_APP_PATH"

  set +e
  ensure_chatgpt_app "$case_dir/stage" "$FAKE_CHATGPT_RESOURCE_DIR" >/dev/null 2>&1
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail 'ChatGPT bootstrap overwrote a concurrent target'
  assert_contains "$CHATGPT_APP_PATH/owner" 'competitor'
  [[ ! -e "$CHATGPT_APP_PATH/Contents/Resources/bootstrap-marker" ]] \
    || fail 'concurrent ChatGPT target was overwritten'
  assert_chatgpt_bootstrap_scratch_clean "$case_dir"
}

test_chatgpt_bootstrap_cleanup_retries_detach_before_removing_mount() {
  local case_dir="$TEST_TMP/chatgpt-cleanup-detach-retry"
  local mount_dir
  local status
  prepare_chatgpt_bootstrap_case "$case_dir"
  mount_dir="$case_dir/stage/chatgpt-mount.retry"
  mkdir -p "$mount_dir"
  CHATGPT_BOOTSTRAP_STAGE_DIR="$case_dir/stage"
  CHATGPT_BOOTSTRAP_MOUNT_DIR="$mount_dir"
  CHATGPT_BOOTSTRAP_MOUNT_STATE='attached'
  CHATGPT_BOOTSTRAP_TEMP_DIR=''
  export FAKE_CHATGPT_BOOTSTRAP_MODE=detach-fail-once

  set +e
  cleanup_chatgpt_bootstrap >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail 'first detach cleanup unexpectedly succeeded'
  assert_equals "$CHATGPT_BOOTSTRAP_MOUNT_DIR" "$mount_dir"
  [[ -d "$mount_dir" ]] || fail 'failed detach removed a still-mounted path'
  [[ ! -e "$FAKE_CHATGPT_RM_LOG" ]] || fail 'failed detach invoked mount removal'

  cleanup_chatgpt_bootstrap
  assert_equals "$CHATGPT_BOOTSTRAP_MOUNT_DIR" ''
  [[ ! -e "$mount_dir" ]] || fail 'second cleanup did not remove detached mount directory'
  assert_occurrences "$FAKE_CHATGPT_HDIUTIL_LOG" 'detach ' 2
}

test_chatgpt_bootstrap_cleanup_preserves_pending_mount_when_inspection_fails() {
  local case_dir="$TEST_TMP/chatgpt-cleanup-mount-inspection"
  local mount_dir
  local status
  prepare_chatgpt_bootstrap_case "$case_dir"
  mount_dir="$case_dir/stage/chatgpt-mount.pending"
  mkdir -p "$mount_dir"
  CHATGPT_BOOTSTRAP_STAGE_DIR="$case_dir/stage"
  CHATGPT_BOOTSTRAP_MOUNT_DIR="$mount_dir"
  CHATGPT_BOOTSTRAP_MOUNT_STATE='pending'
  CHATGPT_BOOTSTRAP_TEMP_DIR=''
  export FAKE_MOUNT_CHECK_FAIL=1

  set +e
  cleanup_chatgpt_bootstrap >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail 'mount inspection failure unexpectedly cleaned the mount'
  assert_equals "$CHATGPT_BOOTSTRAP_MOUNT_STATE" 'pending'
  assert_equals "$CHATGPT_BOOTSTRAP_MOUNT_DIR" "$mount_dir"
  [[ -d "$mount_dir" ]] || fail 'mount inspection failure removed an unknown mount path'
  [[ ! -e "$FAKE_CHATGPT_RM_LOG" ]] || fail 'mount inspection failure invoked rm'

  export FAKE_MOUNT_CHECK_FAIL=0
  cleanup_chatgpt_bootstrap
  assert_equals "$CHATGPT_BOOTSTRAP_MOUNT_DIR" ''
  [[ ! -e "$mount_dir" ]] || fail 'retry did not clean the inactive mount directory'
}

test_chatgpt_bootstrap_cleanup_retries_mount_and_temp_removal() {
  local mount_case="$TEST_TMP/chatgpt-cleanup-mount-rm-retry"
  local temp_case="$TEST_TMP/chatgpt-cleanup-temp-rm-retry"
  local mount_dir
  local temp_dir
  local status

  prepare_chatgpt_bootstrap_case "$mount_case"
  mount_dir="$mount_case/stage/chatgpt-mount.retry"
  mkdir -p "$mount_dir"
  CHATGPT_BOOTSTRAP_STAGE_DIR="$mount_case/stage"
  CHATGPT_BOOTSTRAP_MOUNT_DIR="$mount_dir"
  CHATGPT_BOOTSTRAP_MOUNT_STATE='attached'
  CHATGPT_BOOTSTRAP_TEMP_DIR=''
  export FAKE_CHATGPT_BOOTSTRAP_MODE=rm-fail-once
  set +e
  cleanup_chatgpt_bootstrap >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail 'first mount removal unexpectedly succeeded'
  assert_equals "$CHATGPT_BOOTSTRAP_MOUNT_DIR" "$mount_dir"
  assert_equals "$CHATGPT_BOOTSTRAP_MOUNT_STATE" 'detached'
  [[ -d "$mount_dir" ]] || fail 'failed mount removal lost retry state'
  cleanup_chatgpt_bootstrap
  assert_equals "$CHATGPT_BOOTSTRAP_MOUNT_DIR" ''
  assert_occurrences "$FAKE_CHATGPT_HDIUTIL_LOG" 'detach ' 1

  prepare_chatgpt_bootstrap_case "$temp_case"
  temp_dir="$temp_case/Applications/.chatgpt-modelhub.retry"
  mkdir -p "$temp_dir"
  CHATGPT_BOOTSTRAP_STAGE_DIR="$temp_case/stage"
  CHATGPT_BOOTSTRAP_MOUNT_DIR=''
  CHATGPT_BOOTSTRAP_MOUNT_STATE='none'
  CHATGPT_BOOTSTRAP_TEMP_DIR="$temp_dir"
  export FAKE_CHATGPT_BOOTSTRAP_MODE=rm-fail-once
  set +e
  cleanup_chatgpt_bootstrap >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail 'first temp removal unexpectedly succeeded'
  assert_equals "$CHATGPT_BOOTSTRAP_TEMP_DIR" "$temp_dir"
  [[ -d "$temp_dir" ]] || fail 'failed temp removal lost retry state'
  cleanup_chatgpt_bootstrap
  assert_equals "$CHATGPT_BOOTSTRAP_TEMP_DIR" ''
  [[ ! -e "$temp_dir" ]] || fail 'second cleanup did not remove temp directory'
}

test_chatgpt_bootstrap_detach_failure_prevents_publication() {
  local case_dir="$TEST_TMP/chatgpt-detach-before-publish"
  local status
  prepare_chatgpt_bootstrap_case "$case_dir"
  export FAKE_CHATGPT_BOOTSTRAP_MODE=detach-fail-always

  set +e
  ensure_chatgpt_app "$case_dir/stage" "$FAKE_CHATGPT_RESOURCE_DIR" >/dev/null 2>&1
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail 'bootstrap accepted a failed DMG detach'
  [[ ! -e "$CHATGPT_APP_PATH" ]] || fail 'ChatGPT was published before successful DMG detach'
  assert_not_contains "$FAKE_CHATGPT_EVENT_LOG" 'publish'
  export FAKE_CHATGPT_BOOTSTRAP_MODE=success
  cleanup_chatgpt_bootstrap
}

test_chatgpt_bootstrap_final_validation_failure_preserves_target_and_fails() {
  local case_dir="$TEST_TMP/chatgpt-final-validation-failure"
  local output
  local status
  prepare_chatgpt_bootstrap_case "$case_dir"
  export FAKE_FINAL_APP_STRICT=fail

  set +e
  output="$(ensure_chatgpt_app "$case_dir/stage" "$FAKE_CHATGPT_RESOURCE_DIR" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail 'bootstrap accepted a final ChatGPT signature failure'
  [[ "$output" == *'official OpenAI download page'* ]] \
    || fail "final ChatGPT validation failure omitted recovery guidance: $output"
  [[ -d "$CHATGPT_APP_PATH" ]] || fail 'final validation failure removed the committed ChatGPT target'
  assert_contains "$CHATGPT_APP_PATH/Contents/Resources/bootstrap-marker" 'installed-from-official-dmg'
  assert_chatgpt_bootstrap_scratch_clean "$case_dir"
}

test_chatgpt_bootstrap_rejects_modified_resigned_helper_by_pinned_hash() {
  local case_dir="$TEST_TMP/chatgpt-resigned-helper"
  local helper_path
  local modified_source="$case_dir/modified-rename-exclusive.c"
  local status
  prepare_chatgpt_bootstrap_case "$case_dir"
  helper_path="$FAKE_CHATGPT_RESOURCE_DIR/helpers/rename-exclusive"
  sed 's/destination already exists/destination collision/' \
    "$RENAME_HELPER_SOURCE" >"$modified_source"
  /usr/bin/xcrun clang \
    -arch arm64 -mmacosx-version-min=12.0 \
    -Os -Wall -Wextra -Werror \
    -o "$helper_path" "$modified_source"
  /usr/bin/codesign \
    --force --sign - --timestamp=none \
    --identifier com.ccswitch.modelhub.rename-exclusive \
    "$helper_path" >/dev/null

  set +e
  ensure_chatgpt_app "$case_dir/stage" "$FAKE_CHATGPT_RESOURCE_DIR" >/dev/null 2>&1
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail 'bootstrap accepted a modified re-signed helper'
  [[ ! -e "$FAKE_CHATGPT_CURL_LOG" ]] || fail 'modified helper was rejected only after download'
  assert_not_contains "$FAKE_CHATGPT_EVENT_LOG" 'publish'
  [[ ! -e "$CHATGPT_APP_PATH" ]] || fail 'modified helper installed ChatGPT'
}

test_chatgpt_bootstrap_rejects_tampered_trusted_copy_before_exec() {
  local case_dir="$TEST_TMP/chatgpt-tampered-trusted-copy"
  local status
  prepare_chatgpt_bootstrap_case "$case_dir"
  export FAKE_CHATGPT_BOOTSTRAP_MODE=trusted-copy-tamper

  set +e
  ensure_chatgpt_app "$case_dir/stage" "$FAKE_CHATGPT_RESOURCE_DIR" >/dev/null 2>&1
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail 'bootstrap executed a tampered trusted helper copy'
  assert_not_contains "$FAKE_CHATGPT_EVENT_LOG" 'publish'
  [[ ! -e "$CHATGPT_APP_PATH" ]] || fail 'tampered trusted helper installed ChatGPT'
  assert_chatgpt_bootstrap_scratch_clean "$case_dir"
}

test_chatgpt_bootstrap_trusted_parent_blocks_post_hash_replacement() {
  local case_dir="$TEST_TMP/chatgpt-trusted-parent-attack"
  local trusted_dir
  local attack_line
  local publish_line
  prepare_chatgpt_bootstrap_case "$case_dir"
  export FAKE_TRUSTED_PARENT_ATTACK=1

  assert_equals "$(/usr/bin/stat -f %u /private/var/tmp)" '0'
  [[ "$(/usr/bin/stat -f %Sp /private/var/tmp)" == *t ]] \
    || fail '/private/var/tmp is not sticky'
  ensure_chatgpt_app "$case_dir/stage" "$FAKE_CHATGPT_RESOURCE_DIR"

  trusted_dir="$(/bin/cat "$FAKE_TRUSTED_DIR_STATE")"
  [[ "$trusted_dir" == /private/var/tmp/.cc-switch-modelhub-helper.* ]] \
    || fail "trusted helper used an unsafe parent: $trusted_dir"
  assert_contains "$FAKE_CHATGPT_EVENT_LOG" 'attack-attempt'
  assert_contains "$FAKE_CHATGPT_EVENT_LOG" 'attack-blocked'
  assert_not_contains "$FAKE_CHATGPT_EVENT_LOG" 'attacker-executed'
  assert_contains "$CHATGPT_APP_PATH/Contents/Resources/bootstrap-marker" 'installed-from-official-dmg'
  attack_line="$(grep -n '^attack-blocked$' "$FAKE_CHATGPT_EVENT_LOG" | cut -d: -f1)"
  publish_line="$(grep -n '^publish$' "$FAKE_CHATGPT_EVENT_LOG" | cut -d: -f1)"
  [[ "$attack_line" -lt "$publish_line" ]] || fail 'attack hook did not run before helper execution'
  assert_chatgpt_bootstrap_scratch_clean "$case_dir"
}

test_chatgpt_bootstrap_requires_root_sticky_trusted_parent() {
  validate_trusted_helper_parent
  assert_equals "$(/usr/bin/stat -f %u /private/var/tmp)" '0'
  [[ "$(/usr/bin/stat -f %Sp /private/var/tmp)" == *t ]] \
    || fail '/private/var/tmp is not sticky'
}

test_production_mode_ignores_privileged_tool_overrides() {
  local case_dir="$TEST_TMP/production-tool-overrides"
  local malicious="$case_dir/malicious"
  mkdir -p "$case_dir"
  write_executable_stub "$malicious" 'exit 99'
  export CC_SWITCH_INSTALLER_TEST_MODE=0
  export CC_SWITCH_SUDO_BIN="$malicious"
  export CC_SWITCH_CODESIGN_BIN="$malicious"
  export CC_SWITCH_PLUTIL_BIN="$malicious"
  export CC_SWITCH_FILE_BIN="$malicious"
  export CC_SWITCH_DITTO_BIN="$malicious"
  export CC_SWITCH_RM_BIN="$malicious"
  export CC_SWITCH_XATTR_BIN="$malicious"
  export CC_SWITCH_HELPER_CODESIGN_BIN="$malicious"
  export CC_SWITCH_LIPO_BIN="$malicious"
  export CC_SWITCH_MOUNT_BIN="$malicious"

  assert_equals "$(sudo_command)" '/usr/bin/sudo'
  assert_equals "$(installer_tool_path CC_SWITCH_CODESIGN_BIN /usr/bin/codesign)" '/usr/bin/codesign'
  assert_equals "$(installer_tool_path CC_SWITCH_PLUTIL_BIN /usr/bin/plutil)" '/usr/bin/plutil'
  assert_equals "$(installer_tool_path CC_SWITCH_FILE_BIN /usr/bin/file)" '/usr/bin/file'
  assert_equals "$(installer_tool_path CC_SWITCH_DITTO_BIN /usr/bin/ditto)" '/usr/bin/ditto'
  assert_equals "$(installer_tool_path CC_SWITCH_RM_BIN /bin/rm)" '/bin/rm'
  assert_equals "$(installer_tool_path CC_SWITCH_XATTR_BIN /usr/bin/xattr)" '/usr/bin/xattr'
  assert_equals "$(installer_tool_path CC_SWITCH_HELPER_CODESIGN_BIN /usr/bin/codesign)" '/usr/bin/codesign'
  assert_equals "$(installer_tool_path CC_SWITCH_LIPO_BIN /usr/bin/lipo)" '/usr/bin/lipo'
  assert_equals "$(installer_tool_path CC_SWITCH_MOUNT_BIN /sbin/mount)" '/sbin/mount'
}

test_real_sudo_rejects_non_allowlisted_privileged_commands() {
  local case_dir="$TEST_TMP/privileged-command-allowlist"
  local malicious="$case_dir/malicious"
  local malicious_log="$case_dir/malicious.log"
  local sudo_symlink="$case_dir/system-sudo"
  mkdir -p "$case_dir"
  write_executable_stub "$malicious" ': >"$MALICIOUS_LOG"' 'exit 0'
  ln -s /usr/bin/sudo "$sudo_symlink"
  export CC_SWITCH_INSTALLER_TEST_MODE=1
  export CC_SWITCH_SUDO_BIN="$sudo_symlink"
  export MALICIOUS_LOG="$malicious_log"
  NEEDS_SUDO=1

  assert_equals "$(sudo_command)" '/usr/bin/sudo'
  validate_privileged_command /usr/bin/ditto
  validate_privileged_command /usr/bin/codesign
  validate_privileged_command /bin/rm
  assert_command_fails validate_privileged_command "$malicious"
  assert_command_fails run_with_privilege "$malicious"
  [[ ! -e "$malicious_log" ]] || fail 'test sudo override executed a non-allowlisted command'
}

test_chatgpt_bootstrap_validates_root_owned_staging_through_privilege() {
  local case_dir="$TEST_TMP/chatgpt-root-owned-staging"
  prepare_chatgpt_bootstrap_case "$case_dir"
  export FAKE_REQUIRE_PRIVILEGED_STAGING=1

  ensure_chatgpt_app "$case_dir/stage" "$FAKE_CHATGPT_RESOURCE_DIR"

  [[ -d "$CHATGPT_APP_PATH" ]] || fail 'privileged staging validation did not install ChatGPT'
  assert_contains "$FAKE_CHATGPT_SUDO_LOG" "$case_dir/plutil -extract"
  assert_contains "$FAKE_CHATGPT_SUDO_LOG" "$case_dir/codesign --verify --deep --strict"
  assert_contains "$FAKE_CHATGPT_SUDO_LOG" "$case_dir/file -b"
}

test_chatgpt_bootstrap_rejects_unverified_packaged_helper_before_download() {
  local case_dir="$TEST_TMP/chatgpt-unverified-helper"
  local corrupt_helper
  local status
  prepare_chatgpt_bootstrap_case "$case_dir"
  corrupt_helper="$FAKE_CHATGPT_RESOURCE_DIR/helpers/rename-exclusive"
  printf 'tamper\n' >>"$corrupt_helper"

  set +e
  ensure_chatgpt_app "$case_dir/stage" "$FAKE_CHATGPT_RESOURCE_DIR" >/dev/null 2>&1
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail 'bootstrap accepted an unverified rename helper'
  [[ ! -e "$FAKE_CHATGPT_CURL_LOG" ]] || fail 'unverified helper was rejected only after download'
  [[ ! -e "$CHATGPT_APP_PATH" ]] || fail 'unverified helper installed ChatGPT'
}

test_chatgpt_bootstrap_rejects_signed_helper_outside_verified_resource_root() {
  local case_dir="$TEST_TMP/chatgpt-outside-helper"
  local outside_helper="$case_dir/outside-rename-exclusive"
  local status
  prepare_chatgpt_bootstrap_case "$case_dir"
  cp "$TEST_RENAME_HELPER" "$outside_helper"

  set +e
  ensure_chatgpt_app "$case_dir/stage" "$outside_helper" >/dev/null 2>&1
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail 'bootstrap accepted a signed helper outside verified resources'
  [[ ! -e "$FAKE_CHATGPT_CURL_LOG" ]] || fail 'outside helper was rejected only after download'
  [[ ! -e "$CHATGPT_APP_PATH" ]] || fail 'outside helper installed ChatGPT'
}

test_chatgpt_bootstrap_signal_after_commit_preserves_prevalidated_target() {
  local case_dir="$TEST_TMP/chatgpt-signal-after-publish"
  local status
  prepare_chatgpt_bootstrap_case "$case_dir"
  export FAKE_SIGNAL_AFTER_PUBLISH=1

  set +e
  (
    trap 'cleanup_chatgpt_bootstrap; exit 143' TERM
    ensure_chatgpt_app "$case_dir/stage" "$FAKE_CHATGPT_RESOURCE_DIR"
  ) >/dev/null 2>&1
  status=$?
  set -e

  assert_equals "$status" '143'
  [[ -d "$CHATGPT_APP_PATH" ]] || fail 'signal after commit removed the prevalidated ChatGPT target'
  assert_contains "$CHATGPT_APP_PATH/Contents/Resources/bootstrap-marker" 'installed-from-official-dmg'
  assert_chatgpt_bootstrap_scratch_clean "$case_dir"
}

create_expected_resource_tree() {
  local root="$1/modelhub-installer"
  mkdir -p "$root/assets" "$root/golden" "$root/helpers" "$root/templates"
  ensure_test_rename_helper
  : >"$root/assets/models-modelhub-1m.json"
  cp "$GOLDEN_CODEX_CONFIG" "$root/golden/codex-config.toml"
  cp "$GOLDEN_SETTINGS" "$root/golden/settings.json"
  /bin/bash "$GOLDEN_DB_BUILDER" \
    --schema "$GOLDEN_DB_SCHEMA" \
    --provider-config "$GOLDEN_CODEX_CONFIG" \
    --provider-meta "$META_TEMPLATE" \
    --output "$root/golden/cc-switch.db" >/dev/null
  cp "$TEST_RENAME_HELPER" "$root/helpers/rename-exclusive"
  : >"$root/templates/modelhub-provider.toml"
  : >"$root/templates/modelhub-provider-meta.json"
  : >"$root/templates/com.ccswitch.modelhub-env.plist"
  : >"$root/templates/load-modelhub-env.sh"
}

test_preflight_verifies_all_release_checksums() {
  local case_dir="$TEST_TMP/preflight-checksums"
  mkdir -p "$case_dir"
  printf 'installer\n' >"$case_dir/install.sh"
  printf 'app\n' >"$case_dir/CC-Switch-ModelHub-3.19.1-arm64.app.zip"
  printf 'resources\n' >"$case_dir/modelhub-installer-resources.tar.gz"
  (
    cd "$case_dir"
    shasum -a 256 \
      install.sh \
      CC-Switch-ModelHub-3.19.1-arm64.app.zip \
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
  printf 'app\n' >"$case_dir/CC-Switch-ModelHub-3.19.1-arm64.app.zip"
  printf 'resources\n' >"$case_dir/modelhub-installer-resources.tar.gz"
  printf 'extra\n' >"$case_dir/not-allowed.txt"
  (
    cd "$case_dir"
    shasum -a 256 \
      install.sh \
      CC-Switch-ModelHub-3.19.1-arm64.app.zip \
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
  printf 'app\n' >"$remote_dir/CC-Switch-ModelHub-3.19.1-arm64.app.zip"
  printf 'resources\n' >"$remote_dir/modelhub-installer-resources.tar.gz"
  printf 'checksums\n' >"$remote_dir/SHA256SUMS.txt"
  assert_equals "$RELEASE_TAG" 'modelhub-installer-20260803-r6'
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
    '[[ "$url" == *"/releases/download/modelhub-installer-20260803-r6/"* ]]' \
    'cp "$FAKE_RELEASE_DIR/${url##*/}" "$output"' \
    >"$curl_stub"
  chmod +x "$curl_stub"

  FAKE_RELEASE_DIR="$remote_dir" CC_SWITCH_CURL_BIN="$curl_stub" \
    download_release_assets "$output_dir"

  assert_contains "$output_dir/install.sh" 'installer'
  assert_contains "$output_dir/CC-Switch-ModelHub-3.19.1-arm64.app.zip" 'app'
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
  export FAKE_SUDO_LOG="$case_dir/sudo.log"
  export FAKE_SUDO_APP_PATH="$applications_dir/CC Switch.app"
  activate_fake_privilege_runner "$sudo_bin"
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

test_existing_nontraversable_app_requires_privilege() {
  local case_dir="$TEST_TMP/existing-nontraversable-app"
  local applications_dir="$case_dir/Applications"
  local sudo_bin="$case_dir/fake-sudo"
  mkdir -p "$applications_dir/CC Switch.app/Contents"
  chmod 0775 "$applications_dir"
  chmod 0666 "$applications_dir/CC Switch.app"
  write_executable_stub "$sudo_bin" \
    'printf "%s\n" "$*" >>"$FAKE_SUDO_LOG"' \
    '[[ "${1:-}" == "-v" ]]'
  export CC_SWITCH_INSTALLER_TEST_MODE=1
  export CC_SWITCH_INSTALLER_TEST_HOME="$case_dir/home"
  export CC_SWITCH_INSTALLER_TEST_APPLICATIONS_DIR="$applications_dir"
  export FAKE_SUDO_LOG="$case_dir/sudo.log"
  activate_fake_privilege_runner "$sudo_bin"
  configure_install_paths

  prepare_application_permissions
  chmod 0775 "$applications_dir/CC Switch.app"

  assert_equals "$NEEDS_SUDO" '1'
  assert_contains "$FAKE_SUDO_LOG" '-v'
}

test_rejects_root_execution_validation_contract() {
  assert_command_fails validate_non_root 0
  validate_non_root 501
  export CC_SWITCH_INSTALLER_TEST_MODE=1
  assert_command_fails validate_execution_identity 0 501
  assert_command_fails validate_execution_identity 501 0
  validate_execution_identity 501 501
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
    '    /bin/cat "$FAKE_KEYCHAIN_STATE"' \
    '    ;;' \
    '  add-generic-password)' \
    '    [[ "${FAKE_SECURITY_MODE:-success}" != "cancel" ]] || exit 1' \
    '    modelhub_ak=""' \
    '    password_value_count=0' \
    '    shift' \
    '    while [[ $# -gt 0 ]]; do' \
    '      if [[ "$1" == "-w" ]]; then' \
    '        [[ $# -gt 1 ]] || exit 64' \
    '        modelhub_ak="$2"' \
    '        password_value_count=$((password_value_count + 1))' \
    '        shift 2' \
    '      else' \
    '        shift' \
    '      fi' \
    '    done' \
    '    [[ "$password_value_count" == "1" ]] || exit 64' \
    '    printf "%s" "$modelhub_ak" >"$FAKE_KEYCHAIN_STATE"' \
    '    if [[ "${FAKE_SECURITY_MODE:-success}" == "write-then-fail" && ! -e "$FAKE_SECURITY_WRITE_THEN_FAIL_STATE" ]]; then' \
    '      : >"$FAKE_SECURITY_WRITE_THEN_FAIL_STATE"' \
    '      exit 70' \
    '    fi' \
    '    ;;' \
    '  delete-generic-password)' \
    '    rm -f "$FAKE_KEYCHAIN_STATE"' \
    '    ;;' \
    'esac'
  write_executable_stub "$stub_dir/launchctl" \
    'mkdir -p "$FAKE_LAUNCHCTL_STATE_DIR"' \
    'case "${1:-}" in' \
    '  setenv) printf "%s" "$3" >"$FAKE_LAUNCHCTL_STATE_DIR/env-$2" ;;' \
    '  getenv)' \
    '    if [[ -n "${FAKE_LAUNCHCTL_GETENV_STATUS:-}" ]]; then exit "$FAKE_LAUNCHCTL_GETENV_STATUS"; fi' \
    '    [[ -f "$FAKE_LAUNCHCTL_STATE_DIR/env-$2" ]] || exit 1' \
    '    /bin/cat "$FAKE_LAUNCHCTL_STATE_DIR/env-$2"' \
    '    ;;' \
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
  write_executable_stub "$stub_dir/sleep" \
    'if [[ -n "${FAKE_ROUTING_REWRITE_AK:-}" && ! -e "$FAKE_ROUTING_REWRITE_STATE" ]]; then' \
    '  /usr/bin/sqlite3 "$FAKE_PROVIDER_DATABASE_PATH" "UPDATE providers SET settings_config=json_set(settings_config, '\''$.auth'\'', json_object('\''OPENAI_API_KEY'\'', '\''$FAKE_ROUTING_REWRITE_AK'\'')) WHERE id='\''bytedance-modelhub-official-cli'\'' AND app_type='\''codex'\'';"' \
    '  if [[ "${FAKE_ROUTING_REWRITE_ALL:-0}" == "1" ]]; then' \
    '    printf "%s" "$FAKE_ROUTING_REWRITE_AK" >"$FAKE_KEYCHAIN_STATE"' \
    '    printf "%s" "$FAKE_ROUTING_REWRITE_AK" >"$FAKE_LAUNCHCTL_STATE_DIR/env-MODELHUB_AK"' \
    '  fi' \
    '  /usr/bin/sed '''s#https://aidp.bytedance.net/api/modelhub/online#http://127.0.0.1:15721/v1#g''' "$FAKE_LIVE_CONFIG_PATH" >"$FAKE_LIVE_CONFIG_PATH.next"' \
    '  /bin/mv "$FAKE_LIVE_CONFIG_PATH.next" "$FAKE_LIVE_CONFIG_PATH"' \
    '  : >"$FAKE_ROUTING_REWRITE_STATE"' \
    'fi' \
    'exit 0'
  write_executable_stub "$stub_dir/curl" \
    'if [[ "${FAKE_HEALTH_MODE:-healthy}" == "healthy" ]]; then' \
    '  if [[ -z "${FAKE_ROUTING_REWRITE_AK:-}" && -n "${FAKE_LIVE_CONFIG_PATH:-}" && -f "$FAKE_LIVE_CONFIG_PATH" ]]; then' \
    '    /usr/bin/sed '''s#https://aidp.bytedance.net/api/modelhub/online#http://127.0.0.1:15721/v1#g''' "$FAKE_LIVE_CONFIG_PATH" >"$FAKE_LIVE_CONFIG_PATH.next"' \
    '    /bin/mv "$FAKE_LIVE_CONFIG_PATH.next" "$FAKE_LIVE_CONFIG_PATH"' \
    '  fi' \
    '  if [[ -n "${FAKE_PROVIDER_REWRITE_AK:-}" ]]; then' \
    '    /usr/bin/sqlite3 "$FAKE_PROVIDER_DATABASE_PATH" "UPDATE providers SET settings_config=json_set(settings_config, '\''$.auth'\'', json_object('\''OPENAI_API_KEY'\'', '\''$FAKE_PROVIDER_REWRITE_AK'\'')) WHERE id='\''bytedance-modelhub-official-cli'\'' AND app_type='\''codex'\'';"' \
    '  fi' \
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
  COPYFILE_DISABLE=1 /usr/bin/ditto -c -k --keepParent "$app_dir" "$case_dir/assets/CC-Switch-ModelHub-3.19.1-arm64.app.zip"
}

create_transaction_assets() {
  local case_dir="$1"
  local asset_dir="$case_dir/assets"
  local resource_root="$case_dir/resource-build/modelhub-installer"
  mkdir -p \
    "$asset_dir" \
    "$resource_root/assets" \
    "$resource_root/golden" \
    "$resource_root/helpers" \
    "$resource_root/templates"
  ensure_test_rename_helper
  cp "$INSTALLER" "$asset_dir/install.sh"
  create_fake_app_zip "$case_dir"
  printf '{"models":{}}\n' >"$resource_root/assets/models-modelhub-1m.json"
  cp "$GOLDEN_CODEX_CONFIG" "$resource_root/golden/codex-config.toml"
  cp "$GOLDEN_SETTINGS" "$resource_root/golden/settings.json"
  /bin/bash "$GOLDEN_DB_BUILDER" \
    --schema "$GOLDEN_DB_SCHEMA" \
    --provider-config "$GOLDEN_CODEX_CONFIG" \
    --provider-meta "$META_TEMPLATE" \
    --output "$resource_root/golden/cc-switch.db" >/dev/null
  cp "$TEST_RENAME_HELPER" "$resource_root/helpers/rename-exclusive"
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
      CC-Switch-ModelHub-3.19.1-arm64.app.zip \
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
  export CC_SWITCH_INSTALLER_TEST_MODELHUB_AK='test-modelhub-ak-r5'
  export FAKE_KEYCHAIN_STATE="$case_dir/keychain-state"
  export FAKE_SECURITY_LOG="$case_dir/security.log"
  export FAKE_LAUNCHCTL_STATE_DIR="$case_dir/launchctl-state"
  export FAKE_PGREP_LOG="$case_dir/pgrep.log"
  export FAKE_PGREP_ONCE_STATE="$case_dir/pgrep-once-state"
  export FAKE_SECURITY_MODE=success
  export FAKE_SECURITY_WRITE_THEN_FAIL_STATE="$case_dir/security-write-then-fail-state"
  export FAKE_SECURITY_FIND_STATUS=''
  export FAKE_HEALTH_MODE=healthy
  export FAKE_PROVIDER_DATABASE_PATH="$case_dir/home/.cc-switch/cc-switch.db"
  export FAKE_PROVIDER_REWRITE_AK=''
  export FAKE_ROUTING_REWRITE_AK=''
  export FAKE_ROUTING_REWRITE_ALL=0
  export FAKE_ROUTING_REWRITE_STATE="$case_dir/routing-rewrite-state"
  export FAKE_LIVE_CONFIG_PATH="$case_dir/home/.codex/config.toml"
  export CC_SWITCH_INSTALLER_ROUTING_TIMEOUT=1
  export FAKE_COMPLETION_MARKER_DIR=''
  export FAKE_LAUNCHCTL_SIGNAL_TERM=0
  export FAKE_LAUNCHCTL_GETENV_STATUS=''
  export FAKE_PGREP_MODE=stopped
}

prepare_missing_chatgpt_transaction_case() {
  local case_dir="$1"

  prepare_transaction_case "$case_dir"
  rm -rf "$case_dir/Applications/ChatGPT.app"
  mkdir -p "$case_dir/dmg-source"
  create_chatgpt_app_fixture "$case_dir/dmg-source/ChatGPT.app"
  printf 'installed-from-official-dmg\n' \
    >"$case_dir/dmg-source/ChatGPT.app/Contents/Resources/bootstrap-marker"
  create_chatgpt_bootstrap_stubs "$case_dir"
  export CC_SWITCH_PLUTIL_BIN="$case_dir/stubs/plutil"
  export CC_SWITCH_CODESIGN_BIN="$case_dir/stubs/codesign"
  export CC_SWITCH_FILE_BIN="$case_dir/stubs/file"
  export FAKE_CHATGPT_DMG_SOURCE="$case_dir/dmg-source/ChatGPT.app"
  export FAKE_CHATGPT_BOOTSTRAP_MODE=success
  export FAKE_APP_TEAM_ID=2DC432GLL2
  export FAKE_APP_STRICT=pass
  export FAKE_TEMP_APP_STRICT=pass
  export FAKE_RACE_TARGET=''
  export CC_SWITCH_INSTALLER_TEST_RENAME_HELPER_SHA256="$(
    /usr/bin/shasum -a 256 "$TEST_RENAME_HELPER" | awk '{ print $1 }'
  )"
}

test_keeps_bootstrapped_chatgpt_after_failure_and_explicit_rollback() {
  local failed_case_dir="$TEST_TMP/chatgpt-bootstrap-transaction-failure"
  local rollback_case_dir="$TEST_TMP/chatgpt-bootstrap-explicit-rollback"

  mkdir -p "$failed_case_dir"
  prepare_missing_chatgpt_transaction_case "$failed_case_dir"
  export FAKE_HEALTH_MODE=unhealthy
  assert_command_fails perform_install
  assert_contains \
    "$failed_case_dir/Applications/ChatGPT.app/Contents/Resources/bootstrap-marker" \
    'installed-from-official-dmg'

  mkdir -p "$rollback_case_dir"
  prepare_missing_chatgpt_transaction_case "$rollback_case_dir"
  export FAKE_HEALTH_MODE=healthy
  perform_install
  assert_contains \
    "$rollback_case_dir/Applications/ChatGPT.app/Contents/Resources/bootstrap-marker" \
    'installed-from-official-dmg'
  rollback_latest
  assert_contains \
    "$rollback_case_dir/Applications/ChatGPT.app/Contents/Resources/bootstrap-marker" \
    'installed-from-official-dmg'
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
  assert_contains "$case_dir/home/.codex/config.toml" 'approval_policy = "never"'
  assert_not_contains "$case_dir/home/.codex/config.toml" '[plugins."browser@openai-bundled"]'
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

test_transaction_synchronizes_modelhub_ak() {
  local case_dir="$TEST_TMP/transaction-modelhub-ak-sync"
  local database
  local provider_ak
  local launchd_ak
  mkdir -p "$case_dir"
  prepare_transaction_case "$case_dir"
  database="$case_dir/home/.cc-switch/cc-switch.db"

  perform_install

  assert_equals "$(/bin/cat "$FAKE_KEYCHAIN_STATE")" 'test-modelhub-ak-r5'
  provider_ak="$(sqlite3 "$database" \
    "SELECT json_extract(settings_config, '$.auth.OPENAI_API_KEY') FROM providers WHERE id='bytedance-modelhub-official-cli' AND app_type='codex';")"
  assert_equals "$provider_ak" 'test-modelhub-ak-r5'
  launchd_ak="$("$CC_SWITCH_LAUNCHCTL_BIN" getenv MODELHUB_AK)"
  assert_equals "$launchd_ak" 'test-modelhub-ak-r5'
}

test_transaction_detects_startup_modelhub_ak_drift_and_rolls_back() {
  local case_dir="$TEST_TMP/transaction-modelhub-ak-drift"
  local before
  local after
  mkdir -p "$case_dir"
  prepare_transaction_case "$case_dir"
  before="$(managed_state_digest "$case_dir")"
  export FAKE_PROVIDER_REWRITE_AK='old-modelhub-ak'

  assert_command_fails perform_install

  after="$(managed_state_digest "$case_dir")"
  assert_equals "$after" "$before"
  [[ ! -e "$FAKE_KEYCHAIN_STATE" ]] || fail 'credential drift rollback left a new keychain item'
  [[ ! -e "$FAKE_LAUNCHCTL_STATE_DIR/env-MODELHUB_AK" ]] \
    || fail 'credential drift rollback left MODELHUB_AK in launchd'
}

test_transaction_detects_routing_stage_modelhub_ak_drift_and_rolls_back() {
  local case_dir="$TEST_TMP/transaction-modelhub-ak-routing-drift"
  local before
  local after
  mkdir -p "$case_dir"
  prepare_transaction_case "$case_dir"
  before="$(managed_state_digest "$case_dir")"
  export CC_SWITCH_INSTALLER_ROUTING_TIMEOUT=2
  export FAKE_ROUTING_REWRITE_AK='old-modelhub-ak'

  assert_command_fails perform_install

  after="$(managed_state_digest "$case_dir")"
  assert_equals "$after" "$before"
  [[ ! -e "$FAKE_KEYCHAIN_STATE" ]] || fail 'routing drift rollback left a new keychain item'
  [[ ! -e "$FAKE_LAUNCHCTL_STATE_DIR/env-MODELHUB_AK" ]] \
    || fail 'routing drift rollback left MODELHUB_AK in launchd'
}

test_transaction_restores_existing_modelhub_credential_state_after_failure() {
  local case_dir="$TEST_TMP/transaction-existing-modelhub-credential-rollback"
  local before
  local after
  mkdir -p "$case_dir"
  prepare_transaction_case "$case_dir"
  /bin/mkdir -p "$FAKE_LAUNCHCTL_STATE_DIR"
  printf '%s' 'existing-modelhub-ak-r5' >"$FAKE_KEYCHAIN_STATE"
  printf '%s' 'existing-modelhub-ak-r5' >"$FAKE_LAUNCHCTL_STATE_DIR/env-MODELHUB_AK"
  before="$(managed_state_digest "$case_dir")"
  export FAKE_HEALTH_MODE=timeout

  assert_command_fails perform_install

  after="$(managed_state_digest "$case_dir")"
  assert_equals "$after" "$before"
  assert_equals "$(/bin/cat "$FAKE_KEYCHAIN_STATE")" 'existing-modelhub-ak-r5'
  assert_equals \
    "$("$CC_SWITCH_LAUNCHCTL_BIN" getenv MODELHUB_AK)" \
    'existing-modelhub-ak-r5'
}

test_transaction_launchd_snapshot_error_preserves_existing_state() {
  local case_dir="$TEST_TMP/transaction-launchd-snapshot-error"
  local database
  local before
  local after
  mkdir -p "$case_dir"
  prepare_transaction_case "$case_dir"
  database="$case_dir/home/.cc-switch/cc-switch.db"
  /bin/mkdir -p "$FAKE_LAUNCHCTL_STATE_DIR"
  printf '%s' 'existing-modelhub-ak-r5' >"$FAKE_KEYCHAIN_STATE"
  printf '%s' 'existing-modelhub-ak-r5' >"$FAKE_LAUNCHCTL_STATE_DIR/env-MODELHUB_AK"
  before="$(managed_state_digest "$case_dir")"
  export FAKE_LAUNCHCTL_GETENV_STATUS=36

  assert_command_fails perform_install

  export FAKE_LAUNCHCTL_GETENV_STATUS=''
  after="$(managed_state_digest "$case_dir")"
  assert_equals "$after" "$before"
  assert_equals "$(/bin/cat "$FAKE_KEYCHAIN_STATE")" 'existing-modelhub-ak-r5'
  assert_sql "$database" \
    "SELECT json_extract(settings_config, '$.auth.OPENAI_API_KEY') FROM providers WHERE id='existing-provider' AND app_type='codex';" \
    'keep-existing'
  assert_sql "$database" \
    "SELECT count(*) FROM providers WHERE id='bytedance-modelhub-official-cli' AND app_type='codex';" \
    '0'
  assert_equals \
    "$("$CC_SWITCH_LAUNCHCTL_BIN" getenv MODELHUB_AK)" \
    'existing-modelhub-ak-r5'
}

test_transaction_rejects_uniform_credential_drift_from_expected_ak() {
  local case_dir="$TEST_TMP/transaction-uniform-credential-drift"
  local before
  local after
  mkdir -p "$case_dir"
  prepare_transaction_case "$case_dir"
  before="$(managed_state_digest "$case_dir")"
  export CC_SWITCH_INSTALLER_ROUTING_TIMEOUT=2
  export FAKE_ROUTING_REWRITE_AK='uniform-drift-test-r5'
  export FAKE_ROUTING_REWRITE_ALL=1

  assert_command_fails perform_install

  after="$(managed_state_digest "$case_dir")"
  assert_equals "$after" "$before"
  [[ ! -e "$FAKE_KEYCHAIN_STATE" ]] || fail 'uniform credential drift rollback left a new keychain item'
  [[ ! -e "$FAKE_LAUNCHCTL_STATE_DIR/env-MODELHUB_AK" ]] \
    || fail 'uniform credential drift rollback left MODELHUB_AK in launchd'
}

test_transaction_restores_existing_keychain_after_write_then_fail() {
  local case_dir="$TEST_TMP/transaction-existing-keychain-write-then-fail"
  local before
  local after
  mkdir -p "$case_dir"
  prepare_transaction_case "$case_dir"
  printf '%s' 'existing-keychain-test-r5' >"$FAKE_KEYCHAIN_STATE"
  before="$(managed_state_digest "$case_dir")"
  export FAKE_SECURITY_MODE=write-then-fail

  assert_command_fails perform_install

  after="$(managed_state_digest "$case_dir")"
  assert_equals "$after" "$before"
  [[ "$(/bin/cat "$FAKE_KEYCHAIN_STATE")" == 'existing-keychain-test-r5' ]] \
    || fail 'write-then-fail rollback did not restore the previous keychain item'
}

test_transaction_removes_new_keychain_after_write_then_fail() {
  local case_dir="$TEST_TMP/transaction-new-keychain-write-then-fail"
  local before
  local after
  mkdir -p "$case_dir"
  prepare_transaction_case "$case_dir"
  before="$(managed_state_digest "$case_dir")"
  export FAKE_SECURITY_MODE=write-then-fail

  assert_command_fails perform_install

  after="$(managed_state_digest "$case_dir")"
  assert_equals "$after" "$before"
  [[ ! -e "$FAKE_KEYCHAIN_STATE" ]] || fail 'write-then-fail rollback left a new keychain item'
}

test_transaction_restores_custom_codex_cli_path_after_failure() {
  local case_dir="$TEST_TMP/transaction-custom-codex-cli-path-rollback"
  local before
  local after
  local restored_codex_cli_path
  mkdir -p "$case_dir"
  prepare_transaction_case "$case_dir"
  /bin/mkdir -p "$FAKE_LAUNCHCTL_STATE_DIR"
  printf '%s' '/custom/preinstall/codex' >"$FAKE_LAUNCHCTL_STATE_DIR/env-CODEX_CLI_PATH"
  before="$(managed_state_digest "$case_dir")"
  export FAKE_HEALTH_MODE=timeout

  assert_command_fails perform_install

  after="$(managed_state_digest "$case_dir")"
  assert_equals "$after" "$before"
  if ! restored_codex_cli_path="$("$CC_SWITCH_LAUNCHCTL_BIN" getenv CODEX_CLI_PATH)"; then
    fail 'rollback removed the previous CODEX_CLI_PATH'
    return 1
  fi
  assert_equals "$restored_codex_cli_path" '/custom/preinstall/codex'
}

test_security_stub_requires_explicit_password_value() {
  local case_dir="$TEST_TMP/security-stub-password-source"
  mkdir -p "$case_dir"
  prepare_transaction_case "$case_dir"
  /bin/rm -f "$FAKE_KEYCHAIN_STATE"

  assert_command_fails \
    "$CC_SWITCH_SECURITY_BIN" add-generic-password -a test -s test -U -w
  [[ ! -e "$FAKE_KEYCHAIN_STATE" ]] || fail 'security stub accepted a missing password value'

  "$CC_SWITCH_SECURITY_BIN" add-generic-password \
    -a test \
    -s test \
    -U \
    -w 'explicit-security-test-value'
  assert_equals "$(/bin/cat "$FAKE_KEYCHAIN_STATE")" 'explicit-security-test-value'
}

test_transaction_overwrites_golden_configuration_and_rolls_back() {
  local case_dir="$TEST_TMP/transaction-golden-overwrite"
  local auth_path
  local auth_before
  local before
  local after_rollback
  mkdir -p "$case_dir"
  prepare_transaction_case "$case_dir"
  auth_path="$case_dir/home/.codex/auth.json"
  auth_before="$(shasum -a 256 "$auth_path" | awk '{ print $1 }')"
  before="$(managed_state_digest "$case_dir")"

  perform_install

  assert_not_contains "$case_dir/home/.codex/config.toml" '[plugins."browser@openai-bundled"]'
  assert_not_contains "$case_dir/home/.codex/config.toml" 'approval_policy = "on-request"'
  assert_contains "$case_dir/home/.codex/config.toml" 'approval_policy = "never"'
  assert_contains \
    "$case_dir/home/.codex/config.toml" \
    "model_catalog_json = \"$case_dir/home/.codex/models-modelhub-1m.json\""
  assert_equals "$(shasum -a 256 "$auth_path" | awk '{ print $1 }')" "$auth_before"
  assert_sql "$case_dir/home/.cc-switch/cc-switch.db" 'SELECT count(*) FROM providers' '1'
  assert_sql "$case_dir/home/.cc-switch/cc-switch.db" \
    'SELECT id FROM providers' 'bytedance-modelhub-official-cli'
  assert_sql "$case_dir/home/.cc-switch/cc-switch.db" \
    "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='sentinel'" '0'
  assert_sql "$case_dir/home/.cc-switch/cc-switch.db" \
    'SELECT count(*) FROM proxy_request_logs' '0'
  assert_equals \
    "$(jq -r 'has("language") or has("showInTray")' "$case_dir/home/.cc-switch/settings.json")" \
    'false'
  assert_equals \
    "$(jq -r '.currentProviderCodex' "$case_dir/home/.cc-switch/settings.json")" \
    'bytedance-modelhub-official-cli'

  rollback_latest
  after_rollback="$(managed_state_digest "$case_dir")"
  assert_equals "$after_rollback" "$before"
}

test_golden_routing_verification_rejects_reversed_routes() {
  local case_dir="$TEST_TMP/golden-routing-verification"
  local live_config="$case_dir/config.toml"
  local database="$case_dir/cc-switch.db"
  mkdir -p "$case_dir"
  /bin/bash "$GOLDEN_DB_BUILDER" \
    --schema "$GOLDEN_DB_SCHEMA" \
    --provider-config "$GOLDEN_CODEX_CONFIG" \
    --provider-meta "$META_TEMPLATE" \
    --output "$database" >/dev/null
  /usr/bin/sed \
    -e "s#__USER_HOME__#$case_dir/home#g" \
    -e 's#https://aidp.bytedance.net/api/modelhub/online#http://127.0.0.1:15721/v1#g' \
    "$GOLDEN_CODEX_CONFIG" >"$live_config"
  export CC_SWITCH_SLEEP_BIN=/usr/bin/true

  wait_for_golden_routing_state "$database" "$live_config" 1

  sqlite3 "$database" <<'SQL'
UPDATE providers
SET settings_config = json_set(
  settings_config,
  '$.config',
  replace(
    json_extract(settings_config, '$.config'),
    'https://aidp.bytedance.net/api/modelhub/online',
    'http://127.0.0.1:15721/v1'
  )
);
SQL
  assert_command_fails wait_for_golden_routing_state "$database" "$live_config" 1

  /bin/cp "$GOLDEN_CODEX_CONFIG" "$live_config"
  assert_command_fails wait_for_golden_routing_state "$database" "$live_config" 1
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
  mkdir -p "$source_dir/assets" "$source_dir/golden" "$source_dir/helpers" "$source_dir/templates"
  cp "$INSTALLER" "$source_dir/install.sh"
  cp "$GOLDEN_DB_BUILDER" "$source_dir/build-golden-db.sh"
  cp "$LOCAL_GOLDEN_SNAPSHOT_BUILDER" "$source_dir/build-local-golden-snapshot.sh"
  cp "$GOLDEN_DB_SCHEMA" "$source_dir/golden/cc-switch-schema.sql"
  cp "$GOLDEN_CODEX_CONFIG" "$source_dir/golden/codex-config.toml"
  cp "$GOLDEN_SETTINGS" "$source_dir/golden/settings.json"
  cp "$TEMPLATE" "$source_dir/templates/modelhub-provider.toml"
  cp "$META_TEMPLATE" "$source_dir/templates/modelhub-provider-meta.json"
  cp "$REPO_ROOT/scripts/modelhub-installer/templates/com.ccswitch.modelhub-env.plist" \
    "$source_dir/templates/com.ccswitch.modelhub-env.plist"
  cp "$REPO_ROOT/scripts/modelhub-installer/templates/load-modelhub-env.sh" \
    "$source_dir/templates/load-modelhub-env.sh"
  cp "$RENAME_HELPER_SOURCE" "$source_dir/helpers/rename-exclusive.c"
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
  local extracted_dir="$case_dir/extracted"
  local helper_sha
  mkdir -p "$case_dir"
  create_packager_source "$source_dir"
  printf 'verified-app-zip\n' >"$case_dir/app.zip"

  run_packager "$source_dir" "$case_dir/app.zip" "$output_dir"

  assert_contains \
    "$output_dir/install.sh" \
    "readonly RELEASE_TAG='modelhub-installer-20260803-r6'"
  actual_files="$(find "$output_dir" -maxdepth 1 -type f -exec basename '{}' \; | LC_ALL=C sort)"
  expected_files="$(printf '%s\n' \
    'CC-Switch-ModelHub-3.19.1-arm64.app.zip' \
    'SHA256SUMS.txt' \
    'install.sh' \
    'modelhub-installer-resources.tar.gz' \
    | LC_ALL=C sort)"
  assert_equals "$actual_files" "$expected_files"
  verify_release_assets "$output_dir"
  validate_resource_archive "$output_dir/modelhub-installer-resources.tar.gz"
  mkdir -p "$extracted_dir"
  tar -xzf "$output_dir/modelhub-installer-resources.tar.gz" -C "$extracted_dir"
  [[ -x "$extracted_dir/modelhub-installer/helpers/rename-exclusive" ]] \
    || fail 'resource package is missing the executable rename helper'
  [[ ! -e "$extracted_dir/modelhub-installer/helpers/rename-exclusive.c" ]] \
    || fail 'resource package unexpectedly ships rename helper source'
  [[ -f "$extracted_dir/modelhub-installer/golden/codex-config.toml" ]] \
    || fail 'resource package is missing golden Codex config'
  [[ -f "$extracted_dir/modelhub-installer/golden/settings.json" ]] \
    || fail 'resource package is missing golden settings'
  [[ -f "$extracted_dir/modelhub-installer/golden/cc-switch.db" ]] \
    || fail 'resource package is missing golden CC Switch database'
  assert_sql "$extracted_dir/modelhub-installer/golden/cc-switch.db" \
    'PRAGMA integrity_check' 'ok'
  assert_sql "$extracted_dir/modelhub-installer/golden/cc-switch.db" \
    'SELECT count(*) FROM providers' '1'
  assert_sql "$extracted_dir/modelhub-installer/golden/cc-switch.db" \
    "SELECT instr(json_extract(settings_config, '$.config'), '127.0.0.1:15721') FROM providers" \
    '0'
  assert_equals \
    "$(/usr/bin/lipo -archs "$extracted_dir/modelhub-installer/helpers/rename-exclusive")" \
    'arm64'
  /usr/bin/codesign --verify --strict --verbose=2 \
    "$extracted_dir/modelhub-installer/helpers/rename-exclusive"
  helper_sha="$(
    /usr/bin/shasum -a 256 "$extracted_dir/modelhub-installer/helpers/rename-exclusive" \
      | awk '{ print $1 }'
  )"
  assert_contains "$output_dir/install.sh" "readonly RENAME_HELPER_SHA256='$helper_sha'"
  assert_not_contains "$output_dir/install.sh" '__RENAME_HELPER_SHA256__'
  assert_equals "$(
    CC_SWITCH_INSTALLER_TEST_MODE=0 /bin/bash -c \
      'source "$1"; expected_rename_helper_sha256' \
      _ "$output_dir/install.sh"
  )" "$helper_sha"
  assert_equals "$(awk 'NF { count += 1 } END { print count + 0 }' "$output_dir/SHA256SUMS.txt")" '3'
}

test_package_reproducibly_renders_pinned_helper_hash() {
  local case_dir="$TEST_TMP/package-helper-reproducibility"
  local source_dir="$case_dir/source"
  local first_output="$case_dir/first-output"
  local second_output="$case_dir/second-output"
  local first_tree="$case_dir/first-tree"
  local second_tree="$case_dir/second-tree"
  local helper_sha
  mkdir -p "$case_dir" "$first_tree" "$second_tree"
  create_packager_source "$source_dir"
  printf 'verified-app-zip\n' >"$case_dir/app.zip"

  run_packager "$source_dir" "$case_dir/app.zip" "$first_output"
  run_packager "$source_dir" "$case_dir/app.zip" "$second_output"
  tar -xzf "$first_output/modelhub-installer-resources.tar.gz" -C "$first_tree"
  tar -xzf "$second_output/modelhub-installer-resources.tar.gz" -C "$second_tree"

  assert_equals \
    "$(shasum -a 256 "$first_tree/modelhub-installer/helpers/rename-exclusive" | awk '{ print $1 }')" \
    "$(shasum -a 256 "$second_tree/modelhub-installer/helpers/rename-exclusive" | awk '{ print $1 }')"
  assert_equals \
    "$(shasum -a 256 "$first_output/install.sh" | awk '{ print $1 }')" \
    "$(shasum -a 256 "$second_output/install.sh" | awk '{ print $1 }')"
  cmp \
    "$first_output/modelhub-installer-resources.tar.gz" \
    "$second_output/modelhub-installer-resources.tar.gz" \
    || fail 'resource archives are not byte reproducible'
  cmp "$first_output/SHA256SUMS.txt" "$second_output/SHA256SUMS.txt" \
    || fail 'release checksum manifests are not byte reproducible'
  helper_sha="$(shasum -a 256 "$first_tree/modelhub-installer/helpers/rename-exclusive" | awk '{ print $1 }')"
  assert_contains "$first_output/install.sh" "readonly RENAME_HELPER_SHA256='$helper_sha'"
  assert_contains "$second_output/install.sh" "readonly RENAME_HELPER_SHA256='$helper_sha'"
  assert_not_contains "$first_output/install.sh" '__RENAME_HELPER_SHA256__'
  assert_not_contains "$second_output/install.sh" '__RENAME_HELPER_SHA256__'
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

test_package_rejects_unsafe_golden_snapshot_source() {
  local case_dir="$TEST_TMP/package-unsafe-golden"
  local source_dir="$case_dir/source"
  mkdir -p "$case_dir"
  printf 'verified-app-zip\n' >"$case_dir/app.zip"
  create_packager_source "$source_dir"
  printf '\nbase_url = "http://127.0.0.1:15721/v1"\n' \
    >>"$source_dir/golden/codex-config.toml"

  assert_command_fails run_packager \
    "$source_dir" "$case_dir/app.zip" "$case_dir/output"
  [[ ! -e "$case_dir/output/modelhub-installer-resources.tar.gz" ]] \
    || fail 'unsafe golden source left a publishable resource archive'
}

test_golden_db_builder_creates_minimal_public_snapshot() {
  local case_dir="$TEST_TMP/golden-db-builder"
  local first_db="$case_dir/first.db"
  local second_db="$case_dir/second.db"
  local config_text
  mkdir -p "$case_dir"

  /bin/bash "$GOLDEN_DB_BUILDER" \
    --schema "$GOLDEN_DB_SCHEMA" \
    --provider-config "$GOLDEN_CODEX_CONFIG" \
    --provider-meta "$META_TEMPLATE" \
    --output "$first_db"
  /bin/bash "$GOLDEN_DB_BUILDER" \
    --schema "$GOLDEN_DB_SCHEMA" \
    --provider-config "$GOLDEN_CODEX_CONFIG" \
    --provider-meta "$META_TEMPLATE" \
    --output "$second_db"

  cmp "$first_db" "$second_db" || fail 'golden DB builds are not byte reproducible'
  assert_sql "$first_db" 'PRAGMA integrity_check' 'ok'
  assert_sql "$first_db" 'PRAGMA user_version' '16'
  assert_sql "$first_db" 'SELECT count(*) FROM providers' '1'
  assert_sql "$first_db" 'SELECT id FROM providers' 'bytedance-modelhub-official-cli'
  assert_sql "$first_db" \
    "SELECT json_array_length(json_extract(settings_config, '$.auth')) FROM providers" \
    '0'
  assert_sql "$first_db" \
    "SELECT instr(json_extract(settings_config, '$.config'), 'https://aidp.bytedance.net/api/modelhub/online') > 0 FROM providers" \
    '1'
  assert_sql "$first_db" \
    "SELECT instr(json_extract(settings_config, '$.config'), '127.0.0.1:15721') FROM providers" \
    '0'
  assert_sql "$first_db" \
    "SELECT proxy_enabled || ':' || enabled || ':' || auto_failover_enabled || ':' || listen_address || ':' || listen_port FROM proxy_config WHERE app_type='codex'" \
    '1:1:0:127.0.0.1:15721'
  assert_sql "$first_db" 'SELECT count(*) FROM proxy_request_logs' '0'
  assert_sql "$first_db" 'SELECT count(*) FROM proxy_live_backup' '0'
  assert_sql "$first_db" 'SELECT count(*) FROM provider_health' '0'
  assert_sql "$first_db" 'SELECT count(*) FROM provider_endpoints' '0'

  config_text="$(/bin/cat "$GOLDEN_CODEX_CONFIG")"
  [[ "$config_text" == *'__USER_HOME__/.codex/models-modelhub-1m.json'* ]] \
    || fail 'golden Codex config omits the portable home placeholder'
  [[ "$config_text" == *'https://aidp.bytedance.net/api/modelhub/online'* ]] \
    || fail 'golden Codex config omits the ModelHub upstream'
  [[ "$config_text" != *'/Users/'* ]] || fail 'golden Codex config contains a user path'
  [[ "$config_text" != *'127.0.0.1:15721'* ]] || fail 'golden Codex config contains a live proxy address'
  [[ "$config_text" != *'experimental_bearer_token'* ]] \
    || fail 'golden Codex config contains a bearer token field'
  jq -e \
    '.currentProviderCodex == "bytedance-modelhub-official-cli"
      and .enableLocalProxy == true
      and .preserveCodexOfficialAuthOnSwitch == true' \
    "$GOLDEN_SETTINGS" >/dev/null
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
      "$case_dir/assets/CC-Switch-ModelHub-3.19.1-arm64.app.zip" \
      "$asset_dir"
  fi

  export CC_SWITCH_INSTALLER_TEST_MODE=1
  export CC_SWITCH_INSTALLER_TEST_HOME="$case_dir/home"
  export CC_SWITCH_INSTALLER_TEST_APPLICATIONS_DIR="$case_dir/Applications"
  export CC_SWITCH_INSTALLER_ASSET_DIR="$asset_dir"
  export CC_SWITCH_INSTALLER_TIMESTAMP='20260727T130000Z'
  export CC_SWITCH_INSTALLER_HEALTH_TIMEOUT=1
  export CC_SWITCH_INSTALLER_ROUTING_TIMEOUT=1
  export CC_SWITCH_INSTALLER_TEST_MODELHUB_AK='test-modelhub-ak-r5'
  export FAKE_KEYCHAIN_STATE="$case_dir/keychain-state"
  export FAKE_LAUNCHCTL_STATE_DIR="$case_dir/launchctl-state"
  export FAKE_SECURITY_MODE=success
  export FAKE_HEALTH_MODE=healthy
  export FAKE_LIVE_CONFIG_PATH="$case_dir/home/.codex/config.toml"
  database="$case_dir/home/.cc-switch/cc-switch.db"

  /bin/bash -s <"$asset_dir/install.sh"
  first_install_digest="$(managed_state_digest "$case_dir")"
  assert_contains "$case_dir/home/.codex/config.toml" 'approval_policy = "never"'
  assert_sql "$database" "select count(*) from providers where name='Bytedance ModelHub - 官方CLI'" '1'

  export CC_SWITCH_INSTALLER_TIMESTAMP='20260727T130001Z'
  /bin/bash "$asset_dir/install.sh"
  assert_sql "$database" "select count(*) from providers where name='Bytedance ModelHub - 官方CLI'" '1'

  /bin/bash "$case_dir/home/.local/share/cc-switch-modelhub/install.sh" --rollback latest
  after_rollback_digest="$(managed_state_digest "$case_dir")"
  assert_equals "$after_rollback_digest" "$first_install_digest"
}

run_test "merge preserves unmanaged sections" test_merge_preserves_unmanaged_sections
run_test "helper exclusive rename preserves exact collision" test_helper_exclusive_rename_preserves_exact_collision
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
run_test "blocks invalid existing ChatGPT symlink" test_blocks_invalid_existing_chatgpt_symlink_without_download
run_test "preflight blocks invalid existing ChatGPT before release assets" test_preflight_blocks_invalid_existing_chatgpt_before_release_assets
run_test "bootstraps missing ChatGPT from official DMG" test_bootstraps_missing_chatgpt_from_official_dmg
run_test "bootstraps missing ChatGPT cleans all failure paths" test_bootstraps_missing_chatgpt_cleans_all_failure_paths
run_test "bootstraps missing ChatGPT rejects final target race" test_bootstraps_missing_chatgpt_rejects_final_target_race
run_test "ChatGPT bootstrap cleanup retries detach" test_chatgpt_bootstrap_cleanup_retries_detach_before_removing_mount
run_test "ChatGPT bootstrap cleanup preserves pending mount on inspection failure" test_chatgpt_bootstrap_cleanup_preserves_pending_mount_when_inspection_fails
run_test "ChatGPT bootstrap cleanup retries mount and temp removal" test_chatgpt_bootstrap_cleanup_retries_mount_and_temp_removal
run_test "ChatGPT bootstrap detach failure prevents publication" test_chatgpt_bootstrap_detach_failure_prevents_publication
run_test "ChatGPT bootstrap final validation failure preserves target" test_chatgpt_bootstrap_final_validation_failure_preserves_target_and_fails
run_test "ChatGPT bootstrap rejects modified re-signed helper by pinned hash" test_chatgpt_bootstrap_rejects_modified_resigned_helper_by_pinned_hash
run_test "ChatGPT bootstrap rejects tampered trusted copy before exec" test_chatgpt_bootstrap_rejects_tampered_trusted_copy_before_exec
run_test "ChatGPT bootstrap trusted parent blocks post-hash replacement" test_chatgpt_bootstrap_trusted_parent_blocks_post_hash_replacement
run_test "ChatGPT bootstrap requires root sticky trusted parent" test_chatgpt_bootstrap_requires_root_sticky_trusted_parent
run_test "production mode ignores privileged tool overrides" test_production_mode_ignores_privileged_tool_overrides
run_test "real sudo rejects non-allowlisted privileged commands" test_real_sudo_rejects_non_allowlisted_privileged_commands
run_test "ChatGPT bootstrap validates root-owned staging through privilege" test_chatgpt_bootstrap_validates_root_owned_staging_through_privilege
run_test "ChatGPT bootstrap rejects unverified packaged helper" test_chatgpt_bootstrap_rejects_unverified_packaged_helper_before_download
run_test "ChatGPT bootstrap rejects signed helper outside verified resources" test_chatgpt_bootstrap_rejects_signed_helper_outside_verified_resource_root
run_test "ChatGPT bootstrap signal after commit preserves prevalidated target" test_chatgpt_bootstrap_signal_after_commit_preserves_prevalidated_target
run_test "keeps bootstrapped ChatGPT after failure and explicit rollback" test_keeps_bootstrapped_chatgpt_after_failure_and_explicit_rollback
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
run_test "existing nontraversable app requires privilege" test_existing_nontraversable_app_requires_privilege
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
run_test "transaction synchronizes ModelHub AK" test_transaction_synchronizes_modelhub_ak
run_test "transaction detects startup ModelHub AK drift and rolls back" test_transaction_detects_startup_modelhub_ak_drift_and_rolls_back
run_test "transaction detects routing-stage ModelHub AK drift and rolls back" test_transaction_detects_routing_stage_modelhub_ak_drift_and_rolls_back
run_test "transaction restores existing ModelHub credential state after failure" test_transaction_restores_existing_modelhub_credential_state_after_failure
run_test "transaction launchd snapshot error preserves existing state" test_transaction_launchd_snapshot_error_preserves_existing_state
run_test "transaction rejects uniform credential drift from expected AK" test_transaction_rejects_uniform_credential_drift_from_expected_ak
run_test "transaction restores existing keychain after write-then-fail" test_transaction_restores_existing_keychain_after_write_then_fail
run_test "transaction removes new keychain after write-then-fail" test_transaction_removes_new_keychain_after_write_then_fail
run_test "transaction restores custom CODEX_CLI_PATH after failure" test_transaction_restores_custom_codex_cli_path_after_failure
run_test "security stub requires explicit password value" test_security_stub_requires_explicit_password_value
run_test "transaction overwrites golden configuration" test_transaction_overwrites_golden_configuration_and_rolls_back
run_test "golden routing verification rejects reversed routes" test_golden_routing_verification_rejects_reversed_routes
run_test "transaction rollback latest restores and removes files" test_transaction_rollback_latest_restores_and_removes_files
run_test "transaction rollback without backup reports clear error" test_transaction_rollback_without_backup_reports_clear_error
run_test "transaction CLI help and argument validation" test_transaction_cli_help_and_argument_validation
run_test "transaction corrupt backup fails before restore writes" test_transaction_corrupt_backup_fails_before_restore_writes
run_test "package builds exact allowlisted release assets" test_package_builds_exact_allowlisted_release_assets
run_test "package reproducibly renders pinned helper hash" test_package_reproducibly_renders_pinned_helper_hash
run_test "package rejects sensitive content" test_package_rejects_sensitive_content
run_test "package rejects generic credential key shapes" test_package_rejects_generic_credential_key_shapes
run_test "package rejects sensitive file types" test_package_rejects_sensitive_file_types
run_test "package rejects output inside source tree" test_package_rejects_output_inside_source_tree
run_test "package rejects source symlinks" test_package_rejects_source_symlinks
run_test "package rejects unsafe golden snapshot" test_package_rejects_unsafe_golden_snapshot_source
run_test "golden DB builder creates minimal public snapshot" test_golden_db_builder_creates_minimal_public_snapshot
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
