import std/unittest
import std/unicode
import ttty

suite "grid: plain text":
  test "plain text renders on row 0":
    let g = newGrid()
    g.feed("hello")
    check g.rowText(0) == "hello"
    check g.row == 0
    check g.col == 5

  test "UTF-8 multi-byte characters":
    let g = newGrid()
    g.feed("café")
    check g.rowText(0) == "café"

  test "empty grid has one empty row":
    let g = newGrid()
    check g.rowText(0) == ""
    check g.rows.len == 1

suite "grid: line breaks":
  test "LF moves to next row":
    let g = newGrid()
    g.feed("ab\ncd")
    check g.rowText(0) == "ab"
    check g.rowText(1) == "cd"

  test "CR resets column":
    let g = newGrid()
    g.feed("abc\rX")
    check g.rowText(0) == "Xbc"

  test "CR+LF moves to next row":
    let g = newGrid()
    g.feed("ab\r\ncd")
    check g.rowText(0) == "ab"
    check g.rowText(1) == "cd"

suite "grid: cursor movement":
  test "cursor up (A)":
    let g = newGrid()
    g.feed("line1\nline2")
    check g.row == 1
    g.feed("\x1b[1A")
    check g.row == 0
    g.feed("\x1b[1G")  # col 0
    g.feed("X")
    check g.rowText(0) == "Xine1"

  test "cursor down (B)":
    let g = newGrid()
    g.feed("hi")
    check g.row == 0
    g.feed("\x1b[2B")
    check g.row == 2

  test "cursor forward (C)":
    let g = newGrid()
    g.feed("ab")
    g.feed("\x1b[3C")
    check g.col == 5

  test "cursor back (D) clamps at 0":
    let g = newGrid()
    g.feed("abc")
    g.feed("\x1b[10D")
    check g.col == 0

  test "cursor horizontal absolute (G) is 1-based":
    let g = newGrid()
    g.feed("abcde")
    g.feed("\x1b[3G")
    check g.col == 2

  test "cursor position (H) row;col is 1-based":
    let g = newGrid()
    g.feed("row0\nrow1\nrow2")
    g.feed("\x1b[2;4H")
    check g.row == 1
    check g.col == 3

  test "H with no params goes to 0,0":
    let g = newGrid()
    g.feed("hello\nworld")
    g.feed("\x1b[H")
    check g.row == 0
    check g.col == 0

suite "grid: line erase":
  test "erase to end of line (K mode 0)":
    let g = newGrid()
    g.feed("hello")
    g.feed("\x1b[2D")  # back 2 -> col 3
    g.feed("\x1b[K")
    check g.rowText(0) == "hel"

  test "erase from start of line (K mode 1)":
    let g = newGrid()
    g.feed("hello")
    g.feed("\x1b[2D")  # col 3
    g.feed("\x1b[1K")
    check g.rowText(0) == "   lo"

  test "erase entire line (K mode 2)":
    let g = newGrid()
    g.feed("hello")
    g.feed("\x1b[2K")
    check g.rowText(0) == ""

suite "grid: display erase":
  test "erase from start to cursor (J mode 1)":
    let g = newGrid()
    g.feed("row0\nrow1\nrow2")
    g.feed("\x1b[1;3H")  # row 0, col 2
    g.feed("\x1b[1J")
    check g.rowText(0) == "  w0"
    check g.rowText(1) == "row1"
    check g.rowText(2) == "row2"

  test "erase entire display (J mode 2)":
    let g = newGrid()
    g.feed("abc\ndef\nghi")
    g.feed("\x1b[2J")
    check g.rowText(0) == ""
    check g.rowText(1) == ""
    check g.rowText(2) == ""

suite "grid: cursor save/restore":
  test "save and restore cursor position":
    let g = newGrid()
    g.feed("hello")
    check g.row == 0
    check g.col == 5
    g.feed("\x1b[s")
    g.feed("\x1b[2;1H")
    check g.row == 1
    check g.col == 0
    g.feed("\x1b[u")
    check g.row == 0
    check g.col == 5
    check g.hasSaved == true

  test "restore without save is no-op":
    let g = newGrid()
    g.feed("abc")
    g.feed("\x1b[u")
    check g.row == 0
    check g.col == 3

suite "grid: cursor visibility":
  test "CSI ?25 l hides cursor":
    let g = newGrid()
    check g.cursorHidden == false
    g.feed("\x1b[?25l")
    check g.cursorHidden == true

  test "CSI ?25 h shows cursor":
    let g = newGrid()
    g.feed("\x1b[?25l")
    check g.cursorHidden == true
    g.feed("\x1b[?25h")
    check g.cursorHidden == false

