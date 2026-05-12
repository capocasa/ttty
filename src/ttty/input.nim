type
  Input* = ref object
    bytes*: seq[int]
    pos*: int

const
  KeyCtrlC* = @[3]
  KeyEnter* = @[13]
  KeyEsc* = @[27]
  KeyBackspace* = @[127]
  KeyTab* = @[9]
  KeyLeft* = @[27, 91, 68]
  KeyRight* = @[27, 91, 67]
  KeyUp* = @[27, 91, 65]
  KeyDown* = @[27, 91, 66]
  KeyHome* = @[27, 91, 72]
  KeyEnd* = @[27, 91, 70]
  KeyDelete* = @[27, 91, 51, 126]
  KeyAltEnter* = @[27, 13]
  KeyKittyShiftEnter* = @[27, 91, 49, 51, 59, 50, 117]
  KeyModifyOtherShiftEnter* = @[27, 91, 50, 55, 59, 50, 59, 49, 51, 126]

proc newInput*(): Input =
  Input(bytes: @[], pos: 0)

proc clear*(input: Input) =
  input.bytes.setLen(0)
  input.pos = 0

proc push*(input: Input, keys: openArray[int]) =
  for key in keys:
    input.bytes.add key

proc pushByte*(input: Input, key: int) =
  input.bytes.add key

proc pushText*(input: Input, text: string) =
  for ch in text:
    input.bytes.add ch.int

proc hasPendingInput*(input: Input): bool =
  input.pos < input.bytes.len

proc pendingLen*(input: Input): int =
  max(0, input.bytes.len - input.pos)

proc read*(input: Input): int =
  if not input.hasPendingInput:
    return -1
  result = input.bytes[input.pos]
  inc input.pos

