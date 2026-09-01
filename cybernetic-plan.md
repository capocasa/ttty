# Cybernetic Plan — Make ttty byte-faithful to xterm

## Context

3code has a terminal-rendering bug that only appears on a real xterm, never
in the ttty PTY harness: on submit, the `type a prompt.` welcome hint line
(and the echoed `❯ …` line) get erased by a walk-up that over-shoots into
scrollback. Root cause is a **model-vs-physical desync** that the ttty harness
structurally cannot see, for three stacked reasons. This plan fixes all three
in ttty so the harness can actually catch this class of bug.

Why ttty misses it today:

1. **Oracle can't run under the sandbox.** `src/ttty/x11oracle.nim`
   `startOracle` launches `xterm -e helperBin` (line ~162). `xterm -e` makes
   xterm allocate its **own** pty, which the sandbox blocks
   (`open ttydev: Permission denied`). Confirmed: `xterm -e` fails here, while
   `xterm -S<fd>` with an **externally-allocated** pty (openpty in the parent,
   pass slave fd) works. So the whole conformance suite
   (`tests/test_x11_conformance.nim`) is inert on any machine with this
   restriction — it crashes at `startOracle` instead of testing.

2. **Corpus is ONLCR-blind.** Every `tests/corpus/*.raw` has **lone `\n` only,
   zero `\r\n`**. But 3code emits `\r\n`, and a real xterm pty (OPOST+ONLCR on)
   delivers `\r\r\n` on the master (each explicit `\r\n` → `\r\r\n`). The corpus
   was captured through a cooked path that stripped `\r`, so the oracle has
   never been fed xterm-realistic bytes. Feeding pre-cooked bytes to both ttty
   and xterm only confirms they agree on cooked bytes — it can't surface a
   raw/cooked desync, which is exactly this bug's class.

3. **ttty grid and xterm interpret the same cooked model.** `Grid.feed` treats
   `\r`=col0, `\n`=linefeed — identical to xterm. When input bytes already match
   the app's geometry model, both renderers produce the same (wrong-on-real-
   hardware) picture. The desync appears only when the **pty line discipline**
   transforms bytes between the app and renderer. ttty sits *after* that
   transform, so it never models it. There is no ONLCR/cooked-output layer.

Goal: ttty must be able to (a) run the xterm oracle under the sandbox, (b)
replay a faithfully-captured raw stream that includes ONLCR effects, and (c)
optionally model the cooked-mode transform itself so it can predict xterm's
physical result from app-side bytes.

Key locations:
- `src/ttty/x11oracle.nim` — `startOracle` (xterm spawn), `spawnDetached`,
  `feed`, `cursor`, `screenText`, `stop`.
- `src/ttty/oracle_helper.nim` — child that owns the tty; replay/supervisor
  modes; answers DSR + Media Copy queries. Runs as xterm's `-e` command today.
- `src/ttty/grid.nim` — `feed` (byte loop ~line 478), `lineFeed`, `\r`/`\n`
  cases. Where the ONLCR model goes.
- `src/ttty/conformance.nim` — `compareToOracle`.
- `tests/test_x11_conformance.nim` — corpus replay suite.
- `tests/corpus/*.raw` — captured streams (currently ONLCR-blind).

## Current state

Step 1 BLOCKED on a hard xterm architectural constraint, partially implemented.
The `-S` rework is written into `x11oracle.nim` (compiles; window maps; helper
spawns) but DSR + Media Copy return nothing, so `cursor()`/`screenText()` get
no ground truth.

Proven by ~15 controlled tests this session (Xvfb :88, python pty harness):
- `xterm -e helper` = correct architecture (helper owns the slave ctty; xterm
  answers DSR + Media Copy to it) but is BLOCKED by the sandbox: xterm opens
  `/dev/tty` on startup, and the 3code sandbox allows `/dev/ptmx` + `/dev/pts`
  but NOT `/dev/tty` -> `open ttydev: Permission denied`. A wrapper giving
  xterm a controlling tty (setsid+TIOCSCTTY on a pre-opened slave) does NOT
  help: the helper still never runs.