suite "grid: SGR passthrough":
  test "SGR sequences do not affect text":
    let g = newGrid()
    g.feed("\x1b[1;31mred\x1b[0m")
    check g.rowText(0) == "red"
    check g.col == 3

  test "bare SGR does not crash":
    let g = newGrid()
    g.feed("\x1b[m")
    check g.rowText(0) == ""

suite "grid: SGR attribute tracking":
  test "bold attribute":
    let g = newGrid()
    g.feed("\x1b[1mX")
    check g.cellAt(0, 0).attrs.hasAttr(saBold)

  test "dim attribute":
    let g = newGrid()
    g.feed("\x1b[2mX")
    check g.cellAt(0, 0).attrs.hasAttr(saDim)

  test "italic attribute":
    let g = newGrid()
    g.feed("\x1b[3mX")
    check g.cellAt(0, 0).attrs.hasAttr(saItalic)

  test "underline attribute":
    let g = newGrid()
    g.feed("\x1b[4mX")
    check g.cellAt(0, 0).attrs.hasAttr(saUnderline)

  test "blink attribute":
    let g = newGrid()
    g.feed("\x1b[5mX")
    check g.cellAt(0, 0).attrs.hasAttr(saBlink)

  test "blink attribute (fast blink code 6)":
    let g = newGrid()
    g.feed("\x1b[6mX")
    check g.cellAt(0, 0).attrs.hasAttr(saBlink)

  test "reverse attribute":
    let g = newGrid()
    g.feed("\x1b[7mX")
    check g.cellAt(0, 0).attrs.hasAttr(saReverse)

  test "strikethrough attribute":
    let g = newGrid()
    g.feed("\x1b[9mX")
    check g.cellAt(0, 0).attrs.hasAttr(saStrikethrough)

  test "reset clears all attributes":
    let g = newGrid()
    g.feed("\x1b[1;3;4mX\x1b[0mY")
    check g.cellAt(0, 0).attrs.hasAttr(saBold)
    check g.cellAt(0, 0).attrs.hasAttr(saItalic)
    check g.cellAt(0, 0).attrs.hasAttr(saUnderline)
    check not g.cellAt(0, 1).attrs.hasAttr(saBold)
    check not g.cellAt(0, 1).attrs.hasAttr(saItalic)
    check not g.cellAt(0, 1).attrs.hasAttr(saUnderline)

  test "turning off individual attributes":
    let g = newGrid()
    g.feed("\x1b[1;3mX\x1b[23mY")
    check g.cellAt(0, 0).attrs.hasAttr(saBold)
    check g.cellAt(0, 0).attrs.hasAttr(saItalic)
    check g.cellAt(0, 1).attrs.hasAttr(saBold)
    check not g.cellAt(0, 1).attrs.hasAttr(saItalic)

  test "22 turns off bold and dim":
    let g = newGrid()
    g.feed("\x1b[1;2mX\x1b[22mY")
    check g.cellAt(0, 0).attrs.hasAttr(saBold)
    check g.cellAt(0, 0).attrs.hasAttr(saDim)
    check not g.cellAt(0, 1).attrs.hasAttr(saBold)
    check not g.cellAt(0, 1).attrs.hasAttr(saDim)

  test "multiple attributes stack":
    let g = newGrid()
    g.feed("\x1b[1;3;4;5;7;9mX")
    let a = g.cellAt(0, 0).attrs
    check a.hasAttr(saBold)
    check a.hasAttr(saItalic)
    check a.hasAttr(saUnderline)
    check a.hasAttr(saBlink)
    check a.hasAttr(saReverse)
    check a.hasAttr(saStrikethrough)

  test "attributes apply to new cells only":
    let g = newGrid()
    g.feed("A")
    g.feed("\x1b[1mB")
    check not g.cellAt(0, 0).attrs.hasAttr(saBold)
    check g.cellAt(0, 1).attrs.hasAttr(saBold)

