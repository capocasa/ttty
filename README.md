# ttty

Headless terminal testing for Nim.

`ttty` is a tiny in-memory terminal mock. Feed it the bytes your terminal UI
would write to stdout, queue the bytes your user would type on stdin, then
assert on the resulting screen grid: rows, cells, cursor position, cursor
visibility, colors, text attributes, and pending input.

It is built for tests that need more truth than `stripAnsi(output)`, but do not
need a real PTY, a screenshot, or a full terminal emulator.

## Why

Terminal UIs fail in places plain string tests cannot see:

- a prompt lands one row too low
- a status bar stacks in scrollback
- `\r`, `\b`, or `\x1b[K` erases the wrong cells
- a hidden cursor is never restored
- a dim prompt accidentally becomes bold cyan
- a wide glyph or combining mark shifts layout

`ttty` gives tests a terminal-shaped view of those bytes.

```nim
import std/unittest
import ttty/grid

test "status stays above prompt":
  let g = newGrid()
  g.feed "\x1b[36mready\x1b[0m\r\n> "

  check rowText(g, 0) == "ready"
  check rowText(g, 1) == "> "
  check g.cellFg(0, 0) == colCyan
  check g.row == 1
  check g.col == 2
```

## Install

```sh
nimble install ttty
```

Or during local development:

```sh
nimble install ~/p/ttty
```

## Quickstart

```nim
import std/unittest
import ttty/grid

suite "terminal output":
  test "carriage return overwrites in place":
    let g = newGrid()
    g.feed "working\rready"

    check rowText(g, 0) == "readyng"
    check g.row == 0
    check g.col == 5

  test "erase to end of line":
    let g = newGrid()
    g.feed "hello"
    g.feed "\x1b[2D"
    g.feed "\x1b[K"

    check rowText(g, 0) == "hel"
```

## The API

The public surface is intentionally small:

```nim
let g = newGrid()
g.feed(bytes)

rowText(g, row)
cellAt(g, row, col)
cellFg(g, row, col)
cellBg(g, row, col)
cellAttr(g, row, col)
hasAttr(attrs, saBold)

let input = newInput()
input.pushText("hello")
input.push(KeyEnter)
input.read()
input.hasPendingInput()

let term = newTerminal(width = 80, height = 24)
term.pushText("hello")
term.write("> hello\r\n")
term.read()
rowText(term.grid, 0)
```

`Grid` and `Cell` fields are public on purpose. For a test tool this small,
direct inspection is often clearer than a large assertion DSL:

```nim
check g.row == 3
check g.col == 0
check g.cursorHidden
check g.cellAt(0, 0).fgColorIdx == 244
```

The defaults are unbounded and conservative. To test wrapping or scrollback,
set dimensions directly:

```nim
let g = newGrid()
g.width = 80
g.height = 24
g.scrollback = 200
g.tabWidth = 4
```

Leaving `width` or `height` at `0` disables that part of the model.

## Text And Cursor Movement

`ttty` handles the common byte controls used by terminal REPLs:

```nim
let g = newGrid()

g.feed "a\nb"       # LF: next row, column 0
check rowText(g, 1) == "b"

g.feed "\rX"        # CR: column 0
check rowText(g, 1) == "X"

g.feed "abc\bZ"     # BS: move left, next write overwrites
check rowText(g, 1) == "XabZ"

g.feed "\tT"        # tab expands to spaces up to the next tab stop
```

## Input Queues

`Input` models the byte stream a terminal application reads from stdin. This is
deliberately byte-oriented because line editors usually need to see exact escape
sequences:

```nim
let input = newInput()
input.pushText("ab")
input.push(KeyLeft)

check input.read() == 'a'.int
check input.read() == 'b'.int
check input.hasPendingInput
check input.read() == 27
```

Common key constants are exported:

```nim
input.push(KeyEnter)
input.push(KeyEsc)
input.push(KeyLeft)
input.push(KeyKittyShiftEnter)
input.push(KeyModifyOtherShiftEnter)
```

