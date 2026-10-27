# Sourced by the installer suite; never operates real launchd or credentials.
test_r29_demand_only_install_completes() {
  local case_dir="$TEST_TMP/r29-demand-only"
  prepare_transaction_case "$case_dir"
  export FAKE_LAUNCHCTL_ON_DEMAND_ONLY=1
  export CC_SWITCH_INSTALLER_TEST_LAUNCHD_ATTEMPTS=3
  perform_install >"$case_dir/output" 2>&1
  [[ -f "$ACTIVE_BACKUP_DIR/install-completed" && -e "$FAKE_LAUNCHCTL_STATE_DIR/job" ]] \
    || fail 'registered demand-only installation did not complete'
  [[ ! -e "$FAKE_LAUNCHCTL_STATE_DIR/demand-pending" ]] || fail 'job never started'
  verify_launch_agent_environment
  assert_not_contains "$case_dir/output" 'fixture-do-not-print'
  assert_not_contains "$case_dir/output" 'test-modelhub-ak-r6'
}

test_r29_start_failure_rolls_back() {
  local case_dir="$TEST_TMP/r29-start-failure"
  local before
  prepare_transaction_case "$case_dir"
  before="$(managed_state_digest "$case_dir")"
  export FAKE_LAUNCHCTL_KICKSTART_STATUS=5
  if perform_install >"$case_dir/output" 2>&1; then fail 'explicit start failure was accepted'; fi
  assert_contains "$case_dir/output" 'failed to start ModelHub environment LaunchAgent'
  assert_equals "$(managed_state_digest "$case_dir")" "$before"
  [[ ! -e "$FAKE_KEYCHAIN_STATE" && ! -e "$FAKE_LAUNCHCTL_STATE_DIR/job" ]] \
    || fail 'start failure retained new credentials or job'
  [[ ! -e "$FAKE_LAUNCHCTL_STATE_DIR/env-MODELHUB_AK" && ! -e "$FAKE_LAUNCHCTL_STATE_DIR/env-CODEX_CLI_PATH" ]] \
    || fail 'start failure retained changed runtime environment'
  assert_not_contains "$case_dir/output" 'test-modelhub-ak-r6'
  assert_not_contains "$case_dir/output" 'fixture-do-not-print'
}

test_r29_running_helper_is_not_killed() {
  local case_dir="$TEST_TMP/r29-running-helper"
  prepare_r24_loaded_job "$case_dir"
  export FAKE_LAUNCHCTL_HELPER_DELAY_POLLS=2
  export FAKE_LAUNCHCTL_PENDING_STATE=running
  export FAKE_LAUNCHCTL_PENDING_EXIT=0
  install_launch_agent >"$case_dir/output" 2>&1
  [[ ! -e "$FAKE_LAUNCHCTL_STATE_DIR/helper-pending" ]] || fail 'stale completion accepted before helper finished'
  assert_contains "$FAKE_LAUNCHCTL_STATE_DIR/calls" "kickstart gui/$(/usr/bin/id -u)/com.ccswitch.modelhub-env"
  assert_not_contains "$FAKE_LAUNCHCTL_STATE_DIR/calls" 'kickstart -k'
}

run_test 'R29 demand-only registered helper completes installation' test_r29_demand_only_install_completes
run_test 'R29 explicit start failure rolls back files credentials and job' test_r29_start_failure_rolls_back
run_test 'R29 already-running helper is not killed or accepted early' test_r29_running_helper_is_not_killed
