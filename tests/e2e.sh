#!/usr/bin/env bash
# End-to-end test through the real UI: opens the panel on a live Hyprland
# session, types into it with wtype, and checks what came out the other side.
#
# This is the only test that proves the thing that is easy to get wrong here --
# that a dropdown hung off a WlrKeyboardFocus.None bar can be typed into at all.
#
# It takes over the keyboard for a few seconds and drives the real notes. All
# seven dots are snapshotted and restored on any exit path; even so, run it
# when you are not mid-sentence somewhere else.
#
# Usage: tests/e2e.sh
set -euo pipefail

root_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

fail() { printf '\033[1;31mFAIL\033[0m %s\n' "$1" >&2; exit 1; }
pass() { printf '\033[1;32mok\033[0m   %s\n' "$1"; }
skip() { printf '\033[1;33mskip\033[0m %s\n' "$1"; }

json_get() { python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$1" 2>/dev/null; }

# Wait for a dot to hold exactly this text. Typing has to travel wtype ->
# compositor -> editor -> a 400ms debounce -> the service, and every step of
# that is slower under load. Waiting on the result makes the test say what it
# means instead of guessing a sleep long enough to usually work.
await_text() {
  local dot="$1" want="$2" _
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ $(omarchy-shell seven read "$dot") == "$want" ]] && return 0
    sleep 0.3
  done
  printf '    wanted %q\n    got    %q\n' "$want" "$(omarchy-shell seven read "$dot")" >&2
  return 1
}

# Type text and confirm it arrived, resending once if the compositor dropped it.
# wtype builds a virtual keyboard per invocation and under load the odd key
# never lands; retrying only after await_text has already waited three seconds
# means a slow keystroke is never mistaken for a lost one and typed twice.
type_text() {
  local dot="$1" text="$2" want="$3" attempt
  for attempt in 1 2; do
    wtype -- "$text"
    await_text "$dot" "$want" && return 0
  done
  return 1
}

# The service holds a keystroke the moment it is typed; the file gets it 400ms
# later, after the debounce. Anything asserting about disk has to wait for that
# second step rather than assume the first implies it.
await_disk() {
  local path="$1" want="$2" _
  for _ in 1 2 3 4 5 6 7 8; do
    [[ -f $path && $(cat "$path") == "$want" ]] && return 0
    sleep 0.3
  done
  return 1
}

panel_mode() {
  omarchy-shell seven status 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["panel"]["mode"])' 2>/dev/null
}

# Press a mode chord until the panel agrees it landed. Same reasoning as
# select_dot: a modifier chord from a virtual keyboard goes missing often
# enough under load that one press is not a state change.
set_mode() {
  local want="$1"; shift
  local attempt _
  for attempt in 1 2 3; do
    wtype "$@"
    for _ in 1 2 3 4; do
      sleep 0.3
      [[ $(panel_mode) == "$want" ]] && return 0
    done
  done
  return 1
}

# Send Alt+N until the service agrees it is on that note. A modifier chord from
# a virtual keyboard is dropped often enough under load that a single press is
# not a reliable way to put the panel in a known state, and every assertion
# after one depends on it having worked.
select_dot() {
  local want="$1" attempt _
  for attempt in 1 2 3; do
    wtype -M alt -k "$want" -m alt
    for _ in 1 2 3 4; do
      sleep 0.3
      [[ $(json_get active <<<"$(omarchy-shell seven status)") == "$want" ]] && return 0
    done
  done
  return 1
}

await_open() {
  local _
  for _ in 1 2 3 4 5 6 7 8; do
    panel_open && return 0
    sleep 0.3
  done
  return 1
}

# The panel keeps its layer mapped through a 140ms fade, so "closed" is a state
# to wait for, not something true the instant close returns.
await_closed() {
  local _
  for _ in 1 2 3 4 5 6 7 8; do
    panel_open || return 0
    sleep 0.3
  done
  return 1
}

