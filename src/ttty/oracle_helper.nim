## Child helper for the x11 oracle. Runs INSIDE xterm as its `-e` command
## and owns the tty, so it is the only process that can query xterm in-band.
##
## Two modes:
##
## Replay mode (default): renders byte-streams the parent feeds it.
##   cmd_feed   raw bytes -> write verbatim to the tty (xterm renders them)
##
## Supervisor mode (TTTY_ORACLE_RUN set): spawn that command as a sub-child
## sharing this tty, and forward input to it. Used to run a REAL interactive
## program (e.g. the 3code stub) inside the oracle while still being able to
## query xterm. Input typed via XTEST lands on this tty; the supervisor
## passes it to the sub-child's stdin (which is the same tty), so it just
## stays out of the way and only acts on command files.
##
## Common commands:
##   cmd_query  -> issue CSI 6 n, write xterm's answer to cursor.txt
##   cmd_screen -> issue CSI 0 i (print screen); xterm pipes its rendered
##                 screen text to printerCommand (a `cat > screen.txt`).
## After each action the helper writes `done` so the parent can synchronize.

import std/[os, posix, termios, strutils]

proc main() =
  let dir = getEnv("TTTY_ORACLE_DIR")
  if dir.len == 0: quit("TTTY_ORACLE_DIR not set", 2)
  let cmdFeed = dir / "cmd_feed"
  let cmdQuery = dir / "cmd_query"
  let cmdScreen = dir / "cmd_screen"
  let doneF = dir / "done"
  let cursorF = dir / "cursor.txt"
  let screenF = dir / "screen.txt"

  # Supervisor mode: spawn the real program as a sub-child on this tty.
  let runCmd = getEnv("TTTY_ORACLE_RUN")
  var childPid: Pid = 0
  if runCmd.len > 0:
    childPid = fork()
    if childPid == 0:
      # Replace this process image's child with the real program. It
      # inherits our tty as stdin/stdout/stderr, so xterm renders it and
      # XTEST keystrokes reach it directly.
      var args = [cstring "/bin/sh", "-c", cstring(runCmd), nil]
      discard execvp("/bin/sh", cast[cstringArray](args[0].addr))
      quit(127)
    # Parent (supervisor) falls through to the command loop, only servicing
    # query/screen requests. It must NOT read stdin (that's the child's).

  proc query(): string =
    var orig: Termios
    discard tcGetAttr(0, addr orig)
    var raw = orig
    raw.c_lflag = raw.c_lflag and not Cflag(ICANON or ECHO)
    raw.c_cc[VMIN] = 0.char
    raw.c_cc[VTIME] = 0.char
    discard tcSetAttr(0, TCSANOW, addr raw)
    try:
      discard posix.write(1, cstring("\x1b[6n"), 4)
      var buf = newString(64)
      var total = 0
      var waited = 0
      while waited < 1500:
        var pfd: TPollfd
        pfd.fd = 0
        pfd.events = POLLIN
        let r = poll(addr pfd, 1.Tnfds, 50.cint)
        waited += 50
        if r > 0 and (pfd.revents and POLLIN) != 0:
          let n = posix.read(0, addr buf[total], buf.len - total)
          if n > 0:
            total += n
            if total >= 4 and buf[total - 1] == 'R': break
            else: break
      result = buf[0 ..< total]
    finally:
      discard tcSetAttr(0, TCSANOW, addr orig)

  while true:
    if fileExists(cmdFeed) and runCmd.len == 0:
      let bytes = readFile(cmdFeed)
      removeFile(cmdFeed)
      if bytes.len > 0:
        discard posix.write(1, cstring(bytes), bytes.len)
      writeFile(doneF, "feed")
    elif fileExists(cmdQuery):
      removeFile(cmdQuery)
      writeFile(cursorF, query())
      writeFile(doneF, "query")
    elif fileExists(cmdScreen):
      removeFile(cmdScreen)
      removeFile(screenF)
      discard posix.write(1, cstring("\x1b[0i"), 4)
      var waited = 0
      while waited < 3000 and not fileExists(screenF):
        sleep(30)
        waited += 30
      writeFile(doneF, "screen")
    else:
      sleep(20)

main()
