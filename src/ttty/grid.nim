import std/[unicode, strutils]

type
  Grid* = ref object
    rows*: seq[seq[Rune]]
    row*, col*: int
    savedRow*, savedCol*: int
    hasSaved*: bool
    cursorHidden*: bool

proc newGrid*(): Grid =
  Grid(rows: @[newSeq[Rune]()], row: 0, col: 0,
       savedRow: 0, savedCol: 0, hasSaved: false,
       cursorHidden: false)

proc ensureRow*(g: Grid, r: int) =
  while g.rows.len <= r:
    g.rows.add newSeq[Rune]()

proc padTo(row: var seq[Rune], col: int) =
  while row.len < col:
    row.add Rune(' ')

proc putRune(g: Grid, r: Rune) =
  ensureRow(g, g.row)
  padTo(g.rows[g.row], g.col)
  if g.rows[g.row].len == g.col:
    g.rows[g.row].add r
  else:
    g.rows[g.row][g.col] = r
  inc g.col

proc eraseLine(g: Grid, mode: int) =
  ensureRow(g, g.row)
  case mode
  of 0:
    if g.rows[g.row].len > g.col:
      g.rows[g.row].setLen(g.col)
  of 1:
    for k in 0 ..< min(g.col, g.rows[g.row].len):
      g.rows[g.row][k] = Rune(' ')
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
      g.rows[g.row][k] = Rune(' ')
  of 2:
    for r in 0 ..< g.rows.len:
      g.rows[r].setLen(0)
  else: discard

proc parseN(s: string): int =
  if s.len == 0: return 1
  try: max(1, parseInt(s))
  except ValueError: 1

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
            discard
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
  for ru in g.rows[r]: result.add $ru