# Clearing travels IPC -> service -> panel reload. Waiting for the result beats
# guessing a sleep, and keeps the typing that follows from racing the reload.
await_empty() {
  local dot="$1" _
  omarchy-shell -q seven clear "$dot" >/dev/null
  for _ in 1 2 3 4 5 6 7 8; do
    sleep 0.3
    [[ -z $(omarchy-shell seven read "$dot") ]] && return 0
  done
  return 1
}

command -v omarchy-shell >/dev/null || fail "omarchy-shell not found"
command -v wtype >/dev/null || fail "wtype not found (required to drive the keyboard)"
command -v hyprctl >/dev/null || fail "hyprctl not found"
command -v python3 >/dev/null || fail "python3 not found"

# A shell started in an older session inherits a stale instance signature, and
# every hyprctl call then fails against a dead socket. Find one that answers.
if ! hyprctl version >/dev/null 2>&1; then
  for candidate in $(ls -t "${XDG_RUNTIME_DIR:-/run/user/$UID}/hypr" 2>/dev/null); do
    if HYPRLAND_INSTANCE_SIGNATURE="$candidate" hyprctl version >/dev/null 2>&1; then
      export HYPRLAND_INSTANCE_SIGNATURE="$candidate"
      break
    fi
  done
fi
hyprctl version >/dev/null 2>&1 || fail "no live Hyprland session to test against"
pass "talking to a live Hyprland session"

panel_open() { [[ $(hyprctl layers -j | grep -c 'omarchy-keyboard-panel') -gt 0 ]]; }

status=$(omarchy-shell seven status 2>/dev/null) || fail "Seven service is not answering"
dots_dir=$(json_get dir <<<"$status")
[[ -d $dots_dir ]] || fail "storage directory $dots_dir does not exist"

# --- snapshot and restore -----------------------------------------------------

backup=$(mktemp -d)
entry_backup=""
beacon_pid=""
restore() {
  [[ -n $beacon_pid ]] && kill "$beacon_pid" 2>/dev/null
  omarchy-shell seven close >/dev/null 2>&1 || true
  local n
  for n in 1 2 3 4 5 6 7; do
    if [[ -f "$backup/$n.md" ]]; then cp "$backup/$n.md" "$dots_dir/$n.md"; else rm -f "$dots_dir/$n.md"; fi
  done
  # Put this widget's shell.json entry back exactly as it was; the right-click
  # test writes a setting into it.
  if [[ -n $entry_backup && -f $entry_backup ]]; then
    python3 - "$entry_backup" <<'RESTORE'
import json, pathlib, sys
saved = json.loads(pathlib.Path(sys.argv[1]).read_text())
path = pathlib.Path.home() / ".config/omarchy/shell.json"
config = json.loads(path.read_text())
for section in config.get("bar", {}).get("layout", {}).values():
    for item in section:
        if item.get("id") == "melonamin.seven":
            item.clear()
            item.update(saved)
path.write_text(json.dumps(config, indent=2) + "\n")
RESTORE
    rm -f "$entry_backup"
  fi
  sleep 1
  rm -rf "$backup"
}
trap restore EXIT

for n in 1 2 3 4 5 6 7; do
  [[ -f "$dots_dir/$n.md" ]] && cp "$dots_dir/$n.md" "$backup/$n.md"
done
for n in 1 2 3 4 5 6 7; do omarchy-shell seven clear "$n" >/dev/null; done
sleep 1
pass "snapshotted the notes and cleared the board"

# --- open ---------------------------------------------------------------------

# Start from a known-closed panel. The shared KeyboardPanel can leave its
# layer mapped after a close -- the first-party audio panel does the same --
# and an open/close cycle clears it. This is setup, not the assertion; that
# close works is checked properly further down, from a state this established.
omarchy-shell seven close >/dev/null 2>&1 || true
if ! await_closed; then
  omarchy-shell -q seven show 1 >/dev/null 2>&1 || true
  await_open || true
  omarchy-shell -q seven close >/dev/null 2>&1 || true
  await_closed || fail "the panel stayed mapped through a close and a full cycle"
fi

omarchy-shell seven show 2 >/dev/null
await_open || fail "the panel did not appear"
[[ $(json_get active <<<"$(omarchy-shell seven status)") == 2 ]] || fail "'show 2' did not select dot 2"
pass "the panel opens on the requested dot"

