import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui
import "DotsModel.js" as DotsModel
import "components"

// Bar button plus the dropdown that holds the notes.
//
// The dropdown is a KeyboardPanel rather than a PopupCard because the bar
// surface is WlrKeyboardFocus.None: an xdg-popup hung off it can be clicked
// but never typed into, and a notes app you cannot type into is a display
// case. KeyboardPanel is the shell's own answer to that -- a layer-shell
// window that primes focus on open.
//
// One of these exists per monitor. All seven notes live in the service, so
// the panels are interchangeable views onto the same text.
Panel {
  id: root

  moduleName: DotsModel.PLUGIN_ID
  // The service owns the single "dots" IPC target; a per-monitor panel
  // registering it would mean duplicate handlers fighting over one route.
  manageIpc: false

  readonly property var service: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor(DotsModel.PLUGIN_ID)
    : null

  readonly property var config: DotsModel.settingsFromEntry(settings)
  readonly property int activeIndex: service ? service.activeIndex : 0
  readonly property var filled: service ? service.filled : []
  readonly property string activeText: service ? service.textAt(activeIndex) : ""
  readonly property color activeHue: DotsModel.colorFor(activeIndex)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Which half of the dot is showing. Always resets to editing on open: the
  // reason you hit the shortcut is almost always to write something down.
  property bool previewing: false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function selectDot(index) {
    if (service) service.setActiveIndex(index)
  }

  function stepDot(delta) {
    selectDot(DotsModel.stepIndex(activeIndex, delta))
  }

  // The editor's text is assigned, not bound: a binding to the service would
  // fight the user's own keystrokes. These are the moments it is refilled.
  //
  // Read straight off the service rather than through this item's derived
  // `activeIndex` / `activeText`. When the service's index changes, QML
  // re-evaluates the derived bindings in its own order and fires
  // onActiveIndexChanged in the middle of it -- so `activeText` read from here
  // can still hold the *previous* dot's text. Refilling the editor with that
  // leaves the old note on screen under the new dot's number, and the next
  // keystroke saves it into the wrong dot.
  function loadActiveIntoEditor() {
    editor.text = root.service ? root.service.textAt(root.service.activeIndex) : ""
  }

  function focusActiveSurface() {
    if (root.previewing) keyCatcher.forceActiveFocus()
    else editor.focusAtEnd()
  }

  function togglePreview() {
    previewing = !previewing
  }

  onOpenedChanged: {
    if (opened) {
      previewing = false
      loadActiveIntoEditor()
      Qt.callLater(focusActiveSurface)
    } else if (service) {
      // Don't leave the last sentence sitting in the debounce window once the
      // panel is out of sight.
      service.flush()
    }
  }

  onActiveIndexChanged: {
    loadActiveIntoEditor()
    if (opened) Qt.callLater(focusActiveSurface)
  }

  onPreviewingChanged: if (opened) Qt.callLater(focusActiveSurface)

  // A dot edited on disk or through IPC. Adopt it unless the user is typing
  // into that very dot right now, in which case the service already kept our
  // copy and this panel is the one holding it.
  Connections {
    target: root.service
    ignoreUnknownSignals: true

    function onDotChangedExternally(index) {
      if (index !== root.activeIndex) return
      if (root.opened && !root.previewing && editor.editorItem.activeFocus) return
      root.loadActiveIntoEditor()
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // A single dot, in the active dot's colour: filled when that dot has
    // something in it, hollow when it doesn't. The bar says which note you
    // are on and whether it is empty, and nothing else.
    text: root.filled[root.activeIndex] === true ? "●" : "○"
    foreground: root.activeHue
    active: root.opened
    tooltipText: DotsModel.tooltipFor(root.service ? root.service.texts : [], root.activeIndex)

    onPressed: function(b) {
      if (b === Qt.RightButton) root.stepDot(1)
      else if (b === Qt.MiddleButton) root.stepDot(-1)
      else root.toggle()
    }

    onWheelMoved: function(delta) { root.stepDot(delta > 0 ? -1 : 1) }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    // While editing, the TextArea itself takes focus so the panel is ready to
    // type into the instant it appears.
    focusTarget: root.previewing ? keyCatcher : editor.editorItem
    contentWidth: panel.fittedContentWidth(Style.space(430))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight)

    // Deliberately not qs.Ui's PanelKeyCatcher. That component is built for
    // list panels and treats bare h/j/k/l as navigation, which is wrong for a
    // panel whose content is prose: pressing "h" while reading a note would
    // silently move you to a different note, and the next thing you typed
    // would land there. Only arrows and digits move between dots.
    //
    // Default (AfterItem) key priority, so while editing the TextArea sees
    // every key first and only what it ignores reaches here.
    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          root.close()
          event.accepted = true
          return
        }
        if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
          root.togglePreview()
          event.accepted = true
          return
        }
        if (event.key === Qt.Key_Right) {
          root.stepDot(1)
          event.accepted = true
          return
        }
        if (event.key === Qt.Key_Left) {
          root.stepDot(-1)
          event.accepted = true
          return
        }
        if (event.key >= Qt.Key_1 && event.key <= Qt.Key_7) {
          root.selectDot(event.key - Qt.Key_1)
          event.accepted = true
          return
        }
      }

      Column {
        id: panelColumn
        width: parent.width
        spacing: Style.space(9)

        // ---------- Dots + which one you are on ----------
        Item {
          width: parent.width
          implicitHeight: dotStrip.implicitHeight

          DotStrip {
            id: dotStrip
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            filled: root.filled
            activeIndex: root.activeIndex
            foreground: Color.popups.text
            onSelected: function(index) { root.selectDot(index) }
          }

          Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.previewing ? "PREVIEW" : "DOT " + (root.activeIndex + 1)
            textFormat: Text.PlainText
            color: root.previewing ? root.activeHue : Util.alpha(Color.popups.text, 0.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1.1
            font.bold: true
          }
        }

        PanelSeparator {
          width: parent.width
        }

        // ---------- The note ----------
        // Fixed height on purpose: a panel that resized to its content would
        // jump every time you crossed a line boundary or switched dots.
        Item {
          width: parent.width
          height: Style.space(300)

          DotEditor {
            id: editor
            anchors.fill: parent
            visible: !root.previewing
            enabled: !root.previewing
            foreground: Color.popups.text
            monospace: root.config.monospace

            // Same reason as loadActiveIntoEditor: the service's own index is
            // the authority on which dot this text belongs to.
            onEdited: function(text) {
              if (root.service) root.service.setText(root.service.activeIndex, text)
            }
            onCloseRequested: root.close()
            onPreviewRequested: root.togglePreview()
            onDotRequested: function(index) { root.selectDot(index) }
            onStepRequested: function(delta) { root.stepDot(delta) }
          }

          DotPreview {
            id: preview
            anchors.fill: parent
            visible: root.previewing
            enabled: root.previewing
            foreground: Color.popups.text
            source: root.activeText

            onLinkActivated: function(url) {
              Quickshell.execDetached(["xdg-open", url])
              root.close()
            }
          }
        }

        PanelSeparator {
          width: parent.width
        }

        // ---------- Counts and the two keys worth knowing ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(counts.implicitHeight, hint.implicitHeight)

          Text {
            id: counts
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            visible: root.config.showCounts
            text: DotsModel.countsLabel(root.activeText)
            textFormat: Text.PlainText
            color: Util.alpha(Color.popups.text, 0.55)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            id: hint
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.previewing ? "Tab edit · Esc close" : "Tab preview · Alt+1-7 dots · Esc close"
            textFormat: Text.PlainText
            color: Util.alpha(Color.popups.text, 0.38)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }
    }
  }
}
