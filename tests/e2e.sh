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

json_get() { python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$1" 2>/dev/null; }

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

status=$(omarchy-shell dots status 2>/dev/null) || fail "Dots service is not answering"
dots_dir=$(json_get dir <<<"$status")
[[ -d $dots_dir ]] || fail "storage directory $dots_dir does not exist"

# --- snapshot and restore -----------------------------------------------------

backup=$(mktemp -d)
restore() {
  omarchy-shell dots close >/dev/null 2>&1 || true
  local n
  for n in 1 2 3 4 5 6 7; do
    if [[ -f "$backup/$n.md" ]]; then cp "$backup/$n.md" "$dots_dir/$n.md"; else rm -f "$dots_dir/$n.md"; fi
  done
  sleep 1
  rm -rf "$backup"
}
trap restore EXIT

for n in 1 2 3 4 5 6 7; do
  [[ -f "$dots_dir/$n.md" ]] && cp "$dots_dir/$n.md" "$backup/$n.md"
done
for n in 1 2 3 4 5 6 7; do omarchy-shell dots clear "$n" >/dev/null; done
sleep 1
pass "snapshotted the notes and cleared the board"

# --- open ---------------------------------------------------------------------

omarchy-shell dots close >/dev/null 2>&1 || true
sleep 1
panel_open && fail "the panel was still mapped after close"

omarchy-shell dots show 2 >/dev/null
sleep 1
panel_open || fail "the panel did not appear"
[[ $(json_get active <<<"$(omarchy-shell dots status)") == 2 ]] || fail "'show 2' did not select dot 2"
pass "the panel opens on the requested dot"

# --- typing -------------------------------------------------------------------

typed="typed through the compositor"
wtype "$typed"
sleep 1

[[ $(omarchy-shell dots read 2) == "$typed" ]] \
  || fail "keystrokes never reached the editor (the dropdown is not taking keyboard focus)"
pass "keystrokes reach the editor and land in the active dot"

[[ -f "$dots_dir/2.md" ]] || fail "typing was never written to disk"
[[ $(cat "$dots_dir/2.md") == "$typed" ]] || fail "the file on disk does not match what was typed"
pass "what was typed is on disk at $dots_dir/2.md"

# --- switching dots from the keyboard ----------------------------------------

wtype -M alt -k 5 -m alt
sleep 1
[[ $(json_get active <<<"$(omarchy-shell dots status)") == 5 ]] || fail "Alt+5 did not switch to dot 5"
pass "Alt+N switches dots without closing the panel"

wtype "note five"
sleep 1
[[ $(omarchy-shell dots read 5) == "note five" ]] || fail "typing after a dot switch went to the wrong dot"
[[ $(omarchy-shell dots read 2) == "$typed" ]] || fail "switching dots disturbed the previous dot"
pass "each dot keeps its own text across switches"

# --- preview ------------------------------------------------------------------

wtype -k Tab
sleep 1
# Letters in the preview must do nothing at all: not insert, and not navigate.
# The shell's shared PanelKeyCatcher would read "h" here as "move left", which
# would leave the next thing typed in a different note.
wtype "this must not be inserted"
sleep 1
[[ $(omarchy-shell dots read 5) == "note five" ]] \
  || fail "the preview accepted keystrokes; it must be read-only"
[[ $(json_get active <<<"$(omarchy-shell dots status)") == 5 ]] \
  || fail "letters typed in the preview navigated away from the current dot"
pass "Tab switches to preview, which neither accepts text nor navigates"

wtype -k Tab
sleep 1
wtype " again"
sleep 1
[[ $(omarchy-shell dots read 5) == "note five again" ]] || fail "Tab did not return to the editor"
pass "Tab returns to the editor with typing restored"

# --- closing ------------------------------------------------------------------

wtype -k Escape
sleep 1
panel_open && fail "Escape did not close the panel"
pass "Escape closes the panel"

# The note must outlive the panel -- that is the whole point of a scratchpad.
[[ $(omarchy-shell dots read 5) == "note five again" ]] || fail "text was lost when the panel closed"
pass "notes survive the panel closing"

printf '\n\033[1;32mend-to-end passed\033[0m\n'
