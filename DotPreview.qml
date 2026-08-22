import QtQuick
import QtQuick.Controls
import qs.Commons

// The rendered half of a dot. Qt's own Markdown renderer does the work, so
// there is no parser in this plugin to drift from CommonMark or to get wrong.
ScrollView {
  id: root

  property color foreground: Color.popups.text
  property string source: ""

  signal linkActivated(string url)
  signal closeRequested()
  signal editRequested()

  clip: true
  ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
  ScrollBar.vertical.policy: rendered.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

  Text {
    id: rendered

    width: root.availableWidth
    // The dot is markdown source on disk; this is the only place it is ever
    // interpreted. Editing always shows the raw text.
    textFormat: Text.MarkdownText
    text: root.source === "" ? "*Nothing here yet.*" : root.source
    wrapMode: Text.Wrap
    color: root.foreground
    linkColor: Color.accent
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    opacity: root.source === "" ? 0.45 : 1

    onLinkActivated: function(link) { root.linkActivated(link) }

    // Only the link cursor -- the preview is not selectable on purpose, so
    // Tab back to the editor is the obvious way to get at the text.
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.NoButton
      cursorShape: rendered.hoveredLink !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
    }
  }
}
