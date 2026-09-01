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
  TerminalKind* = enum
    termXterm  ## xterm -e helper (DSR + Media Copy); needs /dev/tty
    termSt     ## st -e helper (DSR; screen via X11 pixels); openpty-only

  Oracle* = ref object
    display*: string
    dpy: PDisplay
    xvfbPid: Pid
    xtermPid: Pid
    wmPid: Pid
    win: Window
    dir: string
    cols*, rows*: int
    cellW*, cellH*: int
    term*: TerminalKind
    started: bool

proc oracleAvailable*(): bool =
  ## True when the tools the oracle needs are present. Used to self-skip
  ## conformance tests on machines/CI without an X stack. Either xterm or st
  ## suffices: both run the helper as their foreground program and answer DSR.
  when defined(posix):
    result = findExe("Xvfb").len > 0 and
      (findExe("xterm").len > 0 or findExe("st").len > 0)
  else:
    result = false

# --- low-level helpers ------------------------------------------------------

proc freeDisplay(): string =
  ## A display number is free when neither its lock file nor its socket
  ## exists. A crashed Xvfb leaves the lock behind (false busy); a running
  ## one has the socket even if the lock was removed (false free). Check
  ## both so we never reuse a live display's number nor skip a reusable one.
  for n in 90 ..< 100:
    let d = ":" & $n
    if not fileExists("/tmp/.X" & $n & "-lock") and
       not fileExists("/tmp/.X11-unix/X" & $n):
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

proc windowTitleMatches(d: PDisplay; w: Window; target: string): bool =
  var nm: cstring
  if XFetchName(d, w, addr nm) != 0 and nm != nil:
    let s = $nm
    discard XFree(nm)
    return target in s
  false

proc windowClassMatches(d: PDisplay; w: Window; cls: string): bool =
  let hint = XAllocClassHint()
  if hint == nil: return false
  defer:
    if hint.res_name != nil: discard XFree(hint.res_name)
    if hint.res_class != nil: discard XFree(hint.res_class)
    discard XFree(hint)
  if XGetClassHint(d, w, hint) == 0 or hint.res_class == nil:
    return false
  $hint.res_class == cls

proc findWindow(d: PDisplay; root: Window;
                match: proc(d: PDisplay; w: Window): bool): Window =
  ## Depth-first walk of the window tree. A window manager reparents client
  ## windows under its own frame windows, so a flat root-children scan misses
  ## the terminal: the WM frame is the root child, the terminal is its child.
  if match(d, root):
    return root
  var rr, par: Window
  var kids: PWindow
  var n: cuint
  if XQueryTree(d, root, addr rr, addr par, addr kids, addr n) == 0:
    return 0
  defer:
    if kids != nil: discard XFree(kids)
  let arr = cast[ptr UncheckedArray[Window]](kids)
  for i in 0 ..< n.int:
    let w = findWindow(d, arr[i], match)
    if w != 0:
      return w
  0

proc findWindowByTitle(d: PDisplay; root: Window; target: string): Window =
  findWindow(d, root, proc(d: PDisplay; w: Window): bool =
    windowTitleMatches(d, w, target))

proc findWindowByClass(d: PDisplay; root: Window; cls: string): Window =
  findWindow(d, root, proc(d: PDisplay; w: Window): bool =
    windowClassMatches(d, w, cls))

proc waitForWindow(d: PDisplay; title: string; timeoutMs: int): Window =
  let root = XDefaultRootWindow(d)
  let deadline = epochTime() + timeoutMs / 1000
  while epochTime() < deadline:
    let w = findWindowByTitle(d, root, title)
    if w != 0: return w
    sleep 100
  0

proc waitForWindowClass(d: PDisplay; cls: string; timeoutMs: int): Window =
  let root = XDefaultRootWindow(d)
  let deadline = epochTime() + timeoutMs / 1000
  while epochTime() < deadline:
    let w = findWindowByClass(d, root, cls)
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

proc swallowXError(d: PDisplay; ev: PXErrorEvent): cint {.cdecl.} =
  ## xterm can map a window and then die (sandbox denies its pty setup). The
  ## oracle then queries a stale window id, and Xlib's default error handler
  ## kills the process. Swallow errors instead: a dead window just yields no
  ## reply, which the helper-liveness probe already treats as "reject xterm".
  0