# --- typing -------------------------------------------------------------------

typed="typed through the compositor"
type_text 2 "$typed" "$typed" \
  || fail "keystrokes never reached the editor (the dropdown is not taking keyboard focus)"
pass "keystrokes reach the editor and land in the active dot"

await_disk "$dots_dir/2.md" "$typed" \
  || fail "what was typed never reached disk, file holds: $(printf '%q' "$(cat "$dots_dir/2.md" 2>/dev/null)")"
pass "what was typed is on disk at $dots_dir/2.md"

# --- switching dots from the keyboard ----------------------------------------

select_dot 5 || fail "Alt+5 did not switch to dot 5"
pass "Alt+N switches dots without closing the panel"

type_text 5 "note five" "note five" || fail "typing after a dot switch went to the wrong dot"
[[ $(omarchy-shell seven read 2) == "$typed" ]] || fail "switching dots disturbed the previous dot"
pass "each dot keeps its own text across switches"

# --- preview ------------------------------------------------------------------

set_mode preview -M alt -k p -m alt || fail "Alt+P did not switch to the preview"
# Letters in the preview must do nothing at all: not insert, and not navigate.
# The shell's shared PanelKeyCatcher would read "h" here as "move left", which
# would leave the next thing typed in a different note.
wtype "this must not be inserted"
sleep 1
[[ $(omarchy-shell seven read 5) == "note five" ]] \
  || fail "the preview accepted keystrokes; it must be read-only"
[[ $(json_get active <<<"$(omarchy-shell seven status)") == 5 ]] \
  || fail "letters typed in the preview navigated away from the current dot"
pass "Alt+P switches to preview, which neither accepts text nor navigates"

set_mode editor -M alt -k p -m alt || fail "Alt+P did not return to the editor"
type_text 5 " again" "note five again" || fail "typing did not resume after the preview"
pass "Alt+P returns to the editor with typing restored"

# Tab indents by four spaces. If it moved focus out of the editor instead,
# the typing that follows would vanish.
wtype -k Tab
sleep 1
type_text 5 "indented" "note five again    indented" \
  || fail "Tab did not insert four spaces, got: $(printf '%q' "$(omarchy-shell seven read 5)")"
pass "Tab indents by four spaces and keeps focus"

# --- closing ------------------------------------------------------------------

wtype -k Escape
sleep 1
panel_open && fail "Escape did not close the panel"
pass "Escape closes the panel"

# --- markdown editing affordances -------------------------------------------

omarchy-shell -q seven clear 7 >/dev/null
omarchy-shell -q seven show 7 >/dev/null
sleep 1.5
await_empty 7 || fail "dot 7 did not start empty"

# `--` because wtype reads a leading dash as one of its own options.
wtype -- "- milk"
await_text 7 "- milk" || fail "the first list line never arrived"
wtype -k Return; sleep 0.4
wtype "eggs"
await_text 7 $'- milk\n- eggs' || fail "Enter did not continue the bullet list"
wtype -k Return; sleep 0.4
wtype "bread"
await_text 7 $'- milk\n- eggs\n- bread' || fail "Enter did not continue the list a second time"
pass "Enter continues a bullet list"

# Enter on the marker-only line it just made must end the list, not extend it.
wtype -k Return; sleep 0.4
wtype -k Return; sleep 0.4
wtype "plain"
await_text 7 $'- milk\n- eggs\n- bread\nplain' \
  || fail "Enter on an empty list item did not end the list"
pass "Enter on an empty list item ends the list"

await_empty 7 || fail "clear did not empty dot 7"
wtype "bold"; sleep 0.6
wtype -M ctrl -k a -m ctrl; sleep 0.4
wtype -M ctrl -k b -m ctrl
await_text 7 "**bold**" || fail "Ctrl+B did not bold the selection"
pass "Ctrl+B wraps the selection in bold"

wtype -M ctrl -k b -m ctrl
await_text 7 "bold" || fail "Ctrl+B did not unbold"
pass "Ctrl+B on bold text unwraps it"

