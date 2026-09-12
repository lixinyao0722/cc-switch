# Sourced by modelhub-installer.test.sh; all OS services are isolated fixtures.
prepare_r24_loaded_job() {
  local case_dir="$1"
  prepare_transaction_case "$case_dir"
  configure_install_paths
  mkdir -p "$(dirname "$LAUNCH_AGENT_PATH")" "$FAKE_LAUNCHCTL_STATE_DIR"
  render_template "$REPO_ROOT/scripts/modelhub-installer/templates/com.ccswitch.modelhub-env.plist" \
    "$LAUNCH_AGENT_PATH" '__HELPER_PATH__' "$(xml_escape "$ENV_HELPER_PATH")"
  cp "$REPO_ROOT/scripts/modelhub-installer/templates/load-modelhub-env.sh" "$ENV_HELPER_PATH"
  chmod 700 "$ENV_HELPER_PATH"
  printf '%s' 'r24-fixture-old-key' >"$FAKE_KEYCHAIN_STATE"
  printf '%s' 'r24-fixture-old-key' >"$FAKE_LAUNCHCTL_STATE_DIR/env-MODELHUB_AK"
  printf '%s' '/Applications/ChatGPT.app/Contents/Resources/codex' >"$FAKE_LAUNCHCTL_STATE_DIR/env-CODEX_CLI_PATH"
  : >"$FAKE_LAUNCHCTL_STATE_DIR/job"
}

test_r24_launchd_completion_pending_then_success() {
  local pending_exit case_dir index=0
  # Missing exit status and stale numeric status are not current-run completion.
  for pending_exit in '(never exited)' '' '0' '7'; do
    index=$((index + 1))
    case_dir="$TEST_TMP/r24-completion-success-$index"
    prepare_r24_loaded_job "$case_dir"
    export FAKE_LAUNCHCTL_HELPER_DELAY_POLLS=2
    export FAKE_LAUNCHCTL_PENDING_EXIT="$pending_exit"
    install_launch_agent >"$case_dir/output" 2>&1
    [[ ! -e "$FAKE_LAUNCHCTL_STATE_DIR/helper-pending" ]] \
      || fail 'installation accepted the running helper before completion'
    [[ -e "$FAKE_LAUNCHCTL_STATE_DIR/job" ]] || fail 'completed helper lost its job'
    assert_not_contains "$case_dir/output" 'fixture-do-not-print'
    assert_not_contains "$case_dir/output" 'r24-fixture-old-key'
  done
}

test_r24_launchd_completion_waits_for_first_exit() {
  local pending_state case_dir index=0
  for pending_state in waiting spawning 'spawn scheduled'; do
    index=$((index + 1))
    case_dir="$TEST_TMP/r24-completion-first-exit-$index"
    prepare_r24_loaded_job "$case_dir"
    export FAKE_LAUNCHCTL_HELPER_DELAY_POLLS=2
    export FAKE_LAUNCHCTL_PENDING_STATE="$pending_state"
    install_launch_agent >"$case_dir/output" 2>&1
    [[ ! -e "$FAKE_LAUNCHCTL_STATE_DIR/helper-pending" ]] \
      || fail 'helper without a first exit was accepted as completed'
    assert_not_contains "$case_dir/output" 'fixture-do-not-print'
  done
}

test_r24_launchd_completion_failure_restores_files() {
  local case_dir="$TEST_TMP/r24-completion-failure"
  local before
  prepare_transaction_case "$case_dir"
  before="$(managed_state_digest "$case_dir")"
  export FAKE_LAUNCHCTL_HELPER_DELAY_POLLS=2
  export FAKE_LAUNCHCTL_HELPER_EXIT=7
  if perform_install >"$case_dir/output" 2>&1; then fail 'nonzero helper exit was accepted'; fi
  assert_contains "$case_dir/output" 'exit code 7'
  assert_equals "$(managed_state_digest "$case_dir")" "$before"
  [[ ! -e "$FAKE_KEYCHAIN_STATE" && ! -e "$FAKE_LAUNCHCTL_STATE_DIR/job" ]] \
    || fail 'helper failure retained new credentials or job'
  assert_not_contains "$case_dir/output" 'fixture-do-not-print'
  assert_not_contains "$case_dir/output" 'test-modelhub-ak-r6'
}

