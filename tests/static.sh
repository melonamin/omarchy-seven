#!/usr/bin/env bash
# Static checks that need no running shell: manifest shape, QML syntax, and the
# handful of wiring facts that only break at runtime if nobody looks for them.
#
# Usage: tests/static.sh
set -euo pipefail

root_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

fail() { printf '\033[1;31mFAIL\033[0m %s\n' "$1" >&2; exit 1; }
pass() { printf '\033[1;32mok\033[0m   %s\n' "$1"; }
skip() { printf '\033[1;33mskip\033[0m %s\n' "$1"; }

command -v jq >/dev/null || fail "jq not found"

# --- manifest -----------------------------------------------------------------

if command -v omarchy >/dev/null; then
  omarchy plugin validate "$root_dir" >/dev/null || fail "omarchy plugin validate rejected the plugin"
  pass "manifest passes omarchy plugin validate"
else
  skip "omarchy not installed; manifest validated by unit tests only"
fi

jq -e . "$root_dir/manifest.json" >/dev/null || fail "manifest.json is not valid JSON"
pass "manifest.json parses"

# --- QML syntax ---------------------------------------------------------------

# /usr/bin/qmllint is Qt5's on some systems: it reports nothing and rejects
# valid Qt6 syntax such as typed IPC signatures. Insist on a Qt6 binary.
qmllint=""
for candidate in /usr/lib/qt6/bin/qmllint "$(command -v qmllint6 || true)" "$(command -v qmllint || true)"; do
  [[ -n $candidate && -x $candidate ]] || continue
  if "$candidate" --version 2>&1 | grep -qE 'qmllint 6'; then
    qmllint="$candidate"
    break
  fi
done

if [[ -n $qmllint ]]; then
  qml_import_args=(-I /usr/lib/qt6/qml)
  [[ -d /usr/share/omarchy/shell ]] && qml_import_args+=(-I /usr/share/omarchy/shell)
  while IFS= read -r qml; do
    "$qmllint" "${qml_import_args[@]}" "$qml" >/dev/null 2>&1 \
      || fail "qmllint rejected ${qml#"$root_dir/"}"
  done < <(find "$root_dir" -name '*.qml' -not -path '*/.git/*')
  pass "every .qml file parses under $("$qmllint" --version)"
else
  skip "no Qt6 qmllint found; QML syntax unchecked"
fi

# --- wiring -------------------------------------------------------------------

# The service is the only place allowed to claim the IPC target: a bar widget
# is instantiated once per monitor, so a handler there would register twice.
ipc_in_panel=$(grep -c 'IpcHandler' "$root_dir/Panel.qml" || true)
[[ $ipc_in_panel -eq 0 ]] || fail "Panel.qml declares an IpcHandler; it exists per monitor"
grep -q 'IpcHandler' "$root_dir/Service.qml" || fail "Service.qml has no IpcHandler"
grep -q 'manageIpc: false' "$root_dir/Panel.qml" \
  || fail "Panel.qml must set manageIpc:false so Ui.Panel does not claim a target"
pass "IPC is owned by the service alone"

# The dropdown must be a KeyboardPanel. A PopupCard cannot receive typing,
# because the bar surface it would hang off is WlrKeyboardFocus.None.
grep -qE '^[[:space:]]*KeyboardPanel[[:space:]]*\{' "$root_dir/Panel.qml" \
  || fail "Panel.qml does not instantiate a KeyboardPanel"
# Matches a declaration, not the comment above it explaining why PopupCard is
# the wrong base here.
if grep -qE '^[[:space:]]*PopupCard[[:space:]]*\{' "$root_dir/Panel.qml"; then
  fail "Panel.qml instantiates PopupCard, which cannot take keyboard focus"
fi
pass "dropdown uses KeyboardPanel so the editor can be typed into"

# Seven is the whole premise, so it is defined once in the model and every
# other file counts through it.
grep -q 'model: SevenModel.DOT_COUNT' "$root_dir/DotStrip.qml" \
  || fail "DotStrip.qml must build its dots from SevenModel.DOT_COUNT"
grep -q 'model: SevenModel.DOT_COUNT' "$root_dir/Service.qml" \
  || fail "Service.qml must build its FileViews from SevenModel.DOT_COUNT"
grep -q 'SevenModel.DOT_COUNT' "$root_dir/Service.qml" || fail "Service.qml ignores DOT_COUNT"
pass "the dot count comes only from SevenModel.DOT_COUNT"

# The shortcut is registered at runtime through this file; the service builds a
# `hyprctl eval` command around its path, so a rename breaks the binding
# silently.
[[ -f $root_dir/hypr/seven.lua ]] || fail "hypr/seven.lua is missing"
grep -q 'hypr/seven.lua' "$root_dir/Service.qml" || fail "Service.qml does not load hypr/seven.lua"
grep -q 'description = DESCRIPTION' "$root_dir/hypr/seven.lua" \
  || fail "the bind must carry a description or it will not appear in the SUPER+K menu"
pass "the runtime shortcut is wired to hypr/seven.lua with a description"

# Tab indents. If it ever goes back to toggling the preview, indenting a
# markdown list becomes impossible.
grep -qE 'Qt\.Key_(Tab|Backtab)' "$root_dir/Panel.qml" \
  && fail "Tab is bound in the panel; it belongs to the editor"
grep -q 'Qt.Key_Tab' "$root_dir/DotEditor.qml" \
  || fail "Tab is not bound in the editor"
grep -q 'SevenModel.tabEdit' "$root_dir/DotEditor.qml" \
  || fail "Tab must insert spaces through SevenModel.tabEdit, not a literal tab"
