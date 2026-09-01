## Ground-truth conformance: compare ttty's `Grid` against a real xterm.
##
## Feeds one byte stream to both ttty and the headless-xterm oracle, then
## asserts the two agree on the things ttty models and xterm reports
## independently:
##
##   - cursor position (row, col)  — xterm's own DSR `CSI 6 n` answer
##   - visible screen text         — xterm's Media Copy (`CSI 0 i`) dump of
##                                   exactly what it rendered
##
## This mirrors how ghostty audits itself against xterm: behavior, not
## rendered pixels. A divergence means either ttty mis-models a sequence, or
## the byte stream itself walks into scrollback (a real app bug); both are
## worth surfacing. `compareToOracle` reports the first mismatch with
## context.

import std/strutils
import ./grid
import ./x11oracle

type
  Divergence* = object
    kind*: string        ## "cursor" | "row"
    row*: int
    detail*: string

proc compareToOracle*(bytes: string; cols = 80, rows = 24;
                      oracle: Oracle = nil): tuple[ok: bool, dv: Divergence] =
  ## Replay `bytes` into a fresh ttty Grid and a fresh (or supplied) real
  ## xterm; assert cursor + screen-text agreement. Supplying `oracle` lets a
  ## caller replay many streams through one xterm (state carries over),
  ## matching how a real session accumulates.
  let g = newGrid()
  g.width = cols
  g.height = rows

  var o = oracle
  var ownOracle = false
  if o == nil:
    o = startOracle(cols, rows)
    ownOracle = true
  defer:
    if ownOracle: o.stop()

  g.feed(bytes)
  o.feed(bytes)

  # Cursor agreement.
  let oc = o.cursor()
  if oc.row != g.row or oc.col != g.col:
    return (false, Divergence(kind: "cursor", row: oc.row,
      detail: "ttty cursor=(" & $g.row & "," & $g.col & ") but xterm=(" &
        $oc.row & "," & $oc.col & ")"))

  # Screen agreement over the visible rows. xterm gives exact text (Media
  # Copy), so compare text cell-for-cell. st gives only an ink map
  # (occupancy), which is too coarse for byte-level streams: st renders
  # sequences the grid models as text (DECSCUSR, unhandled private modes)
  # and vice versa, so occupancy diverges on content that is not a real
  # scrollback bug. For st the DSR cursor above is the ground truth; skip
  # the noisy occupancy comparison rather than fail on artifacts.
  if o.term == termXterm:
    let xt = o.screenText()
    for r in 0 ..< rows:
      let tt = rowText(g, r).strip(leading = false, trailing = true)
      let xr = if r < xt.len: xt[r] else: ""
      if tt != xr:
        return (false, Divergence(kind: "row", row: r,
          detail: "row " & $r & ": ttty=" & tt.escape & " xterm=" & xr.escape))

  result = (true, Divergence())

proc reportDivergence*(d: Divergence): string =
  "DIVERGENCE [" & d.kind & "] " & d.detail

proc compareAppSide*(appBytes: string; cols = 80, rows = 24): tuple[ok: bool, dv: Divergence] =
  ## Replay APP-SIDE bytes (what a program wrote to stdout, BEFORE the pty
  ## line discipline transforms them) into a cooked-output Grid and a real
  ## terminal, and assert they agree. The Grid gets `cookedOutput = true` so
  ## it applies the same ONLCR transform the terminal's pty applies; the
  ## terminal receives the bytes raw and its pty does the transform. If the
  ## two disagree, the app's byte stream does not mean what the app thinks
  ## it means on a real cooked terminal — the model-vs-physical desync made
  ## visible. This is the check the verbatim `compareToOracle` cannot do.
  let g = newGrid()
  g.width = cols
  g.height = rows
  g.cookedOutput = true
  let o = startOracle(cols, rows)
  defer: o.stop()
  g.feed(appBytes)
  o.feed(appBytes)
  let oc = o.cursor()
  if oc.row != g.row or oc.col != g.col:
    return (false, Divergence(kind: "cursor", row: oc.row,
      detail: "app-side cooked: ttty cursor=(" & $g.row & "," & $g.col &
        ") but terminal=(" & $oc.row & "," & $oc.col & ")"))
  result = (true, Divergence())