wtype -M ctrl -k i -m ctrl
await_text 7 "*bold*" || fail "Ctrl+I did not italicise"
wtype -M ctrl -k i -m ctrl; sleep 1.2

wtype -M ctrl -M shift -k x -m shift -m ctrl
await_text 7 "~~bold~~" || fail "Ctrl+Shift+X did not strike through"
wtype -M ctrl -M shift -k x -m shift -m ctrl; sleep 1.2
pass "Ctrl+I and Ctrl+Shift+X wrap and unwrap too"

wtype -M ctrl -k 2 -m ctrl
await_text 7 "## bold" || fail "Ctrl+2 did not set a heading"
pass "Ctrl+2 makes the line a heading"

wtype -M ctrl -k 2 -m ctrl
await_text 7 "bold" || fail "Ctrl+2 did not toggle the heading back off"
pass "the same heading key toggles it off"

# A deliberate instruction must land even while the editor holds focus.
await_empty 7 || fail "clear was ignored while the panel had focus"
pass "clear reaches a dot whose editor is focused"

omarchy-shell -q seven close >/dev/null 2>&1 || true
sleep 1

# --- edits made somewhere else ----------------------------------------------

# The panel is open and the editor has focus. An edit made in another program
# has to appear here, and must not be overwritten by whatever is typed next.
# This used to fail: focus was mistaken for "the user is typing", so the note
# stayed stale on screen and the next keystroke wrote the stale copy back.
await_empty 7 || fail "dot 7 did not empty before the external-edit checks"
omarchy-shell -q seven show 7 >/dev/null; sleep 1.5
type_text 7 "mine" "mine" || fail "could not seed dot 7"
# Let the debounce finish before editing from outside. An external write that
# lands while a flush is still pending is, correctly, discarded in favour of
# the typing -- that is the conflict rule, and it is checked further down. What
# is being tested here is the other case.
await_disk "$dots_dir/7.md" "mine" || fail "the seed never reached disk"

printf 'theirs\n' > "$dots_dir/7.md"
for _ in 1 2 3 4 5 6; do
  sleep 0.4
  [[ $(omarchy-shell seven read 7) == "theirs" ]] && break
done
[[ $(omarchy-shell seven read 7) == "theirs" ]] \
  || fail "an edit made outside was not picked up while the panel was focused"
pass "an external edit reaches a focused editor"

type_text 7 "!" "theirs!" \
  || fail "typing did not continue from the external edit, got: $(printf '%q' "$(omarchy-shell seven read 7)")"
pass "typing continues from the external edit rather than clobbering it"

await_disk "$dots_dir/7.md" "theirs!" || fail "the keystroke never reached disk"

# An editor that writes by replacing the file (a temp file plus rename, which
# is what nvim does by default) must be noticed too -- the watcher is following
# a path whose inode just changed.
printf 'replaced\n' > "$dots_dir/7.md.tmp"
mv "$dots_dir/7.md.tmp" "$dots_dir/7.md"
for _ in 1 2 3 4 5 6; do
  sleep 0.4
  [[ $(omarchy-shell seven read 7) == "replaced" ]] && break
done
[[ $(omarchy-shell seven read 7) == "replaced" ]] \
  || fail "an atomic replace (write + rename) was not noticed"
pass "an atomic replace is noticed, not just an in-place write"

# The other side of the rule: an edit that lands while a sentence is actually
# being typed loses to the person at the keyboard.
await_empty 7 || fail "dot 7 did not empty before the conflict check"
wtype "mid-sentence"
printf 'clobber\n' > "$dots_dir/7.md"
sleep 2
[[ $(omarchy-shell seven read 7) == "mid-sentence" ]] \
  || fail "an external write during typing beat the person typing"
pass "an external write during typing loses to the keyboard"

omarchy-shell -q seven close >/dev/null 2>&1 || true
sleep 1

