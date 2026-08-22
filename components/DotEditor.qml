import QtQuick
import QtQuick.Controls
import qs.Commons
import "../SevenModel.js" as SevenModel

// The editing half of a dot. A plain TextArea -- no toolbar, no formatting
// buttons, no autosave indicator. Text is saved by the service on a debounce,
// so there is nothing here for the user to do about saving.
ScrollView {
  id: root

  property color foreground: Color.popups.text
  property bool monospace: true
  property alias text: area.text
  property alias editorItem: area

  signal edited(string text)
  signal closeRequested()
  signal previewRequested()
  signal dotRequested(int index)
  signal stepRequested(int delta)

  clip: true
  ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
  ScrollBar.vertical.policy: area.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

  function focusEditor() {
    area.forceActiveFocus()
  }

  // Focus follows visibility rather than being pushed in from outside. The
  // panel flips this item and the preview in and out by binding `visible`, and
  // a forceActiveFocus() scheduled from there can land while this item is
  // still hidden -- which does nothing at all, silently, and leaves the next
  // keystrokes going nowhere. Reacting to the change itself cannot lose that
  // race.
  onVisibleChanged: if (visible) Qt.callLater(focusEditor)

  // Put the caret where a returning writer expects it: at the end of what they
  // already wrote, not at the top of the note.
  function focusAtEnd() {
    area.forceActiveFocus()
    area.cursorPosition = area.length
  }

  // Apply one edit plan from SevenModel. Going through remove/insert rather
  // than reassigning `text` is what keeps Ctrl+Z working.
  function applyEdit(plan) {
    if (!plan) return
    if (plan.end > plan.start) area.remove(plan.start, plan.end)
    if (plan.text.length > 0) area.insert(plan.start, plan.text)
    if (plan.cursorEnd > plan.cursorStart) area.select(plan.cursorStart, plan.cursorEnd)
    else area.cursorPosition = plan.cursorStart
  }

  function wrapSelection(marker) {
    applyEdit(SevenModel.toggleWrap(area.text, area.selectionStart, area.selectionEnd, marker))
  }

  function setHeading(level) {
    applyEdit(SevenModel.toggleHeading(area.text, area.cursorPosition, level))
  }

  TextArea {
    id: area

    width: root.availableWidth
    wrapMode: TextArea.Wrap
    selectByMouse: true
    persistentSelection: true
    placeholderText: "Type here."
    color: root.foreground
    placeholderTextColor: Util.alpha(root.foreground, 0.38)
    selectionColor: Style.selectionFillFor(root.foreground, Color.accent)
    selectedTextColor: root.foreground
    // "monospace" is the fontconfig alias the whole shell resolves through, so
    // the toggle honours the user's configured mono font rather than a hardcoded one.
    font.family: root.monospace ? "monospace" : Style.font.family
    font.pixelSize: Style.font.body
    leftPadding: 0
    rightPadding: 0
    topPadding: 0
    bottomPadding: Style.space(4)

    background: null

    onTextChanged: root.edited(text)

    // The editor owns the keyboard while it is focused, so every shortcut the
    // panel offers has to be answered here too -- PanelKeyCatcher is blocked
    // for exactly this reason.
    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Escape) {
        root.closeRequested()
        event.accepted = true
        return
      }

      // Enter continues a list or carries the indentation down. Shift+Enter is
      // left alone as the escape hatch for a plain, unadorned newline.
      if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
          && !(event.modifiers & (Qt.ShiftModifier | Qt.ControlModifier | Qt.AltModifier))) {
        root.applyEdit(SevenModel.newlineEdit(area.text, area.cursorPosition))
        event.accepted = true
        return
      }

      if (event.modifiers & Qt.ControlModifier) {
        if (event.key === Qt.Key_B && !(event.modifiers & Qt.ShiftModifier)) {
          root.wrapSelection("**")
          event.accepted = true
          return
        }
        if (event.key === Qt.Key_I && !(event.modifiers & Qt.ShiftModifier)) {
          root.wrapSelection("*")
          event.accepted = true
          return
        }
        // Ctrl+Shift+X for strikethrough, as GitHub's editor has it.
        if (event.key === Qt.Key_X && (event.modifiers & Qt.ShiftModifier)) {
          root.wrapSelection("~~")
          event.accepted = true
          return
        }
        // Ctrl+1..6 sets a heading level, Ctrl+0 clears it. Pressing the level
        // a line already has clears it too, so one key does both ways.
        if (event.key >= Qt.Key_0 && event.key <= Qt.Key_6) {
          root.setHeading(event.key - Qt.Key_0)
          event.accepted = true
          return
        }
      }
      if (event.modifiers & Qt.AltModifier) {
        if (event.key === Qt.Key_P) {
          root.previewRequested()
          event.accepted = true
          return
        }
        if (event.key >= Qt.Key_1 && event.key <= Qt.Key_7) {
          root.dotRequested(event.key - Qt.Key_1)
          event.accepted = true
          return
        }
        if (event.key === Qt.Key_Right) {
          root.stepRequested(1)
          event.accepted = true
          return
        }
        if (event.key === Qt.Key_Left) {
          root.stepRequested(-1)
          event.accepted = true
          return
        }
      }
    }
  }
}
