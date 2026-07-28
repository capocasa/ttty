## Headless real-terminal oracle.
##
## Runs a REAL xterm on a private Xvfb display and reads back ground truth
## that ttty's in-memory model cannot fake:
##   - cursor position (row/col) via xterm's own DSR `CSI 6 n` answer
##   - per-cell ink/blank map via `XGetImage` pixels divided by cell size
##
## The point: ttty's `Grid` interprets a byte stream with the same model an
## app uses to emit it, so a model-vs-physical desync is self-concealing.
## xterm is an independent renderer; comparing ttty against what xterm
## actually drew exposes the desync.
##
## Shape (byte-replay, deterministic):
##   oracle = startOracle(cols=80, rows=24)
##   oracle.feed(bytes)          # bytes rendered by real xterm
##   oracle.cursor()             # (row, col) 0-based, from xterm itself
##   oracle.ink(r, c)            # did xterm paint anything in cell r,c?
##   oracle.inkRows()            # full bitmap
##   oracle.stop()
##
## Environment: needs Xvfb + xterm + the x11 Nim package (link -lX11 -lXtst).
## Processes are spawned with posix fork/exec (execCmdEx is unusable in some
## shells). A small Nim helper runs as xterm's child, owns the tty, and
## answers queries by writing reply files the parent reads.

import std/[os, posix, strutils, syncio, envvars, times]
import x11/xlib, x11/x, x11/xutil, x11/xtst, x11/keysym

const
  DefaultCellW = 6
  DefaultCellH = 13

type
  Oracle* = ref object
    display*: string
    dpy: PDisplay
    xvfbPid: Pid
    xtermPid: Pid
    win: Window
    dir: string
    cols*, rows*: int
    cellW*, cellH*: int
    started: bool

proc oracleAvailable*(): bool =
  ## True when the tools the oracle needs are present. Used to self-skip
  ## conformance tests on machines/CI without an X stack.
  when defined(posix):
    result = findExe("Xvfb").len > 0 and findExe("xterm").len > 0
  else:
    result = false

# --- low-level helpers ------------------------------------------------------

proc freeDisplay(): string =
  for n in 90 ..< 100:
    let d = ":" & $n
    if not fileExists("/tmp/.X" & $n & "-lock"):
      return d
  raise newException(IOError, "no free X display number")

proc spawnDetached(argv: openArray[string]; env: openArray[(string, string)]): Pid =
  let pid = fork()
  if pid == 0:
    discard setsid()
    for (k, v) in env: putEnv(k, v)
    var args: seq[cstring]
    for a in argv: args.add a.cstring
    args.add nil
    discard execvp(argv[0].cstring, cast[cstringArray](args[0].addr))
    quit(127)
  result = pid

proc findWindowByTitle(d: PDisplay; root: Window; target: string): Window =
  var rr, par: Window
  var kids: PWindow
  var n: cuint
  if XQueryTree(d, root, addr rr, addr par, addr kids, addr n) == 0:
    return 0
  defer:
    if kids != nil: discard XFree(kids)
  let arr = cast[ptr UncheckedArray[Window]](kids)
  for i in 0 ..< n.int:
    var nm: cstring
    if XFetchName(d, arr[i], addr nm) != 0 and nm != nil:
      let s = $nm
      discard XFree(nm)
      if target in s:
        return arr[i]
  0

proc waitForWindow(d: PDisplay; title: string; timeoutMs: int): Window =
  let root = XDefaultRootWindow(d)
  let deadline = epochTime() + timeoutMs / 1000
  while epochTime() < deadline:
    let w = findWindowByTitle(d, root, title)
    if w != 0: return w
    sleep 100
  0

# --- child helper (runs inside xterm) ---------------------------------------
##
## The helper owns xterm's tty. It renders byte-streams and answers cursor
## queries, driven by command files the parent drops in `dir`. It is a
## prebuilt binary (src/ttty/oracle_helper.nim -> build/oracle_helper);
## building it is a one-time setup step, NOT done at oracle-start because
## shelling out to the compiler from a headless process is unreliable.

