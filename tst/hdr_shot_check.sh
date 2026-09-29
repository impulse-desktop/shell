# A check of the capture the compositor handed over against two captures of
# the output taken around it: only pixels equal in both count, the rest of
# the desktop may have moved on. The stand-in editor writes the capture's
# pixels as a P6, code values as they were read back, SDR or PQ alike, so a
# stable pixel must equal the output's own capture within <tolerance>.
capture_frame_check() { # <capture.ppm> <before.ppm> <after.ppm> <tolerance>
    python3 - "$@" <<'PY'
import sys

def load_ppm(path):
    with open(path, 'rb') as f:
        assert f.readline().strip() == b'P6'
        w, h = map(int, f.readline().split())
        f.readline()
        return w, h, f.read(w * h * 3)

cw, ch, capture = load_ppm(sys.argv[1])
w, h, before = load_ppm(sys.argv[2])
_, _, after = load_ppm(sys.argv[3])
tolerance = int(sys.argv[4])
assert (cw, ch) == (w, h), f"capture {cw}x{ch} is not the {w}x{h} output"
stable = [i for i in range(0, w * h * 3, 3 * 11) if before[i:i + 3] == after[i:i + 3]]
same = sum(1 for i in stable if all(abs(capture[i + c] - before[i + c]) <= tolerance for c in range(3)))
print(f"stable samples={len(stable)} same={same}")
assert len(stable) >= 1000 and same >= len(stable) * .95, "the capture is not the output's frame"
PY
}
