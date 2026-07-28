## Oracle smoke test: feed known bytes to real xterm, verify cursor +
## screenText readback (media-copy ground truth).

import ttty/x11oracle

proc main() =
  if not oracleAvailable():
    echo "SKIP: Xvfb/xterm not available"
    return
  let o = startOracle(80, 24)
  defer: o.stop()

  o.feed("hello")
  doAssert o.cursor() == (0, 5), "cursor after hello"
  doAssert o.screenText()[0] == "hello"

  o.feed("\r\nworld")
  doAssert o.cursor() == (1, 5), "cursor after world"
  let txt = o.screenText()
  doAssert txt[0] == "hello"
  doAssert txt[1] == "world"

  echo "ORACLE OK"

main()
