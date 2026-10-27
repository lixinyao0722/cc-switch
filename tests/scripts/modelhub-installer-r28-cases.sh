#!/bin/bash

prepare_r28_stream_case() {
  local case_dir="$1"
  create_chatgpt_app_fixture "$case_dir/Applications/ChatGPT.app"
  make_r27_chatgpt_layout "$case_dir/Applications/ChatGPT.app"
  create_transaction_stubs "$case_dir"
  create_chatgpt_validation_stubs "$case_dir"
  cp "$REPO_ROOT/tests/scripts/fixtures/modelhub-codesign-stream.sh" "$case_dir/stream-codesign"
  chmod +x "$case_dir/stream-codesign"
  export CC_SWITCH_INSTALLER_TEST_MODE=1
  export CC_SWITCH_INSTALLER_TEST_APPLICATIONS_DIR="$case_dir/Applications"
  export CC_SWITCH_PLUTIL_BIN="$case_dir/plutil"
  export CC_SWITCH_CODESIGN_BIN="$case_dir/stream-codesign"
  export CC_SWITCH_SECURITY_BIN="$case_dir/stubs/security"
  export CC_SWITCH_LAUNCHCTL_BIN="$case_dir/stubs/launchctl"
  export FAKE_KEYCHAIN_STATE="$case_dir/keychain-state"
  export FAKE_LAUNCHCTL_STATE_DIR="$case_dir/launchctl-state"
  printf %s stream-test-ak >"$FAKE_KEYCHAIN_STATE"
}

test_r28_helper_consumes_app_signature_stream() {
  local case_dir="$TEST_TMP/r28-app-stream"
  prepare_r28_stream_case "$case_dir"
  export FAKE_SIGNATURE_STREAM_SCOPE=app
  /bin/bash "$REPO_ROOT/scripts/modelhub-installer/templates/load-modelhub-env.sh"
  assert_equals "$("$CC_SWITCH_LAUNCHCTL_BIN" getenv CODEX_CLI_PATH)" \
    "$case_dir/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
  assert_equals "$("$CC_SWITCH_LAUNCHCTL_BIN" getenv MODELHUB_AK)" stream-test-ak
}

test_r28_helper_consumes_payload_signature_stream() {
  local case_dir="$TEST_TMP/r28-payload-stream"
  prepare_r28_stream_case "$case_dir"
  export FAKE_SIGNATURE_STREAM_SCOPE=payload
  /bin/bash "$REPO_ROOT/scripts/modelhub-installer/templates/load-modelhub-env.sh"
  assert_equals "$("$CC_SWITCH_LAUNCHCTL_BIN" getenv CODEX_CLI_PATH)" \
    "$case_dir/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
}

test_r28_helper_rejects_display_failure_after_match() {
  local case_dir="$TEST_TMP/r28-display-error"
  prepare_r28_stream_case "$case_dir"
  /bin/bash "$REPO_ROOT/scripts/modelhub-installer/templates/load-modelhub-env.sh"
  FAKE_SIGNATURE_DISPLAY_STATUS=42 assert_command_fails \
    /bin/bash "$REPO_ROOT/scripts/modelhub-installer/templates/load-modelhub-env.sh"
  [[ ! -e "$FAKE_LAUNCHCTL_STATE_DIR/env-MODELHUB_AK" ]] || fail "failed signature display retained AK"
  [[ ! -e "$FAKE_LAUNCHCTL_STATE_DIR/env-CODEX_CLI_PATH" ]] || fail "failed signature display retained CLI path"
}

test_r28_helper_rejects_payload_display_failure_after_match() {
  local case_dir="$TEST_TMP/r28-payload-display-error"
  prepare_r28_stream_case "$case_dir"
  export FAKE_SIGNATURE_STREAM_SCOPE=payload
  /bin/bash "$REPO_ROOT/scripts/modelhub-installer/templates/load-modelhub-env.sh"
  FAKE_SIGNATURE_DISPLAY_FAILURE_SCOPE=payload FAKE_SIGNATURE_DISPLAY_STATUS=42 \
    assert_command_fails /bin/bash "$REPO_ROOT/scripts/modelhub-installer/templates/load-modelhub-env.sh"
  [[ ! -e "$FAKE_LAUNCHCTL_STATE_DIR/env-MODELHUB_AK" ]] || fail "failed payload signature display retained AK"
  [[ ! -e "$FAKE_LAUNCHCTL_STATE_DIR/env-CODEX_CLI_PATH" ]] || fail "failed payload signature display retained CLI path"
}

run_test 'R28 consumes complete outer app signature stream' test_r28_helper_consumes_app_signature_stream
run_test 'R28 consumes complete payload signature stream' test_r28_helper_consumes_payload_signature_stream
run_test 'R28 rejects signature display failure after matching team' test_r28_helper_rejects_display_failure_after_match
run_test 'R28 rejects payload signature display failure after matching team' test_r28_helper_rejects_payload_display_failure_after_match
