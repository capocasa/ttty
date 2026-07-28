## Oracle smoke test: feed known bytes to real xterm, verify the oracle's
## cursor + ink readback matches what we expect. This is the foundation the
## ttty-grounding comparator builds on.

import std/[os, strutils]
import ttty/x11oracle

proc main() =
  if not oracleAvailable():
    echo "SKIP: Xvfb/xterm not available"
    return
  let o = startOracle(80, 24)
  defer: o.stop()

  echo "oracle started: cell=", o.cellW, "x", o.cellH

  # Feed "hello" — cursor should land at row 0 col 5.
  o.feed("hello")
  let cur = o.cursor()
  echo "after 'hello': cursor=", cur
  doAssert cur == (0, 5), "expected (0,5), got " & $cur

  # Ink: cells 0..4 of row 0 should have ink, cell 10 should not.
  let ink = o.inkRows()
  for c in 0 ..< 5:
    doAssert ink[0][c], "expected ink at row0 col" & $c
  doAssert not ink[0][10], "expected no ink at row0 col10"
  echo "ink check passed"

  # Newline then "world" — cursor at row 1 col 5, ink on row 1.
  o.feed("\r\nworld")
  let cur2 = o.cursor()
  echo "after 'world': cursor=", cur2
  doAssert cur2 == (1, 5), "expected (1,5), got " & $cur2

  echo "ORACLE OK"

main()