`read()` returns `-1` when the queue is empty. `hasPendingInput()` and
`pendingLen()` let tests model timing-sensitive checks such as distinguishing a
bare Escape from an ESC-prefixed key sequence.

## Mock Terminal

`Terminal` combines an input queue with an output grid. It is the usual choice
for testing a REPL or line editor:

```nim
let term = newTerminal(width = 80, height = 24, scrollback = 200)
term.pushText("hello")
term.push(KeyEnter)

let getCh = proc(): int = term.read()
let write = proc(s: string) = term.write(s)
let hasPendingInput = proc(): bool = term.hasPendingInput()

discard myReadline(getCh, write, hasPendingInput)
check rowText(term.grid, 0).startsWith("> hello")
```

Supported CSI movement:

```nim
g.feed "\x1b[2A"    # cursor up
g.feed "\x1b[2B"    # cursor down
g.feed "\x1b[3C"    # cursor forward
g.feed "\x1b[3D"    # cursor back
g.feed "\x1b[10G"   # horizontal absolute, 1-based
g.feed "\x1b[4;1H"  # row/column absolute, 1-based
```

Save and restore cursor position:

```nim
g.feed "\x1b[s"
g.feed "\x1b[10;1H"
g.feed "\x1b[u"
```

Cursor visibility:

```nim
g.feed "\x1b[?25l"
check g.cursorHidden

g.feed "\x1b[?25h"
check not g.cursorHidden
```

Bracketed paste mode state is tracked too:

```nim
g.feed "\x1b[?2004h"
check g.bracketedPaste

g.feed "\x1b[?2004l"
check not g.bracketedPaste
```

## Erasing

Line erase:

```nim
g.feed "\x1b[K"   # clear from cursor to end of line
g.feed "\x1b[1K"  # clear from start of line to cursor
g.feed "\x1b[2K"  # clear entire line
```

Display erase:

```nim
g.feed "\x1b[J"   # clear from cursor to end of display
g.feed "\x1b[1J"  # clear from start of display to cursor
g.feed "\x1b[2J"  # clear display
```

These operations update the grid, not just the visible text string, so later
cell assertions still reflect the new screen state.

## Scroll Regions And In-Place Edits

REPLs with bottom-pinned status rows often rely on terminal scroll regions and
line insertion/deletion. `ttty` models the common CSI forms:

```nim
let g = newGrid()
g.height = 5
g.feed "a\nb\nc\nd\ne"

g.feed "\x1b[2;4r"  # scrolling region: rows 2..4, 1-based
g.feed "\x1b[4;1H"  # move to region bottom
g.feed "\n"         # scrolls only rows 2..4

check rowText(g, 0) == "a"
check rowText(g, 4) == "e"
```

Reset the scroll region with `CSI r`:

```nim
g.feed "\x1b[r"
```

Insert and delete lines:

```nim
g.feed "\x1b[L"   # insert one blank line at cursor row
g.feed "\x1b[2L"  # insert two blank lines
g.feed "\x1b[M"   # delete one line at cursor row
g.feed "\x1b[2M"  # delete two lines
```

Insert and delete characters:

```nim
g.feed "\x1b[2@"  # insert two blank cells at cursor column
g.feed "\x1b[2P"  # delete two cells at cursor column
```

When `width` is set, character insertion truncates at the right edge and
character deletion fills to the right edge with blanks.

## Styles And Colors

`ttty` tracks SGR attributes on each cell:

```nim
let g = newGrid()
g.feed "\x1b[1;3;4mX\x1b[0mY"

check hasAttr(g.cellAttr(0, 0), saBold)
check hasAttr(g.cellAttr(0, 0), saItalic)
check hasAttr(g.cellAttr(0, 0), saUnderline)
check not hasAttr(g.cellAttr(0, 1), saBold)
```

Supported attributes:

- `saBold`
- `saDim`
- `saItalic`
- `saUnderline`
- `saBlink`
- `saReverse`
- `saStrikethrough`

Supported colors:

```nim
g.feed "\x1b[31mred"          # 16-color foreground
g.feed "\x1b[44mblue bg"      # 16-color background
g.feed "\x1b[96mbright cyan"  # bright foreground
g.feed "\x1b[38;5;244mgrey"   # 256-color foreground
g.feed "\x1b[48;5;100mbg"     # 256-color background
```

