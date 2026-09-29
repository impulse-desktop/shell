#!/usr/bin/env bash
# imway-env: IMWAY_CHILD_LOG=./viewer.log
# imway-args: --hdr 300
# The screenshot handoff on an HDR (BT.2020 + PQ) KMS session: the handed-off
# scanout is a 10-bit buffer, and the editor is told the output is HDR with
# its white level, once for a PNG and once for a lossless JPEG XL; the
# editor's stand-in reports each.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/hdr_shot_check.sh"

in_log "HDR output: BT.2020 + PQ" || { echo "no HDR boot"; cat "$IMWAY_LOG"; exit 1; }
in_log "scanout swapchain" || { echo "no zero-copy swapchain, nothing to hand off"; cat "$IMWAY_LOG"; exit 1; }

shots="$XDG_RUNTIME_DIR/shots"
ctl "set applications.screenshot_directory $shots"
ctl "set applications.screenshot_name handoff"
ctl "set applications.screenshot_format 1" # png
ctl "set applications.screenshot_action 1" # save, no window
await 100 in_log "control: set applications.screenshot_action" || { echo "settings are not reachable"; exit 1; }

receipt="$shots/handoff.shim"
shot() { # <exits before>: one Print, its editor gone
    local before=$1
    rm -f "$receipt"
    done_saving() {
        [[ -s "$receipt" && "$(grep -c "exited with status 0" "$IMWAY_LOG" || true)" -gt "$before" ]]
    }
    ctl "key 99 press"; ctl "key 99 release" # Print
    await 200 done_saving || {
        echo "the handoff never reached the editor"
        cat "$IMWAY_LOG" "$XDG_RUNTIME_DIR/viewer.log" 2>/dev/null
        exit 1
    }
}

shot 0
in_log "screenshot handoff of the scanout buffer" || { echo "the capture was read back instead of handed off"; cat "$IMWAY_LOG"; exit 1; }
grep -q '^source=dmabuf$' "$receipt" || { echo "the editor was not handed the scanout buffer:"; cat "$receipt"; exit 1; }
grep -Eq '^vkformat=(58|64)$' "$receipt" || { echo "the handed-off scanout is not a 10-bit buffer (A2R10G10B10 or A2B10G10R10):"; cat "$receipt"; exit 1; }
grep -q '^color=1:' "$receipt" || { echo "the editor was not told the output is HDR:"; cat "$receipt"; exit 1; }
grep -q '^format=png$' "$receipt" || { echo "the first save was not asked for as a PNG:"; cat "$receipt"; exit 1; }

ctl "set applications.screenshot_format 0" # jxl
ctl "set applications.screenshot_lossless true"
shot 1
grep -q '^format=jxl$' "$receipt" && grep -q '^lossless=1$' "$receipt" || { echo "the second save was not asked for as a lossless JPEG XL:"; cat "$receipt"; exit 1; }

expect_alive "compositor died handing off an HDR scanout"
echo "OK: an HDR scanout reaches the editor as a 10-bit dma-buf with its HDR metadata"
