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
set -euo pipefail

root_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

fail() { printf '\033[1;31mFAIL\033[0m %s\n' "$1" >&2; exit 1; }
pass() { printf '\033[1;32mok\033[0m   %s\n' "$1"; }
skip() { printf '\033[1;33mskip\033[0m %s\n' "$1"; }

json_get() { python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$1" 2>/dev/null; }

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
restore() {
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

omarchy-shell seven close >/dev/null 2>&1 || true
sleep 1
panel_open && fail "the panel was still mapped after close"

omarchy-shell seven show 2 >/dev/null
sleep 1
panel_open || fail "the panel did not appear"
[[ $(json_get active <<<"$(omarchy-shell seven status)") == 2 ]] || fail "'show 2' did not select dot 2"
pass "the panel opens on the requested dot"

# --- typing -------------------------------------------------------------------

typed="typed through the compositor"
wtype "$typed"
sleep 1

[[ $(omarchy-shell seven read 2) == "$typed" ]] \
  || fail "keystrokes never reached the editor (the dropdown is not taking keyboard focus)"
pass "keystrokes reach the editor and land in the active dot"

[[ -f "$dots_dir/2.md" ]] || fail "typing was never written to disk"
[[ $(cat "$dots_dir/2.md") == "$typed" ]] || fail "the file on disk does not match what was typed"
pass "what was typed is on disk at $dots_dir/2.md"

# --- switching dots from the keyboard ----------------------------------------

wtype -M alt -k 5 -m alt
sleep 1
[[ $(json_get active <<<"$(omarchy-shell seven status)") == 5 ]] || fail "Alt+5 did not switch to dot 5"
pass "Alt+N switches dots without closing the panel"

wtype "note five"
sleep 1
[[ $(omarchy-shell seven read 5) == "note five" ]] || fail "typing after a dot switch went to the wrong dot"
[[ $(omarchy-shell seven read 2) == "$typed" ]] || fail "switching dots disturbed the previous dot"
pass "each dot keeps its own text across switches"

# --- preview ------------------------------------------------------------------

wtype -M alt -k p -m alt
sleep 1
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

wtype -M alt -k p -m alt
sleep 1
wtype " again"
sleep 1
[[ $(omarchy-shell seven read 5) == "note five again" ]] || fail "Alt+P did not return to the editor"
pass "Alt+P returns to the editor with typing restored"

# Tab must stay an ordinary editing key now that it no longer toggles the
# preview -- if it moved focus out of the editor instead, typing would vanish.
wtype -k Tab
sleep 1
wtype "indented"
sleep 1.2
[[ $(omarchy-shell seven read 5) == *"indented" ]] || fail "Tab moved focus out of the editor"
pass "Tab stays in the editor as an ordinary key"

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
wtype -- "- milk"; sleep 0.3
wtype -k Return;   sleep 0.3
wtype "eggs";      sleep 0.3
wtype -k Return;   sleep 0.3
wtype "bread";     sleep 1.2
[[ $(omarchy-shell seven read 7) == $'- milk\n- eggs\n- bread' ]] \
  || fail "Enter did not continue the bullet list, got: $(printf '%q' "$(omarchy-shell seven read 7)")"
pass "Enter continues a bullet list"

# Enter on the marker-only line it just made must end the list, not extend it.
wtype -k Return; sleep 0.4
wtype -k Return; sleep 0.4
wtype "plain";   sleep 1.2
[[ $(omarchy-shell seven read 7) == $'- milk\n- eggs\n- bread\nplain' ]] \
  || fail "Enter on an empty list item did not end the list, got: $(printf '%q' "$(omarchy-shell seven read 7)")"
pass "Enter on an empty list item ends the list"

await_empty 7 || fail "clear did not empty dot 7"
wtype "bold"; sleep 0.6
wtype -M ctrl -k a -m ctrl; sleep 0.4
wtype -M ctrl -k b -m ctrl; sleep 1.2
[[ $(omarchy-shell seven read 7) == "**bold**" ]] || fail "Ctrl+B did not bold the selection"
pass "Ctrl+B wraps the selection in bold"

wtype -M ctrl -k b -m ctrl; sleep 1.2
[[ $(omarchy-shell seven read 7) == "bold" ]] || fail "Ctrl+B did not unbold"
pass "Ctrl+B on bold text unwraps it"

wtype -M ctrl -k i -m ctrl; sleep 1.2
[[ $(omarchy-shell seven read 7) == "*bold*" ]] || fail "Ctrl+I did not italicise"
wtype -M ctrl -k i -m ctrl; sleep 1.2

wtype -M ctrl -M shift -k x -m shift -m ctrl; sleep 1.2
[[ $(omarchy-shell seven read 7) == "~~bold~~" ]] || fail "Ctrl+Shift+X did not strike through"
wtype -M ctrl -M shift -k x -m shift -m ctrl; sleep 1.2
pass "Ctrl+I and Ctrl+Shift+X wrap and unwrap too"

wtype -M ctrl -k 2 -m ctrl; sleep 1.2
[[ $(omarchy-shell seven read 7) == "## bold" ]] || fail "Ctrl+2 did not set a heading"
pass "Ctrl+2 makes the line a heading"

wtype -M ctrl -k 2 -m ctrl; sleep 1.2
[[ $(omarchy-shell seven read 7) == "bold" ]] || fail "Ctrl+2 did not toggle the heading back off"
pass "the same heading key toggles it off"

# A deliberate instruction must land even while the editor holds focus.
await_empty 7 || fail "clear was ignored while the panel had focus"
pass "clear reaches a dot whose editor is focused"

omarchy-shell -q seven close >/dev/null 2>&1 || true
sleep 1

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
[[ $final == "note five again"* && $final == *"indented" ]] \
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
