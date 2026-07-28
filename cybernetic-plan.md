# ttty ground-truth grounding via real xterm

## Context

ttty is a ~580-line in-memory ANSI VT grid (`src/ttty/grid.nim`) used as the
screen model for 3code's PTY test harness (`tests/tty_expect.nim` in
~/p/3code). It has a structural blind spot the user hit as two real bugs:
ttty interprets bytes with the *same row/cursor model* the app uses to emit
them, so a model-vs-physical desync (walk-up off by one, wrap disagreement)
is invisible in ttty's captured frames — the erase lands in scrollback and
ttty applies the identical wrong assumption, so frames look perfect.

Observed in a real xterm: 3code's prompt-only commit path under-walks by one
row, so the prompt drifts down one row per `:provider` command (confirmed via
a DSR `CSI 6 n` probe: absolute cursor row climbed 12 → 17 → 23 across three
identical commands, +1 unaccounted each time). ttty showed no such drift.

Goal: ground ttty against a REAL terminal (xterm on Xvfb, driven via the
`x11` Nim package) so ttty's grid is validated against ground truth across
many sequences. We compare TEXT + CURSOR + INK/BLANK structure only —
we explicitly do NOT decode fonts, colors, or SGR appearance from pixels
(SGR attr values stay ttty-internal assertions). Conformance inputs are REAL
byte streams captured from 3code's tty tests (`s.raw` in tty_expect.nim),
replayed through both ttty and the xterm oracle, asserting agreement.

Verified ground-truth channels (proven working this session):
- xterm answers `CSI 6 n` → `ESC[<row>;<col>R` (cursor, 1-based)
- xterm answers `CSI 18 t` → `ESC[8;<rows>;<cols>t` (screen size in cells)
- xterm answers `CSI 14 t` → `ESC[4;<h>;<w>t` (text area in pixels); needs
  `-xrm 'xterm*allowWindowOps: true'`. Confirmed 80x24 → 480x312 px → cell = 6x13 px.
- The child running INSIDE xterm (as `xterm -e <child>`) owns the tty and can
  issue these queries itself, reading replies on its stdin in raw mode.
- Keystrokes injectable from outside via XTEST (`xdotool` or x11 pkg
  `XTestFakeKeyEvent`); pixels readable via `XGetImage`.
- Xvfb: `Xvfb :99 -screen 0 1024x768x24`. Headless, CI-friendly.

The x11 Nim package (~/.nimble/pkgs2/x11-1.2-...) exports: XOpenDisplay,
XDefaultRootWindow, XQueryTree, XGetWindowAttributes, XGetImage, XGetPixel,
XTestFakeKeyEvent, XStringToKeysym, XKeysymToKeycode, XWarpPointer, XSync/XFlush.

Corpus source: ~/p/3code tests write `frames.txt.raw` per tty test
(probe_linebugs, probe_resume_bar, slurp_resize, spinner_race, etc.). These
are the real sequences (walk-ups `CSI n A`, erases `CSI J/K`, footers,
spinners, CR/LF) 3code emits. We replay them.

## Architecture (decided)

- `src/ttty/x11oracle.nim` — spawn Xvfb + xterm running a child shim; the
  shim owns the tty and can query xterm in-band. Oracle ops:
    feed(bytes)   -> shim writes bytes to its own tty (xterm renders)
    cursor()      -> CSI 6 n -> (row, col) 1-based
    geometry()    -> CSI 18 t / 14 t -> cells + pixel cell size
    inkCells()    -> XGetImage / cell size -> per-cell ink bitmap
    typeKeys(s)   -> XTEST keystrokes (only where real input needed)
  Communication parent<->shim: simplest robust channel (shim reads a command
  FIFO/file, writes replies to a result FIFO/file, OR shim speaks a tiny
  line protocol on a socket). Chosen below after first spike.
- `src/ttty/conformance.nim` — replay a corpus stream into both a ttty Grid
  and the oracle; assert text-per-row (where decodable), cursor row/col,
  ink/blank map. Report first divergence with full context.
- Byte-replay for the corpus (fast, deterministic). A thin XTEST
  keystroke-driven end-to-end layer for real 3code binary later.
- Most 3code tests stay in ttty for speed; the xterm rig is the oracle for
  conformance + a few integration tests.

## Current state

Step 1 spike GREEN (tools/spike_oracle.nim). Proven from one Nim process,
fully headless: posix fork/exec (NOT execCmdEx — it hangs in this shell
environment, use fork/setsid/execvp + putEnv) launches Xvfb :93 and xterm
(80x24). XQueryTree finds the xterm window (title is the child cmd name,
e.g. "bash"); XGetWindowAttributes 484x316 px = 80x24 cells at exactly 6x13
px/cell; XGetImage reads real pixels (non-black count confirms content).
Comms channel decision: parent<->child is fork/exec + child writes reply
FILES (geom/cursor); xterm in-band queries (CSI 6 n cursor, 14t/18t size)
work when the child owns the tty and reads its own stdin in raw mode (a Nim
helper, mirroring 3code's terminaldbg probe — bash /dev/tty read is flaky).
Keystroke injection: XTEST XTestFakeKeyEvent with XKeysymToKeycode.

Next: Step 2 — package into src/ttty/x11oracle.nim with a clean API and a
Nim child helper (not bash) that answers cursor/geometry queries from stdin.

## Steps

- [x] 1. Oracle spike GREEN. fork/exec Xvfb+xterm; XQueryTree window find;
      XGetImage pixel readback at 6x13 px/cell. Channel = fork/exec + child
  writes reply files; xterm queries via a Nim child helper on its own stdin.
  execCmdEx hangs here — always posix fork/exec. See Current state.
- [ ] 2. `src/ttty/x11oracle.nim`: package the spike into a clean Nim API
      (start/stop, feed, cursor, geometry, inkCells, typeKeys). Manage Xvfb
  lifecycle (pick free display, kill on close). No test wiring yet.
- [ ] 3. Screen reader: decode `XGetImage` pixels -> per-cell ink bitmap using
      queried cell geometry; expose `inkAt(r,c)` and `inkRows()`. Add glyph
  -> text decoding ONLY if cheap via a fixed-font atlas; otherwise assert
  ink/cursor and keep text assertions in ttty. Decide in-code.
- [ ] 4. `src/ttty/conformance.nim`: comparator that feeds one byte stream to
      ttty Grid + oracle and asserts agreement (cursor + ink + text where
  available). Clear divergence reporting (row, expected vs actual).
- [ ] 5. Harvest corpus: collect real `.raw` streams from ~/p/3code tty tests
      into `tests/corpus/` with a small manifest (name + source scenario).
  Include the prompt-only `:provider` sequence (the drift repro).
- [ ] 6. Conformance suite `tests/test_x11_conformance.nim`: replay every
      corpus stream, assert ttty == oracle. Self-skip cleanly when Xvfb/xterm
  absent (CI gate via env). Expect initial FAILURES where ttty diverges.
- [ ] 7. Fix ttty grid bugs the oracle exposes (each a focused fix + keep the
      conformance test green). Record each divergence + root cause here.
- [ ] 8. 3code end-to-end integration test: drive the real stub binary through
      the oracle across its visual features (fresh prompt, :provider, a
  streamed turn, resume-with-bar), incl. the prompt-only drift repro.
- [ ] 9. Fix the 3code prompt-only under-walk bug (oracle red -> green).
- [ ] 10. Full verification: ttty suite + 3code tty suite green; release build.
      Cut ttty release (bump version, tag, push) per ~/p/.agents/release.md.
