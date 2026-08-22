#!/usr/bin/env bash
# Static checks that need no running shell: manifest shape, QML syntax, and the
# handful of wiring facts that only break at runtime if nobody looks for them.
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
grep -q 'model: DotsModel.DOT_COUNT' "$root_dir/components/DotStrip.qml" \
  || fail "DotStrip.qml must build its dots from DotsModel.DOT_COUNT"
grep -q 'model: DotsModel.DOT_COUNT' "$root_dir/Service.qml" \
  || fail "Service.qml must build its FileViews from DotsModel.DOT_COUNT"
grep -q 'DotsModel.DOT_COUNT' "$root_dir/Service.qml" || fail "Service.qml ignores DOT_COUNT"
pass "the dot count comes only from DotsModel.DOT_COUNT"

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