proc waitDone(o: Oracle; timeoutMs = 8000)

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
  # A window manager is needed for st's window to composite its rendered
  # pixels under Xvfb (bare Xvfb leaves XGetImage reading an unmapped black
  # window). Best-effort: harmless if a WM is already running or none exists.
  if findExe("openbox").len > 0:
    result.wmPid = spawnDetached(["openbox"], @[("DISPLAY", result.display)])
  result.dpy = XOpenDisplay(result.display.cstring)
  doAssert result.dpy != nil, "cannot open display " & result.display
  discard XSetErrorHandler(swallowXError)

  let geom = $cols & "x" & $rows
  var xenv = @[("DISPLAY", result.display),
               ("TTTY_ORACLE_DIR", result.dir)]
  for (k, v) in runEnv:
    xenv.add (k, v)
  if run.len > 0:
    xenv.add ("TTTY_ORACLE_RUN", run)

  # The printer command turns xterm's Media Copy (CSI 0 i) into an exact
  # text dump of the rendered screen. printAttributes:0 keeps it plain text
  # (no SGR reconstruction escapes).
  let printCmd = "cat > " & (result.dir / "screen.txt")

  # Prefer xterm (`-e` helper, DSR + Media Copy). Where a sandbox denies
  # xterm's internal pty setup (`open ttydev`), xterm exits before mapping a
  # window; fall back to st, which allocates its pty via openpty (allowed)
  # and still runs the helper as its foreground program + answers DSR. st
  # has no Media Copy, so screenText reads its window back via X11 pixels.
  var win: Window = 0
  if findExe("xterm").len > 0:
    result.term = termXterm
    result.xtermPid = spawnDetached(
      ["xterm", "-xrm", "xterm*allowWindowOps: true",
       "-xrm", "xterm*printerCommand: " & printCmd,
       "-xrm", "xterm*printAttributes: 0",
       "-geometry", geom, "-e", helperBin],
      xenv)
    win = waitForWindow(result.dpy, "oracle_helper", 6000)
    # xterm can map a window yet never become usable: its internal pty
    # setup (`-e` needs a pty pair, and it opens /dev/tty) is denied by
    # sandboxes, so it renders nothing and answers no DSR. Probe with a real
    # cursor query and require a well-formed reply; an empty/absent answer
    # means xterm is dead-in-the-water, so fall through to st.
    if win != 0:
      # Probe by RENDERING then querying: xterm's helper can ack a bare
      # query yet be unable to feed xterm's pty (the sandbox lets xterm map
      # a window but blocks the pty it needs to render), so a query alone
      # passes falsely. Render a marker (moves the cursor off home) and
      # require the DSR to reflect it; a dead renderer stays at home.
      writeFile(result.dir / "cmd_feed", "\x1b[999C")
      var fed = true
      try:
        waitDone(result, 3000)
      except IOError:
        fed = false
      sleep 300
      var probed = (0, 0)
      if fed:
        writeFile(result.dir / "cmd_query", "")
        try:
          waitDone(result, 3000)
          let cursorF = result.dir / "cursor.txt"
          let reply = if fileExists(cursorF): readFile(cursorF) else: ""
          if reply.len >= 4 and reply[0] == '\x1b' and reply[^1] == 'R':
            let body = reply[2 ..< ^1]
            let semi = body.find(';')
            if semi > 0:
              let rr = try: parseInt(body[0 ..< semi]) except CatchableError: 0
              let cc = try: parseInt(body[semi + 1 .. ^1]) except CatchableError: 0
              probed = (max(0, rr - 1), max(0, cc - 1))
        except IOError:
          probed = (0, 0)
      if probed == (0, 0):
        win = 0
      # Clean up the probe: home the cursor and drop the probe's cursor.txt
      # so the first real cursor() call is not confused by probe leftovers.
      writeFile(result.dir / "cmd_feed", "\x1b[H")
      try: waitDone(result, 2000) except IOError: discard
      removeFile(result.dir / "cursor.txt")
    if win == 0:
      if result.xtermPid > 0:
        discard kill(result.xtermPid, 15)
        result.xtermPid = 0
  if win == 0 and findExe("st").len > 0:
    result.term = termSt
    result.xtermPid = spawnDetached(
      ["st", "-g", geom, "-e", helperBin],
      xenv)
    # st titles its window after the `-e` command path (not a stable
    # string), so match its WM_CLASS ("st-256color" here, "st" elsewhere).
    win = waitForWindowClass(result.dpy, "st-256color", 4000)
    if win == 0:
      win = waitForWindowClass(result.dpy, "st", 4000)
    when defined(debugOracle):
      stderr.writeLine "st window search result=", win.int
  doAssert win != 0, "terminal window never mapped"
  result.win = win
  when defined(debugOracle):
    stderr.writeLine "oracle terminal=", result.term, " win=", win.int,
      " pid=", result.xtermPid.int

  # Cell geometry: measure window pixel size vs known grid. We confirm by
  # reading window attributes.
  var att: XWindowAttributes
  discard XGetWindowAttributes(result.dpy, result.win, addr att)
  result.cellW = max(1, att.width.int div cols)
  result.cellH = max(1, att.height.int div rows)
  result.started = true
  # The terminal maps its window before the helper is up and reading command
  # files. Feeding or querying in that window loses bytes (the first DSR is
  # answered from the home position or dropped). Wait for the helper's
  # `ready` marker so the first feed/query lands in a live terminal.
  let readyF = result.dir / "ready"
  let deadline = epochTime() + 8.0
  while not fileExists(readyF) and epochTime() < deadline:
    sleep 50

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
  ## Render raw bytes through the real terminal (its child writes them to
  ## the tty). Synchronous: returns once the terminal has been handed the
  ## bytes. Replay mode only; in run mode the program owns the tty. st
  ## answers DSR/Media-Copy-style queries only after it has drained the feed
  ## burst from its pty input queue, so settle briefly here — otherwise the
  ## very next `cursor()`/`screenText()` races the drain and reads nothing.
  writeFile(o.dir / "cmd_feed", bytes)
  o.waitDone()
  # st answers DSR only after draining the feed burst from its pty input
  # queue; the first query issued too soon is consumed mid-drain and lost.
  # Settle long enough for the drain to finish so the next query lands.
  sleep 600

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