proc findHelperBin(): string =
  ## Locate the prebuilt helper. Checked into build/ by the test setup.
  for cand in [getCurrentDir() / "build" / "oracle_helper",
               getAppDir() / "oracle_helper",
               getAppDir() / ".." / ".." / "build" / "oracle_helper"]:
    if fileExists(cand): return cand
  raise newException(IOError,
    "oracle helper binary not found; build it with: " &
    "nim c -o:build/oracle_helper src/ttty/oracle_helper.nim")

# --- public API ---------------------------------------------------------------

proc startOracle*(cols = 80, rows = 24; workDir = ""; run = "";
                 runEnv: openArray[(string, string)] = []): Oracle =
  ## Launch Xvfb + xterm running the helper child. Blocks until the xterm
  ## window is mapped and cell geometry is known.
  ##
  ## `run`: when non-empty, the helper spawns this command as a real
  ## interactive program on the tty (supervisor mode). Keystrokes injected
  ## via XTEST reach it directly; the helper still answers cursor/screen
  ## queries. Use this to drive a REAL program (e.g. 3code) inside the
  ## oracle. When empty, the helper is in replay mode (feed bytes via
  ## `feed`).
  result = Oracle(cols: cols, rows: rows)
  result.display = freeDisplay()
  result.dir = if workDir.len > 0: workDir
               else: getTempDir() / ("ttty_oracle_" & $getCurrentProcessId())
  createDir(result.dir)
  let helperBin = findHelperBin()

  result.xvfbPid = spawnDetached(
    ["Xvfb", result.display, "-screen", "0", "1024x768x24"], [])
  sleep 800
  result.dpy = XOpenDisplay(result.display.cstring)
  doAssert result.dpy != nil, "cannot open display " & result.display

  # The printer command turns xterm's Media Copy (CSI 0 i) into an exact
  # text dump of the rendered screen. printAttributes:0 keeps it plain text
  # (no SGR reconstruction escapes).
  let printCmd = "cat > " & (result.dir / "screen.txt")
  let geom = $cols & "x" & $rows
  var xenv = @[("DISPLAY", result.display),
               ("TTTY_ORACLE_DIR", result.dir)]
  for (k, v) in runEnv:
    xenv.add (k, v)
  if run.len > 0:
    xenv.add ("TTTY_ORACLE_RUN", run)
  result.xtermPid = spawnDetached(
    ["xterm", "-xrm", "xterm*allowWindowOps: true",
     "-xrm", "xterm*printerCommand: " & printCmd,
     "-xrm", "xterm*printAttributes: 0",
     "-geometry", geom, "-e", helperBin],
    xenv)

  result.win = waitForWindow(result.dpy, "oracle_helper", 8000)
  if result.win == 0:
    # title may be the full path; fall back to any mapped window
    result.win = waitForWindow(result.dpy, "oracle", 4000)
  doAssert result.win != 0, "xterm window never mapped"

  # Cell geometry: measure window pixel size vs known grid. Default xterm
  # uses a 6x13 fixed font; we confirm by reading window attributes.
  var att: XWindowAttributes
  discard XGetWindowAttributes(result.dpy, result.win, addr att)
  result.cellW = max(1, att.width.int div cols)
  result.cellH = max(1, att.height.int div rows)
  result.started = true

proc waitDone(o: Oracle; timeoutMs = 8000) =
  let doneF = o.dir / "done"
  let deadline = epochTime() + timeoutMs / 1000
  while epochTime() < deadline:
    if fileExists(doneF):
      removeFile(doneF)
      return
    sleep 15
  raise newException(IOError, "oracle helper did not acknowledge command")

proc feed*(o: Oracle; bytes: string) =
  ## Render raw bytes through the real xterm (its child writes them to the
  ## tty). Synchronous: returns once xterm has been handed the bytes.
  ## Replay mode only; in run mode the program owns the tty.
  writeFile(o.dir / "cmd_feed", bytes)
  o.waitDone()
  sleep 60  # let xterm actually paint before we capture

