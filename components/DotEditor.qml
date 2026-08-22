import QtQuick
import QtQuick.Controls
import qs.Commons

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

  // Put the caret where a returning writer expects it: at the end of what they
  // already wrote, not at the top of the note.
  function focusAtEnd() {
    area.forceActiveFocus()
    area.cursorPosition = area.length
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
      if (event.key === Qt.Key_Tab && !(event.modifiers & Qt.ShiftModifier)) {
        root.previewRequested()
        event.accepted = true
        return
      }
      if (event.modifiers & Qt.AltModifier) {
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
