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
  if g.width > 0 and g.col > 0 and g.col + w > g.width:
    lineFeed(g)
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
    if g.rows[g.row].len > g.col:
      g.rows[g.row].setLen(g.col)
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

proc feed*(g: Grid, bytes: string) =
  var i = 0
  while i < bytes.len:
    let b = bytes[i]
    case b
    of '\r':
      g.col = 0
      g.pendingWrap = false
      inc i
    of '\n':
      lineFeed(g)
      inc i
    of '\t':
      tab(g)
      inc i
    of '\b':
      backspace(g)
      inc i
    of '\x1b':
      if i + 1 < bytes.len and bytes[i + 1] == '[':
        var j = i + 2
        var private = false
        if j < bytes.len and bytes[j] == '?':
          private = true; inc j
        var params = ""
        while j < bytes.len and (bytes[j] in {'0'..'9'} or bytes[j] == ';'):
          params.add bytes[j]
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
            # DEC 2026 synchronized output. Semantics (batching) are not
            # modeled — only frame well-formedness is validated.
            if final == 'h':
              if g.syncOpen:
                g.violations.add "nested DEC 2026 sync begin at byte " & $i
              g.syncOpen = true
            elif final == 'l':
              if not g.syncOpen:
                g.violations.add "DEC 2026 sync end without begin at byte " & $i
              g.syncOpen = false
        else:
          case final
          of '@':
            insertChars(g, parseN(params))
          of 'A':
            g.row = max(0, g.row - parseN(params))
            g.pendingWrap = false
          of 'B':
            g.row += parseN(params); ensureRow(g, g.row)
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
      else:
        inc i
    else:
      let rl = runeLenAt(bytes, i)
      let r = runeAt(bytes, i)
      putRune(g, r)
      i += rl

proc checkStreamClosed*(g: Grid) =
  ## Call when a byte stream is complete: flags a DEC 2026 sync begin
  ## that was never closed.
  if g.syncOpen:
    g.violations.add "DEC 2026 sync begin never closed"
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
