## Conformance smoke: run sequences through ttty + real xterm (media-copy
## text ground truth) and report agreement. Fresh oracle per sequence.

import std/strutils
import ttty/conformance
import ttty/x11oracle

proc run(name, bytes: string): bool =
  let (ok, dv) = compareToOracle(bytes)
  if ok:
    echo "PASS  ", name
  else:
    echo "FAIL  ", name, " :: ", reportDivergence(dv)
  result = ok

proc main() =
  if not oracleAvailable():
    echo "SKIP: Xvfb/xterm not available"
    return
  var allOk = true
  allOk = run("plain text", "hello") and allOk
  allOk = run("two lines", "hello\r\nworld") and allOk
  allOk = run("carriage return overwrite", "abc\rX") and allOk
  allOk = run("cursor up + edit", "line1\r\nline2\x1b[1A\x1b[1GX") and allOk
  allOk = run("erase to end of line", "abcdef\r\x1b[3C\x1b[K") and allOk
  allOk = run("erase display below", "one\r\ntwo\r\nthree\x1b[2A\x1b[J") and allOk
  allOk = run("walk-up erase (3code shape)",
              "one\r\ntwo\r\nthree\r\n\r\n> \x1b[2A\x1b[J") and allOk
  allOk = run("absolute position", "\x1b[3;10Hhere") and allOk
  allOk = run("insert chars", "abcdef\r\x1b[2C\x1b[3@XYZ") and allOk
  allOk = run("delete chars", "abcdef\r\x1b[2C\x1b[2P") and allOk
  echo (if allOk: "ALL CONFORM" else: "DIVERGENCES FOUND")

main()
