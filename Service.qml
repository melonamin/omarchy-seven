import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "SevenModel.js" as SevenModel

// Owner of the seven notes.
//
// The bar instantiates one Panel per monitor, so the text cannot live in the
// widget: it lives here, in the single service instance, and every panel reads
// and writes through it. This is also what lets the notes survive the popup
// closing, which is the entire point of a scratchpad.
//
// On disk each dot is its own plain file (`1.md` ... `7.md`) under
// $XDG_DATA_HOME/omarchy-seven/dots. Plain files, plainly named, so `grep`,
// `nvim`, Syncthing, and `git` all work on them without this plugin's help.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : SevenModel.PLUGIN_ID
  readonly property string sourceDir: manifest && manifest.__sourceDir ? String(manifest.__sourceDir) : ""
  readonly property string luaPath: sourceDir ? sourceDir + "/hypr/seven.lua" : ""
  readonly property string configPath: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
  readonly property string home: Quickshell.env("HOME")
  readonly property string dotsDir: SevenModel.dotsDir(home, Quickshell.env("XDG_DATA_HOME"))
  readonly property string statePath: SevenModel.dotsDir(home, Quickshell.env("XDG_DATA_HOME"))
    .replace(/\/dots$/, "") + "/active"

  // The live text of all seven dots. Replaced wholesale (never mutated in
  // place) so QML property bindings on `texts` actually re-evaluate.
  // Read from shell.json rather than injected by the bar: the global shortcut
  // belongs to the plugin as a whole, not to one monitor's bar widget.
  property var settings: SevenModel.settingsFromEntry(null)
  readonly property string requestedShortcut: String(settings.shortcut || "")
  property bool shortcutRegistered: false
  property string shortcutDiagnostic: ""

  property var texts: ["", "", "", "", "", "", ""]
  property int activeIndex: 0
  property bool ready: false

  // Dots whose in-memory text has diverged from disk and is waiting for the
  // debounce timer. A dot listed here ignores reload events, so a file watcher
  // firing mid-keystroke can't yank text out from under the cursor.
  property var dirty: ({})

  // What this plugin last wrote per dot. An onLoaded carrying exactly this is
  // our own write echoing back; anything else is a genuine external edit.
  property var lastWritten: ({})

  readonly property var filled: SevenModel.filledFlags(texts)
  readonly property int filledCount: SevenModel.filledCount(texts)

  // Bumped whenever a dot's text changes from outside the editor (disk edit,
  // IPC append, clear). Panels watch this to resync an unfocused editor.
  property int revision: 0

  signal dotChangedExternally(int index)

  function textAt(index) {
    return String(texts[SevenModel.clampIndex(index)] || "")
  }

  function setActiveIndex(index) {
    var next = SevenModel.clampIndex(index)
    if (next === activeIndex) return
    activeIndex = next
    activeSaveTimer.restart()
  }

  // Called on every keystroke from the editor. Cheap on purpose: swap the
  // array, mark the dot dirty, and let the debounce timer do the I/O.
  function setText(index, text) {
    var slot = SevenModel.clampIndex(index)
    var value = SevenModel.normalize(text)
    if (String(texts[slot]) === value) return

    var next = texts.slice()
    next[slot] = value
    texts = next

    var pending = ({})
    for (var key in dirty) pending[key] = dirty[key]
    pending[slot] = true
    dirty = pending

    saveTimer.restart()
  }

  function appendText(index, addition) {
    var slot = SevenModel.clampIndex(index)
    setText(slot, SevenModel.appendText(textAt(slot), addition))
    revision++
    dotChangedExternally(slot)
  }

  function clearDot(index) {
    var slot = SevenModel.clampIndex(index)
    setText(slot, "")
    revision++
    dotChangedExternally(slot)
  }

  // Where unaddressed text goes: the first empty dot, matching Tot.
  function captureIndex() {
    return SevenModel.firstBlankIndex(texts)
  }

  function flush() {
    for (var key in dirty) {
      if (!dirty[key]) continue
      var slot = SevenModel.clampIndex(key)
      var file = dotFiles.objectAt(slot)
      if (!file) continue
      var value = String(texts[slot] || "")
      // Track the exact bytes handed to FileView, including the trailing
      // newline, so the reload this write triggers is recognised as our own.
      var payload = value === "" ? "" : (value.charAt(value.length - 1) === "\n" ? value : value + "\n")
      var written = ({})
      for (var k in lastWritten) written[k] = lastWritten[k]
      written[slot] = payload
      lastWritten = written
      file.setText(payload)
    }
    dirty = ({})
  }

  // A reload landed. Decide whether it is our own write coming back, or a real
  // edit somebody made in another editor.
  function adoptFromDisk(index, raw) {
    var slot = SevenModel.clampIndex(index)
    var value = SevenModel.normalize(raw)

    // Mid-edit: our in-memory copy is newer, and flush() will overwrite the
    // file shortly. Dropping the reload is what protects the typing cursor.
    if (dirty[slot]) return

    if (lastWritten[slot] !== undefined && SevenModel.normalize(lastWritten[slot]) === value) {
      // Our own write, echoed back by the watcher. Keep the trailing-newline
      // form out of the editor but change nothing else.
      var same = texts.slice()
      same[slot] = value.replace(/\n$/, "")
      texts = same
      return
    }

    var next = texts.slice()
    next[slot] = value.replace(/\n$/, "")
    texts = next
    revision++
    dotChangedExternally(slot)
  }

  Component.onCompleted: {
    ensureDirProc.running = true
    // Give mkdir a turn of the event loop before the FileViews reach for
    // files inside a directory that may not exist yet on a first run.
    Qt.callLater(function() {
      for (var i = 0; i < SevenModel.DOT_COUNT; i++) {
        var file = dotFiles.objectAt(i)
        if (file) file.reload()
      }
      activeFile.reload()
      root.ready = true
    })
  }

  // Writing on the way out matters more here than anywhere else: the debounce
  // window is exactly where an unlucky shell restart would eat a sentence.
  Component.onDestruction: flush()

  Process {
    id: ensureDirProc
    command: ["mkdir", "-p", root.dotsDir]
  }

  Timer {
    id: saveTimer
    interval: 400
    repeat: false
    onTriggered: root.flush()
  }

  Timer {
    id: activeSaveTimer
    interval: 400
    repeat: false
    onTriggered: activeFile.setText(String(root.activeIndex + 1) + "\n")
  }

  // One FileView per dot. `watchChanges` is what makes an external `nvim 3.md`
  // show up in the panel without a shell restart.
  Instantiator {
    id: dotFiles
    model: SevenModel.DOT_COUNT

    delegate: FileView {
      required property int index

      path: root.dotsDir + "/" + SevenModel.fileNameFor(index)
      watchChanges: true
      atomicWrites: true
      printErrors: false

      onLoaded: root.adoptFromDisk(index, text())
      onFileChanged: reload()
      // Absent on first run, which is not an error: an empty dot is the
      // correct starting state and the file appears on the first keystroke.
      onLoadFailed: root.adoptFromDisk(index, "")
    }
  }

  // Which dot you were last on. Small enough to be its own file rather than
  // dragging a JSON state document into a plugin that otherwise has none.
  FileView {
    id: activeFile
    path: root.statePath
    watchChanges: false
    atomicWrites: true
    printErrors: false

    onLoaded: {
      var parsed = SevenModel.indexFromNumber(String(text()).trim())
      if (parsed >= 0) root.activeIndex = parsed
    }
    onLoadFailed: {}
  }

  // ------------------------------------------------------------- shortcut
  //
  // The binding is registered at runtime through `hyprctl eval`, the same way
  // Compose does it, so no Hyprland configuration file is ever edited. It
  // carries a description, which is what puts it in Omarchy's keybindings menu
  // (SUPER + K).

  readonly property string shortcutDescription: "Seven notes"

  function applyConfig(raw) {
    var parsed
    try {
      parsed = JSON.parse(raw)
    } catch (error) {
      console.warn("seven: could not parse shell.json:", error)
      return
    }
    var next = SevenModel.settingsFromEntry(SevenModel.findSettingsEntry(parsed, pluginId))
    var changed = next.shortcut !== settings.shortcut
    settings = next
    if (changed && luaPath) installBinds(false)
  }

  function luaQuote(value) {
    return "'" + String(value || "").replace(/\\/g, "\\\\").replace(/'/g, "\\'") + "'"
  }

  function installBinds(afterReload) {
    if (!luaPath) return
    if (binder.running) {
      binder.queued = true
      if (afterReload) binder.queuedStale = true
      return
    }
    binder.command = ["hyprctl", "-i", "0", "eval",
      "dofile(" + luaQuote(luaPath) + "); omarchy_seven.install("
        + luaQuote(requestedShortcut) + ", " + (afterReload ? "true" : "false") + ")"]
    binder.running = true
  }

  onLuaPathChanged: if (luaPath) installBinds(false)

  FileView {
    path: root.configPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.applyConfig(text())
    // No shell.json yet, or none readable: the defaults already stand.
    onLoadFailed: root.settings = SevenModel.settingsFromEntry(null)
  }

  Process {
    id: binder
    property bool queued: false
    property bool queuedStale: false
    onExited: function(code) {
      if (code !== 0) {
        root.shortcutDiagnostic = "Could not register the shortcut"
        console.warn("seven: hyprctl eval failed with", code)
      } else if (!shortcutCheck.running) {
        shortcutCheck.running = true
      }
      if (queued) {
        queued = false
        var stale = queuedStale
        queuedStale = false
        root.installBinds(stale)
      }
    }
  }

  // Confirms the bind is actually on the chord we asked for, and notices when
  // something else already owns it -- a silently-dead shortcut is worse than a
  // reported one.
  Process {
    id: shortcutCheck
    command: ["hyprctl", "-i", "0", "binds", "-j"]
    stdout: StdioCollector { id: shortcutOutput; waitForEnd: true }
    onExited: function(code) {
      if (code !== 0) return
      var bindings = []
      try {
        bindings = JSON.parse(String(shortcutOutput.text || "[]"))
      } catch (error) {
        return
      }
      var state = SevenModel.shortcutState(bindings, root.requestedShortcut, root.shortcutDescription)
      root.shortcutRegistered = root.requestedShortcut !== "" && state.found && !state.collision
      if (root.requestedShortcut === "") root.shortcutDiagnostic = "Shortcut disabled"
      else if (state.collision) root.shortcutDiagnostic = "Shortcut collision: " + root.requestedShortcut
      else if (!state.found) root.shortcutDiagnostic = "Shortcut is not registered"
      else root.shortcutDiagnostic = ""
    }
  }

  // A config reload drops every runtime bind, so put ours back.
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name === "configreloaded") reinstall.restart()
    }
  }

  Timer {
    id: reinstall
    interval: 400
    onTriggered: root.installBinds(true)
  }

  // Backstop for the cases the event connection misses -- a compositor restart,
  // or a stale inherited instance signature that never delivers the event.
  Timer {
    interval: 15000
    repeat: true
    running: root.luaPath !== ""
    onTriggered: {
      if (shortcutCheck.running || binder.running) return
      if (root.requestedShortcut !== "" && !root.shortcutRegistered) root.installBinds(true)
      else shortcutCheck.running = true
    }
  }

  // Single IPC surface for the plugin. It lives on the service, not the panel,
  // because the panel exists once per monitor and would register duplicates.
  IpcHandler {
    target: "seven"

    function open(): void {
      if (root.shell && typeof root.shell.summon === "function") root.shell.summon(root.pluginId, "")
    }

    function close(): void {
      if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
    }

    function toggle(): void {
      if (root.shell && typeof root.shell.toggle === "function") root.shell.toggle(root.pluginId, "")
    }

    // Reads print the dot verbatim so `omarchy-shell seven read 3 | wc -l` is
    // honest about the content.
    function read(dot: string): string {
      var index = SevenModel.indexFromNumber(dot)
      if (index < 0) return "error: dot must be 1-" + SevenModel.DOT_COUNT
      return root.textAt(index)
    }

    function append(dot: string, text: string): string {
      var index = SevenModel.indexFromNumber(dot)
      if (index < 0) return "error: dot must be 1-" + SevenModel.DOT_COUNT
      root.appendText(index, text)
      return "ok"
    }

    // No dot number: goes to the first empty one, then reports where it went
    // so a script can tell.
    function capture(text: string): string {
      var index = root.captureIndex()
      root.appendText(index, text)
      return String(index + 1)
    }

    function clear(dot: string): string {
      var index = SevenModel.indexFromNumber(dot)
      if (index < 0) return "error: dot must be 1-" + SevenModel.DOT_COUNT
      root.clearDot(index)
      return "ok"
    }

    function show(dot: string): string {
      var index = SevenModel.indexFromNumber(dot)
      if (index < 0) return "error: dot must be 1-" + SevenModel.DOT_COUNT
      root.setActiveIndex(index)
      if (root.shell && typeof root.shell.summon === "function") root.shell.summon(root.pluginId, "")
      return "ok"
    }

    // Deliberately reports shape, not content: a status call should be safe to
    // paste into a bug report.
    function status(): string {
      return JSON.stringify({
        ready: root.ready,
        dir: root.dotsDir,
        active: root.activeIndex + 1,
        filled: root.filledCount,
        shortcut: root.requestedShortcut,
        shortcutRegistered: root.shortcutRegistered,
        diagnostic: root.shortcutDiagnostic,
        counts: root.texts.map(function(value) { return String(value || "").length })
      })
    }
  }
}
