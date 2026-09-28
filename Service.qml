import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "SevenModel.js" as SevenModel
import "NoteIo.js" as NoteIo

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
  // Resolve bundled files from this component; the public plugin manifest
  // does not expose the registry's private source directory.
  readonly property string luaPath: decodeURIComponent(String(Qt.resolvedUrl("hypr/seven.lua")).replace(/^file:\/\//, ""))
  readonly property string helperPath: decodeURIComponent(String(Qt.resolvedUrl("note-io.pl")).replace(/^file:\/\//, ""))
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

  // What the panel is currently showing. Pushed in by Panel.qml rather than
  // derived here, because the panel owns that state and there is one per
  // display. Reported by `status` so the mode is observable from outside --
  // useful when a shortcut appears to do nothing and you need to know whether
  // the keystroke arrived at all.
  property var uiState: ({ open: false, mode: "editor" })

  function setUiState(state) {
    var value = state || {}
    uiState = {
      open: value.open === true,
      mode: String(value.mode || "editor")
    }
  }

  property var texts: ["", "", "", "", "", "", ""]
  property int activeIndex: 0
  property bool ready: false
  property int loading: SevenModel.DOT_COUNT + 1

  // Dots whose in-memory text has diverged from disk and is waiting for the
  // debounce timer. A dot listed here ignores reload events, so a file watcher
  // firing mid-keystroke can't yank text out from under the cursor.
  property var dirty: ({})

  // Dots whose file exceeds MAX_NOTE_BYTES, mapped to their real size. These
  // are never loaded, never edited, and never written back -- truncating
  // somebody's oversized file would be a worse outcome than refusing it.
  property var oversized: ({})
  property var ioErrors: ({})
  readonly property var refused: Object.assign({}, oversized, ioErrors)

  // What this plugin last wrote per dot. An onLoaded carrying exactly this is
  // our own write echoing back; anything else is a genuine external edit.
  property var lastWritten: ({})

  readonly property var filled: SevenModel.filledFlags(texts, refused)
  readonly property int filledCount: SevenModel.filledCount(texts, refused)

  // Bumped whenever a dot's text changes from outside the editor (disk edit,
  // IPC append, clear). Panels watch this to resync an unfocused editor.
  property int revision: 0

  // A dot's text was replaced by something other than the editor: a file
  // watcher, or an explicit clear/append over IPC. Panels showing that dot
  // refill from it.
  //
  // There is no "but the user might be typing" caveat here on purpose.
  // adoptFromDisk below already refuses to touch a dot with unsaved local
  // changes, so by the time this fires the editor's copy is the same text the
  // file held a moment ago -- there is nothing left to protect.
  signal dotChangedExternally(int index)

  function textAt(index) {
    return String(texts[SevenModel.clampIndex(index)] || "")
  }

  // Re-read one dot from disk. The panel calls this on open so a file that was
  // refused, then deleted or shrunk, recovers without a shell restart -- and so
  // a watch event missed while the panel was closed cannot leave it stale.
  function reloadDot(index) {
    var entry = dotFiles.objectAt(SevenModel.clampIndex(index))
    if (entry) entry.reload()
  }

  function isOversized(index) {
    return oversized[SevenModel.clampIndex(index)] !== undefined
  }

  function oversizedBytes(index) {
    return Number(oversized[SevenModel.clampIndex(index)] || 0)
  }

  function isRefused(index) {
    return refused[SevenModel.clampIndex(index)] !== undefined
  }

  function noteError(index) {
    var slot = SevenModel.clampIndex(index)
    if (isOversized(slot)) return SevenModel.oversizedNotice(slot, oversizedBytes(slot))
    return "Dot " + (slot + 1) + " could not be accessed: " + String(ioErrors[slot] || "I/O failed")
      + "\n\nSeven only reads and replaces regular files. Fix the file or directory, then reopen this dot to retry."
  }

  function refuseIo(index, message) {
    var next = Object.assign({}, ioErrors)
    next[index] = message || "I/O failed or exceeded its deadline"
    ioErrors = next
    revision++
    dotChangedExternally(index)
  }

  function payloadFor(value) {
    return value === "" || value.charAt(value.length - 1) === "\n" ? value : value + "\n"
  }

  function acceptWrite(index, payload, code, error) {
    if (code !== 0) {
      refuseIo(index, error)
      return
    }
    if (payloadFor(textAt(index)) === payload) {
      var pending = Object.assign({}, dirty)
      delete pending[index]
      dirty = pending
    }
    reloadDot(index)
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
    // A dot we refused to load must not be written back: the editor is holding
    // a notice, not the note, and saving that would destroy the file.
    if (isRefused(slot)) return
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

  // Where unaddressed text goes: the first empty dot, matching Tot. A dot whose
  // file was refused looks empty in `texts` but is not, so it is skipped.
  function captureIndex() {
    for (var i = 0; i < SevenModel.DOT_COUNT; i++) {
      if (!isRefused(i) && SevenModel.isBlank(texts[i])) return i
    }
    return SevenModel.DOT_COUNT - 1
  }

  function flush() {
    for (var key in dirty) {
      if (!dirty[key]) continue
      var slot = SevenModel.clampIndex(key)
      if (isRefused(slot)) continue
      var entry = dotFiles.objectAt(slot)
      if (!entry) continue
      var value = String(texts[slot] || "")
      // Track the exact bytes handed to the writer, including the trailing
      // newline, so the reload this write triggers is recognised as our own.
      var payload = payloadFor(value)
      var written = ({})
      for (var k in lastWritten) written[k] = lastWritten[k]
      written[slot] = payload
      lastWritten = written
      entry.setText(payload)
    }
  }

  // A bounded read came back. Decide whether it is our own write echoing, a
  // real edit somebody made elsewhere, or a file too big to take at all.
  function acceptRead(index, output) {
    var slot = SevenModel.clampIndex(index)
    var parsed = SevenModel.parseBoundedRead(output)
    if (!parsed.valid) {
      refuseIo(slot, "Invalid response from the note reader")
      return
    }
    if (ioErrors[slot] !== undefined) {
      var errors = Object.assign({}, ioErrors)
      delete errors[slot]
      ioErrors = errors
      revision++
      dotChangedExternally(slot)
      if (dirty[slot]) saveTimer.restart()
    }

    var next = ({})
    for (var key in oversized) next[key] = oversized[key]

    if (SevenModel.isOversized(parsed.bytes)) {
      // Nothing of the file is kept. parsed.text holds at most the limit, and
      // is dropped here rather than shown as if it were the whole note.
      if (next[slot] === parsed.reportedBytes) return
      next[slot] = parsed.reportedBytes
      oversized = next
      console.warn("seven: dot " + (slot + 1) + " is "
        + SevenModel.formatBytes(parsed.reportedBytes) + ", over the "
        + SevenModel.formatBytes(SevenModel.MAX_NOTE_BYTES) + " limit; not loading it")
      var cleared = texts.slice()
      cleared[slot] = ""
      texts = cleared
      revision++
      dotChangedExternally(slot)
      return
    }

    if (next[slot] !== undefined) {
      delete next[slot]
      oversized = next
    }

    adoptFromDisk(slot, parsed.text)
  }

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
    installBinds(false)
  }

  // Writing on the way out matters more here than anywhere else: the debounce
  // window is exactly where an unlucky shell restart would eat a sentence.
  //
  // The shortcut goes with it. Disabling or removing the plugin unloads this
  // service but leaves the compositor holding a bind that now runs a command
  // nothing answers -- a dead chord squatting on SUPER+CTRL+J until the next
  // Hyprland reload. The plugin folder still exists at this point, so the Lua
  // is still there to load.
  Component.onDestruction: {
    flush()
    if (activeSaveTimer.running) activeWriter.setText(String(activeIndex + 1) + "\n")
    activeWriter.release()
    if (!luaPath) return
    Quickshell.execDetached(["hyprctl", "-i", "0", "eval",
      "dofile(" + luaQuote(luaPath) + "); omarchy_seven.uninstall()"])
  }

  Process {
    id: ensureDirProc
    command: ["mkdir", "-p", root.dotsDir]
    onExited: {
      for (var i = 0; i < SevenModel.DOT_COUNT; i++) {
        var entry = dotFiles.objectAt(i)
        if (entry) entry.reload()
      }
      activeReader.running = true
    }
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
    onTriggered: root.activeWriter.setText(String(root.activeIndex + 1) + "\n")
  }

  // FileView only watches. All note/state I/O goes through the bounded helper,
  // which refuses links and special files and pins the containing directory.
  // Writers outlive plugin unloading so the final debounced edit can finish.
  property var activeWriter: NoteIo.createWriter(Qt.resolvedUrl("NoteWriter.qml"), root.helperPath, root.statePath)

  Connections {
    target: root.activeWriter
    function onCompleted(code, error) {
      if (code !== 0) console.warn("seven: could not save active dot:", error)
    }
  }

  Instantiator {
    id: dotFiles
    model: SevenModel.DOT_COUNT

    delegate: Item {
      id: slot
      required property int index
      property bool initiallyLoaded: false
      readonly property string filePath: root.dotsDir + "/" + SevenModel.fileNameFor(index)
      property var writer: NoteIo.createWriter(Qt.resolvedUrl("NoteWriter.qml"), root.helperPath, slot.filePath)

      Component.onDestruction: writer.release()

      function reload() {
        if (writer.running) return // Its completion will reload the final file.
        if (reader.running) reader.queued = true
        else reader.running = true
      }

      function setText(value) { writer.setText(value) }

      Connections {
        target: slot.writer
        function onCompleted(code, error) {
          root.acceptWrite(slot.index, slot.writer.payload, code, error)
        }
      }

      FileView {
        path: slot.filePath
        preload: false
        watchChanges: true
        printErrors: false
        onFileChanged: slot.reload()
      }

      Process {
        id: reader
        property bool queued: false
        command: ["timeout", "--kill-after=1s", "3s", "perl", root.helperPath,
          "read", slot.filePath, String(SevenModel.MAX_NOTE_BYTES)]
        stdout: StdioCollector { id: readerOutput; waitForEnd: true }
        stderr: StdioCollector { id: readerError; waitForEnd: true }

        onExited: function(code) {
          if (!slot.writer.running) {
            if (code === 0) root.acceptRead(slot.index, String(readerOutput.text || ""))
            else root.refuseIo(slot.index, String(readerError.text || "").trim())
          }
          if (!slot.initiallyLoaded) {
            slot.initiallyLoaded = true
            root.loading--
            if (root.loading === 0) root.ready = true
          }
          if (queued) {
            queued = false
            slot.reload()
          }
        }
      }
    }
  }

  Process {
    id: activeReader
    command: ["timeout", "--kill-after=1s", "3s", "perl", root.helperPath,
      "read", root.statePath, "16"]
    stdout: StdioCollector { id: activeOutput; waitForEnd: true }
    stderr: StdioCollector { id: activeError; waitForEnd: true }
    onExited: function(code) {
      root.loading--
      if (root.loading === 0) root.ready = true
      if (code !== 0) {
        console.warn("seven: could not read active dot:", String(activeError.text || "").trim())
        return
      }
      var read = SevenModel.parseBoundedRead(String(activeOutput.text || ""))
      if (!read.valid || read.bytes > 16) return
      var parsed = SevenModel.indexFromNumber(read.text.trim())
      if (parsed >= 0) root.activeIndex = parsed
    }
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
      // Not the same as empty, and must not read as empty to a script.
      if (root.isRefused(index)) return refusedError(index)
      return root.textAt(index)
    }

    function refusedError(index: int): string {
      if (!root.isOversized(index)) return "error: " + root.noteError(index)
      return "error: dot " + (index + 1) + " is "
        + SevenModel.formatBytes(root.oversizedBytes(index)) + ", over the "
        + SevenModel.formatBytes(SevenModel.MAX_NOTE_BYTES)
        + " limit; Seven will not read or modify it"
    }

    function append(dot: string, text: string): string {
      var index = SevenModel.indexFromNumber(dot)
      if (index < 0) return "error: dot must be 1-" + SevenModel.DOT_COUNT
      if (root.isRefused(index)) return refusedError(index)
      root.appendText(index, text)
      return "ok"
    }

    // No dot number: goes to the first empty one, then reports where it went
    // so a script can tell.
    function capture(text: string): string {
      var index = root.captureIndex()
      if (root.isRefused(index)) return refusedError(index)
      root.appendText(index, text)
      return String(index + 1)
    }

    function clear(dot: string): string {
      var index = SevenModel.indexFromNumber(dot)
      if (index < 0) return "error: dot must be 1-" + SevenModel.DOT_COUNT
      // Refused rather than obeyed: clearing would mean writing an empty file
      // over one Seven never read.
      if (root.isRefused(index)) return refusedError(index)
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
        colorfulDot: root.settings.colorfulDot,
        panel: root.uiState,
        limitBytes: SevenModel.MAX_NOTE_BYTES,
        oversized: root.oversized,
        ioErrors: root.ioErrors,
        shortcutRegistered: root.shortcutRegistered,
        diagnostic: root.shortcutDiagnostic,
        counts: root.texts.map(function(value) { return String(value || "").length })
      })
    }
  }
}
