## Reproduce the 3code prompt-only drift bug against real-xterm ground truth.
##
## Fresh 3code start (prompt-only, no token bar). Each `:provider <name>`
## commits a profile block and the prompt lands one row lower than the
## walk-up model assumed, so the prompt creeps DOWN one row per command on a
## real terminal. Invisible in ttty (its model shares 3code's assumption).
##
## We run the real 3code stub inside the oracle (supervisor mode), type
## `:provider stub` via XTEST, and read xterm's rendered screen (media-copy)
## after each command. The drift shows as the last content row climbing.

import std/[os, strutils]
import ttty/x11oracle

proc main() =
  if not oracleAvailable():
    echo "SKIP: no Xvfb/xterm"
    return
  let stub = getHomeDir() / "p/3code/linebugs/build/3code_stub"
  doAssert fileExists(stub), "stub not built: " & stub

  let home = getTempDir() / "drift_home"
  removeDir(home)
  createDir(home / "xdg" / "3code"); createDir(home / "data")
  createDir(home / "tmp"); createDir(home / "run")
  writeFile(home / "xdg" / "3code" / "config", """
[settings]
current = "stub.stub-model"

[provider]
name = "stub"
url = "stub://provider"
key = "stub"
family = "glm"
models = "stub-model"
reasoning = "low"
reasonings = "off, low, high"
""")
  writeFile(home / "run" / "stub_responses.json",
    """[{"content":"ok","contentChunks":["ok"],"usage":{"promptTokens":1,""" &
    """"completionTokens":1,"totalTokens":2,"cachedTokens":0}}]""")

  let o = startOracle(120, 40,
    run = stub & " -x -i",
    runEnv = [("HOME", home),
              ("XDG_CONFIG_HOME", home / "xdg"),
              ("XDG_DATA_HOME", home / "data"),
              ("TMPDIR", home / "tmp"),
              ("THREECODE_STUB_RESPONSES", home / "run" / "stub_responses.json")])
  defer: o.stop()

  sleep 3500  # welcome + initial prompt

  proc lastContentRow(t: seq[string]): int =
    for r in countdown(t.len - 1, 0):
      if t[r].strip.len > 0: return r
    0

  var rows: seq[int] = @[]
  for i in 1 .. 4:
    o.typeKeys(":provider stub\n", delayMs = 35)
    sleep 1600
    let lr = lastContentRow(o.screenText())
    rows.add lr
    echo "after :provider #", i, " last-content-row=", lr

  echo "last-content rows across commands: ", rows
  var drift = 0
  for i in 1 ..< rows.len:
    inc drift, rows[i] - rows[i-1]
  echo "net downward drift over ", rows.len - 1, " commands: ", drift, " rows"
  if drift > 0:
    echo ">>> DRIFT REPRODUCED: prompt creeping down on real xterm"
  else:
    echo "no downward drift"

main()
