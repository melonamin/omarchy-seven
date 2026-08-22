import QtQuick
import qs.Commons

// Every binding, in two columns, over the note. The rows come from
// SevenModel.shortcutSheet so there is one list to keep true rather than a
// second copy of the keymap living in the UI.
Item {
  id: root

  property var leftGroups: []
  property var rightGroups: []
  property color foreground: Color.popups.text
  property string fontFamily: Style.font.family

  // The key column is sized for the longest chord on the sheet
  // ("Ctrl + Shift + X"); letting it size to its content would leave the two
  // columns disagreeing about where their labels start.
  // Wide enough for the longest chord on the sheet, "Ctrl + Shift + X".
  readonly property int keyWidth: Style.space(100)
  readonly property int columnGap: Style.space(18)
  readonly property int keyGap: Style.space(8)

  // Everything the list needs is passed in rather than reached for, so the
  // component has no opinion about what encloses it.
  component GroupList: Column {
    property var groups: []
    property color foreground: "white"
    property string fontFamily: ""
    property int keyWidth: 0
    property int gap: 0

    // Labels are given the space that is left and elide into it. A Column does
    // not clip its children, so an unconstrained label would run straight over
    // the next column rather than wrapping or stopping.
    readonly property int labelWidth: Math.max(0, width - keyWidth - gap)

    spacing: Style.space(10)

    Repeater {
      model: groups

      delegate: Column {
        required property var modelData
        readonly property var style: parent

        spacing: Style.space(3)

        Text {
          text: parent.modelData.title.toUpperCase()
          textFormat: Text.PlainText
          color: Util.alpha(parent.style.foreground, 0.45)
          font.family: parent.style.fontFamily
          font.pixelSize: Style.font.caption
          font.letterSpacing: 1.1
          font.bold: true
          bottomPadding: Style.space(2)
        }

        Repeater {
          model: parent.modelData.items

          delegate: Row {
            required property var modelData
            readonly property var style: parent.parent

            spacing: parent.style.gap

            Text {
              width: parent.style.keyWidth
              text: parent.modelData.keys
              textFormat: Text.PlainText
              color: parent.style.foreground
              font.family: parent.style.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            Text {
              width: parent.style.labelWidth
              text: parent.modelData.label
              textFormat: Text.PlainText
              color: Util.alpha(parent.style.foreground, 0.62)
              font.family: parent.style.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }
        }
      }
    }
  }

  Row {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    spacing: root.columnGap

    GroupList {
      width: (root.width - root.columnGap) / 2
      groups: root.leftGroups
      foreground: root.foreground
      fontFamily: root.fontFamily
      keyWidth: root.keyWidth
      gap: root.keyGap
    }

    GroupList {
      width: (root.width - root.columnGap) / 2
      groups: root.rightGroups
      foreground: root.foreground
      fontFamily: root.fontFamily
      keyWidth: root.keyWidth
      gap: root.keyGap
    }
  }
}
