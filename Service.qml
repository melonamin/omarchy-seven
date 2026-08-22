import QtQuick
import Quickshell
import Quickshell.Io
import "DotsModel.js" as DotsModel

// Owner of the seven notes.
//
// The bar instantiates one Panel per monitor, so the text cannot live in the
// widget: it lives here, in the single service instance, and every panel reads
// and writes through it. This is also what lets the notes survive the popup
// closing, which is the entire point of a scratchpad.
//
// On disk each dot is its own plain file (`1.md` ... `7.md`) under
// $XDG_DATA_HOME/omarchy-dots/dots. Plain files, plainly named, so `grep`,
// `nvim`, Syncthing, and `git` all work on them without this plugin's help.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : DotsModel.PLUGIN_ID
  readonly property string home: Quickshell.env("HOME")
  readonly property string dotsDir: DotsModel.dotsDir(home, Quickshell.env("XDG_DATA_HOME"))
  readonly property string statePath: DotsModel.dotsDir(home, Quickshell.env("XDG_DATA_HOME"))
    .replace(/\/dots$/, "") + "/active"

  // The live text of all seven dots. Replaced wholesale (never mutated in
  // place) so QML property bindings on `texts` actually re-evaluate.
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

  readonly property var filled: DotsModel.filledFlags(texts)
  readonly property int filledCount: DotsModel.filledCount(texts)

  // Bumped whenever a dot's text changes from outside the editor (disk edit,
  // IPC append, clear). Panels watch this to resync an unfocused editor.
  property int revision: 0

  signal dotChangedExternally(int index)

  function textAt(index) {
    return String(texts[DotsModel.clampIndex(index)] || "")
  }

  function setActiveIndex(index) {
    var next = DotsModel.clampIndex(index)
    if (next === activeIndex) return
    activeIndex = next
    activeSaveTimer.restart()
  }

  // Called on every keystroke from the editor. Cheap on purpose: swap the
  // array, mark the dot dirty, and let the debounce timer do the I/O.
  function setText(index, text) {
    var slot = DotsModel.clampIndex(index)
    var value = DotsModel.normalize(text)
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
    var slot = DotsModel.clampIndex(index)
    setText(slot, DotsModel.appendText(textAt(slot), addition))
    revision++
    dotChangedExternally(slot)
  }

  function clearDot(index) {
    var slot = DotsModel.clampIndex(index)
    setText(slot, "")
    revision++
    dotChangedExternally(slot)
  }

  // Where unaddressed text goes: the first empty dot, matching Tot.
  function captureIndex() {
    return DotsModel.firstBlankIndex(texts)
  }

  function flush() {
    for (var key in dirty) {
      if (!dirty[key]) continue
      var slot = DotsModel.clampIndex(key)
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
    var slot = DotsModel.clampIndex(index)
    var value = DotsModel.normalize(raw)

    // Mid-edit: our in-memory copy is newer, and flush() will overwrite the
    // file shortly. Dropping the reload is what protects the typing cursor.
    if (dirty[slot]) return

    if (lastWritten[slot] !== undefined && DotsModel.normalize(lastWritten[slot]) === value) {
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
      for (var i = 0; i < DotsModel.DOT_COUNT; i++) {
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
    model: DotsModel.DOT_COUNT

    delegate: FileView {
      required property int index

      path: root.dotsDir + "/" + DotsModel.fileNameFor(index)
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
      var parsed = DotsModel.indexFromNumber(String(text()).trim())
      if (parsed >= 0) root.activeIndex = parsed
    }
    onLoadFailed: {}
  }

  // Single IPC surface for the plugin. It lives on the service, not the panel,
  // because the panel exists once per monitor and would register duplicates.
  IpcHandler {
    target: "dots"

    function open(): void {
      if (root.shell && typeof root.shell.summon === "function") root.shell.summon(root.pluginId, "")
    }

    function close(): void {
      if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
    }

    function toggle(): void {
      if (root.shell && typeof root.shell.toggle === "function") root.shell.toggle(root.pluginId, "")
    }

    // Reads print the dot verbatim so `omarchy-shell dots read 3 | wc -l` is
    // honest about the content.
    function read(dot: string): string {
      var index = DotsModel.indexFromNumber(dot)
      if (index < 0) return "error: dot must be 1-" + DotsModel.DOT_COUNT
      return root.textAt(index)
    }

    function append(dot: string, text: string): string {
      var index = DotsModel.indexFromNumber(dot)
      if (index < 0) return "error: dot must be 1-" + DotsModel.DOT_COUNT
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
      var index = DotsModel.indexFromNumber(dot)
      if (index < 0) return "error: dot must be 1-" + DotsModel.DOT_COUNT
      root.clearDot(index)
      return "ok"
    }

    function show(dot: string): string {
      var index = DotsModel.indexFromNumber(dot)
      if (index < 0) return "error: dot must be 1-" + DotsModel.DOT_COUNT
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
        counts: root.texts.map(function(value) { return String(value || "").length })
      })
    }
  }
}
