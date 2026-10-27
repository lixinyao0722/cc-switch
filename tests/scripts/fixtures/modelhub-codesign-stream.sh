#!/bin/bash
# Signature-display boundary fixture: actual writes beyond a pipe buffer.
set -euo pipefail
target="${@: -1}"
case "${1:-}" in
  --verify)
    [[ "$2" == --deep && "$3" == --strict && "$#" == 4 ]] || exit 64
    [[ "${FAKE_APP_STRICT:-pass}" == pass ]]
    ;;
  -dv)
    [[ "$2" == --verbose=4 && "$#" == 3 ]] || exit 64
    scope=app
    [[ "$target" != */Contents/MacOS/codex ]] || scope=payload
    printf "Executable=%s\nIdentifier=com.openai.codex\nTeamIdentifier=%s\n" \
      "$target" "${FAKE_SIGNING_TEAM:-2DC432GLL2}" >&2
    if [[ "${FAKE_SIGNATURE_STREAM_SCOPE:-app}" == "$scope" ]]; then
      /usr/bin/awk 'BEGIN { for (i=0; i<65536; i++) print "Sealed Resources diagnostic trailing line " i }' >&2
    fi
    if [[ "${FAKE_SIGNATURE_DISPLAY_FAILURE_SCOPE:-app}" == "$scope" ]]; then
      exit "${FAKE_SIGNATURE_DISPLAY_STATUS:-0}"
    fi
    exit 0
    ;;
  *) exit 64 ;;
esac
