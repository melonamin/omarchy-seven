import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui
import "SevenModel.js" as SevenModel
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

  moduleName: SevenModel.PLUGIN_ID
  // The service owns the single "seven" IPC target; a per-monitor panel
  // registering it would mean duplicate handlers fighting over one route.
  manageIpc: false

  readonly property var service: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor(SevenModel.PLUGIN_ID)
    : null

  readonly property var config: SevenModel.settingsFromEntry(settings)
  readonly property int activeIndex: service ? service.activeIndex : 0
  readonly property var filled: service ? service.filled : []
  readonly property string activeText: service ? service.textAt(activeIndex) : ""
  readonly property color activeHue: SevenModel.colorFor(activeIndex)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Which half of the dot is showing. Always resets to editing on open: the
  // reason you hit the shortcut is almost always to write something down.
  property bool previewing: false

  // The cheat sheet, shown over the note. Closing it returns to whichever half
  // of the dot was showing before.
  property bool helpOpen: false

  readonly property string activeShortcut: root.service
    ? String(root.service.requestedShortcut)
    : String(root.config.shortcut)
  readonly property var sheet: SevenModel.shortcutSheet(root.activeShortcut)

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function selectDot(index) {
    if (service) service.setActiveIndex(index)
  }

  function stepDot(delta) {
    selectDot(SevenModel.stepIndex(activeIndex, delta))
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

  // Refill the editor when a dot is rewritten under an open panel, putting the
  // caret where SevenModel.caretAfterReload says it belongs.
  function reloadKeepingCaret() {
    var previous = editor.text
    var caret = editor.editorItem.cursorPosition
    loadActiveIntoEditor()
    editor.editorItem.cursorPosition = SevenModel.caretAfterReload(previous, editor.text, caret)
  }

  function focusActiveSurface() {
    if (root.helpOpen || root.previewing) keyCatcher.forceActiveFocus()
    else editor.focusAtEnd()
  }

  // Deferred focus, always through a closure that reaches for `root` by id.
  //
  // Qt.callLater(focusActiveSurface) -- passing the bare function -- looks
  // equivalent and is not: QML resolves that reference again when the call
  // finally runs, and if the context it was captured in is no longer valid the
  // call throws "Property 'focusAtEnd' is not a function" into the log and the
  // panel is left with nothing focused. Typing then goes nowhere, on and off,
  // depending on what else the shell was doing.
  function focusSoon() {
    Qt.callLater(function() {
      if (root.opened) root.focusActiveSurface()
    })
  }

  function toggleHelp() {
    helpOpen = !helpOpen
  }

  // Escape peels one layer at a time: the sheet first, the panel second.
  function dismiss() {
    if (helpOpen) helpOpen = false
    else close()
  }

  function togglePreview() {
    previewing = !previewing
  }

  // Flip the bar dot between its two presentations and remember the choice.
  // Applied locally first so the dot changes on the click itself; the write to
  // shell.json comes back through the bar as the same value.
  function toggleDotStyle() {
    var entry = SevenModel.withSetting(root.settings, root.moduleName, "colorfulDot", !root.config.colorfulDot)
    root.settings = entry
    if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
      bar.shell.updateEntryInline(root.moduleName, entry)
  }

  onOpenedChanged: {
    if (opened) {
      previewing = false
      helpOpen = false
      loadActiveIntoEditor()
      focusSoon()
    } else if (service) {
      // Don't leave the last sentence sitting in the debounce window once the
      // panel is out of sight.
      service.flush()
    }
  }

  onActiveIndexChanged: {
    loadActiveIntoEditor()
    if (opened) focusSoon()
  }

  onPreviewingChanged: if (opened) focusSoon()
  onHelpOpenChanged: if (opened) focusSoon()

  // A dot rewritten out from under the panel: edited in another program, or
  // changed by an IPC clear/append. Always adopt it.
  //
  // An earlier version skipped this while the editor had focus, meaning to
  // protect a half-typed sentence. Focus is not the same as typing, though: a
  // panel can sit open and focused for an hour, and in that state an edit made
  // in nvim was shown nowhere and then overwritten by the next keystroke. The
  // service already declines to adopt a dot with unsaved changes, so that case
  // never reaches here.
  Connections {
    target: root.service
    ignoreUnknownSignals: true

    function onDotChangedExternally(index) {
      if (index !== root.activeIndex) return
      root.reloadKeepingCaret()
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // Two presentations, per the colourfulDot setting. Coloured: the dot takes
    // the active note's hue and goes hollow when that note is empty, so the bar
    // says which note you are on and whether there is anything in it. Plain: a
    // solid dot in the bar's own foreground, indistinguishable from every other
    // item up there.
    text: root.config.colorfulDot && root.filled[root.activeIndex] !== true ? "○" : "●"
    foreground: root.config.colorfulDot ? root.activeHue : root.barForeground
    active: root.opened
    // While a widget's panel is open the bar normally repaints its label in the
    // urgent colour. For a coloured dot that would throw away the one thing the
    // dot is there to say -- which note you are on -- and the open state is
    // already drawn as the underline beneath it. A plain dot is asked to behave
    // like every other bar item, so it keeps the tint.
    useActiveColor: !root.config.colorfulDot
    tooltipText: SevenModel.tooltipFor(root.service ? root.service.texts : [], root.activeIndex)

    onPressed: function(b) {
      // Right click swaps the dot's presentation. It is the one setting whose
      // effect is entirely visible in the bar, so the bar is where it belongs
      // -- and clicking again puts it back.
      if (b === Qt.RightButton) root.toggleDotStyle()
      else if (b === Qt.MiddleButton) root.stepDot(1)
      else root.toggle()
    }

    // Both directions live on the wheel, which is why stepping does not need a
    // second mouse button of its own.
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
    // The sheet needs two readable columns of key-and-meaning, which do not fit
    // the writing width. Widening for it beats eliding the explanations.
    contentWidth: panel.fittedContentWidth(Style.space(root.helpOpen ? 620 : 430))

    Behavior on contentWidth {
      NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
    }
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
          root.dismiss()
          event.accepted = true
          return
        }
        if (event.key === Qt.Key_F1) {
          root.toggleHelp()
          event.accepted = true
          return
        }
        // With the sheet up, nothing else should move the note underneath it.
        if (root.helpOpen) return
        if (event.key === Qt.Key_P && (event.modifiers & Qt.AltModifier)) {
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

        // ---------- The dots ----------
        // No "which dot" caption: the ring around the active dot already says
        // it, and the number was a label for something the eye reads faster.
        Item {
          width: parent.width
          implicitHeight: dotStrip.implicitHeight

          DotStrip {
            id: dotStrip
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            filled: root.filled
            activeIndex: root.activeIndex
            foreground: Color.popups.text
            onSelected: function(index) { root.selectDot(index) }
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
            visible: !root.previewing && !root.helpOpen
            // Deliberately not `enabled: visible`. A hidden item receives no
            // keys anyway, and tying the two means that at the instant
            // `visible` becomes true `enabled` is still false -- so a
            // forceActiveFocus() scheduled off onVisibleChanged lands on a
            // disabled item and does nothing, silently. That race decided
            // whether typing worked after leaving the preview.
            foreground: Color.popups.text
            monospace: root.config.monospace

            // Same reason as loadActiveIntoEditor: the service's own index is
            // the authority on which dot this text belongs to.
            onEdited: function(text) {
              if (root.service) root.service.setText(root.service.activeIndex, text)
            }
            onCloseRequested: root.dismiss()
            onHelpRequested: root.toggleHelp()
            onPreviewRequested: root.togglePreview()
            onDotRequested: function(index) { root.selectDot(index) }
            onStepRequested: function(delta) { root.stepDot(delta) }
          }

          DotPreview {
            id: preview
            anchors.fill: parent
            visible: root.previewing && !root.helpOpen
            foreground: Color.popups.text
            source: root.activeText

            onLinkActivated: function(url) {
              Quickshell.execDetached(["xdg-open", url])
              root.close()
            }
          }

          ShortcutSheet {
            anchors.fill: parent
            visible: root.helpOpen
            leftGroups: root.sheet.left
            rightGroups: root.sheet.right
            foreground: Color.popups.text
            fontFamily: root.fontFamily
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
            text: SevenModel.countsLabel(root.activeText)
            textFormat: Text.PlainText
            color: Util.alpha(Color.popups.text, 0.55)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          // The keys used to be spelled out along this edge, which only ever
          // had room for three of them. One question mark opens the lot.
          Item {
            id: hint
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(18)
            height: Style.space(18)

            Rectangle {
              anchors.fill: parent
              radius: width / 2
              color: root.helpOpen
                ? Util.alpha(Color.popups.text, 0.14)
                : (helpHover.hovered ? Util.alpha(Color.popups.text, 0.09) : "transparent")
            }

            Text {
              anchors.centerIn: parent
              text: "?"
              textFormat: Text.PlainText
              color: Util.alpha(Color.popups.text, root.helpOpen || helpHover.hovered ? 0.85 : 0.42)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            HoverHandler {
              id: helpHover
              cursorShape: Qt.PointingHandCursor
            }

            MouseArea {
              anchors.fill: parent
              onClicked: root.toggleHelp()
            }
          }
        }
      }
    }
  }
}