grep -q 'Qt.Key_P' "$root_dir/DotEditor.qml" || fail "Alt+P is not bound in the editor"
grep -q 'Qt.Key_P' "$root_dir/Panel.qml" || fail "Alt+P is not bound in the preview"
pass "Alt+P toggles the preview and Tab indents"

# The cheat sheet is the discoverability surface now that the footer no longer
# spells three keys out, so it has to be reachable by both mouse and keyboard.
grep -q 'ShortcutSheet' "$root_dir/Panel.qml" || fail "Panel.qml does not show the cheat sheet"
grep -q 'root.toggleHelp()' "$root_dir/Panel.qml" || fail "nothing opens the cheat sheet"
grep -q 'Qt.Key_F1' "$root_dir/Panel.qml" || fail "F1 does not open the cheat sheet from the preview"
grep -q 'Qt.Key_F1' "$root_dir/DotEditor.qml" || fail "F1 does not open the cheat sheet from the editor"
grep -q 'SevenModel.shortcutSheet' "$root_dir/Panel.qml" \
  || fail "the sheet must be built from SevenModel.shortcutSheet"
grep -q 'onClicked: root.toggleHelp()' "$root_dir/Panel.qml" \
  || fail "the ? button is not wired to the cheat sheet"
pass "the cheat sheet opens from the ? button, F1, and is built from the model"

# Without this, the bar repaints the dot in the urgent colour whenever the panel
# is open, which erases the note colour exactly when you are looking at it.
grep -q 'useActiveColor: !root.config.colorfulDot' "$root_dir/Panel.qml" \
  || fail "the coloured bar dot must opt out of the bar's active tint"
pass "a coloured bar dot keeps its hue while the panel is open"

# Right click swaps the dot's presentation and persists it; without the
# updateEntryInline call the change would evaporate on the next shell restart.
grep -q 'Qt.RightButton) root.toggleDotStyle()' "$root_dir/Panel.qml" \
  || fail "right click is not wired to the dot-style toggle"
grep -q 'updateEntryInline' "$root_dir/Panel.qml" \
  || fail "the dot-style toggle does not persist to shell.json"
pass "right click toggles the dot style and persists it"

# The markdown affordances live in the model as pure edit plans; the editor
# only applies them. Keeping the logic out of QML is what makes it testable.
for helper in newlineEdit toggleWrap toggleHeading; do
  grep -q "function $helper" "$root_dir/SevenModel.js" || fail "SevenModel.js has no $helper"
  grep -q "SevenModel.$helper" "$root_dir/DotEditor.qml" \
    || fail "DotEditor.qml does not use SevenModel.$helper"
done
pass "list continuation, wrapping, and headings come from the model"

# Edits go through remove/insert so Ctrl+Z still works; reassigning `text`
# would flatten the whole note into one undo step.
grep -q 'area.remove' "$root_dir/DotEditor.qml" \
  || fail "edits must be applied through TextArea.remove/insert to keep undo"
grep -q 'area.insert' "$root_dir/DotEditor.qml" \
  || fail "edits must be applied through TextArea.remove/insert to keep undo"
pass "markdown edits preserve the editor's undo history"

# Focus must follow visibility; a forceActiveFocus pushed in from the panel
# races the visible binding and silently does nothing.
grep -q 'onVisibleChanged: if (visible)' "$root_dir/DotEditor.qml" \
  || fail "the editor must take focus when it becomes visible"
pass "the editor takes focus when it becomes visible"

# `enabled: visible` looks harmless and is not: at the instant `visible` turns
# true the `enabled` binding has not propagated, so focus scheduled off
# onVisibleChanged lands on a disabled item and is dropped without a word.
# Strip comments first, or this trips over the paragraph above explaining it.
sed 's,//.*,,' "$root_dir/Panel.qml" | grep -q 'enabled: visible' \
  && fail "Panel.qml ties enabled to visible; that race silently drops keyboard focus"
pass "visibility and enabled are not tied together"

# A bare function reference handed to Qt.callLater is re-resolved when the call
# runs, and throws if that context has gone invalid -- leaving nothing focused
# and the typing that follows going nowhere, intermittently.
if sed 's,//.*,,' "$root_dir/Panel.qml" "$root_dir/DotEditor.qml" \
  | grep -qE 'Qt\.callLater\([A-Za-z_.]+\)'; then
  fail "Qt.callLater is passed a bare function reference; wrap it in a closure"
fi
pass "deferred calls go through closures, not bare function references"

# --- hygiene ------------------------------------------------------------------

link=$(find "$root_dir" -name .git -prune -o -type l -print -quit)
[[ -z $link ]] || fail "symlink inside the plugin folder: $link (the shell refuses these)"
pass "no symlinks inside the plugin folder"

while IFS= read -r file; do
  [[ -s $file ]] || continue
  [[ $(tail -c1 "$file" | wc -l) -eq 1 ]] || fail "${file#"$root_dir/"} does not end with a newline"
done < <(find "$root_dir" -type f \( -name '*.qml' -o -name '*.js' -o -name '*.json' -o -name '*.md' -o -name '*.sh' \) -not -path '*/.git/*')
pass "text files end with a newline"

while IFS= read -r script; do
  bash -n "$script" || fail "${script#"$root_dir/"} is not valid bash"
  [[ -x $script ]] || fail "${script#"$root_dir/"} is not executable"
done < <(find "$root_dir/tests" -name '*.sh')
pass "test scripts parse and are executable"

printf '\n\033[1;32mstatic checks passed\033[0m\n'
