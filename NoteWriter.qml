import QtQuick
import Quickshell.Io

// Created outside the service's object tree so its final queued write can
// finish after a plugin unload. release() destroys it after that write.
Process {
  id: root
  required property string helperPath
  required property string filePath
  property string payload: ""
  property string pending: ""
  property bool queued: false
  property bool released: false

  signal completed(int code, string error)
  signal retired()

  command: ["timeout", "--kill-after=1s", "3s", "perl", helperPath, "write", filePath]
  stderr: StdioCollector { id: errors; waitForEnd: true }

  function setText(value) {
    if (running) {
      pending = value
      queued = true
    } else {
      payload = value
      stdinEnabled = true
      running = true
    }
  }

  function release() {
    released = true
    if (!running) dispose()
  }

  function dispose() {
    retired()
    destroy()
  }

  onStarted: {
    write(payload)
    stdinEnabled = false
  }

  onExited: function(code) {
    if (queued) {
      queued = false
      setText(pending)
    } else {
      completed(code, String(errors.text || "").trim())
      if (released) dispose()
    }
  }
}
