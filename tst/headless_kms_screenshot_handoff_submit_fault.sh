#!/usr/bin/env bash
# imway-env: IMWAY_CHAOS=shot-submit=1
# The queue refuses the copy submit of a screenshot handoff after the
# scanout was exported for the viewer: the refusal is reported, the
# exported dma-buf fd is closed rather than left open in the compositor,
# the capture retries as a pixel readback and reaches the editor. The session
# keeps flipping.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

in_log "scanout swapchain" || { echo "no zero-copy swapchain, nothing to hand off"; cat "$IMWAY_LOG"; exit 1; }

shots="$XDG_RUNTIME_DIR/shots"
ctl "set applications.screenshot_directory $shots"
ctl "set applications.screenshot_name refused"
ctl "set applications.screenshot_format 1" # png
ctl "set applications.screenshot_action 1" # save, no window
await 100 in_log "control: set applications.screenshot_action" || { echo "settings are not reachable"; exit 1; }

dmabufs() {
    local n=0 f
    for f in /proc/"$IMWAY_PID"/fd/*; do
        [[ "$(readlink "$f" 2>/dev/null)" == /dmabuf:* ]] && n=$((n + 1))
    done
    echo "$n"
}
before=$(dmabufs)

ctl "key 99 press"; ctl "key 99 release" # Print
await 100 in_log "screenshot handoff of the scanout buffer" || { echo "no handoff"; cat "$IMWAY_LOG"; exit 1; }
await 100 in_log "imway: screenshot submit failed (-2)" || { echo "the refused submit was not reported"; cat "$IMWAY_LOG"; exit 1; }
await 100 in_log "imway: screenshot readback" || { echo "the capture did not retry as a readback"; cat "$IMWAY_LOG"; exit 1; }
await 200 test -s "$shots/refused.shim" || { echo "the retried capture never reached the editor"; cat "$IMWAY_LOG"; exit 1; }
grep -q '^source=memfd$' "$shots/refused.shim" || { echo "the retry did not reach the editor as a readback:"; cat "$shots/refused.shim"; exit 1; }

flips() { dump_field '^kms' flips; }
f0=$(flips)
advanced() { [[ "$(flips)" -ge "$((f0 + 4))" ]]; }
for i in $(seq 1 60); do
    advanced && break
    ctl "motion $((100 + i * 5)) 300"
    sleep 0.05
done
advanced || { echo "flips stopped after the refused handoff"; exit 1; }

after=$(dmabufs)
echo "dma-buf fds: before=$before after=$after"
[[ "$after" -le "$before" ]] || { echo "the exported scanout fd stayed open after the refused handoff"; ls -l /proc/"$IMWAY_PID"/fd; exit 1; }

expect_alive "compositor died on a refused handoff submit"
echo "OK: a refused handoff submit closes the exported buffer and the capture still saves"