RGB SGR (`38;2;r;g;b` and `48;2;r;g;b`) is recognized as `colRgb`, but the RGB
components are not stored yet.

Malformed and unknown SGR parameters are ignored instead of raising, matching
the forgiving behavior tests usually need from a terminal model.

## Width, Wrapping, And Unicode

By default, `ttty` does not wrap. Set `g.width` to model a terminal column
limit:

```nim
let g = newGrid()
g.width = 5
g.feed "abcdef"

check rowText(g, 0) == "abcde"
check rowText(g, 1) == "f"
```

Wide glyphs consume two cells:

```nim
let g = newGrid()
g.width = 4
g.feed "abc界Z"

check rowText(g, 0) == "abc"
check rowText(g, 1) == "界Z"
check cellAt(g, 1, 0).width == 2
```

Combining marks attach to the previous cell without advancing the cursor:

```nim
let g = newGrid()
g.feed "e\u0301X"

check rowText(g, 0) == "e\u0301X"
check g.col == 2
```

The width table is intentionally approximate. It covers common CJK ranges,
fullwidth forms, and emoji blocks well enough for CLI layout tests. It is not a
replacement for a full Unicode terminal width database.

## Scrollback

Set `height` to model a visible terminal height. Set `scrollback` to keep rows
above the visible viewport:

```nim
let g = newGrid()
g.height = 2
g.scrollback = 1
g.feed "a\nb\nc\nd"

check g.rows.len == 3
check rowText(g, 0) == "b"
check rowText(g, 1) == "c"
check rowText(g, 2) == "d"
```

If `height == 0`, the grid is unbounded and never scrolls.

## Testing A REPL

The usual pattern is to inject a write callback in your REPL/editor, feed every
write into a grid, and assert at checkpoints:

```nim
type Driver = ref object
  grid: Grid
  output: string

let d = Driver(grid: newGrid())
d.grid.width = 80
d.grid.height = 24
d.grid.scrollback = 200

let write = proc(s: string) =
  d.output.add s
  d.grid.feed s

myReadline(write)

check rowText(d.grid, d.grid.row).startsWith("> ")
check not d.grid.cursorHidden
```

For applications with persistent footer/status rows, assert both text and
geometry:

```nim
check "tokens" in rowText(g, g.row)
check ">" in rowText(g, g.row + 1)
check g.cellFg(g.row, 0) == colCyan
check hasAttr(g.cellAttr(g.row, 0), saBold)
```

## Limitations

`ttty` is a focused terminal mock, not a complete terminal emulator.

Currently modeled:

- text writes, CR, LF, backspace, tabs
- cursor movement and absolute positioning
- line/display erase
- save/restore cursor
- cursor visibility
- bracketed paste mode state
- scroll regions
- insert/delete line and insert/delete character
- SGR attributes, 16-color, 256-color, RGB marker
- optional width, wrapping, terminal height, and scrollback
- wide glyphs and combining marks
- byte-oriented input queues
- combined input/output mock terminals

Not currently modeled:

- alternate screen buffers
- origin mode and margins beyond scroll regions
- OSC sequences
- mouse tracking
- PTY process management
- exact Unicode version and East Asian Ambiguous width policy
- RGB component storage

For enhanced REPLs, the next useful additions are likely alternate screen,
origin mode, and OSC title/clipboard handling if your UI starts emitting them.
For bottom-pinned bars and prompts, scroll regions and insert/delete operations
are already modeled.

## Design Notes

The library is deliberately direct:

- no PTY process management
- no subprocess
- no terminal database
- no screenshot comparison
- no assertion DSL

That keeps tests fast and local. It also makes failures easy to inspect:
`rowText(g, n)` tells you what text is on a row, and `cellAt(g, r, c)` tells you
what style is on a cell.

When `ttty` does not model something, prefer adding a small terminal behavior
with tests over adding a broad abstraction. The value of the tool is that it
stays close to the bytes terminal applications actually emit.
