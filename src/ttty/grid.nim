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
    fgColor*: Color
    bgColor*: Color
    colorIdx*: uint8
    fgColorIdx*: uint8
    bgColorIdx*: uint8
    attrs*: SgrAttr

  Grid* = ref object
    rows*: seq[seq[Cell]]
    row*, col*: int
    savedRow*, savedCol*: int
    hasSaved*: bool
    cursorHidden*: bool
    curFg*: Color
    curBg*: Color
    curFgIdx*: uint8
    curBgIdx*: uint8
    curAttrs*: SgrAttr

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
  Cell(rune: rune, fgColor: fg, bgColor: bg,
       fgColorIdx: fi, bgColorIdx: bi, attrs: attrs)

proc newGrid*(): Grid =
  Grid(rows: @[newSeq[Cell]()],
       row: 0, col: 0, savedRow: 0, savedCol: 0,
       hasSaved: false, cursorHidden: false,
       curFg: colDefault, curBg: colDefault, curAttrs: SgrAttr(0))

proc ensureRow*(g: Grid, r: int) =
  while g.rows.len <= r:
    g.rows.add newSeq[Cell]()

proc padTo(row: var seq[Cell], col: int, fg: Color, bg: Color,
           ci: uint8, attrs: SgrAttr) =
  while row.len < col:
    row.add Cell(rune: Rune(' '), fgColor: fg, bgColor: bg,
                 colorIdx: ci, attrs: attrs)

proc putRune(g: Grid, r: Rune) =
  ensureRow(g, g.row)
  padTo(g.rows[g.row], g.col, g.curFg, g.curBg, g.curFgIdx, g.curAttrs)
  let cell = Cell(rune: r, fgColor: g.curFg, bgColor: g.curBg,
                  fgColorIdx: g.curFgIdx, bgColorIdx: g.curBgIdx, attrs: g.curAttrs)
  if g.rows[g.row].len == g.col:
    g.rows[g.row].add cell
  else:
    g.rows[g.row][g.col] = cell
  inc g.col

proc eraseLine(g: Grid, mode: int) =
  ensureRow(g, g.row)
  case mode
  of 0:
    if g.rows[g.row].len > g.col:
      g.rows[g.row].setLen(g.col)
  of 1:
    for k in 0 ..< min(g.col, g.rows[g.row].len):
      g.rows[g.row][k] = Cell(rune: Rune(' '))
  of 2:
    g.rows[g.row].setLen(0)
  else: discard

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
      g.rows[g.row][k] = Cell(rune: Rune(' '))
  of 2:
    for r in 0 ..< g.rows.len:
      g.rows[r].setLen(0)
  else: discard

proc parseN(s: string): int =
  if s.len == 0: return 1
  try: max(1, parseInt(s))
  except ValueError: 1

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
    let n = if p.len == 0: 0 else: parseInt(p)
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
        let idx = parseInt(parts[i + 2])
        if idx < 16:
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
        let idx = parseInt(parts[i + 2])
        if idx < 16:
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

proc feed*(g: Grid, bytes: string) =
  var i = 0
  while i < bytes.len:
    let b = bytes[i]
    case b
    of '\r':
      g.col = 0
      inc i
    of '\n':
      inc g.row
      g.col = 0
      ensureRow(g, g.row)
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
        else:
          case final
          of 'A':
            g.row = max(0, g.row - parseN(params))
          of 'B':
            g.row += parseN(params); ensureRow(g, g.row)
          of 'C':
            g.col += parseN(params)
          of 'D':
            g.col = max(0, g.col - parseN(params))
          of 'G':
            g.col = max(0, parseN(params) - 1)
          of 'K':
            var mode = 0
            if params.len > 0:
              try: mode = parseInt(params)
              except ValueError: discard
            eraseLine(g, mode)
          of 'J':
            var mode = 0
            if params.len > 0:
              try: mode = parseInt(params)
              except ValueError: discard
            eraseDisplay(g, mode)
          of 'm':
            applySgr(g, params)
          of 's':
            g.savedRow = g.row
            g.savedCol = g.col
            g.hasSaved = true
          of 'u':
            if g.hasSaved:
              g.row = g.savedRow
              g.col = g.savedCol
              ensureRow(g, g.row)
          of 'H', 'f':
            let semi = params.find(';')
            let r = if semi < 0: parseN(params) - 1
                    else: parseN(params[0 ..< semi]) - 1
            let c = if semi < 0: 0 else: parseN(params[semi + 1 .. ^1]) - 1
            g.row = max(0, r); g.col = max(0, c)
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

proc rowText*(g: Grid, r: int): string =
  if r < 0 or r >= g.rows.len: return ""
  for cell in g.rows[r]: result.add $cell.rune

proc cellAt*(g: Grid, r, c: int): Cell =
  if r < 0 or r >= g.rows.len: return Cell(rune: Rune(' '))
  if c < 0 or c >= g.rows[r].len: return Cell(rune: Rune(' '))
  g.rows[r][c]

proc cellAttr*(g: Grid, r, c: int): SgrAttr =
  g.cellAt(r, c).attrs

proc cellFg*(g: Grid, r, c: int): Color =
  g.cellAt(r, c).fgColor

proc cellBg*(g: Grid, r, c: int): Color =
  g.cellAt(r, c).bgColor
