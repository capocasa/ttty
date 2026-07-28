## Conformance of ttty against real xterm on REAL captured byte streams.
##
## Each tests/corpus/*.raw is a byte stream 3code actually wrote during a PTY
## test (welcome screen, :provider flow, streaming turn, resume-with-bar).
## We replay it into both a ttty Grid and a live xterm (media-copy text +
## DSR cursor) at the same 120x40 grid the captures used, and assert the two
## agree row-for-row. A divergence is a ttty modeling bug or a real 3code
## scrollback bug — either way it is now visible.
##
## Skips cleanly when Xvfb/xterm are absent (CI without an X stack).

import std/[os, strutils, unittest]
import ttty/conformance
import ttty/x11oracle

const CorpusDir = "tests" / "corpus"
const Cols = 120
const Rows = 40

suite "x11 conformance: ttty == real xterm on captured 3code streams":
  if not oracleAvailable():
    test "oracle unavailable (no Xvfb/xterm), skipping":
      skip()
  else:
    # Fresh oracle per stream: a captured stream is a self-contained
    # scenario, and replaying it into a clean xterm is the correct
    # conformance check. (A shared xterm carries scroll state from prior
    # streams, contaminating cursor/scroll positions.)
    var failures: seq[string] = @[]
    for file in walkFiles(CorpusDir / "*.raw"):
      let name = file.extractFilename
      let bytes = readFile(file)
      test name:
        let (ok, dv) = compareToOracle(bytes, Cols, Rows)
        if not ok:
          failures.add name & ": " & reportDivergence(dv)
        check ok
    if failures.len > 0:
      echo "\n=== conformance divergences ==="
      for f in failures: echo "  ", f