suite "grid: SGR color tracking":
  test "standard 16-color fg (30-37)":
    for i in 0..7:
      let g = newGrid()
      g.feed("\x1b[" & $(30 + i) & "mX")
      check g.cellFg(0, 0) == Color(1 + i)

  test "standard 16-color bg (40-47)":
    for i in 0..7:
      let g = newGrid()
      g.feed("\x1b[" & $(40 + i) & "mX")
      check g.cellBg(0, 0) == Color(1 + i)

  test "bright fg (90-97)":
    for i in 0..7:
      let g = newGrid()
      g.feed("\x1b[" & $(90 + i) & "mX")
      check g.cellFg(0, 0) == Color(9 + i)

  test "bright bg (100-107)":
    for i in 0..7:
      let g = newGrid()
      g.feed("\x1b[" & $(100 + i) & "mX")
      check g.cellBg(0, 0) == Color(9 + i)

  test "256-color fg via 38;5;n":
    let g = newGrid()
    g.feed("\x1b[38;5;244mX")
    let c = g.cellAt(0, 0)
    check c.fgColor == col256
    check c.fgColorIdx == 244

  test "256-color bg via 48;5;n":
    let g = newGrid()
    g.feed("\x1b[48;5;100mX")
    let c = g.cellAt(0, 0)
    check c.bgColor == col256
    check c.bgColorIdx == 100

  test "39 resets fg to default":
    let g = newGrid()
    g.feed("\x1b[31mX\x1b[39mY")
    check g.cellFg(0, 0) == colRed
    check g.cellFg(0, 1) == colDefault

  test "49 resets bg to default":
    let g = newGrid()
    g.feed("\x1b[44mX\x1b[49mY")
    check g.cellBg(0, 0) == colBlue
    check g.cellBg(0, 1) == colDefault

  test "cellAt out of range returns default cell":
    let g = newGrid()
    let c = g.cellAt(99, 99)
    check c.rune == Rune(' ')
    check c.fgColor == colDefault
    check c.bgColor == colDefault
    check not c.attrs.hasAttr(saBold)

  test "convenience procs cellAttr, cellFg, cellBg":
    let g = newGrid()
    g.feed("\x1b[1;36mX")
    check g.cellAttr(0, 0).hasAttr(saBold)
    check g.cellFg(0, 0) == colCyan
    check g.cellBg(0, 0) == colDefault

suite "grid: edge cases":
  test "rowText returns empty for out-of-range rows":
    let g = newGrid()
    check g.rowText(-1) == ""
    check g.rowText(99) == ""

  test "overwriting a cell":
    let g = newGrid()
    g.feed("abc")
    g.feed("\x1b[1G")  # col 0
    g.feed("X")
    check g.rowText(0) == "Xbc"

  test "writing past row end extends with spaces":
    let g = newGrid()
    g.feed("ab")
    g.feed("\x1b[5G")  # col 4
    g.feed("Z")
    check g.rowText(0) == "ab  Z"

  test "multiple newlines create empty rows":
    let g = newGrid()
    g.feed("a\n\nb")
    check g.rowText(0) == "a"
    check g.rowText(1) == ""
    check g.rowText(2) == "b"

suite "grid: terminal-like editing":
  test "backspace moves cursor left and next write overwrites":
    let g = newGrid()
    g.feed("abc\bX")
    check g.rowText(0) == "abX"
    check g.col == 3

  test "tab advances to the next tab stop with styled spaces":
    let g = newGrid()
    g.feed("\x1b[38;5;244mab\tX")
    check g.rowText(0) == "ab      X"
    check g.cellFg(0, 2) == col256
    check g.cellAt(0, 2).fgColorIdx == 244
    check g.cellFg(0, 7) == col256
    check g.cellAt(0, 7).fgColorIdx == 244

  test "custom tab width":
    let g = newGrid()
    g.tabWidth = 4
    g.feed("ab\tX")
    check g.rowText(0) == "ab  X"

suite "grid: width and wrapping":
  test "exactly filling a row leaves wrap pending until next printable":
    let g = newGrid()
    g.width = 5
    g.feed("abcde")
    check g.rowText(0) == "abcde"
    check g.row == 0
    check g.col == 5
    check g.pendingWrap

  test "plain text wraps when width is set":
    let g = newGrid()
    g.width = 5
    g.feed("abcdef")
    check g.rowText(0) == "abcde"
    check g.rowText(1) == "f"
    check g.row == 1
    check g.col == 1

  test "wide glyph consumes two cells and wraps before overflow":
    let g = newGrid()
    g.width = 4
    g.feed("abc界Z")
    check g.rowText(0) == "abc"
    check g.rowText(1) == "界Z"
    check g.cellAt(1, 0).width == 2
    check g.cellAt(1, 1).width == 0
    check g.col == 3

  test "combining mark attaches to previous cell without advancing":
    let g = newGrid()
    g.feed("e\u0301X")
    check g.rowText(0) == "e\u0301X"
    check g.col == 2
    check g.cellAt(0, 0).text == "e\u0301"
    check g.cellAt(0, 1).text == "X"

suite "grid: scrollback":
  test "height limits visible rows and scrollback keeps history":
    let g = newGrid()
    g.height = 2
    g.scrollback = 1
    g.feed("a\nb\nc\nd")
    check g.rows.len == 3
    check g.rowText(0) == "b"
    check g.rowText(1) == "c"
    check g.rowText(2) == "d"
    check g.row == 2

