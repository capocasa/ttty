import ttty/grid
import ttty/input

type
  Terminal* = ref object
    grid*: Grid
    input*: Input
    output*: string

proc newTerminal*(width = 0, height = 0, scrollback = 0): Terminal =
  result = Terminal(grid: newGrid(), input: newInput(), output: "")
  result.grid.width = width
  result.grid.height = height
  result.grid.scrollback = scrollback

proc write*(terminal: Terminal, bytes: string) =
  terminal.output.add bytes
  terminal.grid.feed bytes

proc read*(terminal: Terminal): int =
  terminal.input.read()

proc hasPendingInput*(terminal: Terminal): bool =
  terminal.input.hasPendingInput()

proc push*(terminal: Terminal, keys: openArray[int]) =
  terminal.input.push keys

proc pushByte*(terminal: Terminal, key: int) =
  terminal.input.pushByte key

proc pushText*(terminal: Terminal, text: string) =
  terminal.input.pushText text

proc clearInput*(terminal: Terminal) =
  terminal.input.clear()

