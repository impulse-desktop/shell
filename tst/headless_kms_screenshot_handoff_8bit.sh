#!/usr/bin/env bash
# imway-env: IMWAY_FAKE_KMS_NO_10BIT=1 IMWAY_CHILD_LOG=./viewer.log
# The screenshot handoff from an 8-bit (XRGB8888) scanout, on a plane
# without the 10-bit formats: the editor is handed that buffer, described
# as the 8-bit format it is, with no HDR metadata.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/hdr_shot_check.sh"

in_log "scanout swapchain" || { echo "no zero-copy swapchain, nothing to hand off"; cat "$IMWAY_LOG"; exit 1; }
! in_log "imway: 10-bit scanout" || { echo "the scanout is 10-bit after all"; cat "$IMWAY_LOG"; exit 1; }

shots="$XDG_RUNTIME_DIR/shots"
ctl "set applications.screenshot_directory $shots"
ctl "set applications.screenshot_name handoff"
ctl "set applications.screenshot_format 1" # png
ctl "set applications.screenshot_action 1" # save, no window
await 100 in_log "control: set applications.screenshot_action" || { echo "settings are not reachable"; exit 1; }

ctl "key 99 press"; ctl "key 99 release" # Print
receipt="$shots/handoff.shim"
saved() {
    [[ -s "$receipt" ]] && in_log "exited with status 0"
}
await 200 saved || { echo "the handoff never reached the editor"; cat "$IMWAY_LOG" "$XDG_RUNTIME_DIR/viewer.log" 2>/dev/null; exit 1; }
in_log "screenshot handoff of the scanout buffer" || { echo "the capture was read back instead of handed off"; cat "$IMWAY_LOG"; exit 1; }
grep -q '^source=dmabuf$' "$receipt" || { echo "the editor was not handed the scanout buffer:"; cat "$receipt"; exit 1; }
grep -q '^vkformat=44$' "$receipt" || { echo "the handed-off scanout is not the 8-bit B8G8R8A8 one:"; cat "$receipt"; exit 1; }
! grep -q '^color=1:' "$receipt" || { echo "an SDR output was announced as HDR:"; cat "$receipt"; exit 1; }

expect_alive "compositor died handing off an 8-bit scanout"
echo "OK: an 8-bit scanout reaches the editor as the XRGB8888 dma-buf it is"