test_r24_launchd_completion_timeout_restores_files() {
  local case_dir="$TEST_TMP/r24-completion-timeout"
  local before
  prepare_transaction_case "$case_dir"
  before="$(managed_state_digest "$case_dir")"
  export FAKE_LAUNCHCTL_HELPER_DELAY_POLLS=1000
  export CC_SWITCH_INSTALLER_TEST_LAUNCHD_ATTEMPTS=3
  if perform_install >"$case_dir/output" 2>&1; then fail 'running helper without completion was accepted'; fi
  assert_contains "$case_dir/output" 'did not report completion'
  assert_equals "$(managed_state_digest "$case_dir")" "$before"
  [[ ! -e "$FAKE_KEYCHAIN_STATE" && ! -e "$FAKE_LAUNCHCTL_STATE_DIR/job" ]] \
    || fail 'timeout retained new credentials or job'
  [[ "$(wc -l <"$FAKE_LAUNCHCTL_STATE_DIR/calls")" -le 40 ]] || fail 'helper completion wait was unbounded'
  assert_not_contains "$case_dir/output" 'unsuccessful last exit'
  assert_not_contains "$case_dir/output" 'fixture-do-not-print'
}

test_r24_launchd_completion_waits_during_restore() {
  local case_dir="$TEST_TMP/r24-completion-restore"
  local before
  prepare_r24_loaded_job "$case_dir"
  before="$(managed_state_digest "$case_dir")"
  export FAKE_LAUNCHCTL_HELPER_DELAY_POLLS=2
  export FAKE_HEALTH_MODE=timeout
  if perform_install >"$case_dir/output" 2>&1; then fail 'health failure was ignored'; fi
  assert_equals "$(managed_state_digest "$case_dir")" "$before"
  [[ -e "$FAKE_LAUNCHCTL_STATE_DIR/job" && ! -e "$FAKE_LAUNCHCTL_STATE_DIR/helper-pending" ]] \
    || fail 'automatic rollback did not wait for the old helper to complete'
  assert_not_contains "$case_dir/output" 'rollback was incomplete'
  assert_not_contains "$case_dir/output" 'LaunchAgent restore incomplete'
  assert_not_contains "$case_dir/output" 'unsuccessful last exit'
  export FAKE_HEALTH_MODE=healthy
  perform_install >"$case_dir/install-output" 2>&1
  rollback_latest >"$case_dir/rollback-output" 2>&1
  [[ -e "$FAKE_LAUNCHCTL_STATE_DIR/job" && ! -e "$FAKE_LAUNCHCTL_STATE_DIR/helper-pending" ]] \
    || fail 'explicit rollback did not wait for the old helper to complete'
  assert_not_contains "$case_dir/rollback-output" 'fixture-do-not-print'
}

test_r24_launchd_completion_unknown_status_is_redacted() {
  local case_dir="$TEST_TMP/r24-completion-unknown"
  prepare_r24_loaded_job "$case_dir"
  export FAKE_LAUNCHCTL_HELPER_EXIT='unexpected-fixture-sensitive-status'
  if install_launch_agent >"$case_dir/output" 2>&1; then fail 'unknown helper status was accepted'; fi
  assert_contains "$case_dir/output" 'unrecognized completion status'
  assert_not_contains "$case_dir/output" 'unexpected-fixture-sensitive-status'
  assert_not_contains "$case_dir/output" 'fixture-do-not-print'
}