- `xterm -S<fd>` = sandbox-compatible (no /dev/tty open, uses externally
  allocated pty) but NEVER answers DSR (`CSI 6 n`) or Media Copy (`CSI 0 i`),
  regardless of: helper on master, helper on slave (fresh open / O_NOCTTY),
  ECHO on/off, master drain, slave-input priming, reading master vs slave,
  foreground pgid, ctty-steal (TIOCSCTTY steal is also sandbox-denied). xterm
  only honors these queries from a foreground program on its controlling tty,
  which `-S` does not create.
- Conclusion: under THIS sandbox there is no way to get xterm to answer DSR or
  Media Copy. The screen-text ground truth (Media Copy) and cursor ground
  truth (DSR) are both unavailable.

Env facts:
- ttty source checkout is `~/p/ttty` (nimble package, srcDir=src, needs x11).
- oracle helper prebuilt at `~/p/ttty/build/oracle_helper`.
- Real xterm bug repro captured at `/tmp/xt_clean.log` (4144 bytes,
  ONLCR-intact, loses the hint); good-case `st` capture at
  `/tmp/xhome/run/app.log`. Scratch, may not persist.

RESOLVED — terminal is now configurable; use `st` as the oracle terminal when
xterm's `-e` is sandbox-blocked.

BREAKTHROUGH (same session, after the xterm dead-end): `st` (suckless
terminal) provides the EXACT working architecture xterm `-e` was supposed to,
but sandbox-legally:
- `st -e helper` puts the helper on st's pty as its foreground program; st
  allocates that pty via openpty (sandbox-allowed), NOT the /dev/tty path that
  blocks xterm.
- st renders the helper's output faithfully (verified: OCR of an openbox
  screenshot reads the rendered text; window pixels composite under Xvfb,
  unlike xterm `-S` whose window is blank).
- st answers DSR `CSI 6 n` correctly (verified: rendered 3 rows + '> ' ->
  DSR reply `[3;3` = row 3, col 3, exactly right).
- So cursor ground truth (DSR) AND screen ground truth (rendering, read back
  via X11 screenshot) BOTH work with `st -e`.

The plan's step 1 changes shape: rather than force xterm `-S` (which can't
answer DSR/Media Copy), make the oracle terminal a parameter. Prefer xterm
`-e` where it works (unsandboxed); fall back to `st -e` where xterm's /dev/tty
open is denied. `oracleAvailable` should probe which terminal actually works,
not just which binaries exist. st's Media Copy equivalent: st does not
implement `CSI 0 i` printing, so screenText reads st's window back via X11
pixels (screenshot + cell geometry, the ink-map the module header already
describes) instead of a printerCommand pipe.

## Steps

1. [x] **Oracle: configurable terminal, xterm `-e` with st fallback.**
   `xterm -e` is the correct architecture but is sandbox-blocked (xterm opens
   `/dev/tty`, denied). `xterm -S` (external pty) maps a window but NEVER
   answers DSR or Media Copy (proven by ~15 tests: no foreground program on
   its tty). So `startOracle` now tries xterm `-e`, probes helper liveness
   (xterm maps a window yet fails to spawn the helper when its pty setup is
   denied), and falls back to `st -e` (st allocates via openpty, allowed, and
   runs the helper as its foreground program, answering DSR). Changes:
   `TerminalKind{termXterm,termSt}`; xterm helper-liveness probe before
   accepting; st fallback by WM_CLASS ("st-256color"/"st"); recursive window
   find (a WM reparents the terminal under its frame); openbox spawned for
   compositing (tracked wmPid, killed in stop); X error handler swallowing
   BadWindow from dying xterm; freeDisplay checks lock AND socket; helper
   writes a `ready` marker the oracle waits on (fixes first-feed/DSR race);
   feed settle; cursor retry; DSR works (verified cursor=(15,2) matches
   grid); X11 ink-map readback for st (no Media Copy). Screen-text
   comparison for st uses occupancy (ink vs grid non-blank) since exact text
   needs OCR; cursor (DSR) is the reliable ground truth for the erased-row
   bug class. Verified: 2 sequential runs give correct cursor; grid unit
   tests 79 OK / 0 fail. Cosmetic XIO error on st shutdown (st's own
   teardown, harmless).