# --- notes are untrusted input ----------------------------------------------
#
# Note files are ordinary files, `seven append` is reachable by any local
# process, and a synced directory carries whatever another machine wrote. So a
# note is attacker-controlled, and rendering one must not make the shell fetch
# anything. Qt will happily do so: a markdown image is fetched when rendered,
# and the bar's tooltip Text sniffs its own format, so a note shaped like an
# <img> tag is rendered as rich text and its src fetched on hover.
#
# This plants both and asserts a local server hears nothing.

beacon_dir=$(mktemp -d)
beacon_port=8791
cat > "$beacon_dir/server.py" <<'BEACON'
import http.server, socketserver, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open(sys.argv[2], "a") as f:
            f.write(self.path + "\n")
        self.send_response(404); self.end_headers()
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
try:
    socketserver.TCPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
except OSError:
    sys.exit(1)
BEACON
: > "$beacon_dir/hits"
python3 "$beacon_dir/server.py" "$beacon_port" "$beacon_dir/hits" &
beacon_pid=$!
sleep 1

if ! curl -fsS -o /dev/null "http://127.0.0.1:$beacon_port/selftest" 2>/dev/null && [[ ! -s $beacon_dir/hits ]]; then
  skip "could not start the beacon server on port $beacon_port"
  kill "$beacon_pid" 2>/dev/null; beacon_pid=""
  rm -rf "$beacon_dir"
else
  : > "$beacon_dir/hits"

  # A markdown image, and an HTML img tag, both pointing at the local server.
  printf '# note\n\n![pic](http://127.0.0.1:%s/md-image)\n\n<img src="http://127.0.0.1:%s/html-image">\n' \
    "$beacon_port" "$beacon_port" > "$dots_dir/3.md"
  # And a note whose *first line* is a tag, which is what the bar tooltip shows.
  printf '<img src="http://127.0.0.1:%s/tooltip">\n' "$beacon_port" > "$dots_dir/4.md"
  sleep 1.5

  omarchy-shell -q seven show 3 >/dev/null; sleep 1.5
  [[ ! -s $beacon_dir/hits ]] \
    || fail "opening a note fetched $(tr '\n' ' ' < "$beacon_dir/hits")"
  pass "opening a note with a remote image fetches nothing"

  set_mode preview -M alt -k p -m alt || fail "could not switch to the preview"
  sleep 2
  [[ ! -s $beacon_dir/hits ]] \
    || fail "previewing a note fetched $(tr '\n' ' ' < "$beacon_dir/hits")"
  pass "previewing a note with a remote image fetches nothing"

  omarchy-shell -q seven close >/dev/null 2>&1 || true
  await_closed || true

  # The tooltip path needs the pointer and a findable dot.
  style=$(json_get colorfulDot <<<"$(omarchy-shell seven status)")
  if command -v dotool >/dev/null && python3 -c 'import PIL' 2>/dev/null && [[ $style == True ]]; then
    omarchy-shell -q seven show 4 >/dev/null; sleep 1
    omarchy-shell -q seven close >/dev/null; sleep 1.2
    shot=$(mktemp --suffix=.png)
    grim "$shot"
    spot=$(python3 - "$shot" <<'FIND'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
W, H = im.size
px = im.load()
target = (0x6f, 0xb8, 0x6b)   # dot 4
pts = [(x, y) for y in range(0, 60) for x in range(W)
       if all(abs(px[x, y][i] - target[i]) < 14 for i in range(3))]
if not pts:
    sys.exit(1)
print(sum(p[0] for p in pts) / len(pts) / W, sum(p[1] for p in pts) / len(pts) / H)
FIND
    ) && {
      rm -f "$shot"
      cursor_before=$(hyprctl cursorpos)
      printf 'mouseto 0.5 0.5\n' | dotool; sleep 0.8
      : > "$beacon_dir/hits"
      printf 'mouseto %s\n' "$spot" | dotool; sleep 3.5
      [[ ! -s $beacon_dir/hits ]] \
        || fail "hovering the bar dot fetched $(tr '\n' ' ' < "$beacon_dir/hits")"
      pass "hovering a note shaped like an <img> tag fetches nothing"
      python3 - "$cursor_before" <<'CURSOR' | dotool
import json, subprocess, sys
x, y = (int(v.strip()) for v in sys.argv[1].split(","))
monitor = json.loads(subprocess.run(["hyprctl", "monitors", "-j"],
                                    capture_output=True, text=True).stdout)[0]
scale = float(monitor.get("scale", 1.0))
print(f"mouseto {x / (monitor['width'] / scale)} {y / (monitor['height'] / scale)}")
CURSOR
      sleep 0.3
    } || skip "could not find the bar dot; tooltip fetch unchecked"
  else
    skip "tooltip fetch test needs dotool, python-pillow, and colorfulDot on"
  fi

  kill "$beacon_pid" 2>/dev/null; beacon_pid=""
  rm -rf "$beacon_dir"