proc keySymFor(ch: char): KeySym =
  case ch
  of '\n', '\r': XK_Return
  of ' ': XK_space
  of ':': XK_colon
  of '.': XK_period
  of '/': XK_slash
  of '-': XK_minus
  of '_': XK_underscore
  else:
    if ch in {'a'..'z'}: KeySym(ord(ch))
    elif ch in {'A'..'Z'}: KeySym(ord(ch))
    elif ch in {'0'..'9'}: KeySym(ord(ch))
    else: XK_space

proc focusWindow(o: Oracle) =
  ## Give the xterm window keyboard focus. On a bare Xvfb with no window
  ## manager nothing is focused by default, and XTEST key events go to the
  ## focused window — so without this, injected keystrokes vanish.
  discard XSetInputFocus(o.dpy, o.win, RevertToParent, CurrentTime)
  discard XSync(o.dpy, 0.XBool)

proc typeKeys*(o: Oracle; text: string; delayMs = 25) =
  ## Inject real keystrokes into the xterm window via XTEST. In run mode
  ## these reach the supervised program as genuine keyboard input. Focuses
  ## the window first (see focusWindow).
  o.focusWindow()
  for ch in text:
    let kc = XKeysymToKeycode(o.dpy, keySymFor(ch))
    if kc == char(0): continue
    discard XTestFakeKeyEvent(o.dpy, kc.cuint, 1.XBool, 0.culong)
    discard XTestFakeKeyEvent(o.dpy, kc.cuint, 0.XBool, 0.culong)
    discard XSync(o.dpy, 0.XBool)
    sleep delayMs

proc cursor*(o: Oracle): tuple[row, col: int] =
  ## xterm's real cursor position, 0-based, from its own DSR answer.
  writeFile(o.dir / "cmd_query", "")
  o.waitDone()
  let reply = readFile(o.dir / "cursor.txt")
  # reply shape: ESC [ row ; col R  (1-based)
  if reply.len >= 4 and reply[0] == '\x1b' and reply[1] == '[' and
     reply[^1] == 'R':
    let body = reply[2 ..< ^1]
    let semi = body.find(';')
    if semi > 0:
      let r = try: parseInt(body[0 ..< semi]) except CatchableError: 0
      let c = try: parseInt(body[semi + 1 .. ^1]) except CatchableError: 0
      return (max(0, r - 1), max(0, c - 1))
  (0, 0)

proc screenText*(o: Oracle): seq[string] =
  ## xterm's exact rendered screen as text rows, via Media Copy (CSI 0 i):
  ## xterm pipes the visible screen to its printerCommand, which we point at
  ## a file. This is the ground truth — what xterm actually displays — with
  ## no pixel decoding. Rows are right-trimmed of trailing blanks; the
  ## sequence has exactly `rows` entries (blank rows as "").
  writeFile(o.dir / "cmd_screen", "")
  o.waitDone()
  let raw = readFile(o.dir / "screen.txt")
  var lines = raw.split('\n')
  # Drop a single trailing empty line from the file's final newline.
  if lines.len > 0 and lines[^1].len == 0:
    lines.setLen(lines.len - 1)
  # xterm pads each printed row to the full width with spaces and emits
  # `rows` lines; normalize: right-trim, then pad/truncate to `rows`.
  result = newSeq[string](o.rows)
  for r in 0 ..< o.rows:
    if r < lines.len:
      result[r] = lines[r].strip(leading = false, trailing = true)
    else:
      result[r] = ""

proc stop*(o: Oracle) =
  if not o.started: return
  o.started = false
  if o.dpy != nil:
    discard XCloseDisplay(o.dpy)
    o.dpy = nil
  if o.xtermPid > 0: discard kill(o.xtermPid, 15)
  if o.xvfbPid > 0: discard kill(o.xvfbPid, 15)
  removeDir(o.dir)