test_r24_launchd_completion_still_checks_environment() {
  local case_dir="$TEST_TMP/r24-completion-environment"
  prepare_r24_loaded_job "$case_dir"
  export FAKE_LAUNCHCTL_HELPER_DELAY_POLLS=2
  export FAKE_LAUNCHCTL_GETENV_STATUS=5
  if install_launch_agent >"$case_dir/output" 2>&1; then fail 'completed helper bypassed environment verification'; fi
  assert_contains "$case_dir/output" 'environment readback failed'
  assert_not_contains "$case_dir/output" 'fixture-do-not-print'
}

test_r24_launchd_delayed_bootout() {
  local case_dir="$TEST_TMP/r24-delayed"
  prepare_r24_loaded_job "$case_dir"
  export FAKE_LAUNCHCTL_BOOTOUT_MODE=delayed
  perform_install >"$case_dir/output" 2>&1
  [[ -e "$FAKE_LAUNCHCTL_STATE_DIR/job" ]] || fail 'new job was not established'
  [[ ! -e "$FAKE_LAUNCHCTL_STATE_DIR/pending" ]] || fail 'bootstrap raced pending bootout'
  assert_not_contains "$case_dir/output" 'fixture-do-not-print'
  rollback_latest
  [[ -e "$FAKE_LAUNCHCTL_STATE_DIR/job" ]] || fail 'rollback did not restore the loaded job'
}

test_r24_launchd_bootout_failure() {
  local case_dir="$TEST_TMP/r24-bootout-failure"
  local before before_inode
  prepare_r24_loaded_job "$case_dir"
  before="$(managed_state_digest "$case_dir")"
  before_inode="$(/usr/bin/stat -f '%i:%m' "$CODEX_CONFIG_PATH")"
  export FAKE_LAUNCHCTL_BOOTOUT_MODE=fail
  assert_command_fails perform_install
  assert_equals "$(managed_state_digest "$case_dir")" "$before"
  assert_equals "$(/usr/bin/stat -f '%i:%m' "$CODEX_CONFIG_PATH")" "$before_inode"
  assert_not_contains "$FAKE_SECURITY_LOG" 'add-generic-password'
  [[ -e "$FAKE_LAUNCHCTL_STATE_DIR/job" ]] || fail 'failed bootout removed old job'
}

test_r24_launchd_nonzero_absent() {
  local case_dir="$TEST_TMP/r24-bootout-nonzero-absent"
  prepare_r24_loaded_job "$case_dir"
  export FAKE_LAUNCHCTL_BOOTOUT_STATUS=5
  perform_install >/dev/null 2>&1
  [[ -e "$FAKE_LAUNCHCTL_STATE_DIR/job" ]] || fail 'confirmed-absent bootout prevented install'
}

test_r24_launchd_bootout_timeout() {
  local case_dir="$TEST_TMP/r24-bootout-timeout"
  local before
  prepare_r24_loaded_job "$case_dir"
  before="$(managed_state_digest "$case_dir")"
  export FAKE_LAUNCHCTL_BOOTOUT_MODE=delayed
  export FAKE_LAUNCHCTL_DELAY_POLLS=1000
  export CC_SWITCH_INSTALLER_TEST_LAUNCHD_ATTEMPTS=3
  if perform_install >"$case_dir/output" 2>&1; then fail 'delayed bootout did not time out'; fi
  assert_equals "$(managed_state_digest "$case_dir")" "$before"
  assert_contains "$case_dir/output" 'did not disappear'
  [[ "$(wc -l <"$FAKE_LAUNCHCTL_STATE_DIR/calls")" -le 30 ]] || fail 'launchd polling was not bounded'
}

test_r24_launchd_journal_failure_preserves_job() {
  local case_dir="$TEST_TMP/r24-journal-failure"
  local before
  prepare_r24_loaded_job "$case_dir"
  before="$(managed_state_digest "$case_dir")"
  ACTIVE_BACKUP_DIR="$(create_backup "$BACKUP_ROOT")"
  # An actual filesystem write error, not a mocked installer result.
  mkdir "$ACTIVE_BACKUP_DIR/launch-agent-changed"
  assert_command_fails run_install_transaction "$case_dir/assets" "$case_dir/resources"
  [[ -e "$FAKE_LAUNCHCTL_STATE_DIR/job" ]] || fail 'journal failure unloaded original job'
  assert_not_contains "$FAKE_LAUNCHCTL_STATE_DIR/calls" bootout
  assert_equals "$(managed_state_digest "$case_dir")" "$before"
}

