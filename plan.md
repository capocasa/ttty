# ttty - Extract headless terminal emulator into a standalone Nimble package

## What

Extract the ANSI VT grid renderer (currently copy-pasted in `3code/tests/test_minline.nim` and `3code/tests/test_footer.nim`) into a standalone Nimble package at `~/p/ttty/`.

This is extraction only. No new features. No SGR attribute parsing yet. The merged version should handle the union of both copies' capabilities (cursor save/restore, cursor hidden) and pass existing 3code tests once wired back in.

## Source material

Two copies of the Grid exist:

1. `~/p/3code/bufprompt/tests/test_minline.nim` lines 32-150 (simpler: no cursor save/restore, no cursorHidden)
2. `~/p/3code/bufprompt/tests/test_footer.nim` lines 28-190 (full: cursor save/restore via `s`/`u`, cursorHidden via CSI ?25 l/h)

The footer copy is the superset. Merge into one.

## Package structure

```
~/p/ttty/
  ttty.nimble           # package definition, nimble 1.x format
  src/
    ttty.nim            # re-export module
    ttty/
      grid.nim          # Grid type, feed, rowText, helpers
  tests/
    test_grid.nim       # tests extracted + expanded from both copies
```

Follows Nim project layout convention: `src/<pkg>.nim` at top, submodules in `src/<pkg>/`.

## Implementation steps

### 1. Create the nimble package

`ttty.nimble` with:
- `version = "0.1.0"`
- `author`, `description`, `license = "MIT"`
- `srcDir = "src"`
- `requires "nim >= 2.0"`
- No binary (`bin` not set) - library only

### 2. Create `src/ttty/grid.nim`

Contains the merged Grid from both copies:

**Type:**
```nim
type
  Grid* = ref object
    rows*: seq[seq[Rune]]
    row*, col*: int
    savedRow*, savedCol*: int
    hasSaved*: bool
    cursorHidden*: bool
```

**Exported procs:**
- `newGrid*(): Grid`
- `feed*(g: Grid, bytes: string)` - ANSI VT stream parser, merged from both copies
- `rowText*(g: Grid, r: int): string`
- `ensureRow*(g: Grid, r: int)` (needed by test helpers that build on Grid)

**CSI handling** (union of both copies):
- Cursor movement: A (up), B (down), C (forward), D (back)
- Cursor position: H/f (absolute), G (horizontal absolute)
- Erase: K (line), J (display)
- Save/restore cursor: s/u (SCO)
- Cursor visibility: CSI ?25 l/h (private mode)
- SGR (`m`): discard (no attribute tracking yet)
- Unknown: discard

**Internal helpers** (not exported):
- `parseN(params: string): int` - parse CSI numeric param, default 1
- `putRune(g: Grid, r: Rune)` - write rune at cursor, advance col
- `eraseLine(g: Grid, mode: int)` - modes 0, 1, 2
- `eraseDisplay(g: Grid, mode: int)` - modes 0, 1, 2

### 3. Create `src/ttty.nim`

```nim
import ttty/grid
export grid
```

### 4. Create `tests/test_grid.nim`

Port the Grid-related tests from both source files. Cover:
- Plain text rendering
- Cursor movement (up/down/left/right/home/absolute)
- Line erase (K modes 0,1,2)
- Display erase (J modes 0,1,2)
- Cursor save/restore
- Cursor hidden toggle
- SGR sequences are silently consumed (not crash)
- UTF-8 multi-byte characters
- LF, CR, CR+LF handling

Run via `nimble test`.

### 5. Verify

- `nimble test` passes in `~/p/ttty/`
- `nimble install` succeeds (installs as library)

### 6. Initialize git repo

- `git init`
- Initial commit with all files
- Push to `capocasa/ttty` via `gh`

## What NOT to do

- Do NOT add SGR attribute tracking (fg, bg, bold, etc.) - that's step 2
- Do NOT modify 3code yet - that's step 2
- Do NOT add PTY support or any I/O - Grid is pure in-memory
- Do NOT change the CSI parsing behavior from what the two copies do
- Do NOT add new escape sequence handlers beyond the union of both copies