proc needsShift(ch: char): bool =
  ## Characters produced by holding Shift on a US layout. `XKeysymToKeycode`
  ## maps the shifted keysym to the base key, so we must hold Shift
  ## ourselves or xterm receives the unshifted char (`:` arrives as `;`).
  ch in {'A'..'Z'} or ch in {'!', '@', '#', '$', '%', '^', '&', '*', '(',
    ')', '_', '+', '{', '}', '|', ':', '"', '<', '>', '?', '~'}

proc typeKeys*(o: Oracle; text: string; delayMs = 25) =
  ## Inject real keystrokes into the xterm window via XTEST. In run mode
  ## these reach the supervised program as genuine keyboard input. Focuses
  ## the window first (see focusWindow). Holds Shift for shifted characters
  ## (see needsShift).
  o.focusWindow()
  let shiftKc = XKeysymToKeycode(o.dpy, XK_Shift_L)
  for ch in text:
    let kc = XKeysymToKeycode(o.dpy, keySymFor(ch))
    if kc == char(0): continue
    let shifted = needsShift(ch)
    if shifted:
      discard XTestFakeKeyEvent(o.dpy, shiftKc.cuint, 1.XBool, 0.culong)
    discard XTestFakeKeyEvent(o.dpy, kc.cuint, 1.XBool, 0.culong)
    discard XTestFakeKeyEvent(o.dpy, kc.cuint, 0.XBool, 0.culong)
    if shifted:
      discard XTestFakeKeyEvent(o.dpy, shiftKc.cuint, 0.XBool, 0.culong)
    discard XSync(o.dpy, 0.XBool)
    sleep delayMs

proc cursorOnce(o: Oracle): tuple[row, col: int] =
  writeFile(o.dir / "cmd_query", "")
  o.waitDone()
  let cursorF = o.dir / "cursor.txt"
  let reply = if fileExists(cursorF): readFile(cursorF) else: ""
  # reply shape: ESC [ row ; col R  (1-based)
  if reply.len >= 4 and reply[0] == '\x1b' and reply[1] == '[' and
     reply[^1] == 'R':
    let body = reply[2 ..< ^1]
    let semi = body.find(';')
    if semi > 0:
      let r = try: parseInt(body[0 ..< semi]) except CatchableError: 0
      let c = try: parseInt(body[semi + 1 .. ^1]) except CatchableError: 0
      return (max(0, r - 1), max(0, c - 1))
  (-1, -1)