suite "grid: malformed input is terminal-like":
  test "malformed SGR params are ignored rather than raised":
    let g = newGrid()
    g.feed("\x1b[38;5;mX")
    check g.rowText(0) == "X"
    check g.cellFg(0, 0) == colDefault

  test "out-of-range 256-color param is ignored":
    let g = newGrid()
    g.feed("\x1b[38;5;999mX")
    check g.rowText(0) == "X"
    check g.cellFg(0, 0) == colDefault

  test "unknown private mode is ignored":
    let g = newGrid()
    g.feed("\x1b[?2026hX\x1b[?2026l")
    check g.rowText(0) == "X"

suite "grid: scroll regions":
  test "CSI r sets region and linefeed scrolls only that region":
    let g = newGrid()
    g.height = 5
    g.feed("a\nb\nc\nd\ne")
    g.feed("\x1b[2;4r")
    g.feed("\x1b[4;1H")
    g.feed("\n")
    check g.rowText(0) == "a"
    check g.rowText(1) == "c"
    check g.rowText(2) == "d"
    check g.rowText(3) == ""
    check g.rowText(4) == "e"
    check g.row == 3
    check g.col == 0

  test "empty CSI r resets region to full screen":
    let g = newGrid()
    g.height = 3
    g.feed("\x1b[2;3r")
    check g.scrollTop == 1
    check g.scrollBottom == 2
    g.feed("\x1b[r")
    check g.scrollTop == 0
    check g.scrollBottom == 0

suite "grid: insert and delete lines":
  test "CSI L inserts blank lines inside scroll region":
    let g = newGrid()
    g.height = 5
    g.feed("a\nb\nc\nd\ne")
    g.feed("\x1b[2;5r")
    g.feed("\x1b[3;1H")
    g.feed("\x1b[L")
    check g.rowText(0) == "a"
    check g.rowText(1) == "b"
    check g.rowText(2) == ""
    check g.rowText(3) == "c"
    check g.rowText(4) == "d"

  test "CSI M deletes lines inside scroll region":
    let g = newGrid()
    g.height = 5
    g.feed("a\nb\nc\nd\ne")
    g.feed("\x1b[2;5r")
    g.feed("\x1b[3;1H")
    g.feed("\x1b[M")
    check g.rowText(0) == "a"
    check g.rowText(1) == "b"
    check g.rowText(2) == "d"
    check g.rowText(3) == "e"
    check g.rowText(4) == ""

  test "insert line outside scroll region is ignored":
    let g = newGrid()
    g.height = 4
    g.feed("a\nb\nc\nd")
    g.feed("\x1b[2;3r")
    g.feed("\x1b[1;1H")
    g.feed("\x1b[L")
    check g.rowText(0) == "a"
    check g.rowText(1) == "b"
    check g.rowText(2) == "c"
    check g.rowText(3) == "d"

suite "grid: insert and delete characters":
  test "CSI @ inserts blanks at cursor and truncates at width":
    let g = newGrid()
    g.width = 6
    g.feed("abcdef")
    g.feed("\x1b[1;3H")
    g.feed("\x1b[2@")
    check g.rowText(0) == "ab  cd"
    check g.col == 2

  test "CSI P deletes characters and fills to width":
    let g = newGrid()
    g.width = 6
    g.feed("abcdef")
    g.feed("\x1b[1;3H")
    g.feed("\x1b[2P")
    check g.rowText(0) == "abef  "
    check g.col == 2

suite "grid: bracketed paste mode":
  test "CSI ?2004 h/l toggles bracketed paste state":
    let g = newGrid()
    check not g.bracketedPaste
    g.feed("\x1b[?2004h")
    check g.bracketedPaste
    g.feed("\x1b[?2004l")
    check not g.bracketedPaste

suite "input: queued bytes":
  test "text and key sequences are read in order":
    let input = newInput()
    input.pushText("ab")
    input.push(KeyLeft)
    check input.pendingLen == 5
    check input.read() == 'a'.int
    check input.read() == 'b'.int
    check input.hasPendingInput
    check input.read() == 27
    check input.read() == 91
    check input.read() == 68
    check input.read() == -1
    check not input.hasPendingInput

  test "clear removes queued and consumed input":
    let input = newInput()
    input.pushText("abc")
    check input.read() == 'a'.int
    input.clear()
    check input.pendingLen == 0
    check input.read() == -1

suite "terminal: input and output":
  test "terminal combines input queue with output grid":
    let term = newTerminal(width = 10, height = 3, scrollback = 2)
    term.pushText("hi")
    term.push(KeyEnter)
    term.write("> hi\r\n")
    check term.read() == 'h'.int
    check term.read() == 'i'.int
    check term.read() == 13
    check term.read() == -1
    check rowText(term.grid, 0) == "> hi"
    check term.output == "> hi\r\n"

  test "terminal hasPendingInput tracks the input queue":
    let term = newTerminal()
    check not term.hasPendingInput
    term.push(KeyModifyOtherShiftEnter)
    check term.hasPendingInput
    while term.read() >= 0:
      discard
    check not term.hasPendingInput