fi

# --- the cheat sheet --------------------------------------------------------

await_empty 7 || fail "dot 7 did not empty before the cheat-sheet checks"
omarchy-shell -q seven show 7 >/dev/null; sleep 1.5
type_text 7 "abc" "abc" || fail "could not seed dot 7"

set_mode help -k F1 || fail "F1 did not open the cheat sheet"
wtype "zzz"; sleep 1.2
[[ $(omarchy-shell seven read 7) == "abc" ]] \
  || fail "the note took keystrokes while the cheat sheet was up"
pass "F1 opens the cheat sheet over the note"

# Escape peels one layer: the sheet closes, the panel stays.
set_mode editor -k Escape || fail "Escape did not close the cheat sheet"
panel_open || fail "Escape closed the whole panel instead of just the cheat sheet"
pass "Escape closes the cheat sheet without closing the panel"

type_text 7 "def" "abcdef" \
  || fail "the editor did not get focus back after the cheat sheet closed"
pass "the editor takes focus back when the sheet closes"

# F1 again, then Escape twice, should end with nothing on screen.
set_mode help -k F1 || fail "F1 did not reopen the cheat sheet"
set_mode editor -k Escape || fail "Escape did not close the cheat sheet"
wtype -k Escape; sleep 1.2
panel_open && fail "Escape did not close the panel after the sheet was dismissed"
pass "Escape closes the panel once the sheet is gone"

# --- the global shortcut ---------------------------------------------------
#
# wtype cannot exercise this: synthetic keys from a virtual keyboard do not
# trigger Hyprland's compositor-level binds (Omarchy's own first-party lua
# shortcuts are equally untriggerable that way). So check the three things
# that are checkable: the bind exists on the requested chord, nothing else
# owns that chord, and running the bound command does open the panel.

status=$(omarchy-shell seven status)
shortcut=$(json_get shortcut <<<"$status")
if [[ -z $shortcut ]]; then
  pass "global shortcut is disabled by configuration; skipping its checks"
else
  [[ $(json_get shortcutRegistered <<<"$status") == True ]] \
    || fail "shortcut $shortcut is not registered: $(json_get diagnostic <<<"$status")"
  pass "shortcut $shortcut is registered with Hyprland"

  hyprctl binds -j | python3 -c '
import json, sys
binds = json.load(sys.stdin)
mine = [b for b in binds if b.get("description") == "Seven notes"]
sys.exit(0 if len(mine) == 1 else 1)
' || fail "expected exactly one bind described \"Seven notes\""
  pass "exactly one described bind is registered"

  # Capture before grepping: under `set -o pipefail`, `grep -q` closes the pipe
  # on its first match and the producer dies of SIGPIPE, which would fail the
  # pipeline precisely when the test passes.
  menu_entries=$(omarchy-menu-keybindings --print 2>/dev/null || true)
  grep -q "Seven notes" <<<"$menu_entries" \
    || fail "the shortcut does not appear in the SUPER+K keybindings menu"
  pass "the shortcut is listed in the SUPER+K keybindings menu"

  # Exactly what the bound callback runs.
  omarchy-shell -q seven close >/dev/null 2>&1 || true
  sleep 1
  hyprctl eval 'hl.exec_cmd("omarchy-shell -q seven toggle")' >/dev/null
  sleep 1.5
  panel_open || fail "the bound command did not open the panel"
  omarchy-shell -q seven close >/dev/null 2>&1 || true
  sleep 1
  pass "the command the shortcut runs opens the panel"
