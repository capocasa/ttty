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

PIVOT (important): the ground-truth channel is xterm's MEDIA COPY text
dump, NOT XGetImage pixels. Pixel decoding was a fragile detour (block
cursor leaves ghost ink cells on move / artifacts on reveal; anti-alias
noise). Correct channel, verified working:
  - SCREEN TEXT: helper issues `CSI 0 i` (Media Copy, print screen). xterm
    is launched with `-xrm 'xterm*printerCommand: cat > <dir>/screen.txt'`
    and `-xrm 'xterm*printAttributes: 0'`. xterm pipes its EXACT rendered
    screen as plain text (rows space-padded, right-trim on read). This is
    the self-concealment-proof ground truth. NOTE: `CSI ? 15 i` is printer
    STATUS, not print — print is `CSI 0 i`. Media Copy only works in
    xterm/mlterm, fine since we drive real xterm.
  - CURSOR: helper issues `CSI 6 n`, reads xterm's `ESC[r;cR` on its own
    stdin in raw mode (mirrors 3code terminaldbg probe). Exact.
Ghostty's own xterm audit (issue #632) is behavioral unit tests with
hand-verified expected state, NOT a live oracle — our live-oracle compare
is stronger. ttty models the same state ghostty asserts, so this maps 1:1.

DONE + working (compiled clean, run green):
  - src/ttty/x11oracle.nim: startOracle/feed/cursor/screenText/stop +
    oracleAvailable. Cursor + screenText verified: feed "hello world\\r\\n
    second line\\r\\n" -> row0='hello world' row1='second line' row2='',
    cursor=(2,0). helper = prebuilt build/oracle_helper (fork/exec; child
    owns tty; cmd files cmd_feed/cmd_query/cmd_screen; `done` sync file).
  - src/ttty/conformance.nim: compareToOracle(bytes) asserts ttty Grid ==
    oracle on cursor AND per-row screen text (rowText vs screenText).
Process notes: execCmdEx/execShellCmd HANG in this shell — always posix
fork/exec (spawnDetached in x11oracle). Build helper via direct
`nim c -o:build/oracle_helper src/ttty/oracle_helper.nim`. Test binaries
go in build/ (gitignored). x11 nimble pkg path via `nimble path x11`.
Committed: 90fea5c (oracle) + c091a45 (gitignore). Media-copy pivot NOT yet
committed (conformance.nim rewritten for text; test_conformance tool needs
rebuild + rerun; old pixel procs cellDiffCounts/inkRows/ink REMOVED).

STEPS 4-6 GREEN, committed (3ccc72d conformance+media-copy, 7e934cb corpus
suite). tools/test_conformance: 10/10 sequences conform (plain, CR/LF, CR
overwrite, cursor-up edit, EL, ED, walk-up erase, CUP, ICH, DCH).
tests/test_x11_conformance.nim: all 6 real 3code corpus streams replayed
through ttty AND fresh real xterm at 120x40 -> all conform. KEY LESSON:
use a FRESH oracle per corpus stream (a shared xterm carries scroll state
and produces false cursor divergences, e.g. leftover row-39 scroll).
Existing test_grid suite still green. ttty had NO bugs on these streams —
the model matches xterm. The 3code prompt-only drift bug is in 3code's
walk-up MATH (what it emits), not in ttty's model, so ttty conformance
passes while 3code still drifts on a real terminal. That is Step 9.

