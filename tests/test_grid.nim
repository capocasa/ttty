import std/unittest
import ttty/grid

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
  test "SGR sequences are silently consumed":
    let g = newGrid()
    g.feed("\x1b[1;31mred\x1b[0m")
    check g.rowText(0) == "red"
    check g.col == 3

  test "bare SGR does not crash":
    let g = newGrid()
    g.feed("\x1b[m")
    check g.rowText(0) == ""

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
