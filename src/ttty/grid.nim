import std/[unicode, strutils]

const
  saBold* = 0
  saDim* = 1
  saItalic* = 2
  saUnderline* = 3
  saBlink* = 4
  saReverse* = 5
  saStrikethrough* = 6

type
  SgrAttr* = distinct uint16

  Color* = enum
    colDefault
    colBlack
    colRed
    colGreen
    colYellow
    colBlue
    colMagenta
    colCyan
    colWhite
    colBrightBlack
    colBrightRed
    colBrightGreen
    colBrightYellow
    colBrightBlue
    colBrightMagenta
    colBrightCyan
    colBrightWhite
    col256
    colRgb

  Cell* = object
    rune*: Rune
    text*: string
    fgColor*: Color
    bgColor*: Color
    colorIdx*: uint8
    fgColorIdx*: uint8
    bgColorIdx*: uint8
    attrs*: SgrAttr
    width*: int

  Grid* = ref object
    rows*: seq[seq[Cell]]
    row*, col*: int
    width*: int
    height*: int
    scrollback*: int
    tabWidth*: int
    scrollTop*: int
    scrollBottom*: int
    pendingWrap*: bool
    savedRow*, savedCol*: int
    hasSaved*: bool
    cursorHidden*: bool
    bracketedPaste*: bool
    curFg*: Color
    curBg*: Color
    curFgIdx*: uint8
    curBgIdx*: uint8
    curAttrs*: SgrAttr
    ## Stream well-formedness violations for paired private modes
    ## (currently DEC 2026 synchronized output): nested begin, end without
    ## begin, begin never closed. Interpretation is unchanged — terminals
    ## that honor 2026 batch atomically, ttty applies sequentially — but
    ## malformed frames are exactly where atomic and sequential semantics
    ## diverge, so they are always worth flagging.
    violations*: seq[string]
    syncOpen: bool
    ## DEC 2026 synchronized-output batching, modeled the way xterm applies
    ## it: while a sync block is open the terminal defers rendering, so the
    ## observable screen is the state frozen at `CSI ? 2026 h`. Mutations
    ## accumulate on `syncShadow` (a private scratch grid fed the same
    ## bytes); `CSI ? 2026 l` commits the shadow atomically into the visible
    ## grid. Reading `rows`/`rowText` mid-block yields the frozen pre-sync
    ## frame, exactly what a real terminal paints until the end marker.
    syncShadow: Grid
    ## When true, model the pty output line discipline (OPOST/ONLCR) a real
    ## terminal applies to an app's bytes: each `\n` NOT preceded by `\r`
    ## becomes CR+LF (col 0 + linefeed), while an explicit `\r\n` stays one
    ## linefeed. This lets a test feed APP-SIDE bytes (what the program
    ## wrote, before the line discipline) and get the grid a real
    ## cooked-mode terminal would show — closing the model-vs-physical gap
    ## that hides scrollback desyncs when the harness interprets bytes with
    ## the same model the app used to emit them. Default false: feed bytes
    ## are interpreted verbatim (the terminal's own view).
    cookedOutput*: bool
    prevWasCr: bool
    ## A CSI/OSC cut off at the end of a `feed` chunk is held here until
    ## the next chunk completes it, exactly like a real terminal's parser:
    ## xterm buffers a partial escape instead of dropping the head and
    ## printing the tail as text when the rest of the read arrives.
    heldEsc: string

