# Plan: Wire ttty into 3code tests

## Summary

Four test files in 3code contain inline copies of the ANSI VT Grid renderer.
Replace all four with `import ttty/grid`, delete the inline copies, add ttty as
a dependency, verify tests pass.

## Files affected

| File | Inline Grid lines | Notes |
|---|---|---|
| `bufprompt/tests/test_minline.nim` | 31-149 | Simple variant, Driver uses `grid: Grid` |
| `bufprompt/tests/test_footer.nim` | 28-189 | Full variant (save/restore, cursorHidden) |
| `bufprompt/tests/test_history.nim` | 6-92 | Simple variant, identical to `tests/test_history.nim` |
| `tests/test_history.nim` | 6-92 | Exact duplicate of bufprompt's copy |

## Steps

### 1. Add ttty dependency to both nimble files

In `threecode.nimble` (root) and `bufprompt/threecode.nimble`:
- Add `requires "ttty >= 0.1.0"`

Both nimble files currently have identical content. Both need the same change.

### 2. Install ttty into the local nimble pool

Run `nimble install ~/p/ttty` so both test builds can resolve `import ttty/grid`.

### 3. Replace inline Grid in `bufprompt/tests/test_footer.nim`

- Delete lines 28-189 (the Grid type, all procs)
- Add `import ttty/grid` to the imports
- The existing call sites already use `newGrid()`, `g.feed(...)`, `rowText(g, n)`,
  `g.cursorHidden` - all exported by ttty. No call-site changes needed.
- The section comment `# --- ANSI VT grid renderer ---` (or similar) above the
  block should also be removed.

### 4. Replace inline Grid in `bufprompt/tests/test_minline.nim`

- Delete lines 31-149 (type + procs)
- Add `import ttty/grid` to the imports
- Call sites (`newGrid()`, `d.grid.feed s`, `rowText(d.grid, n)`) already match
  the exported API. No call-site changes needed.
- Remove the section comment above the block.

### 5. Replace inline Grid in `bufprompt/tests/test_history.nim`

- Delete lines 6-92 (type + procs)
- Add `import ttty/grid` to the imports
- Call sites already match. No call-site changes needed.
- Remove the comment `# Inline ANSI grid (subset of test_minline's renderer).`

### 6. Replace inline Grid in `tests/test_history.nim`

- Same as step 5 - this file is an exact duplicate.

### 7. Verify

- `cd ~/p/3code/bufprompt && nimble test` - all tests pass
- `cd ~/p/3code && nimble test` - all tests pass
- Spot-check: `grep -rn "type Grid\|proc newGrid\|proc feed.*Grid" ~/p/3code --include='*.nim'`
  should return zero hits (no inline copies remain).

## What NOT to do

- Do NOT change any test assertions or test logic
- Do NOT modify production source files (only test files and nimble files)
- Do NOT add SGR attribute tracking
- Do NOT add new escape sequence handlers
- Do NOT touch the Driver type or any non-Grid code in the test files
