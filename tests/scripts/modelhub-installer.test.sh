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

run_test "merge preserves unmanaged sections" test_merge_preserves_unmanaged_sections
run_test "merge creates config from empty file" test_merge_creates_config_from_empty_file
run_test "merge creates config when source is missing" test_merge_creates_config_when_source_is_missing
run_test "merge replaces only modelhub section" test_merge_replaces_only_active_modelhub_section
run_test "merge validation rejects unresolved home placeholder" test_validate_rejects_unresolved_home_placeholder

if [[ "$TESTS_RUN" -eq 0 ]]; then
  echo "No tests matched filter: $TEST_FILTER" >&2
  exit 2
fi

if [[ "$TESTS_FAILED" -ne 0 ]]; then
  echo "$TESTS_FAILED of $TESTS_RUN tests failed" >&2
  exit 1
fi

echo "$TESTS_RUN tests passed"