fi

# The note must outlive the panel -- that is the whole point of a scratchpad.
# Dot 5 has accumulated everything typed into it above, tab included.
final=$(omarchy-shell seven read 5)
[[ $final == "note five again"* && $final == *"    indented" ]] \
  || fail "text was lost when the panel closed, got: $(printf '%q' "$final")"
pass "notes survive the panel closing"

# --- right click swaps the bar dot's presentation ---------------------------

style=$(json_get colorfulDot <<<"$(omarchy-shell seven status)")
if ! command -v dotool >/dev/null || ! python3 -c 'import PIL' 2>/dev/null; then
  skip "right-click test needs dotool and python-pillow"
elif [[ $style != True ]]; then
  skip "right-click test needs colorfulDot on, to find the dot by its colour"
else
  entry_backup=$(mktemp)
  python3 - "$entry_backup" <<'SAVE'
import json, pathlib, sys
config = json.loads((pathlib.Path.home() / ".config/omarchy/shell.json").read_text())
for section in config.get("bar", {}).get("layout", {}).values():
    for item in section:
        if item.get("id") == "melonamin.seven":
            pathlib.Path(sys.argv[1]).write_text(json.dumps(item))
SAVE

  # A filled, active dot paints the bar dot in that note's colour, which is how
  # the pointer finds it on screen.
  omarchy-shell -q seven append 1 "anchor" >/dev/null
  omarchy-shell -q seven show 1 >/dev/null; sleep 1
  omarchy-shell -q seven close >/dev/null; sleep 1.2

  shot=$(mktemp --suffix=.png)
  grim "$shot"
  spot=$(python3 - "$shot" <<'FIND'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
W, H = im.size
px = im.load()
target = (0xe5, 0x53, 0x4b)   # dot 1's colour
pts = [(x, y) for y in range(0, 56) for x in range(W)
       if all(abs(px[x, y][i] - target[i]) < 10 for i in range(3))]
if not pts:
    sys.exit(1)
print(sum(p[0] for p in pts) / len(pts) / W, sum(p[1] for p in pts) / len(pts) / H)
FIND
  ) || fail "could not find the bar dot on screen"
  rm -f "$shot"
  pass "located the bar dot at $spot"

  cursor_before=$(hyprctl cursorpos)
  printf 'mouseto %s\n' "$spot" | dotool; sleep 0.5
  printf 'click right\n' | dotool; sleep 1.5
  [[ $(json_get colorfulDot <<<"$(omarchy-shell seven status)") == False ]] \
    || fail "right click did not switch the bar dot to its plain presentation"
  pass "right click switches the bar dot to a plain solid dot"

  printf 'click right\n' | dotool; sleep 1.5
  [[ $(json_get colorfulDot <<<"$(omarchy-shell seven status)") == True ]] \
    || fail "right click did not switch the bar dot back"
  pass "right click switches it back"

  # The choice has to survive in shell.json, not just in the running widget.
  python3 -c '
import json, pathlib, sys
config = json.loads((pathlib.Path.home() / ".config/omarchy/shell.json").read_text())
found = [i for s in config["bar"]["layout"].values() for i in s if i.get("id") == "melonamin.seven"]
sys.exit(0 if found and "colorfulDot" in found[0] else 1)
' || fail "the dot style was not written to shell.json"
  pass "the choice is persisted to shell.json"

  # Put the pointer back. cursorpos is logical; mouseto takes output fractions.
  python3 - "$cursor_before" <<'CURSOR' | dotool
import json, subprocess, sys
x, y = (int(v.strip()) for v in sys.argv[1].split(","))
monitor = json.loads(subprocess.run(["hyprctl", "monitors", "-j"],
                                    capture_output=True, text=True).stdout)[0]
scale = float(monitor.get("scale", 1.0))
print(f"mouseto {x / (monitor['width'] / scale)} {y / (monitor['height'] / scale)}")
CURSOR
  sleep 0.3
  pass "pointer restored"
fi

printf '\n\033[1;32mend-to-end passed\033[0m\n'
