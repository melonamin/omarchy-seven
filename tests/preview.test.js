const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const http = require('node:http')
const { spawn } = require('node:child_process')
const previewCases = require('./preview-cases.js')
const wait = ms => new Promise(resolve => setTimeout(resolve, ms))

test('real DotPreview renders hostile notes without fetching resources', { timeout: 20000 }, async t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'seven-preview-'))
  const hits = []
  // Successful image responses keep resource completion separate from shutdown.
  const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVQI12P4DwQACfsD/WMmxY8AAAAASUVORK5CYII=', 'base64')
  const server = http.createServer((req, res) => {
    hits.push(req.url)
    res.writeHead(200, { 'Content-Type': 'image/png', 'Content-Length': png.length })
    res.end(png)
  })
  let child
  let exited
  let result
  let logs = ''
  t.after(async () => {
    if (child && !result) {
      child.kill('SIGTERM')
      const timer = setTimeout(() => child.kill('SIGKILL'), 2000)
      await exited
      clearTimeout(timer)
    }
    server.closeAllConnections()
    await new Promise(resolve => server.close(resolve))
    fs.rmSync(dir, { recursive: true, force: true })
  })
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve))
  const base = `http://127.0.0.1:${server.address().port}`
  const notes = previewCases(base)
  // Only the theme is stubbed. This is the shipped component, real Qt Markdown
  // parser, QtQuick resource loader, and an actual loopback HTTP server.
  fs.mkdirSync(path.join(dir, 'Commons'))
  fs.writeFileSync(path.join(dir, 'Commons', 'qmldir'), 'module qs.Commons\nsingleton Color 1.0 Color.qml\nsingleton Style 1.0 Style.qml\n')
  fs.writeFileSync(path.join(dir, 'Commons', 'Color.qml'), 'pragma Singleton\nimport QtQuick\nQtObject { property var popups: ({text: "#ffffff"}); property color accent: "#ffffff" }\n')
  fs.writeFileSync(path.join(dir, 'Commons', 'Style.qml'), 'pragma Singleton\nimport QtQuick\nQtObject { property var font: ({family: "sans-serif", body: 14}) }\n')
  fs.mkdirSync(path.join(dir, 'Seven'))
  for (const name of ['DotPreview.qml', 'SevenModel.js']) {
    fs.copyFileSync(path.join(__dirname, '..', name), path.join(dir, 'Seven', name))
  }
  fs.writeFileSync(path.join(dir, 'Cases.js'), `.pragma library\nvar notes = ${JSON.stringify(notes)};\n`)
  const config = path.join(dir, 'shell.qml')
  fs.writeFileSync(config, `import QtQuick
import Quickshell
import "Seven" as Seven
import "Cases.js" as Cases
ShellRoot {
  Window {
    visible: true; width: 500; height: 400
    Text { textFormat: Text.MarkdownText; text: "![control](${base}/control-markdown)" }
    Text { textFormat: Text.MarkdownText; text: '<img src="${base}/control-html"/>' }
    Repeater {
      model: Cases.notes
      Seven.DotPreview {
        required property string modelData
        width: 500; height: 150
        source: modelData
      }
    }
    Component.onCompleted: console.log("PREVIEWS_READY")
  }
}
`)
  child = spawn('qs', ['-p', config, '--no-color'], {
    env: { ...process.env, QT_QPA_PLATFORM: 'offscreen', WAYLAND_DISPLAY: '', HYPRLAND_INSTANCE_SIGNATURE: '' },
    stdio: ['ignore', 'pipe', 'pipe']
  })
  exited = new Promise(resolve => {
    child.on('exit', (code, signal) => { result = { code, signal }; resolve(result) })
    child.on('error', error => { result = { error }; resolve(result) })
  })
  child.stdout.on('data', chunk => { logs += chunk })
  child.stderr.on('data', chunk => { logs += chunk })
  const deadline = Date.now() + 12000
  while (Date.now() < deadline && !result) {
    if (logs.includes('PREVIEWS_READY') && hits.includes('/control-markdown') && hits.includes('/control-html')) break
    await wait(50)
  }
  assert.ok(!result, `renderer exited early: ${JSON.stringify(result)}\n${logs}`)
  assert.ok(logs.includes('PREVIEWS_READY'), logs)
  assert.ok(hits.includes('/control-markdown'), `Markdown positive control did not fetch\n${logs}`)
  assert.ok(hits.includes('/control-html'), `HTML positive control did not fetch\n${logs}`)
  await wait(1500)
  assert.ok(!result, `renderer exited during resource loading\n${logs}`)
  assert.deepEqual(hits.filter(url => !url.startsWith('/control-')), [], 'a hostile preview fetched a resource')
  assert.doesNotMatch(logs, /ReferenceError|TypeError|Error decoding|Cannot load library|is not a type|is not defined/)
  child.kill('SIGTERM')
  await exited
  assert.ok(result.code === 0 || result.signal === 'SIGTERM', `renderer failed at shutdown: ${JSON.stringify(result)}\n${logs}`)
  t.diagnostic(`${notes.length} hostile notes rendered; both unsanitized positive controls fetched`)
})