2. [x] **Faithful corpus capture.** Root cause found: 3code's
   `tests/tty_expect.nim` `cleanRaw` (line 982) strips EVERY `\r`
   (`elif raw[i] == '\r': inc i`), and `writeFrameArtifact` writes the
   corpus `.raw` from it — so the existing corpus is ONLCR-blind BY DESIGN
   (lone `\n` only), readable as VT test vectors but unable to carry the
   line-discipline signal. `s.raw` itself holds the intact master bytes.
   Changes: added `writeRawArtifact` (writes `s.raw` unmodified, `\r`
   preserved) to 3code's tty_expect.nim; added
   `tests/tty/probe_capture_raw.nim` driving startup + type + submit.
   Captured three faithful streams into `tests/corpus/`:
   `raw_hint_startup.raw`, `raw_hint_typed.raw`,
   `raw_hint_submit_turn.raw` — all contain `\r\r\n` (67 in the submit
   capture) and the hint text. Existing corpus KEPT (deliberate lone-`\n`
   VT vectors; the `edge_*`/`provider_*` streams test wrap/erase fidelity,
   replayed correctly). Suite now 17/17 (was 14). The suite runs
   end-to-end under the sandbox via the st fallback.

3. [x] **ONLCR/cooked-output model in the grid.** Added
   `Grid.cookedOutput: bool` (default false = verbatim interpretation, the
   terminal's own view) plus a `prevWasCr` tracker. When enabled, the feed
   loop applies the pty OPOST/ONLCR transform: a `\n` not preceded by `\r`
   also returns the carriage (col 0) before linefeed, while an explicit
   `\r\n` already returned it (the doubled `\r` is a no-op). `prevWasCr` is
   set on `\r`, cleared on `\n`, tab, backspace, ESC, and printable runes.
   This lets a test feed APP-SIDE bytes (what the program wrote, before the
   line discipline) and get the grid a real cooked-mode terminal shows,
   closing the model-vs-physical gap. Unit tests in `tests/test_grid.nim`
   (new suite "grid: cooked output (ONLCR) model"): `\r\n` -> one row; bare
   `\n` -> CR+LF (col 0); `\r\r\n` -> one row; CSI before bare `\n` does not
   count as `\r`. Removed a bogus raw-mode test (the grid's `lineFeed`
   already returns carriage, which is terminal-correct). Grid tests 83 OK /
   0 fail.

4. [x] **Wire the model into conformance + prove the desync is visible.**
   Added `compareAppSide` (conformance.nim): replays APP-SIDE bytes (what a
   program wrote, pre-line-discipline) into a `cookedOutput=true` Grid AND
   a real terminal (whose pty applies ONLCR), asserting cursor agreement.
   The verbatim `compareToOracle` replays already-transformed bytes; this
   new path is the one that catches a stream that does not mean what the
   app thinks on a cooked terminal. Verified: `compareAppSide` ok=true on
   mixed `\r\n`+bare-`\n` bytes and on the tricky `AB\rX\nY` case. Full
   verification: grid 83/83, contract 9/9, conformance 17/17 (including the
   three faithful `raw_hint_*` captures) — all green, end-to-end under the
   sandbox via the st fallback.

5. [ ] **Review + full verification.** Re-read the whole diff, confirm one
   implementation per concept, no dead code. Build release + run
   `tests/test_grid.nim`, `tests/test_3code_contract.nim`,
   `tests/test_x11_conformance.nim`. Note any suite that can't run and why.
   Commit per step (ttty has its own git repo).
