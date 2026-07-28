version       = "0.4.0"
author        = "Carlo Capocasa"
description   = "Headless ANSI VT grid renderer, with a real-xterm ground-truth oracle"
license       = "MIT"
srcDir        = "src"

requires "nim >= 2.0"
# x11 is needed only by the optional xterm ground-truth oracle
# (src/ttty/x11oracle.nim) and its conformance tests, not by the core grid.
requires "x11 >= 1.2"

task oraclehelper, "Build the oracle child helper (build/oracle_helper)":
  exec "nim c --hints:off -o:build/oracle_helper src/ttty/oracle_helper.nim"

task conformance, "Run ttty==xterm ground-truth conformance (needs Xvfb+xterm)":
  exec "nimble oraclehelper"
  let x11path = gorgeEx("nimble path x11").output.splitLines()[0]
  exec "nim c -r --path:src --path:" & x11path & " tests/test_x11_conformance.nim"
