## Child helper for the x11 oracle. Runs INSIDE xterm as its `-e` command,
## owns the tty, and is the only process that can query xterm in-band.
##
## Driven by command files the oracle parent drops in TTTY_ORACLE_DIR:
##   cmd_feed   raw bytes -> write verbatim to the tty (xterm renders them)
##   cmd_query  empty     -> issue CSI 6 n, write xterm's answer to cursor.txt
## After each action it writes `done` so the parent can synchronize.
##
## Built once into build/oracle_helper by the test/oracle setup, NOT compiled
## at oracle-start time (a shell-out to the compiler is unreliable headless).

import std/[os, posix, termios, strutils]

proc main() =
  let dir = getEnv("TTTY_ORACLE_DIR")
  if dir.len == 0: quit("TTTY_ORACLE_DIR not set", 2)
  let cmdFeed = dir / "cmd_feed"
  let cmdQuery = dir / "cmd_query"
  let doneF = dir / "done"
  let cursorF = dir / "cursor.txt"

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
          else:
            break
      result = buf[0 ..< total]
    finally:
      discard tcSetAttr(0, TCSANOW, addr orig)

  while true:
    if fileExists(cmdFeed):
      let bytes = readFile(cmdFeed)
      removeFile(cmdFeed)
      if bytes.len > 0:
        discard posix.write(1, cstring(bytes), bytes.len)
      writeFile(doneF, "feed")
    elif fileExists(cmdQuery):
      removeFile(cmdQuery)
      writeFile(cursorF, query())
      writeFile(doneF, "query")
    else:
      sleep(20)

main()
