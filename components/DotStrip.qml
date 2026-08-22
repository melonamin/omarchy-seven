import QtQuick
import qs.Commons
import "../SevenModel.js" as SevenModel

// The seven dots. A dot is solid when it holds text and hollow when it does
// not, so the row doubles as the only index this plugin has: you learn "the
// blue one is work notes" and never name anything.
Item {
  id: root

  property var filled: []
  property int activeIndex: 0
  property color foreground: Color.popups.text

  signal selected(int index)

  readonly property int dotSize: Style.space(11)
  readonly property int ringSize: Style.space(21)

  implicitWidth: strip.implicitWidth
  implicitHeight: ringSize

  Row {
    id: strip
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(4)

    Repeater {
      model: SevenModel.DOT_COUNT

      delegate: Item {
        required property int index

        readonly property bool isActive: index === root.activeIndex
        readonly property bool isFilled: root.filled[index] === true
        readonly property color hue: SevenModel.colorFor(index)

        width: root.ringSize
        height: root.ringSize

        // Ring around the current dot. Drawn in the dot's own hue rather than
        // the theme accent so the selection reads as "this dot" and not as a
        // generic highlight.
        Rectangle {
          anchors.fill: parent
          radius: width / 2
          color: parent.isActive ? Util.alpha(parent.hue, 0.16) : "transparent"
          border.width: parent.isActive ? Math.max(1, Style.space(1)) : 0
          border.color: parent.isActive ? Util.alpha(parent.hue, 0.55) : "transparent"
        }

        Rectangle {
          anchors.centerIn: parent
          width: root.dotSize
          height: root.dotSize
          radius: width / 2
          // Empty dots are outlines: the row shows what you have without
          // making seven equal blobs that say nothing.
          color: parent.isFilled ? parent.hue : "transparent"
          border.width: parent.isFilled ? 0 : Math.max(1, Style.space(1))
          border.color: Util.alpha(parent.hue, 0.75)

          Behavior on color {
            ColorAnimation { duration: 120 }
          }
        }

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.selected(parent.index)
        }
      }
    }
  }
}