test_r24_explicit_rollback_unload_before_keychain() {
  local case_dir="$TEST_TMP/r24-rollback-unload-first"
  local before_keychain
  prepare_transaction_case "$case_dir"
  perform_install >/dev/null 2>&1
  before_keychain="$(/usr/bin/shasum -a 256 "$FAKE_KEYCHAIN_STATE")"
  export FAKE_LAUNCHCTL_BOOTOUT_MODE=fail
  assert_command_fails rollback_latest
  assert_equals "$(/usr/bin/shasum -a 256 "$FAKE_KEYCHAIN_STATE")" "$before_keychain"
  [[ -e "$FAKE_LAUNCHCTL_STATE_DIR/job" ]] || fail 'failed rollback mutated loaded job'
}

test_r24_explicit_rollback_credential_warning() {
  local case_dir mode expected_changed current_credential
  for mode in replaced unchanged; do
    case_dir="$TEST_TMP/r24-rollback-credential-$mode"
    prepare_r24_loaded_job "$case_dir"
    expected_changed=1
    if [[ "$mode" == unchanged ]]; then
      export CC_SWITCH_INSTALLER_TEST_MODELHUB_AK='r24-fixture-old-key'
      expected_changed=0
    fi
    perform_install >"$case_dir/install-output" 2>&1
    assert_equals "$(/bin/cat "$ACTIVE_BACKUP_DIR/keychain-value-changed")" "$expected_changed"
    current_credential="$(/usr/bin/shasum -a 256 "$FAKE_KEYCHAIN_STATE")"
    rollback_latest >"$case_dir/rollback-output" 2>&1
    assert_equals "$(/usr/bin/shasum -a 256 "$FAKE_KEYCHAIN_STATE")" "$current_credential"
    if [[ "$mode" == replaced ]]; then
      assert_contains "$case_dir/rollback-output" '旧 MODELHUB_AK 无法从文件备份恢复'
      assert_contains "$case_dir/rollback-output" '保留当前 Keychain 凭据'
    else
      assert_not_contains "$case_dir/rollback-output" '旧 MODELHUB_AK 无法从文件备份恢复'
    fi
    assert_not_contains "$case_dir/rollback-output" 'r24-fixture-old-key'
    assert_not_contains "$case_dir/install-output" 'r24-fixture-old-key'
    assert_not_contains "$case_dir/rollback-output" 'fake-modelhub-ak'
  done
}

test_r24_launchd_bootstrap_helper_failure() {
  local mode case_dir before
  for mode in bootstrap helper; do
    case_dir="$TEST_TMP/r24-failure-$mode"
    prepare_transaction_case "$case_dir"
    before="$(managed_state_digest "$case_dir")"
    if [[ "$mode" == bootstrap ]]; then
      export FAKE_LAUNCHCTL_BOOTSTRAP_MODE=fail
    else
      export FAKE_LAUNCHCTL_HELPER_EXIT=7
    fi
    assert_command_fails perform_install
    assert_equals "$(managed_state_digest "$case_dir")" "$before"
    [[ ! -e "$FAKE_LAUNCHCTL_STATE_DIR/job" ]] || fail 'failure retained new job'
    [[ ! -e "$FAKE_KEYCHAIN_STATE" ]] || fail 'failure retained new credentials'
    unset FAKE_LAUNCHCTL_BOOTSTRAP_MODE FAKE_LAUNCHCTL_HELPER_EXIT
  done
}

