#!/usr/bin/env bash
# imway-env: IMWAY_CHAOS=shot-submit=1 IMWAY_FAKE_KMS_NO_PRIME=1
# The queue refuses the copy submit of a screenshot readback (a display
# that cannot import the GPU's buffers scans out dumb ones, with nothing to
# hand off): the refusal is reported, the next frame submits the capture
# again and it reaches the editor.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

shots="$XDG_RUNTIME_DIR/shots"
ctl "set applications.screenshot_directory $shots"
ctl "set applications.screenshot_name refused"
ctl "set applications.screenshot_format 1" # png
ctl "set applications.screenshot_action 1" # save, no window
await 100 in_log "control: set applications.screenshot_action" || { echo "settings are not reachable"; exit 1; }

ctl "key 99 press"; ctl "key 99 release" # Print
await 100 in_log "imway: screenshot submit failed (-2)" || { echo "the refused submit was not reported"; cat "$IMWAY_LOG"; exit 1; }
! in_log "screenshot handoff" || { echo "the dumb-buffer output handed a scanout off"; cat "$IMWAY_LOG"; exit 1; }
retried() {
    [[ $(grep -c "imway: screenshot readback" "$IMWAY_LOG") -ge 2 ]]
}
await 100 retried || { echo "the refused capture was not submitted again"; cat "$IMWAY_LOG"; exit 1; }
await 200 test -s "$shots/refused.shim" || { echo "the retried capture never reached the editor"; cat "$IMWAY_LOG"; exit 1; }
grep -q '^source=memfd$' "$shots/refused.shim" || { echo "the retry did not reach the editor as a readback:"; cat "$shots/refused.shim"; exit 1; }

expect_alive "compositor died on a refused screenshot submit"
echo "OK: a refused readback submit is reported, retried and handed over"
