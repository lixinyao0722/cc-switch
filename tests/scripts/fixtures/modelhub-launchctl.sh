#!/bin/bash
# Stateful launchd boundary fixture. Never executes the real launchctl.
set -euo pipefail
mkdir -p "$FAKE_LAUNCHCTL_STATE_DIR"
printf '%s\n' "${1:-} ${2:-}" >>"$FAKE_LAUNCHCTL_STATE_DIR/calls"
case "${1:-}" in
  print)
    [[ "$2" == "gui/$(/usr/bin/id -u)" ]] && exit "${FAKE_LAUNCHCTL_DOMAIN_STATUS:-0}"
    [[ "$2" == "gui/$(/usr/bin/id -u)/com.ccswitch.modelhub-env" ]] || exit 64
    if [[ -n "${FAKE_LAUNCHCTL_PRINT_STATUS:-}" ]]; then exit "$FAKE_LAUNCHCTL_PRINT_STATUS"; fi
    if [[ -f "$FAKE_LAUNCHCTL_STATE_DIR/pending" ]]; then
      remaining="$(/bin/cat "$FAKE_LAUNCHCTL_STATE_DIR/pending")"
      if [[ "$remaining" -eq 0 ]]; then
        rm -f "$FAKE_LAUNCHCTL_STATE_DIR/job" "$FAKE_LAUNCHCTL_STATE_DIR/pending"
      else
        printf '%s' "$((remaining - 1))" >"$FAKE_LAUNCHCTL_STATE_DIR/pending"
      fi
    fi
    [[ -e "$FAKE_LAUNCHCTL_STATE_DIR/job" ]] || exit 113
    if [[ -f "$FAKE_LAUNCHCTL_STATE_DIR/helper-pending" ]]; then
      remaining="$(/bin/cat "$FAKE_LAUNCHCTL_STATE_DIR/helper-pending")"
      if [[ "$remaining" -gt 0 ]]; then
        printf '%s' "$((remaining - 1))" >"$FAKE_LAUNCHCTL_STATE_DIR/helper-pending"
        printf 'state = %s\nlast exit code = %s\nprivate environment = fixture-do-not-print\n' \
          "${FAKE_LAUNCHCTL_PENDING_STATE:-running}" "${FAKE_LAUNCHCTL_PENDING_EXIT-(never exited)}"
        exit 0
      fi
      rm -f "$FAKE_LAUNCHCTL_STATE_DIR/helper-pending"
    fi
    printf 'state = not running\nlast exit code = %s\nprivate environment = fixture-do-not-print\n' "${FAKE_LAUNCHCTL_HELPER_EXIT:-0}"
    ;;
  bootout)
    [[ "$2" == "gui/$(/usr/bin/id -u)/com.ccswitch.modelhub-env" ]] || exit 64
    [[ -e "$FAKE_LAUNCHCTL_STATE_DIR/job" ]] || exit 113
    if [[ "${FAKE_LAUNCHCTL_BOOTOUT_MODE:-immediate}" == fail ]]; then exit 5; fi
    if [[ "${FAKE_LAUNCHCTL_BOOTOUT_MODE:-immediate}" == delayed ]]; then
      printf '%s' "${FAKE_LAUNCHCTL_DELAY_POLLS:-2}" >"$FAKE_LAUNCHCTL_STATE_DIR/pending"
    else
      rm -f "$FAKE_LAUNCHCTL_STATE_DIR/job"
    fi
    exit "${FAKE_LAUNCHCTL_BOOTOUT_STATUS:-0}"
    ;;
  bootstrap)
    [[ "$2" == "gui/$(/usr/bin/id -u)" && -f "$3" ]] || exit 64
    [[ ! -e "$FAKE_LAUNCHCTL_STATE_DIR/job" ]] || exit 5
    if [[ "${FAKE_LAUNCHCTL_BOOTSTRAP_MODE:-success}" == fail ]]; then exit 5; fi
    if [[ "${FAKE_LAUNCHCTL_BOOTSTRAP_MODE:-success}" == fail-once && ! -e "$FAKE_LAUNCHCTL_STATE_DIR/bootstrap-failed" ]]; then
      : >"$FAKE_LAUNCHCTL_STATE_DIR/bootstrap-failed"
      exit 5
    fi
    if [[ "${FAKE_LAUNCHCTL_BOOTSTRAP_MODE:-success}" != missing ]]; then
      : >"$FAKE_LAUNCHCTL_STATE_DIR/job"
      printf '%s' "${FAKE_LAUNCHCTL_HELPER_DELAY_POLLS:-0}" >"$FAKE_LAUNCHCTL_STATE_DIR/helper-pending"
      /usr/bin/shasum -a 256 "$3" >"$FAKE_LAUNCHCTL_STATE_DIR/loaded-plist"
    fi
    if [[ "${FAKE_LAUNCHCTL_SIGNAL_TERM:-0}" == 1 ]]; then kill -TERM "$PPID"; fi
    ;;
  setenv)
    [[ "${FAKE_LAUNCHCTL_SETENV_FAIL:-}" != "$2" ]] || exit 5
    printf '%s' "$3" >"$FAKE_LAUNCHCTL_STATE_DIR/env-$2"
    ;;
  getenv)
    if [[ -n "${FAKE_LAUNCHCTL_GETENV_STATUS:-}" ]]; then exit "$FAKE_LAUNCHCTL_GETENV_STATUS"; fi
    [[ -f "$FAKE_LAUNCHCTL_STATE_DIR/env-$2" ]] || exit 1
    /bin/cat "$FAKE_LAUNCHCTL_STATE_DIR/env-$2"
    ;;
  unsetenv) rm -f "$FAKE_LAUNCHCTL_STATE_DIR/env-$2" ;;
  *) exit 64 ;;
esac
