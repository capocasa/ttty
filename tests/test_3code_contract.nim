import std/[strutils, unicode, unittest]
import ttty/grid

type
  ExpectedStyle = object
    fg, bg: Color
    bold, dim, italic, underline: bool

  ExpectedCell = object
    text: string
    style: ExpectedStyle

proc colorName(name: string): Color =
  case name
  of "black": colBlack
  of "red": colRed
  of "green": colGreen
  of "yellow": colYellow
  of "blue": colBlue
  of "magenta": colMagenta
  of "cyan": colCyan
  of "white": colWhite
  of "bright-black": colBrightBlack
  of "bright-red": colBrightRed
  of "bright-green": colBrightGreen
  of "bright-yellow": colBrightYellow
  of "bright-blue": colBrightBlue
  of "bright-magenta": colBrightMagenta
  of "bright-cyan": colBrightCyan
  of "bright-white": colBrightWhite
  else: colDefault

proc parseMarkup(markup: string): seq[ExpectedCell] =
  ## Tiny test-only formatting language:
  ##   <cyan bold>text</>
  ##   <red bg:bright-white underline>text</>
  ## Tags are intentionally not nested; each opening tag starts from
  ## default style. This keeps formatting expectations readable without
  ## introducing a general parser.
  var style = ExpectedStyle(fg: colDefault, bg: colDefault)
  var i = 0
  while i < markup.len:
    if markup[i] == '<':
      let close = markup.find('>', i + 1)
      if close < 0:
        break
      let tag = markup[i + 1 ..< close].strip
      style = ExpectedStyle(fg: colDefault, bg: colDefault)
      if tag != "/":
        for part in strutils.splitWhitespace(tag):
          if part.startsWith("bg:"):
            style.bg = colorName(part[3 .. ^1])
          else:
            case part
            of "bold": style.bold = true
            of "dim": style.dim = true
            of "italic": style.italic = true
            of "underline": style.underline = true
            else: style.fg = colorName(part)
      i = close + 1
    else:
      let rl = max(1, runeLenAt(markup, i))
      result.add ExpectedCell(text: markup[i ..< i + rl], style: style)
      i += rl

proc checkMarkup(g: Grid, row, col: int, markup: string) =
  let expected = parseMarkup(markup)
  for i, exp in expected:
    let c = g.cellAt(row, col + i)
    check c.text == exp.text
    check c.fgColor == exp.style.fg
    check c.bgColor == exp.style.bg
    check hasAttr(c.attrs, saBold) == exp.style.bold
    check hasAttr(c.attrs, saDim) == exp.style.dim
    check hasAttr(c.attrs, saItalic) == exp.style.italic
    check hasAttr(c.attrs, saUnderline) == exp.style.underline

suite "ttty grid validation":
  test "cursor movement overwrites at the expected cell":
    let g = newGrid()
    g.feed "abc"
    g.feed "\x1b[2D"
    g.feed "XY"

    check rowText(g, 0).startsWith("aXY")
    check g.row == 0
    check g.col == 3

  test "absolute row and column addressing is one-based":
    let g = newGrid()
    g.feed "\x1b[3;5HZ"

    check rowText(g, 2)[4] == 'Z'
    check g.row == 2
    check g.col == 5

  test "carriage return and line feed match terminal output needs":
    let g = newGrid()
    g.feed "abc\rZ\nQ"

    check rowText(g, 0).startsWith("Zbc")
    check rowText(g, 1).startsWith("Q")

  test "erase line and erase to end of screen clear owned rows":
    let g = newGrid()
    g.feed "one\ntwo\nthree"
    g.feed "\x1b[2;1H\x1b[2K"
    check rowText(g, 0).startsWith("one")
    check rowText(g, 1).strip == ""
    check rowText(g, 2).startsWith("three")

    g.feed "\x1b[2;1H\x1b[J"
    check rowText(g, 0).startsWith("one")
    check rowText(g, 1).strip == ""
    check rowText(g, 2).strip == ""

  test "synchronized update wrappers are ignored as harmless terminal modes":
    let g = newGrid()
    g.feed "\x1b[?2026hA\x1b[?2026lB"

    check rowText(g, 0).startsWith("AB")

  test "utf-8 glyphs used by the UI occupy stable cells":
    let g = newGrid()
    g.feed "❯ ○ ↑ ↓ ↻"

    check rowText(g, 0).startsWith("❯ ○ ↑ ↓ ↻")
    check g.cellAt(0, 0).text == "❯"
    check g.cellAt(0, 2).text == "○"
    check g.cellAt(0, 4).text == "↑"
    check g.cellAt(0, 6).text == "↓"
    check g.cellAt(0, 8).text == "↻"

  test "16 foreground colors and reset are represented":
    let g = newGrid()
    g.feed "\x1b[30m0\x1b[31m1\x1b[32m2\x1b[33m3"
    g.feed "\x1b[34m4\x1b[35m5\x1b[36m6\x1b[37m7"
    g.feed "\x1b[90m8\x1b[91m9\x1b[92ma\x1b[93mb"
    g.feed "\x1b[94mc\x1b[95md\x1b[96me\x1b[97mf"
    g.feed "\x1b[0m!"

    checkMarkup(g, 0, 0,
      "<black>0</><red>1</><green>2</><yellow>3</>" &
      "<blue>4</><magenta>5</><cyan>6</><white>7</>" &
      "<bright-black>8</><bright-red>9</><bright-green>a</>" &
      "<bright-yellow>b</><bright-blue>c</><bright-magenta>d</>" &
      "<bright-cyan>e</><bright-white>f</>!")

  test "16 background colors are represented":
    let g = newGrid()
    g.feed "\x1b[40m0\x1b[41m1\x1b[42m2\x1b[43m3"
    g.feed "\x1b[44m4\x1b[45m5\x1b[46m6\x1b[47m7"
    g.feed "\x1b[100m8\x1b[101m9\x1b[102ma\x1b[103mb"
    g.feed "\x1b[104mc\x1b[105md\x1b[106me\x1b[107mf"

    checkMarkup(g, 0, 0,
      "<bg:black>0</><bg:red>1</><bg:green>2</><bg:yellow>3</>" &
      "<bg:blue>4</><bg:magenta>5</><bg:cyan>6</><bg:white>7</>" &
      "<bg:bright-black>8</><bg:bright-red>9</><bg:bright-green>a</>" &
      "<bg:bright-yellow>b</><bg:bright-blue>c</><bg:bright-magenta>d</>" &
      "<bg:bright-cyan>e</><bg:bright-white>f</>")

  test "basic SGR attrs and reset are represented":
    let g = newGrid()
    g.feed "\x1b[1mB\x1b[0m\x1b[2mD\x1b[0m"
    g.feed "\x1b[3mI\x1b[0m\x1b[4mU\x1b[0mN"

    checkMarkup(g, 0, 0,
      "<bold>B</><dim>D</><italic>I</><underline>U</>N")