test_r24_early_failure_restores_environment_without_job() {
  local case_dir="$TEST_TMP/r24-early-failure-existing-environment"
  local before_ak before_cli
  prepare_transaction_case "$case_dir"
  mkdir -p "$FAKE_LAUNCHCTL_STATE_DIR"
  printf '%s' 'r24-existing-environment-ak' >"$FAKE_LAUNCHCTL_STATE_DIR/env-MODELHUB_AK"
  printf '%s' '/fixture/previous/codex-cli' >"$FAKE_LAUNCHCTL_STATE_DIR/env-CODEX_CLI_PATH"
  before_ak="$(/usr/bin/shasum -a 256 "$FAKE_LAUNCHCTL_STATE_DIR/env-MODELHUB_AK")"
  before_cli="$(/usr/bin/shasum -a 256 "$FAKE_LAUNCHCTL_STATE_DIR/env-CODEX_CLI_PATH")"
  export FAKE_SECURITY_FIND_STATUS=128
  assert_command_fails perform_install
  assert_equals "$(/usr/bin/shasum -a 256 "$FAKE_LAUNCHCTL_STATE_DIR/env-MODELHUB_AK")" "$before_ak"
  assert_equals "$(/usr/bin/shasum -a 256 "$FAKE_LAUNCHCTL_STATE_DIR/env-CODEX_CLI_PATH")" "$before_cli"
  [[ ! -e "$FAKE_LAUNCHCTL_STATE_DIR/job" ]] || fail 'rollback created originally absent job'
}

test_r24_launchd_restore_failure() {
  local case_dir="$TEST_TMP/r24-restore-failure"
  prepare_r24_loaded_job "$case_dir"
  perform_install >/dev/null 2>&1
  export FAKE_LAUNCHCTL_BOOTSTRAP_MODE=fail
  if rollback_latest >"$case_dir/output" 2>&1; then fail 'rollback bootstrap failure was ignored'; fi
  assert_contains "$case_dir/output" 'LaunchAgent'
  assert_contains "$case_dir/output" "$BACKUP_ROOT"
  assert_not_contains "$case_dir/output" 'fixture-do-not-print'
}

test_r24_launchd_plist_validation() {
  local case_dir="$TEST_TMP/r24-plist-validation"
  prepare_transaction_case "$case_dir"
  configure_install_paths
  mkdir -p "$(dirname "$LAUNCH_AGENT_PATH")"
  printf 'invalid plist' >"$LAUNCH_AGENT_PATH"
  write_executable_stub "$ENV_HELPER_PATH" 'exit 0'
  assert_command_fails install_launch_agent
  assert_not_contains "$FAKE_LAUNCHCTL_STATE_DIR/calls" bootstrap
}

test_r24_launchd_missing_job() {
  local case_dir="$TEST_TMP/r24-missing-job"
  prepare_transaction_case "$case_dir"
  export FAKE_LAUNCHCTL_BOOTSTRAP_MODE=missing
  assert_command_fails perform_install
  unset FAKE_LAUNCHCTL_BOOTSTRAP_MODE
  export FAKE_LAUNCHCTL_PRINT_STATUS=5
  assert_command_fails perform_install
}

test_r24_default_managed_config_untouched() {
  local case_dir="$TEST_TMP/r24-managed-untouched"
  local original_inode
  prepare_transaction_case "$case_dir"
  mkdir -p "$case_dir/etc/codex"
  printf '# original system policy\nmodel_provider = "openai"\n' >"$case_dir/etc/codex/managed_config.toml"
  original_inode="$(/usr/bin/stat -f '%i:%m' "$case_dir/etc/codex/managed_config.toml")"
  # Deny traversal: default install must neither read this file nor request sudo for it.
  chmod 000 "$case_dir/etc"
  perform_install >"$case_dir/output" 2>&1 || { chmod 700 "$case_dir/etc"; return 1; }
  rollback_latest >>"$case_dir/output" 2>&1 || { chmod 700 "$case_dir/etc"; return 1; }
  chmod 700 "$case_dir/etc"
  assert_equals "$(/usr/bin/stat -f '%i:%m' "$case_dir/etc/codex/managed_config.toml")" "$original_inode"
  assert_contains "$case_dir/etc/codex/managed_config.toml" 'model_provider = "openai"'
  assert_not_contains "$ACTIVE_BACKUP_DIR/manifest.tsv" 'managed_config.toml'
  assert_not_contains "$case_dir/output" 'Mac 登录用户的管理员密码'
}