CORPUS: tests/corpus/*.raw harvested from ~/p/3code/linebugs tty test
captures (120x40, DefaultTtyCols/Rows). welcome_minimal, provider_typing
_a/_b/_c, provider_stream_turn, resume_bar.

STEP 8 DONE (committed 61eafa8): 3code prompt-only drift REPRODUCED on
real xterm via oracle supervisor mode. tools/test_3code_drift.nim drives
the real 3code stub (build/3code_stub, -d:ssl -d:providerStub --threads:on)
inside the oracle, types `:provider stub` x4 via XTEST, reads xterm screen
(media-copy) after each: last-content row climbs 16 -> 18 -> 19 -> 20 =
prompt creeping DOWN ~1 row/command. This is the user's Bug 2, confirmed
against ground truth (invisible in ttty).

New oracle capabilities (src/ttty/x11oracle.nim):
  - startOracle(..., run = "<cmd>", runEnv = [(k,v)]): supervisor mode.
    helper (oracle_helper.nim) forks the cmd as a sub-child sharing the
    tty; xterm renders the REAL program, XTEST keystrokes reach it.
  - typeKeys(text, delayMs): XTEST keystroke injection. CRITICAL: must
    focusWindow() first (XSetInputFocus RevertToParent) — bare Xvfb has no
    WM so nothing is focused by default and keystrokes vanish silently.
  - screenText() + cursor() work in run mode too (helper services cmd
    files; it must NOT read stdin in supervisor mode — the program owns it).

Known side observation: after the first :provider, subsequent typed input
partially desyncs (a `:` shows as `;` on screen) — consistent with the
walk-up model being off after the first commit, exactly the bug. Do NOT
treat as a test artifact.

STEP 7 (ttty bugs): none found — ttty conforms on all 6 corpus streams +
10 synthetic sequences. ttty's model is correct; the drift is a 3code
walk-up MATH bug (what it emits), not a ttty model bug.

Next: Step 9 — fix the 3code prompt-only drift. The off-by-one: on a fresh
prompt-only commit, 3code's walk-up under-counts by one row (likely the
prompt-only CSI 2K-without-CSI-J path leaves the caret one row low, or the
commit's erase doesn't reclaim the prompt row), so each commit parks the
next prompt one row down. Fix in ~/p/3code (engine.nim appendTranscript
prompt-only path / fatprompt commitTranscriptBytes), then re-run
tools/test_3code_drift -> expect rows stable (no net drift). Rebuild stub
after the fix (nim c -d:ssl -d:providerStub --threads:on --path:src
-o:build/3code_stub src/threecode.nim). Then Step 10 verify + ttty release.

## Steps

- [x] 1. Oracle spike GREEN. fork/exec Xvfb+xterm; XQueryTree window find;
      XGetImage pixel readback at 6x13 px/cell. Channel = fork/exec + child
  writes reply files; xterm queries via a Nim child helper on its own stdin.
  execCmdEx hangs here — always posix fork/exec. See Current state.
- [x] 2. `src/ttty/x11oracle.nim` DONE: startOracle(cols,rows)/feed/cursor/
      inkRows/stop + oracleAvailable. Child helper is a prebuilt binary
  (src/ttty/oracle_helper.nim -> build/oracle_helper), fork/exec Xvfb+xterm,
  window found via XQueryTree title "oracle_helper". Cursor via helper
  reading its own stdin DSR (exact, matches model). Committed 90fea5c.
- [x] 3. Screen reader DONE: XGetImage / 6x13 cell -> per-cell ink map.
      Background calibrated from pixel (0,0); a cell has ink when >=3 sampled
  pixels differ from bg. Block cursor counts as ink at its cell (correct —
  cursor query reports it; hide cursor via DECTCEM when only glyph ink is
  wanted). tools/test_oracle.nim GREEN: 'hello'->cursor(0,5), ink cols0-4;
  '\\r\\nworld'->cursor(1,5). No glyph->text decode (per user: ignore fonts/
  pixels-as-appearance; text stays in ttty). Committed 90fea5c.
- [ ] 4. `src/ttty/conformance.nim`: comparator feeding one byte stream to
      ttty Grid + oracle, asserting cursor + ink agreement. Key mapping:
  ttty cell (r,c) has text iff oracle ink(r,c), EXCLUDING the cursor cell
  (oracle paints block cursor there; hide it via DECTCEM prefix during
  replay so ink == text exactly). Compare row text too. Report first
  divergence with full context.
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
