## Step 1 spike: self-contained headless-xterm oracle using posix fork/exec
## (execCmdEx hangs in this environment). Prove Xvfb + xterm + XGetImage.

import std/[os, posix, strutils, syncio, envvars]
import x11/xlib, x11/x, x11/xutil, x11/xtst, x11/keysym

proc log(s: string) =
  stdout.write s & "\n"; stdout.flushFile()

const Display = ":93"
const Dir = "/tmp/ttty_spike"

proc spawnDetached(argv: openArray[string]): Pid =
  ## fork + setsid + execvp; detached so we can kill the group later.
  let pid = fork()
  if pid == 0:
    discard setsid()
    var args: seq[cstring]
    for a in argv: args.add a.cstring
    args.add nil
    discard execvp(argv[0].cstring, cast[cstringArray](args[0].addr))
    quit(127)
  result = pid

proc killGroup(pat: string) =
  # best-effort cleanup via pkill is unavailable (execCmd hangs); kill by pid
  discard

proc main() =
  log "start"
  removeDir(Dir); createDir(Dir)
  let xv = spawnDetached(["Xvfb", Display, "-screen", "0", "1024x768x24"])
  log "xvfb pid=" & $xv
  sleep 1500

  let d = XOpenDisplay(Display)
  doAssert d != nil, "cannot open " & Display
  log "display open"

  # child helper inside xterm: report geometry to geom.txt then idle in bash
  let helper = """
exec 3<>/dev/tty
printf '\\033[14t\\033[18t' >&3
buf=""
end=$((SECONDS+3))
while [ $SECONDS -lt $end ]; do
  IFS= read -rs -t 0.2 -n 1 ch <&3 && buf="$buf$ch"
  case "$buf" in *t*t) break;; esac
done
printf '%s' "$buf" > /tmp/ttty_spike/geom.txt
exec bash --norc
"""
  writeFile(Dir & "/helper.sh", helper)
  # xterm needs DISPLAY set; fork and set env in child
  let xp = fork()
  if xp == 0:
    discard setsid()
    putEnv("DISPLAY", Display)
    var args = [cstring "xterm", "-xrm", "xterm*allowWindowOps: true",
                "-geometry", "80x24", "-e", "bash",
                cstring(Dir & "/helper.sh"), nil]
    discard execvp("xterm", cast[cstringArray](args[0].addr))
    quit(127)
  log "xterm pid=" & $xp
  sleep 3000

  let root = XDefaultRootWindow(d)
  # find xterm window
  var rr, par: Window
  var kids: PWindow
  var n: cuint
  discard XQueryTree(d, root, addr rr, addr par, addr kids, addr n)
  log "top-level windows: " & $n
  var win: Window = 0
  if kids != nil:
    let arr = cast[ptr UncheckedArray[Window]](kids)
    for i in 0 ..< n.int:
      var nm: cstring
      if XFetchName(d, arr[i], addr nm) != 0 and nm != nil:
        log "  win " & $arr[i] & " name=" & $nm
        discard XFree(nm)
      if win == 0: win = arr[i]
    discard XFree(kids)
  log "using window " & $win

  log "geom.txt: " & (if fileExists(Dir & "/geom.txt"): readFile(Dir & "/geom.txt") else: "(none)")

  # capture the window pixels
  var att: XWindowAttributes
  discard XGetWindowAttributes(d, win, addr att)
  log "window geom " & $att.width & "x" & $att.height
  let img = XGetImage(d, win, 0, 0, att.width.cuint, att.height.cuint,
                      AllPlanes, ZPixmap)
  doAssert img != nil, "XGetImage failed"
  log "image " & $img.width & "x" & $img.height & " bpp=" & $img.bits_per_pixel
  # count non-black pixels
  var nz = 0
  for y in 0 ..< img.height.int:
    for x in 0 ..< img.width.int:
      if XGetPixel(img, x.cint, y.cint) != 0: inc nz
  log "non-black pixels: " & $nz
  discard XDestroyImage(img)

  discard XCloseDisplay(d)
  discard kill(xv, 15)
  discard kill(xp, 15)
  log "done"

main()