test_r24_custom_codex_directory_rejected_before_mutation() {
  local case_dir="$TEST_TMP/r24-custom-codex-directory"
  local before
  prepare_transaction_case "$case_dir"
  write_executable_stub "$CC_SWITCH_OSASCRIPT_BIN" 'printf called >"$CC_SWITCH_INSTALLER_TEST_HOME/quit-called"'
  write_executable_stub "$CC_SWITCH_OPEN_BIN" 'printf called >"$CC_SWITCH_INSTALLER_TEST_HOME/open-called"'
  /usr/bin/plutil -insert codexConfigDir -string "$case_dir/custom-codex" "$case_dir/home/.cc-switch/settings.json"
  before="$(managed_state_digest "$case_dir")"
  if perform_install >"$case_dir/output" 2>&1; then fail 'installer accepted an unbacked custom Codex directory'; fi
  assert_contains "$case_dir/output" 'codexConfigDir'
  assert_contains "$case_dir/output" 'App-only'
  assert_equals "$(managed_state_digest "$case_dir")" "$before"
  [[ ! -e "$case_dir/home/open-called" && ! -e "$case_dir/home/quit-called" && ! -e "$FAKE_SECURITY_LOG" ]] \
    || fail 'custom directory rejection reached an app or credential operation'
  [[ ! -e "$FAKE_LAUNCHCTL_STATE_DIR/calls" && ! -e "$BACKUP_ROOT" ]] \
    || fail 'custom directory rejection reached launchd or backup'
}

test_r24_default_codex_directory_equivalence() {
  local case_dir="$TEST_TMP/r24-default-codex-directory"
  local candidate
  prepare_transaction_case "$case_dir"
  configure_install_paths
  for candidate in '' '~/.codex' '~/.codex/' "$INSTALL_USER_HOME/.codex" "$INSTALL_USER_HOME/.codex/"; do
    /usr/bin/plutil -replace codexConfigDir -string "$candidate" "$CC_SWITCH_SETTINGS_PATH"
    validate_existing_codex_directory
  done
  /usr/bin/plutil -replace codexConfigDir -json null "$CC_SWITCH_SETTINGS_PATH"
  validate_existing_codex_directory
  /usr/bin/plutil -remove codexConfigDir "$CC_SWITCH_SETTINGS_PATH"
  validate_existing_codex_directory
}

