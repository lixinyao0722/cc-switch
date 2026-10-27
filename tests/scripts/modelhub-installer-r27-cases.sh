#!/bin/bash

make_r27_chatgpt_layout() {
  local app_path="$1"
  mkdir -p "$app_path/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS"
  mv "$app_path/Contents/Resources/codex" \
    "$app_path/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
  printf '#!/bin/sh\nexit 99\n' >"$app_path/Contents/Resources/codex-cli/bin-wrapper"
  mkdir -p "$app_path/Contents/Resources/codex-cli/bin"
  mv "$app_path/Contents/Resources/codex-cli/bin-wrapper" \
    "$app_path/Contents/Resources/codex-cli/bin/codex"
  chmod +x "$app_path/Contents/Resources/codex-cli/bin/codex"
}

test_r27_validates_new_chatgpt_layout() {
  local case_dir="$TEST_TMP/r27-validation"
  local app_path="$case_dir/ChatGPT.app"
  local cli_path="$app_path/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
  mkdir -p "$case_dir"
  create_chatgpt_app_fixture "$app_path"
  make_r27_chatgpt_layout "$app_path"
  create_chatgpt_validation_stubs "$case_dir"
  export CC_SWITCH_INSTALLER_TEST_MODE=1
  export CC_SWITCH_PLUTIL_BIN="$case_dir/plutil"
  export CC_SWITCH_CODESIGN_BIN="$case_dir/codesign"
  export CC_SWITCH_FILE_BIN="$case_dir/file"
  validate_chatgpt_app "$app_path" '2DC432GLL2' 'com.openai.codex'
  assert_equals "$(resolve_chatgpt_codex_path "$app_path")" "$cli_path"
  FAKE_CODEX_TEAM_ID=WRONGTEAM assert_command_fails validate_chatgpt_app \
    "$app_path" '2DC432GLL2' 'com.openai.codex'
  chmod -x "$cli_path"
  assert_command_fails validate_chatgpt_app "$app_path" '2DC432GLL2' 'com.openai.codex'
  chmod +x "$cli_path"
  mv "$cli_path" "$case_dir/cli.saved"
  assert_command_fails validate_chatgpt_app "$app_path" '2DC432GLL2' 'com.openai.codex'
  ln -s "$case_dir/cli.saved" "$cli_path"
  assert_command_fails validate_chatgpt_app "$app_path" '2DC432GLL2' 'com.openai.codex'
}

test_r27_legacy_fallback_and_parent_escape() {
  local case_dir="$TEST_TMP/r27-legacy"
  local app_path="$case_dir/ChatGPT.app"
  mkdir -p "$case_dir"
  create_chatgpt_app_fixture "$app_path"
  assert_equals "$(resolve_chatgpt_codex_path "$app_path")" "$app_path/Contents/Resources/codex"
  make_r27_chatgpt_layout "$app_path"
  cp "$app_path/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex" \
    "$app_path/Contents/Resources/codex"
  mv "$app_path/Contents/Resources/codex-cli" "$case_dir/escaped-cli"
  ln -s "$case_dir/escaped-cli" "$app_path/Contents/Resources/codex-cli"
  assert_command_fails resolve_chatgpt_codex_path "$app_path"
}

test_r27_transaction_new_layout_and_environment_refresh() {
  local case_dir="$TEST_TMP/r27-transaction"
  local app_path="$case_dir/Applications/ChatGPT.app"
  local cli_path="$app_path/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
  prepare_transaction_case "$case_dir"
  perform_install >"$case_dir/legacy-output" 2>&1
  assert_equals "$("$CC_SWITCH_LAUNCHCTL_BIN" getenv CODEX_CLI_PATH)" \
    "$app_path/Contents/Resources/codex"
  make_r27_chatgpt_layout "$app_path"
  "$ENV_HELPER_PATH"
  assert_equals "$("$CC_SWITCH_LAUNCHCTL_BIN" getenv CODEX_CLI_PATH)" "$cli_path"
  verify_launch_agent_environment
  perform_install >"$case_dir/new-output" 2>&1
  assert_equals "$CHATGPT_CODEX_PATH" "$cli_path"
  assert_equals "$("$CC_SWITCH_LAUNCHCTL_BIN" getenv CODEX_CLI_PATH)" "$cli_path"
  assert_not_contains "$case_dir/new-output" 'test-modelhub-ak-r6'
  rollback_latest >"$case_dir/rollback-output" 2>&1
  [[ -x "$cli_path" ]] || fail 'rollback modified the ChatGPT CLI'
}

test_r27_helper_rejects_untrusted_app_after_upgrade() {
  local case_dir="$TEST_TMP/r27-helper-integrity"
  prepare_transaction_case "$case_dir"
  make_r27_chatgpt_layout "$case_dir/Applications/ChatGPT.app"
  perform_install >"$case_dir/install-output" 2>&1
  create_chatgpt_validation_stubs "$case_dir"
  export CC_SWITCH_CODESIGN_BIN="$case_dir/codesign"
  FAKE_APP_STRICT=fail assert_command_fails "$ENV_HELPER_PATH"
  [[ ! -e "$FAKE_LAUNCHCTL_STATE_DIR/env-CODEX_CLI_PATH" ]] \
    || fail 'helper retained CLI path after strict signature failure'
  [[ ! -e "$FAKE_LAUNCHCTL_STATE_DIR/env-MODELHUB_AK" ]] \
    || fail 'helper retained AK after strict signature failure'
  FAKE_APP_TEAM_ID=WRONGTEAM assert_command_fails "$ENV_HELPER_PATH"
  FAKE_CODEX_TEAM_ID=WRONGTEAM assert_command_fails "$ENV_HELPER_PATH"
  cp "$CHATGPT_APP_PATH/Contents/Info.plist" "$case_dir/Info.plist.valid"
  printf 'CFBundleIdentifier=com.example.impostor\nCFBundleExecutable=ChatGPT\n' \
    >"$CHATGPT_APP_PATH/Contents/Info.plist"
  assert_command_fails "$ENV_HELPER_PATH"
  cp "$case_dir/Info.plist.valid" "$CHATGPT_APP_PATH/Contents/Info.plist"
  mv "$CHATGPT_APP_PATH/Contents/Resources/codex-cli" "$case_dir/escaped-cli"
  ln -s "$case_dir/escaped-cli" "$CHATGPT_APP_PATH/Contents/Resources/codex-cli"
  assert_command_fails "$ENV_HELPER_PATH"
  rm "$CHATGPT_APP_PATH/Contents/Resources/codex-cli"
  mv "$case_dir/escaped-cli" "$CHATGPT_APP_PATH/Contents/Resources/codex-cli"
  "$ENV_HELPER_PATH"
  verify_launch_agent_environment
}

run_test 'R27 helper rejects untrusted app after upgrade' test_r27_helper_rejects_untrusted_app_after_upgrade
run_test 'R27 validates new ChatGPT layout without wrapper fallback' test_r27_validates_new_chatgpt_layout
run_test 'R27 legacy CLI fallback rejects parent escape' test_r27_legacy_fallback_and_parent_escape
run_test 'R27 transaction supports new layout and environment refresh' test_r27_transaction_new_layout_and_environment_refresh
