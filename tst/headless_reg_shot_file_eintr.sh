#!/usr/bin/env bash
# imway-env: IMWAY_CHAOS=shot-eintr=2 IMWAY_FAKE_KMS_NO_PRIME=1
# The screenshot file's writes are interrupted by a signal, twice: each is
# retried, and the file the editor reads is whole.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

shots="$XDG_RUNTIME_DIR/shots"
ctl "set applications.screenshot_directory $shots"
ctl "set applications.screenshot_format 1" # png
ctl "set applications.screenshot_action 1" # save, no window
ctl "set applications.screenshot_name whole"
await 100 in_log "control: set applications.screenshot_name" || { echo "settings are not reachable"; exit 1; }

ctl "key 99 press"; ctl "key 99 release" # Print
await 200 test -s "$shots/whole.shim" || { echo "the interrupted file never reached the editor"; cat "$IMWAY_LOG"; exit 1; }
! in_log "imway: screenshot readback failed" || { echo "an interrupted write dropped the capture"; cat "$IMWAY_LOG"; exit 1; }

# the capture is the whole output: its header says so, and every byte came
w=$(sed -n 's/^width=//p' "$shots/whole.shim"); h=$(sed -n 's/^height=//p' "$shots/whole.shim")
[[ "$w" == 1280 && "$h" == 800 ]] || { echo "the capture is ${w}x${h}"; exit 1; }
[[ "$(sed -n 's/^bytes=//p' "$shots/whole.shim")" == $((12 + 1280 * 800 * 4)) ]] || { echo "the capture is not whole:"; cat "$shots/whole.shim"; exit 1; }

expect_alive "compositor died on interrupted screenshot writes"
echo "OK: interrupted screenshot writes are retried and the file is whole"