test_r24_legacy_rollback_permissions_before_mutation() {
  local case_dir="$TEST_TMP/r24-legacy-rollback-permissions"
  local before_security before_state before_launch_calls status
  prepare_transaction_case "$case_dir"
  perform_install >"$case_dir/install-output" 2>&1
  mkdir -p "$CODEX_MANAGED_CONFIG_DIR"
  printf '# system policy\nmodel_provider = "custom"\n' >"$CODEX_MANAGED_CONFIG_PATH"
  cp "$CODEX_MANAGED_CONFIG_PATH" "$ACTIVE_BACKUP_DIR/files/codex-managed-config.toml"
  printf '%s\t1\tfiles/codex-managed-config.toml\n' "$CODEX_MANAGED_CONFIG_PATH" >>"$ACTIVE_BACKUP_DIR/manifest.tsv"
  printf '1\n' >"$ACTIVE_BACKUP_DIR/codex-managed-config-parent-existed"
  rm "$ACTIVE_BACKUP_DIR/changed-targets.tsv"
  before_state="$(managed_state_digest "$case_dir")"
  before_security="$(wc -l <"$FAKE_SECURITY_LOG")"
  before_launch_calls="$(wc -l <"$FAKE_LAUNCHCTL_STATE_DIR/calls")"
  write_executable_stub "$CC_SWITCH_OSASCRIPT_BIN" 'printf called >"$CC_SWITCH_INSTALLER_TEST_HOME/quit-called"'
  export FAKE_SUDO_LOG="$case_dir/sudo.log"
  write_executable_stub "$case_dir/fake-sudo" 'printf called >>"$FAKE_SUDO_LOG"' 'exit 1'
  activate_fake_privilege_runner "$case_dir/fake-sudo"
  chmod 500 "$CODEX_MANAGED_CONFIG_DIR"
  if rollback_latest >"$case_dir/rollback-output" 2>&1; then status=0; else status=$?; fi
  chmod 700 "$CODEX_MANAGED_CONFIG_DIR"
  [[ "$status" != 0 ]] || fail 'legacy rollback ignored failed privilege authentication'
  [[ -e "$FAKE_SUDO_LOG" ]] || fail 'legacy rollback never requested system restore permission'
  [[ ! -e "$case_dir/home/quit-called" ]] || fail 'legacy rollback quit apps before permission check'
  assert_equals "$(managed_state_digest "$case_dir")" "$before_state"
  assert_equals "$(wc -l <"$FAKE_SECURITY_LOG")" "$before_security"
  assert_equals "$(wc -l <"$FAKE_LAUNCHCTL_STATE_DIR/calls")" "$before_launch_calls"
}

test_r24_local_assets_install() {
  local case_dir="$TEST_TMP/r24-local-assets"
  prepare_transaction_case "$case_dir"
  /bin/bash "$INSTALLER" --local-assets-dir "$case_dir/assets" >/dev/null 2>&1
  [[ -e "$FAKE_LAUNCHCTL_STATE_DIR/job" ]] || fail 'local asset install did not establish job'
  printf 'corrupt archive' >>"$case_dir/assets/$APP_ASSET"
  assert_command_fails /bin/bash "$INSTALLER" --local-assets-dir "$case_dir/assets"
  assert_command_fails /bin/bash "$INSTALLER" --local-assets-dir "$case_dir/missing"
}

test_r24_local_assets_symlinks_rejected() {
  local case_dir="$TEST_TMP/r24-local-symlink"
  local asset
  prepare_transaction_case "$case_dir"
  ln -s "$case_dir/assets" "$case_dir/assets-link"
  assert_command_fails /bin/bash "$INSTALLER" --local-assets-dir "$case_dir/assets-link"
  for asset in "$APP_ASSET" "$RESOURCES_ASSET" "$CHECKSUM_ASSET" install.sh; do
    mv "$case_dir/assets/$asset" "$case_dir/$asset"
    ln -s "$case_dir/$asset" "$case_dir/assets/$asset"
    assert_command_fails /bin/bash "$INSTALLER" --local-assets-dir "$case_dir/assets"
    rm "$case_dir/assets/$asset"
    mv "$case_dir/$asset" "$case_dir/assets/$asset"
  done
  [[ ! -e "$FAKE_LAUNCHCTL_STATE_DIR/job" ]] || fail 'unsafe local assets reached launchd'
}

test_r24_golden_defaults() {
  local case_dir="$TEST_TMP/r24-golden-defaults"
  prepare_transaction_case "$case_dir"
  perform_install >/dev/null 2>&1
  assert_sql "$CC_SWITCH_DATABASE_PATH" 'PRAGMA user_version' '18'
  assert_sql "$CC_SWITCH_DATABASE_PATH" "SELECT count(*) FROM pragma_table_info('session_log_sync') WHERE name IN ('last_byte_offset', 'last_tail_fingerprint')" '2'
  assert_sql "$CC_SWITCH_DATABASE_PATH" "SELECT json_type(meta, '$.localProxyRequestOverrides.codexRemoteSessions') FROM providers WHERE id='bytedance-modelhub-official-cli'" 'false'
  [[ ! -e "$case_dir/etc/codex" ]] || fail 'default install created system routing directory'
}
