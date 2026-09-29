#!/usr/bin/env bash
# The screenshot chord with each configured action and format: the editor
# is told to save, as PNG or as JPEG XL lossless and lossy at the configured
# quality, into the configured directory under the configured name, and
# maps no window; copy still opens the editor, which Escape leaves.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

shots="$XDG_RUNTIME_DIR/shots"
ctl "set applications.screenshot_directory $shots"
await 100 in_log "control: set applications.screenshot_directory" || { echo "settings are not reachable through the FIFO"; exit 1; }

told() { # <receipt> <key=value>...: every setting reached the editor
    local receipt=$1 line
    shift
    for line in "$@"; do
        grep -Eq "^$line$" "$receipt" || { echo "the editor was not told $line:"; cat "$receipt"; return 1; }
    done
}

# a capture handed off stays busy until the display retires the scanout it
# gave away: the next chord waits for that, as a person's next press would
free() { [[ "$(dump_field '^screenshot' busy)" == 0 ]]; }
capture() { # <name> <format ordinal> <lossless> <quality>
    await 100 free || { echo "the last capture never finished"; dump_state; exit 1; }
    ctl "set applications.screenshot_name $1"
    ctl "set applications.screenshot_format $2"
    ctl "set applications.screenshot_lossless $3"
    ctl "set applications.screenshot_quality $4"
    ctl "key 99 press"  # KEY_SYSRQ: Print
    ctl "key 99 release"
}

ctl "set applications.screenshot_action 1" # save

capture one 1 true 90
await 200 test -s "$shots/one.shim" || { echo "the png save never reached the editor"; cat "$IMWAY_LOG"; exit 1; }
told "$shots/one.shim" action=save format=png lossless=1 || exit 1

capture two 0 true 90
await 200 test -s "$shots/two.shim" || { echo "the lossless jxl save never reached the editor"; cat "$IMWAY_LOG"; exit 1; }
told "$shots/two.shim" action=save format=jxl lossless=1 || exit 1

capture three 0 false 50
await 200 test -s "$shots/three.shim" || { echo "the lossy jxl save never reached the editor"; cat "$IMWAY_LOG"; exit 1; }
told "$shots/three.shim" action=save format=jxl lossless=0 'quality=50(\.0+)?' || exit 1

# every save-mode viewer exited cleanly without mapping a window
saves_done() {
    [[ "$(grep -c "exited with status 0" "$IMWAY_LOG")" -ge 3 ]]
}
await 100 saves_done || { echo "save viewers did not exit cleanly"; cat "$IMWAY_LOG"; exit 1; }
[[ -z "$(dump_field 'title=im screenshot' id)" ]] || { echo "a save-mode viewer mapped a window"; exit 1; }

# copy is the editor for now: the window maps and Escape leaves no file
ctl "set applications.screenshot_action 2"
capture four 1 true 90

viewer_up() {
    [[ -n "$(dump_field 'title=im screenshot' id)" ]]
}
viewer_gone() {
    [[ -z "$(dump_field 'title=im screenshot' id)" ]]
}

await 150 viewer_up || { echo "copy action did not open the editor"; cat "$IMWAY_LOG"; exit 1; }
told "$shots/four.shim" action=copy format=png || exit 1
escape_until viewer_gone || { echo "Escape did not close the editor"; exit 1; }

expect_alive "compositor died during the screenshot actions"
echo "OK: each action and format reaches the editor, save without a window, copy with one"
