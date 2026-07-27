#!/bin/bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="$REPO_ROOT/scripts/modelhub-installer/install.sh"
TEMPLATE="$REPO_ROOT/scripts/modelhub-installer/templates/modelhub-provider.toml"
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
    'base_url = "https://keep.example/v1"' \
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

run_test "merge preserves unmanaged sections" test_merge_preserves_unmanaged_sections
run_test "merge creates config from empty file" test_merge_creates_config_from_empty_file
run_test "merge creates config when source is missing" test_merge_creates_config_when_source_is_missing
run_test "merge replaces only modelhub section" test_merge_replaces_only_active_modelhub_section
run_test "merge validation rejects unresolved home placeholder" test_validate_rejects_unresolved_home_placeholder
run_test "preflight rejects unsupported platforms" test_preflight_rejects_unsupported_platforms
run_test "preflight validates ChatGPT Codex Team ID" test_preflight_validates_chatgpt_codex_team_id
run_test "preflight verifies all release checksums" test_preflight_verifies_all_release_checksums
run_test "preflight rejects unexpected checksum entries" test_preflight_rejects_unexpected_checksum_entries
run_test "preflight accepts exact resource archive" test_preflight_accepts_exact_resource_archive
run_test "preflight rejects archive symlink and extra file" test_preflight_rejects_archive_symlink_and_extra_file
run_test "preflight rejects archive special file types" test_preflight_rejects_archive_special_file_types
run_test "preflight rejects unsafe archive entry names" test_preflight_rejects_unsafe_archive_entry_names
run_test "preflight downloads from immutable release tag" test_preflight_downloads_from_immutable_release_tag

if [[ "$TESTS_RUN" -eq 0 ]]; then
  echo "No tests matched filter: $TEST_FILTER" >&2
  exit 2
fi

if [[ "$TESTS_FAILED" -ne 0 ]]; then
  echo "$TESTS_FAILED of $TESTS_RUN tests failed" >&2
  exit 1
fi

echo "$TESTS_RUN tests passed"
