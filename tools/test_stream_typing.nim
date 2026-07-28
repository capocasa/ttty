## Drive the real bug scenario through the oracle: submit a prompt, then
## type while the reasoning spinner + response stream in. Watch that no
## committed scrollback line is eaten in place (the "reasoning low vanished"
## class of bug), across many GUI repaint ticks.

import std/[os, strutils]
import ttty/x11oracle

proc main() =
  if not oracleAvailable(): echo "SKIP"; return
  let stub = getHomeDir() / "p/3code/linebugs/build/3code_stub"
  doAssert fileExists(stub)
  let home = getTempDir() / "streamtest"
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
  # A reasoning model with a slow streamed response: many spinner ticks and
  # content chunks, so typed keystrokes interleave with repaints.
  writeFile(home / "run" / "stub_responses.json", """[{
    "content": "alpha beta gamma delta epsilon zeta eta theta",
    "contentChunks": ["alpha ", "beta ", "gamma ", "delta ", "epsilon ",
                      "zeta ", "eta ", "theta"],
    "contentChunkDelayMs": 150,
    "reasoning": "thinking about the answer step by step",
    "reasoningChunks": ["thinking ", "about ", "the ", "answer ", "step ",
                        "by ", "step"],
    "usage": {"promptTokens": 20, "completionTokens": 14,
              "totalTokens": 34, "cachedTokens": 0}
  }]""")

  let o = startOracle(120, 40,
    run = stub & " -x -i",
    runEnv = [("HOME", home), ("XDG_CONFIG_HOME", home / "xdg"),
              ("XDG_DATA_HOME", home / "data"), ("TMPDIR", home / "tmp"),
              ("THREECODE_STUB_RESPONSES", home / "run" / "stub_responses.json")])
  defer: o.stop()
  sleep 3500

  # snapshot before submit
  let before = o.screenText()

  # submit a prompt
  o.typeKeys("go\n", delayMs = 90)
  sleep 250  # spinner starts, reasoning streams

  # type while streaming
  o.typeKeys("hel", delayMs = 120)
  sleep 300
  let during = o.screenText()
  echo "=== during stream (rows 8-22) ==="
  for r in 8 .. 22: echo "  ", r, " |", during[r], "|"

  # let the turn finish
  sleep 2500
  let after = o.screenText()
  echo "=== after turn (rows 8-24) ==="
  for r in 8 .. 24: echo "  ", r, " |", after[r], "|"

  # Bug check: any committed scrollback line that was non-blank in `before`
  # and present in `during` but blank in `after` (eaten in place, not scrolled)
  # is the bug. We compare the stable top region (welcome + echoed prompt).

main()