proc cursor*(o: Oracle): tuple[row, col: int] =
  ## The terminal's real cursor position, 0-based, from its own DSR answer.
  ## st occasionally drops the first DSR right after a feed burst (its pty
  ## input queue is still draining), so retry a couple of times before
  ## declaring the cursor unknown.
  for _ in 0 ..< 5:
    let c = o.cursorOnce()
    if c.row >= 0:
      return c
    sleep 300
  (0, 0)

proc screenTextMediaCopy(o: Oracle): seq[string] =
  ## xterm path: exact rendered screen via Media Copy (CSI 0 i). xterm pipes
  ## the visible screen to its printerCommand, pointed at a file.
  writeFile(o.dir / "cmd_screen", "")
  o.waitDone()
  let raw = readFile(o.dir / "screen.txt")
  var lines = raw.split('\n')
  if lines.len > 0 and lines[^1].len == 0:
    lines.setLen(lines.len - 1)
  result = newSeq[string](o.rows)
  for r in 0 ..< o.rows:
    if r < lines.len:
      result[r] = lines[r].strip(leading = false, trailing = true)
    else:
      result[r] = ""

proc backgroundPixel(o: Oracle; img: PXImage): culong =
  ## The window's background pixel value: sample a corner, which no glyph
  ## reaches. Terminals clear to a uniform bg, so the corner pixel is bg.
  img.f.get_pixel(img, 0, 0)

proc inkRows*(o: Oracle): seq[seq[bool]] =
  ## Per-cell painted/blank map of the terminal window, read back as an X11
  ## image and divided by cell geometry. A cell is "ink" when any pixel in
  ## it differs from the background. This is OCR-free ground truth for
  ## occupancy — exactly what catches a row that was erased when it should
  ## not have been (the hint-loss desync). st path; xterm uses Media Copy.
  result = newSeq[seq[bool]](o.rows)
  for r in 0 ..< o.rows:
    result[r] = newSeq[bool](o.cols)
  var att: XWindowAttributes
  discard XGetWindowAttributes(o.dpy, o.win, addr att)
  let img = XGetImage(o.dpy, o.win, 0, 0, att.width.cuint, att.height.cuint,
                      XAllPlanes(), ZPixmap)
  if img == nil:
    return
  defer:
    if img.f.destroy_image != nil:
      discard img.f.destroy_image(img)
  let bg = o.backgroundPixel(img)
  let cw = o.cellW
  let ch = o.cellH
  for r in 0 ..< o.rows:
    for c in 0 ..< o.cols:
      let x0 = c * cw
      let y0 = r * ch
      var painted = false
      # Sample a small grid within the cell; a glyph lights some pixels.
      var yy = y0
      while yy < y0 + ch and yy < img.height.int and not painted:
        var xx = x0
        while xx < x0 + cw and xx < img.width.int:
          if img.f.get_pixel(img, xx.cint, yy.cint) != bg:
            painted = true
            break
          inc(xx, 2)
        inc(yy, 2)
      result[r][c] = painted

proc screenText*(o: Oracle): seq[string] =
  ## The terminal's rendered screen as text rows — the ground truth. xterm
  ## uses Media Copy (CSI 0 i, no pixel decoding), giving exact text. st has
  ## no Media Copy, so we read its window back as an X11 ink map and report
  ## each row as '#' per painted cell: occupancy ground truth, which is what
  ## catches an erased-when-it-should-stay row (the hint-loss desync class).
  ## Rows are right-trimmed; the sequence has exactly `rows` entries.
  if o.term == termXterm:
    return screenTextMediaCopy(o)
  result = newSeq[string](o.rows)
  let ink = o.inkRows()
  for r in 0 ..< o.rows:
    var line = ""
    for c in 0 ..< o.cols:
      line.add (if ink[r][c]: '#' else: ' ')
    result[r] = line.strip(leading = false, trailing = true)

proc stop*(o: Oracle) =
  if not o.started: return
  o.started = false
  # Close our display connection BEFORE killing the X server: killing Xvfb
  # first and then closing leaves Xlib to flush on a dead socket, which
  # prints a fatal XIO error on shutdown.
  if o.dpy != nil:
    discard XCloseDisplay(o.dpy)
    o.dpy = nil
  if o.xtermPid > 0: discard kill(o.xtermPid, 15)
  if o.wmPid > 0: discard kill(o.wmPid, 15)
  if o.xvfbPid > 0: discard kill(o.xvfbPid, 15)
  removeDir(o.dir)
