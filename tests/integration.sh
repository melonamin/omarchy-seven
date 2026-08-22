#!/usr/bin/env bash
# Exercises the running plugin: IPC round trips, the debounced write to disk,
# and the file watcher that picks up an edit made outside the panel.
#
# This drives the real notes, so it snapshots all seven dots up front and a
# trap restores them byte-for-byte on any exit path.
#
# Usage: tests/integration.sh
set -euo pipefail

root_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

fail() { printf '\033[1;31mFAIL\033[0m %s\n' "$1" >&2; exit 1; }
pass() { printf '\033[1;32mok\033[0m   %s\n' "$1"; }

json_get() { python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$1" 2>/dev/null; }

command -v omarchy >/dev/null || fail "omarchy not found"
command -v omarchy-shell >/dev/null || fail "omarchy-shell not found"
command -v python3 >/dev/null || fail "python3 not found"

omarchy plugin validate "$root_dir" >/dev/null || fail "plugin validation failed"
pass "plugin manifest and entry points validate"

status=$(omarchy-shell seven status 2>/dev/null) || fail "Seven service is not answering (is the plugin enabled?)"
python3 -c 'import json,sys; json.load(sys.stdin)' <<<"$status" || fail "status is not valid JSON"
pass "service responds with JSON"

[[ $(json_get ready <<<"$status") == True ]] || fail "service reports it never finished loading"
pass "service reports ready"

dots_dir=$(json_get dir <<<"$status")
[[ -n $dots_dir ]] || fail "status did not report its storage directory"
[[ -d $dots_dir ]] || fail "storage directory $dots_dir does not exist"
pass "storage directory exists at $dots_dir"

# --- snapshot and restore -----------------------------------------------------

backup=$(mktemp -d)
restore() {
  local n
  for n in 1 2 3 4 5 6 7; do
    if [[ -f "$backup/$n.md" ]]; then
      cp "$backup/$n.md" "$dots_dir/$n.md"
    else
      rm -f "$dots_dir/$n.md"
    fi
  done
  # Let the watcher adopt the restored files before the shell writes anything
  # of its own back over them.
  sleep 1
  rm -rf "$backup"
}
trap restore EXIT

for n in 1 2 3 4 5 6 7; do
  [[ -f "$dots_dir/$n.md" ]] && cp "$dots_dir/$n.md" "$backup/$n.md"
done
pass "snapshotted the existing notes"

# Start from a known-empty board so counts are unambiguous.
for n in 1 2 3 4 5 6 7; do
  omarchy-shell seven clear "$n" >/dev/null
done
sleep 1
status=$(omarchy-shell seven status)
[[ $(json_get filled <<<"$status") == 0 ]] || fail "clear did not empty every dot"
pass "clear empties a dot"

# --- append and persistence ---------------------------------------------------

[[ $(omarchy-shell seven append 4 "first line") == ok ]] || fail "append reported failure"
[[ $(omarchy-shell seven append 4 "second line") == ok ]] || fail "second append reported failure"
sleep 1

read_back=$(omarchy-shell seven read 4)
[[ $read_back == $'first line\nsecond line' ]] \
  || fail "read did not round-trip the appended lines, got: $(printf '%q' "$read_back")"
pass "append puts each line on its own line and read round-trips it"

[[ -f "$dots_dir/4.md" ]] || fail "dot 4 was never written to disk"
disk=$(cat "$dots_dir/4.md")
[[ $disk == $'first line\nsecond line' ]] || fail "on-disk content differs from what the service reports"
pass "the debounced write reached $dots_dir/4.md"

# --- capture ------------------------------------------------------------------

# Dot 4 is taken, so an unaddressed capture must land on dot 1.
target=$(omarchy-shell seven capture "no dot number given")
[[ $target == 1 ]] || fail "capture went to dot $target, expected the first empty dot (1)"
pass "capture lands on the first empty dot and reports which one"

# --- input validation ---------------------------------------------------------

for bad in 0 8 x ""; do
  out=$(omarchy-shell seven read "$bad" 2>&1 || true)
  [[ $out == error:* ]] || fail "read accepted an out-of-range dot '$bad'"
done
pass "out-of-range dot numbers are rejected, not clamped"

# --- external edits -----------------------------------------------------------

printf 'edited outside the panel\n' > "$dots_dir/6.md"
# The watcher is event-driven; give it a beat rather than assuming instant.
for _ in 1 2 3 4 5; do
  sleep 0.4
  [[ $(omarchy-shell seven read 6) == "edited outside the panel" ]] && break
done
[[ $(omarchy-shell seven read 6) == "edited outside the panel" ]] \
  || fail "an edit made outside the panel was never picked up"
pass "an external edit to a dot file is adopted live"

# --- status shape -------------------------------------------------------------

status=$(omarchy-shell seven status)
counts=$(python3 -c 'import json,sys; print(len(json.load(sys.stdin)["counts"]))' <<<"$status")
[[ $counts == 7 ]] || fail "status reports $counts dots, expected 7"
# status is meant to be safe to paste into a bug report.
grep -q "no dot number given" <<<"$status" && fail "status leaked note content"
pass "status reports all seven dots without leaking their content"

# --- shortcut -----------------------------------------------------------------

status=$(omarchy-shell seven status)
python3 -c 'import json,sys; d=json.load(sys.stdin); [d[k] for k in ("shortcut","shortcutRegistered","diagnostic")]' <<<"$status" \
  || fail "status does not report the shortcut fields"
pass "status reports the global shortcut and whether it registered"

shortcut=$(json_get shortcut <<<"$status")
if [[ -n $shortcut ]]; then
  [[ $shortcut == "$(tr '[:lower:]' '[:upper:]' <<<"$shortcut")" ]] \
    || fail "the reported shortcut is not normalised: $shortcut"
  pass "the shortcut is normalised to Hyprland's shape ($shortcut)"
fi

printf '\n\033[1;32mintegration passed\033[0m\n'