proc hasAttr*(attrs: SgrAttr, bit: int): bool {.inline.} =
  (uint16(attrs) and (1'u16 shl uint16(bit))) != 0

proc setAttr*(attrs: var SgrAttr, bit: int, on: bool) {.inline.} =
  if on:
    attrs = SgrAttr(uint16(attrs) or (1'u16 shl uint16(bit)))
  else:
    attrs = SgrAttr(uint16(attrs) and not (1'u16 shl uint16(bit)))

proc newCell*(rune: Rune = Rune(' '), fg: Color = colDefault,
              bg: Color = colDefault, fi: uint8 = 0, bi: uint8 = 0,
              attrs: SgrAttr = SgrAttr(0)): Cell {.inline.} =
  Cell(rune: rune, text: $rune, fgColor: fg, bgColor: bg,
       fgColorIdx: fi, bgColorIdx: bi, attrs: attrs, width: 1)

proc newGrid*(): Grid =
  Grid(rows: @[newSeq[Cell]()],
       row: 0, col: 0, width: 0, height: 0, scrollback: 0, tabWidth: 8,
       scrollTop: 0, scrollBottom: 0,
       pendingWrap: false,
       savedRow: 0, savedCol: 0,
       hasSaved: false, cursorHidden: false, bracketedPaste: false,
       curFg: colDefault, curBg: colDefault, curAttrs: SgrAttr(0))

proc blankCell(g: Grid): Cell =
  Cell(rune: Rune(' '), text: " ", fgColor: g.curFg, bgColor: g.curBg,
       fgColorIdx: g.curFgIdx, bgColorIdx: g.curBgIdx, attrs: g.curAttrs,
       width: 1)

proc ensureRow*(g: Grid, r: int) =
  while g.rows.len <= r:
    g.rows.add newSeq[Cell]()

proc blankRow(): seq[Cell] =
  newSeq[Cell]()

proc scrollBottomDefault(g: Grid): int =
  if g.scrollBottom > 0:
    g.scrollBottom
  elif g.height > 0:
    g.height - 1
  else:
    max(0, g.rows.len - 1)

proc scrollBounds(g: Grid): (int, int) =
  let top = max(0, g.scrollTop)
  let bottom = max(top, scrollBottomDefault(g))
  (top, bottom)

proc ensureThrough(g: Grid, bottom: int) =
  ensureRow(g, bottom)

proc padTo(row: var seq[Cell], col: int, fg: Color, bg: Color,
           fi, bi: uint8, attrs: SgrAttr) =
  while row.len < col:
    row.add Cell(rune: Rune(' '), text: " ", fgColor: fg, bgColor: bg,
                 fgColorIdx: fi, bgColorIdx: bi, attrs: attrs, width: 1)

proc trimScrollback(g: Grid) =
  if g.height <= 0: return
  let keep = max(1, g.height + max(0, g.scrollback))
  while g.rows.len > keep:
    g.rows.delete(0)
    g.row = max(0, g.row - 1)
    if g.hasSaved:
      if g.savedRow > 0:
        dec g.savedRow
      else:
        g.hasSaved = false

proc scrollRegionUp(g: Grid, top, bottom, n: int) =
  ensureThrough(g, bottom)
  let count = min(max(0, n), bottom - top + 1)
  for _ in 0 ..< count:
    g.rows.delete(top)
    g.rows.insert(blankRow(), bottom)

proc scrollRegionDown(g: Grid, top, bottom, n: int) =
  ensureThrough(g, bottom)
  let count = min(max(0, n), bottom - top + 1)
  for _ in 0 ..< count:
    g.rows.delete(bottom)
    g.rows.insert(blankRow(), top)

proc lineFeed(g: Grid) =
  let (top, bottom) = scrollBounds(g)
  if (g.scrollTop > 0 or g.scrollBottom > 0) and g.row == bottom and
      g.row >= top:
    scrollRegionUp(g, top, bottom, 1)
  else:
    inc g.row
  g.col = 0
  g.pendingWrap = false
  ensureRow(g, g.row)
  trimScrollback(g)

proc codepoint(r: Rune): int {.inline.} =
  int32(r).int

proc isWide(r: Rune): bool =
  let c = codepoint(r)
  # Approximation of POSIX wcwidth wide ranges. Good enough for terminal UI
  # tests without making the library depend on a full Unicode width table.
  (c >= 0x1100 and
    (c <= 0x115F or
     c == 0x2329 or c == 0x232A or
     (c >= 0x2E80 and c <= 0xA4CF and c != 0x303F) or
     (c >= 0xAC00 and c <= 0xD7A3) or
     (c >= 0xF900 and c <= 0xFAFF) or
     (c >= 0xFE10 and c <= 0xFE19) or
     (c >= 0xFE30 and c <= 0xFE6F) or
     (c >= 0xFF00 and c <= 0xFF60) or
     (c >= 0xFFE0 and c <= 0xFFE6) or
     (c >= 0x1F300 and c <= 0x1FAFF) or
     (c >= 0x20000 and c <= 0x3FFFD)))

proc displayWidth(r: Rune): int =
  if r.isCombining: 0
  elif r.isWide: 2
  else: 1

proc appendCombining(g: Grid, r: Rune) =
  let mark = $r
  if g.row < g.rows.len and g.col > 0 and g.col - 1 < g.rows[g.row].len:
    g.rows[g.row][g.col - 1].text.add mark
  elif g.row > 0 and g.rows[g.row - 1].len > 0:
    g.rows[g.row - 1][g.rows[g.row - 1].high].text.add mark
  else:
    ensureRow(g, g.row)
    let cell = Cell(rune: r, text: mark, fgColor: g.curFg, bgColor: g.curBg,
                    fgColorIdx: g.curFgIdx, bgColorIdx: g.curBgIdx,
                    attrs: g.curAttrs, width: 0)
    g.rows[g.row].add cell

proc putRune(g: Grid, r: Rune) =
  ensureRow(g, g.row)
  let w = displayWidth(r)
  if w == 0:
    appendCombining(g, r)
    return
  if g.pendingWrap:
    lineFeed(g)
  # `col >= width` without pendingWrap means an erase cleared the wrap
  # flag at the last column: the print lands at the last column and
  # re-arms wrap (xterm). Only a mid-row overflow wraps eagerly.
  if g.width > 0 and g.col > 0 and g.col + w > g.width and
     g.col < g.width:
    lineFeed(g)
  if g.width > 0 and g.col >= g.width:
    # Erase-disarmed wrap at the last column: the print overwrites the
    # last cell (xterm), then re-arms pending wrap below.
    g.col = g.width - 1
  padTo(g.rows[g.row], g.col, g.curFg, g.curBg, g.curFgIdx, g.curBgIdx,
        g.curAttrs)
  let cell = Cell(rune: r, fgColor: g.curFg, bgColor: g.curBg,
                  text: $r, fgColorIdx: g.curFgIdx, bgColorIdx: g.curBgIdx,
                  attrs: g.curAttrs, width: w)
  if g.rows[g.row].len == g.col:
    g.rows[g.row].add cell
  else:
    g.rows[g.row][g.col] = cell
  inc g.col
  if w == 2:
    let cont = Cell(rune: Rune(0), text: "", fgColor: g.curFg, bgColor: g.curBg,
                    fgColorIdx: g.curFgIdx, bgColorIdx: g.curBgIdx,
                    attrs: g.curAttrs, width: 0)
    if g.rows[g.row].len == g.col:
      g.rows[g.row].add cont
    else:
      g.rows[g.row][g.col] = cont
    inc g.col
  g.pendingWrap = g.width > 0 and g.col >= g.width

proc eraseLine(g: Grid, mode: int) =
  ensureRow(g, g.row)
  case mode
  of 0:
    if g.rows[g.row].len > g.col:
      g.rows[g.row].setLen(g.col)
  of 1:
    for k in 0 ..< min(g.col, g.rows[g.row].len):
      g.rows[g.row][k] = newCell()
  of 2:
    g.rows[g.row].setLen(0)
  else: discard

proc parseIntDefault(s: string, default = 0): int =
  if s.len == 0: return default
  try: parseInt(s)
  except ValueError: default

proc eraseDisplay(g: Grid, mode: int) =
  ensureRow(g, g.row)
  case mode
  of 0:
    # Clear from cursor to end of row, then drop rows below. Content is
    # blanked, not truncated: when the cursor is at/past the row's
    # content (e.g. pending-wrap at the last column) the row's cells are
    # preserved — xterm behaves this way (edge_wrap_ed.raw conformance).
    for k in g.col ..< g.rows[g.row].len:
      g.rows[g.row][k] = newCell()
    g.rows.setLen(g.row + 1)
  of 1:
    for r in 0 ..< g.row:
      g.rows[r].setLen(0)
    for k in 0 ..< min(g.col, g.rows[g.row].len):
      g.rows[g.row][k] = newCell()
  of 2:
    for r in 0 ..< g.rows.len:
      g.rows[r].setLen(0)
  else: discard

proc parseN(s: string): int =
  if s.len == 0: return 1
  try: max(1, parseInt(s))
  except ValueError: 1

proc parseParams(params: string): seq[int] =
  for part in params.split(';'):
    result.add parseIntDefault(part, 0)

proc paramAt(params: seq[int], idx, default: int): int =
  if idx < params.len and params[idx] > 0: params[idx] else: default

proc parseSgrParam(s: string): int =
  if s.len == 0: 0 else: parseIntDefault(s, -1)

proc applySgr(g: Grid, params: string) =
  if params.len == 0:
    g.curFg = colDefault
    g.curBg = colDefault
    g.curAttrs = SgrAttr(0)
    return

  let parts = params.split(';')
  var i = 0
  while i < parts.len:
    let p = parts[i]
    let n = parseSgrParam(p)
    case n
    of 0:
      g.curFg = colDefault
      g.curBg = colDefault
      g.curAttrs = SgrAttr(0)
    of 1:
      g.curAttrs.setAttr(saBold, true)
    of 2:
      g.curAttrs.setAttr(saDim, true)
    of 3:
      g.curAttrs.setAttr(saItalic, true)
    of 4:
      g.curAttrs.setAttr(saUnderline, true)
    of 5:
      g.curAttrs.setAttr(saBlink, true)
    of 6:
      g.curAttrs.setAttr(saBlink, true)
    of 7:
      g.curAttrs.setAttr(saReverse, true)
    of 9:
      g.curAttrs.setAttr(saStrikethrough, true)
    of 22:
      g.curAttrs.setAttr(saBold, false)
      g.curAttrs.setAttr(saDim, false)
    of 23:
      g.curAttrs.setAttr(saItalic, false)
    of 24:
      g.curAttrs.setAttr(saUnderline, false)
    of 25:
      g.curAttrs.setAttr(saBlink, false)
    of 27:
      g.curAttrs.setAttr(saReverse, false)
    of 29:
      g.curAttrs.setAttr(saStrikethrough, false)
    of 30..37:
      g.curFg = Color(n - 30 + ord(colBlack))
    of 38:
      if i + 1 < parts.len and parts[i + 1] == "5" and i + 2 < parts.len:
        let idx = parseIntDefault(parts[i + 2], -1)
        if idx < 0 or idx > 255:
          discard
        elif idx < 16:
          g.curFg = Color(idx + ord(colBlack))
          g.curFgIdx = 0
        else:
          g.curFg = col256
          g.curFgIdx = uint8(idx)
        inc i, 2
      elif i + 1 < parts.len and parts[i + 1] == "2" and i + 4 < parts.len:
        g.curFg = colRgb
        inc i, 4
    of 39:
      g.curFg = colDefault
      g.curFgIdx = 0
    of 40..47:
      g.curBg = Color(n - 40 + ord(colBlack))
      g.curBgIdx = 0
    of 48:
      if i + 1 < parts.len and parts[i + 1] == "5" and i + 2 < parts.len:
        let idx = parseIntDefault(parts[i + 2], -1)
        if idx < 0 or idx > 255:
          discard
        elif idx < 16:
          g.curBg = Color(idx + ord(colBlack))
          g.curBgIdx = 0
        else:
          g.curBg = col256
          g.curBgIdx = uint8(idx)
        inc i, 2
      elif i + 1 < parts.len and parts[i + 1] == "2" and i + 4 < parts.len:
        g.curBg = colRgb
        inc i, 4
    of 49:
      g.curBg = colDefault
      g.curBgIdx = 0
    of 90..97:
      g.curFg = Color(n - 90 + ord(colBrightBlack))
    of 100..107:
      g.curBg = Color(n - 100 + ord(colBrightBlack))
    else: discard
    inc i

proc tab(g: Grid) =
  if g.pendingWrap:
    lineFeed(g)
  let tw = max(1, g.tabWidth)
  var target = ((g.col div tw) + 1) * tw
  if g.width > 0 and target > g.width:
    target = g.width
  ensureRow(g, g.row)
  while g.col < target:
    if g.width > 0 and g.col >= g.width:
      lineFeed(g)
      break
    padTo(g.rows[g.row], g.col, g.curFg, g.curBg, g.curFgIdx, g.curBgIdx,
          g.curAttrs)
    if g.rows[g.row].len == g.col:
      g.rows[g.row].add blankCell(g)
    else:
      g.rows[g.row][g.col] = blankCell(g)
    inc g.col
  g.pendingWrap = g.width > 0 and g.col >= g.width

proc backspace(g: Grid) =
  g.pendingWrap = false
  if g.col > 0:
    dec g.col

proc insertChars(g: Grid, n: int) =
  ensureRow(g, g.row)
  let count = max(1, n)
  padTo(g.rows[g.row], g.col, g.curFg, g.curBg, g.curFgIdx, g.curBgIdx,
        g.curAttrs)
  for _ in 0 ..< count:
    g.rows[g.row].insert(blankCell(g), g.col)
  if g.width > 0 and g.rows[g.row].len > g.width:
    g.rows[g.row].setLen(g.width)
  g.pendingWrap = false

proc deleteChars(g: Grid, n: int) =
  ensureRow(g, g.row)
  let count = max(1, n)
  for _ in 0 ..< count:
    if g.col < g.rows[g.row].len:
      g.rows[g.row].delete(g.col)
  if g.width > 0:
    while g.rows[g.row].len < g.width:
      g.rows[g.row].add blankCell(g)
  g.pendingWrap = false

proc insertLines(g: Grid, n: int) =
  let (top, bottom) = scrollBounds(g)
  if g.row < top or g.row > bottom: return
  scrollRegionDown(g, g.row, bottom, max(1, n))
  g.pendingWrap = false

proc deleteLines(g: Grid, n: int) =
  let (top, bottom) = scrollBounds(g)
  if g.row < top or g.row > bottom: return
  scrollRegionUp(g, g.row, bottom, max(1, n))
  g.pendingWrap = false

proc setScrollRegion(g: Grid, params: string) =
  if params.len == 0:
    g.scrollTop = 0
    g.scrollBottom = 0
    g.row = 0
    g.col = 0
    g.pendingWrap = false
    return
  let ps = parseParams(params)
  let top = paramAt(ps, 0, 1) - 1
  let bottomDefault = if g.height > 0: g.height else: max(1, g.rows.len)
  let bottom = paramAt(ps, 1, bottomDefault) - 1
  if bottom > top:
    g.scrollTop = max(0, top)
    g.scrollBottom = max(g.scrollTop, bottom)
  else:
    g.scrollTop = 0
    g.scrollBottom = 0
  g.row = 0
  g.col = 0
  g.pendingWrap = false

proc copyGridState(dst, src: Grid) =
  ## Deep-copy the visible + cursor state of `src` into `dst`. Used to
  ## snapshot the grid when a DEC 2026 sync block opens (so mutations during
  ## the block accumulate on a private copy) and to commit the block
  ## atomically when it closes. `violations` and the sync bookkeeping are
  ## deliberately not copied; they belong to the stream, not the frame.
  dst.rows = @[]
  for row in src.rows:
    dst.rows.add row  # Cell is a value type; the seq copy is deep enough
  dst.row = src.row
  dst.col = src.col
  dst.width = src.width
  dst.height = src.height
  dst.scrollback = src.scrollback
  dst.tabWidth = src.tabWidth
  dst.scrollTop = src.scrollTop
  dst.scrollBottom = src.scrollBottom
  dst.pendingWrap = src.pendingWrap
  dst.savedRow = src.savedRow
  dst.savedCol = src.savedCol
  dst.hasSaved = src.hasSaved
  dst.cursorHidden = src.cursorHidden
  dst.bracketedPaste = src.bracketedPaste
  dst.curFg = src.curFg
  dst.curBg = src.curBg
  dst.curFgIdx = src.curFgIdx
  dst.curBgIdx = src.curBgIdx
  dst.curAttrs = src.curAttrs
  dst.cookedOutput = src.cookedOutput
  dst.prevWasCr = src.prevWasCr
  # A held partial escape is stream position, not frame content; carrying
  # it into a sync shadow would replay the head twice at commit.
  dst.heldEsc = ""

proc feedRaw(g: Grid, bytes: string) =
  ## Apply `bytes` to the grid with no 2026 batching: the sequential
  ## interpreter ttty has always had. `feed` routes here either directly
  ## (sync closed) or via the sync shadow (sync open).
  var i = 0
  while i < bytes.len:
    let b = bytes[i]
    case b
    of '\r':
      g.col = 0
      g.pendingWrap = false
      g.prevWasCr = true
      inc i
    of '\n':
      # ONLCR: a linefeed not preceded by a carriage return also returns
      # the carriage (col 0). An explicit `\r\n` already returned it, so the
      # extra `\r` the line discipline inserts is a no-op col-0.
      if g.cookedOutput and not g.prevWasCr:
        g.col = 0
        g.pendingWrap = false
      lineFeed(g)
      g.prevWasCr = false
      inc i
    of '\t':
      g.prevWasCr = false
      tab(g)
      inc i
    of '\b':
      g.prevWasCr = false
      backspace(g)
      inc i
    of '\x1b':
      g.prevWasCr = false
      if i + 1 < bytes.len and bytes[i + 1] == '[':  # CSI
        var j = i + 2
        var private = false
        if j < bytes.len and bytes[j] == '?':
          private = true; inc j
        var params = ""
        while j < bytes.len and (bytes[j] in {'0'..'9'} or bytes[j] == ';'):
          params.add bytes[j]
          inc j
        # Intermediate bytes (0x20-0x2F) sit between params and the final
        # byte (DECSCUSR `CSI 2 q`); skip them so the final byte is the
        # sequence terminator, not the intermediate, and the payload after
        # it is not printed as text (raw_hint_* conformance).
        while j < bytes.len and bytes[j] in {' '..'/'}:
          inc j
        if j >= bytes.len:
          i = j; continue
        let final = bytes[j]
        if private:
          if params == "25":
            if final == 'l': g.cursorHidden = true
            elif final == 'h': g.cursorHidden = false
          elif params == "2004":
            if final == 'h': g.bracketedPaste = true
            elif final == 'l': g.bracketedPaste = false
          elif params == "2026":
            # DEC 2026 markers are consumed by `feed` (which splits the
            # stream on them and routes content to the sync shadow). When
            # `feedRaw` is driven directly they are inert no-ops.
            discard
        else:
          case final
          of '@':
            insertChars(g, parseN(params))
          of 'A':
            g.row = max(0, g.row - parseN(params))
            g.pendingWrap = false
          of 'B':
            # CUD stops at the bottom margin like xterm, never walks past
            # the visible screen into phantom rows (edge_cud_bottom_clamp).
            g.row += parseN(params)
            if g.height > 0:
              g.row = min(g.row, scrollBottomDefault(g))
            ensureRow(g, g.row)
            g.pendingWrap = false
          of 'C':
            g.col += parseN(params)
            g.pendingWrap = false
          of 'D':
            g.col = max(0, g.col - parseN(params))
            g.pendingWrap = false
          of 'G':
            g.col = max(0, parseN(params) - 1)
            g.pendingWrap = false
          of 'K':
            var mode = 0
            if params.len > 0:
              mode = parseIntDefault(params, 0)
            eraseLine(g, mode)
          of 'J':
            var mode = 0
            if params.len > 0:
              mode = parseIntDefault(params, 0)
            eraseDisplay(g, mode)
            # xterm clears pending-wrap on ED: text after `CSI J` at the
            # last column overwrites the wrapped row's first cell rather
            # than wrapping first (edge_wrap_ed.raw conformance).
            g.pendingWrap = false
          of 'L':
            insertLines(g, parseN(params))
          of 'M':
            deleteLines(g, parseN(params))
          of 'P':
            deleteChars(g, parseN(params))
          of 'm':
            applySgr(g, params)
          of 'r':
            setScrollRegion(g, params)
          of 's':
            g.savedRow = g.row
            g.savedCol = g.col
            g.hasSaved = true
          of 'u':
            if g.hasSaved:
              g.row = g.savedRow
              g.col = g.savedCol
              g.pendingWrap = false
              ensureRow(g, g.row)
          of 'H', 'f':
            let semi = params.find(';')
            let r = if semi < 0: parseN(params) - 1
                    else: parseN(params[0 ..< semi]) - 1
            let c = if semi < 0: 0 else: parseN(params[semi + 1 .. ^1]) - 1
            g.row = max(0, r); g.col = max(0, c)
            g.pendingWrap = false
            ensureRow(g, g.row)
          else: discard
        i = j + 1
      elif i + 1 < bytes.len:
        # Non-CSI escapes. Unhandled ones must be consumed whole, not
        # dropped after ESC with their payload printed as text (xterm
        # swallows the sequence; edge_decsc/edge_osc_query/edge_ri).
        case bytes[i + 1]
        of '(', ')', '*', '+':  # charset designation: ESC ( I etc.
          # The designator byte after the selector belongs to the sequence.
          if i + 2 < bytes.len:
            inc i
          inc i; inc i
        of '7':  # DECSC
          g.savedRow = g.row; g.savedCol = g.col; g.hasSaved = true
          inc i; inc i
        of '8':  # DECRC
          if g.hasSaved:
            g.row = g.savedRow; g.col = g.savedCol
            g.pendingWrap = false
            ensureRow(g, g.row)
          inc i; inc i
        of 'M':  # RI: cursor up, scrolling the region down at the top
          dec g.row
          if g.row < 0:
            g.row = 0
            let (top, bottom) = scrollBounds(g)
            scrollRegionDown(g, top, bottom, 1)
          inc i; inc i
        of 'D':  # IND: linefeed honoring the scroll region
          lineFeed(g)
          inc i; inc i
        of 'E':  # NEL: CR + IND
          g.col = 0
          lineFeed(g)
          inc i; inc i
        of ']':  # OSC: swallow through BEL or ST
          var j = i + 2
          while j < bytes.len and bytes[j] != '\x07' and
              not (bytes[j] == '\x1b' and j + 1 < bytes.len and
                   bytes[j + 1] == '\\'):
            inc j
          if j < bytes.len:
            inc j
            if j < bytes.len and bytes[j - 1] == '\x1b':
              inc j
          i = j
        else:  # two-byte escape (charset etc.): consume ESC + next
          inc i; inc i
      else:
        inc i
    else:
      g.prevWasCr = false
      let rl = runeLenAt(bytes, i)
      let r = runeAt(bytes, i)
      putRune(g, r)
      i += rl

const
  SyncBeginMark = "\x1b[?2026h"
  SyncEndMark = "\x1b[?2026l"

proc splitHeldEscape*(bytes: string): tuple[complete, held: string] =
  ## Split `bytes` into the prefix that ends on a whole escape sequence and
  ## a trailing incomplete one. A CSI is complete when a final byte in
  ## `@`..`~` follows the params (and any intermediates); a private `?`
  ## marker is part of the sequence. An OSC is complete at BEL or ST. A
  ## lone trailing ESC (its next byte has not arrived) is held too.
  if bytes.len == 0:
    return
  var i = 0
  var cut = -1
  while i < bytes.len:
    if bytes[i] == '\x1b':
      if i + 1 >= bytes.len:
        cut = i
        break
      case bytes[i + 1]
      of '[':
        var j = i + 2
        if j < bytes.len and bytes[j] == '?':
          inc j
        while j < bytes.len and (bytes[j] in {'0'..'9', ';'} or
            (bytes[j] >= ' ' and bytes[j] <= '/')):
          inc j
        if j >= bytes.len:
          cut = i
          break
        i = j + 1
        continue
      of ']':
        var j = i + 2
        while j < bytes.len and bytes[j] != '\x07' and
            not (bytes[j] == '\x1b' and j + 1 < bytes.len and
                 bytes[j + 1] == '\\'):
          inc j
        if j >= bytes.len:
          cut = i
          break
        if bytes[j] == '\x1b':
          inc j
        i = j + 1
        continue
      else:
        # Two-byte escape: complete by definition.
        i = i + 2
        continue
    inc i
  if cut >= 0:
    result = (bytes[0 ..< cut], bytes[cut ..< bytes.len])
  else:
    result = (bytes, "")

proc feed*(g: Grid, chunk: string) =
  ## Feed bytes into the grid, honoring DEC 2026 synchronized output the way
  ## xterm applies it: while a sync block is open the terminal defers
  ## rendering, so mutations accumulate on a private shadow and the visible
  ## grid stays frozen at the frame that was current when the block opened.
  ## `CSI ? 2026 l` commits the shadow atomically. Reads of `rows`/`rowText`
  ## between a begin and its end observe the frozen pre-sync frame, which is
  ## exactly what a real terminal paints during the block.
  ##
  ## The visible grid `g` is the shadow while a block is open: `feedRaw`
  ## always mutates `g`, and `feed` swaps a frozen snapshot in/out around the
  ## block so the committed frame lands atomically at the end marker.
  # The grid mutations land on: the visible grid when no block is open,
  # the private shadow while a block is open. The shadow starts as a copy
  # of the visible grid, so a block's edits build on the frozen frame.
  #
  # A partial escape held over from the previous chunk is prepended first;
  # the split below then operates on the reassembled stream, so a sync
  # marker or sequence split across a read boundary is seen whole.
  var bytes = chunk
  if g.heldEsc.len > 0:
    bytes = g.heldEsc & chunk
    g.heldEsc = ""
  let (completeBytes, held) = splitHeldEscape(bytes)
  g.heldEsc = held
  if completeBytes.len == 0:
    return
  bytes = completeBytes
  var i = 0
  while i < bytes.len:
    let nextBegin = bytes.find(SyncBeginMark, i)
    let nextEnd = bytes.find(SyncEndMark, i)
    if nextBegin < 0 and nextEnd < 0:
      feedRaw((if g.syncOpen: g.syncShadow else: g), bytes[i ..< bytes.len])
      break
    if nextBegin >= 0 and (nextEnd < 0 or nextBegin < nextEnd):
      if nextBegin > i:
        feedRaw((if g.syncOpen: g.syncShadow else: g), bytes[i ..< nextBegin])
      # Open a block: snapshot the visible frame into the shadow. Mutations
      # now route to the shadow; `g` stays frozen at this frame, which is
      # what xterm paints until the matching end marker.
      if g.syncOpen:
        g.violations.add "nested DEC 2026 sync begin at byte " & $nextBegin
      if g.syncShadow == nil:
        g.syncShadow = newGrid()
      copyGridState(g.syncShadow, g)
      g.syncOpen = true
      i = nextBegin + SyncBeginMark.len
    else:
      if nextEnd > i:
        feedRaw((if g.syncOpen: g.syncShadow else: g), bytes[i ..< nextEnd])
      if not g.syncOpen:
        g.violations.add "DEC 2026 sync end without begin at byte " & $nextEnd
      else:
        # Close: commit the shadow atomically into the visible grid.
        copyGridState(g, g.syncShadow)
      g.syncOpen = false
      i = nextEnd + SyncEndMark.len

proc syncSnapshot*(g: Grid; dst: Grid) =
  ## Copy the frame a real terminal would paint RIGHT NOW into `dst`: the
  ## frozen pre-sync state while a 2026 block is open (which is exactly the
  ## visible grid `g`, since mutations route to the shadow during a block),
  ## the live grid otherwise. Conformance tools that screenshot mid-stream
  ## use this to observe the same deferred frame xterm shows.
  copyGridState(dst, g)

proc checkStreamClosed*(g: Grid) =
  ## Call when a byte stream is complete: commit any sync block left open
  ## (xterm flushes a deferred frame on stream end too) and flag it.
  if g.syncOpen:
    g.violations.add "DEC 2026 sync begin never closed"
    if g.syncShadow != nil:
      copyGridState(g, g.syncShadow)
    g.syncOpen = false

proc rowText*(g: Grid, r: int): string =
  if r < 0 or r >= g.rows.len: return ""
  for cell in g.rows[r]:
    if cell.text.len > 0:
      result.add cell.text

proc cellAt*(g: Grid, r, c: int): Cell =
  if r < 0 or r >= g.rows.len: return newCell()
  if c < 0 or c >= g.rows[r].len: return newCell()
  g.rows[r][c]

proc cellAttr*(g: Grid, r, c: int): SgrAttr =
  g.cellAt(r, c).attrs

proc cellFg*(g: Grid, r, c: int): Color =
  g.cellAt(r, c).fgColor

proc cellBg*(g: Grid, r, c: int): Color =
  g.cellAt(r, c).bgColor

proc resize*(g: Grid, width, height: int) =
  ## Resize grid to new dimensions. Preserves existing content, pads with
  ## blanks if growing, truncates if shrinking. Scrollback is maintained.
  g.width = width
  g.height = height
  # Ensure we have enough rows for the visible area
  ensureRow(g, height - 1)
  # Clamp cursor to new bounds
  g.row = min(g.row, max(0, g.rows.len - 1))
  g.col = min(g.col, max(0, width - 1))
  # Trim scrollback if needed
  trimScrollback(g)

proc renderAnsi*(g: Grid, width, height: int): string =
  ## Render grid contents as ANSI escape sequences. Clears screen, moves
  ## cursor home, writes rows with attributes, resets at end.
  result = "\x1b[2J\x1b[H"  # clear screen, home cursor
  
  for r in 0..<min(height, g.rows.len):
    if r > 0:
      result.add "\r\n"
    var lastFg = colDefault
    var lastBg = colDefault
    var lastAttrs = SgrAttr(0)
    var col = 0
    for cell in g.rows[r]:
      if col >= width: break
      # Emit SGR if attributes changed
      if cell.fgColor != lastFg or cell.bgColor != lastBg or cell.attrs.uint16 != lastAttrs.uint16:
        var params: seq[string] = @["0"]  # reset
        # Foreground
        case cell.fgColor
        of colDefault: discard
        of colBlack: params.add "30"
        of colRed: params.add "31"
        of colGreen: params.add "32"
        of colYellow: params.add "33"
        of colBlue: params.add "34"
        of colMagenta: params.add "35"
        of colCyan: params.add "36"
        of colWhite: params.add "37"
        of colBrightBlack: params.add "90"
        of colBrightRed: params.add "91"
        of colBrightGreen: params.add "92"
        of colBrightYellow: params.add "93"
        of colBrightBlue: params.add "94"
        of colBrightMagenta: params.add "95"
        of colBrightCyan: params.add "96"
        of colBrightWhite: params.add "97"
        of col256: params.add "38;5;" & $cell.fgColorIdx
        of colRgb: discard  # not supported in simple renderer
        # Background
        case cell.bgColor
        of colDefault: discard
        of colBlack: params.add "40"
        of colRed: params.add "41"
        of colGreen: params.add "42"
        of colYellow: params.add "43"
        of colBlue: params.add "44"
        of colMagenta: params.add "45"
        of colCyan: params.add "46"
        of colWhite: params.add "47"
        of colBrightBlack: params.add "100"
        of colBrightRed: params.add "101"
        of colBrightGreen: params.add "102"
        of colBrightYellow: params.add "103"
        of colBrightBlue: params.add "104"
        of colBrightMagenta: params.add "105"
        of colBrightCyan: params.add "106"
        of colBrightWhite: params.add "107"
        of col256: params.add "48;5;" & $cell.bgColorIdx
        of colRgb: discard
        # Attributes
        if cell.attrs.hasAttr(saBold): params.add "1"
        if cell.attrs.hasAttr(saDim): params.add "2"
        if cell.attrs.hasAttr(saItalic): params.add "3"
        if cell.attrs.hasAttr(saUnderline): params.add "4"
        if cell.attrs.hasAttr(saBlink): params.add "5"
        if cell.attrs.hasAttr(saReverse): params.add "7"
        if cell.attrs.hasAttr(saStrikethrough): params.add "9"
        result.add "\x1b[" & params.join(";") & "m"
        lastFg = cell.fgColor
        lastBg = cell.bgColor
        lastAttrs = cell.attrs
      if cell.text.len > 0:
        result.add cell.text
      else:
        result.add " "
      inc col
  # Reset attributes at end
  result.add "\x1b[0m"
