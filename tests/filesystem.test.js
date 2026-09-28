const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { pathToFileURL } = require('node:url')
const { spawn, spawnSync, execFile } = require('node:child_process')
const { promisify } = require('node:util')
const exec = promisify(execFile)
const repo = path.resolve(__dirname, '..')
const helper = path.join(repo, 'note-io.pl')
const wait = ms => new Promise(resolve => setTimeout(resolve, ms))

function fixture(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'seven-filesystem-'))
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }))
  return dir
}
function io(operation, file, input = '', limit = 1048576) {
  return spawnSync('perl', [helper, operation, file, String(limit)], {
    input, encoding: 'utf8', timeout: 4000, maxBuffer: 2 * 1048576
  })
}
async function until(check, message, timeout = 5000) {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    if (await check()) return
    await wait(50)
  }
  assert.fail(message)
}

test('regular, missing, empty and bounded files round-trip without touching shell syntax', t => {
  const dir = fixture(t)
  const file = path.join(dir, 'note $(touch bad); "unicode".md')
  assert.equal(io('read', file).stdout, '0 0\n')
  const text = 'héllo\n"$HOME" `touch bad`\n'
  assert.equal(io('write', file, text).status, 0)
  assert.equal(io('read', file).stdout, `${Buffer.byteLength(text)} ${Buffer.byteLength(text)}\n${text}`)
  fs.chmodSync(file, 0o640)
  assert.equal(io('write', file, '').status, 0)
  assert.equal(fs.readFileSync(file, 'utf8'), '')
  assert.equal(fs.statSync(file).mode & 0o777, 0o640)
  fs.writeFileSync(file, Buffer.alloc(1048578, 'x'))
  assert.equal(io('read', file).stdout, '1048577 1048578\n')
  assert.equal(io('read', file, '', 16).stdout, '17 1048578\n')
})

test('symlinks, dangling links, FIFOs and directories are refused for reads and writes', t => {
  const dir = fixture(t)
  const target = path.join(dir, 'victim')
  fs.writeFileSync(target, 'untouched')
  for (const kind of ['symlink', 'dangling', 'fifo', 'directory']) {
    const file = path.join(dir, kind)
    if (kind === 'symlink') fs.symlinkSync(target, file)
    if (kind === 'dangling') fs.symlinkSync(path.join(dir, 'missing-victim'), file)
    if (kind === 'fifo') assert.equal(spawnSync('mkfifo', [file]).status, 0)
    if (kind === 'directory') fs.mkdirSync(file)
    for (const op of ['read', 'write']) {
      const start = Date.now()
      const result = io(op, file, 'overwrite')
      assert.notEqual(result.status, 0, `${op} must refuse ${kind}`)
      assert.equal(result.error, undefined)
      assert.ok(Date.now() - start < 1500, `${op} must not block on ${kind}`)
    }
  }
  assert.equal(fs.readFileSync(target, 'utf8'), 'untouched')
  const hardlink = path.join(dir, 'hardlink')
  fs.linkSync(target, hardlink)
  assert.equal(io('write', hardlink, 'new note').status, 0)
  assert.equal(fs.readFileSync(target, 'utf8'), 'untouched')
  assert.equal(fs.readFileSync(hardlink, 'utf8'), 'new note')
  assert.equal(fs.existsSync(path.join(dir, 'missing-victim')), false)
  const linkedDir = path.join(dir, 'linked-directory')
  fs.symlinkSync(dir, linkedDir)
  assert.notEqual(io('read', path.join(linkedDir, 'victim')).status, 0)
  assert.notEqual(io('write', path.join(linkedDir, 'victim'), 'overwrite').status, 0)
  assert.equal(fs.readFileSync(target, 'utf8'), 'untouched')
})

test('a destination replaced with a symlink while receiving a write cannot be truncated', async t => {
  const dir = fixture(t)
  const file = path.join(dir, '1.md')
  const victim = path.join(dir, 'victim')
  fs.writeFileSync(file, 'original')
  fs.writeFileSync(victim, 'untouched')
  const child = spawn('perl', [helper, 'write', file], { stdio: ['pipe', 'ignore', 'pipe'] })
  const exited = new Promise(resolve => child.on('exit', resolve))
  child.stderr.resume()
  child.stdin.write('new note')
  await until(() => fs.readdirSync(dir).some(name => name.startsWith('.seven-')), 'writer did not stage')
  fs.unlinkSync(file)
  fs.symlinkSync(victim, file)
  child.stdin.end()
  assert.notEqual(await exited, 0)
  assert.equal(fs.readFileSync(victim, 'utf8'), 'untouched')
  assert.equal(fs.lstatSync(file).isSymbolicLink(), true)
  assert.equal(fs.readdirSync(dir).some(name => name.startsWith('.seven-')), false)
})

test('a renamed parent directory stays pinned while a write is in progress', async t => {
  const dir = fixture(t)
  const parent = path.join(dir, 'dots')
  const moved = path.join(dir, 'moved-dots')
  const other = path.join(dir, 'other')
  fs.mkdirSync(parent)
  fs.mkdirSync(other)
  fs.writeFileSync(path.join(parent, '1.md'), 'old')
  fs.writeFileSync(path.join(other, '1.md'), 'untouched')
  const child = spawn('perl', [helper, 'write', path.join(parent, '1.md')], { stdio: ['pipe', 'ignore', 'pipe'] })
  const exited = new Promise(resolve => child.on('exit', resolve))
  child.stderr.resume()
  child.stdin.write('new')
  await until(() => fs.readdirSync(parent).some(name => name.startsWith('.seven-')), 'writer did not stage')
  fs.renameSync(parent, moved)
  fs.symlinkSync(other, parent)
  child.stdin.end()
  assert.equal(await exited, 0)
  assert.equal(fs.readFileSync(path.join(moved, '1.md'), 'utf8'), 'new')
  assert.equal(fs.readFileSync(path.join(other, '1.md'), 'utf8'), 'untouched')
})

test('a stalled writer hits its deadline and removes its staging file', async t => {
  const dir = fixture(t)
  const file = path.join(dir, '1.md')
  fs.writeFileSync(file, 'old')
  const start = Date.now()
  const child = spawn('perl', [helper, 'write', file], { stdio: ['pipe', 'ignore', 'pipe'] })
  const exited = new Promise(resolve => child.on('exit', resolve))
  let errors = ''
  child.stderr.on('data', chunk => { errors += chunk })
  child.stdin.write('unfinished')
  assert.notEqual(await exited, 0)
  assert.match(errors, /deadline/)
  assert.ok(Date.now() - start < 3500)
  assert.equal(fs.readFileSync(file, 'utf8'), 'old')
  assert.equal(fs.readdirSync(dir).some(name => name.startsWith('.seven-')), false)
})

test('real Service IPC rejects unsafe files, recovers, saves and flushes on plugin unload', async t => {
  const dir = fixture(t)
  const config = path.join(dir, 'shell.qml')
  const data = path.join(dir, 'data')
  const dots = path.join(data, 'omarchy-seven', 'dots')
  const bin = path.join(dir, 'bin')
  const delayedHelper = path.join(dir, 'delayed-writer.pl')
  const queuedFile = path.join(dots, 'queued.md')
  fs.mkdirSync(dots, { recursive: true })
  fs.mkdirSync(bin)
  fs.writeFileSync(delayedHelper, `select(undef, undef, undef, 0.25); exec("perl", ${JSON.stringify(helper)}, @ARGV);\n`)
  // Only compositor operations are stubbed: filesystem I/O and IPC use the
  // real service and helper, isolated from the user's notes and bindings.
  fs.writeFileSync(path.join(bin, 'hyprctl'), '#!/bin/sh\nprintf "[]\\n"\n', { mode: 0o755 })
  fs.mkdirSync(path.join(dir, '.config', 'omarchy'), { recursive: true })
  fs.writeFileSync(path.join(dir, '.config', 'omarchy', 'shell.json'), JSON.stringify({
    plugins: [{ id: 'melonamin.seven', shortcut: '' }]
  }))
  const victim = path.join(dir, 'victim')
  fs.writeFileSync(victim, 'untouched')
  fs.symlinkSync(victim, path.join(dots, '1.md'))
  assert.equal(spawnSync('mkfifo', [path.join(dots, '2.md')]).status, 0)
  assert.equal(spawnSync('mkfifo', [path.join(data, 'omarchy-seven', 'active')]).status, 0)
  fs.writeFileSync(config, `import QtQuick
import Quickshell
import Quickshell.Io
import ${JSON.stringify(pathToFileURL(repo).href)} as Seven
import ${JSON.stringify(pathToFileURL(path.join(repo, 'NoteIo.js')).href)} as NoteIo
ShellRoot {
  Loader { id: loader; sourceComponent: Seven.Service {} }
  IpcHandler {
    target: "test"
    function reload(dot: string): void { loader.item.reloadDot(Number(dot) - 1) }
    function unload(): void { loader.active = false }
    function queue(): void {
      var writer = NoteIo.createWriter(${JSON.stringify(pathToFileURL(path.join(repo, 'NoteWriter.qml')).href)},
        ${JSON.stringify(delayedHelper)}, ${JSON.stringify(queuedFile)})
      writer.setText("first")
      writer.setText("")
      writer.setText("latest")
      writer.release()
    }
  }
}
`)
  const env = { ...process.env, HOME: dir, XDG_DATA_HOME: data,
    QT_QPA_PLATFORM: 'offscreen', WAYLAND_DISPLAY: '', HYPRLAND_INSTANCE_SIGNATURE: '',
    PATH: bin + ':' + process.env.PATH }
  const child = spawn('qs', ['-p', config, '--no-color'], { env })
  let logs = ''
  child.stdout.on('data', chunk => { logs += chunk })
  child.stderr.on('data', chunk => { logs += chunk })
  t.after(async () => {
    child.kill('SIGTERM')
    await Promise.race([new Promise(resolve => child.on('exit', resolve)), wait(1000)])
  })
  async function ipc(target, ...args) {
    const r = await exec('qs', ['ipc', '-p', config, 'call', '--', target, ...args], { env, timeout: 5000 })
    return r.stdout.trimEnd()
  }
  const status = async () => JSON.parse(await ipc('seven', 'status'))
  await until(async () => {
    try { return (await status()).ready } catch { return false }
  }, 'service failed to start: ' + logs)
  assert.ok((await status()).ioErrors['0'])
  assert.ok((await status()).ioErrors['1'])
  for (const dot of ['1', '2']) {
    assert.match(await ipc('seven', 'read', dot), /^error:/)
    assert.match(await ipc('seven', 'clear', dot), /^error:/)
    assert.match(await ipc('seven', 'append', dot, 'overwrite'), /^error:/)
  }
  assert.equal(fs.readFileSync(victim, 'utf8'), 'untouched')
  fs.unlinkSync(path.join(dots, '1.md'))
  fs.writeFileSync(path.join(dots, '1.md'), 'recovered\n')
  await ipc('test', 'reload', '1')
  await until(async () => await ipc('seven', 'read', '1') === 'recovered', 'safe replacement did not recover')
  assert.equal(await ipc('seven', 'clear', '1'), 'ok')
  await until(() => fs.readFileSync(path.join(dots, '1.md'), 'utf8') === '', 'clear did not persist')
  assert.equal(await ipc('seven', 'append', '1', 'saved héllo 😀'), 'ok')
  await until(() => fs.readFileSync(path.join(dots, '1.md'), 'utf8') === 'saved héllo 😀\n', 'append did not persist')
  // Swap after a successful read, before the debounced write.
  await ipc('seven', 'append', '1', 'must not escape')
  fs.unlinkSync(path.join(dots, '1.md'))
  fs.symlinkSync(victim, path.join(dots, '1.md'))
  await until(async () => Boolean((await status()).ioErrors['0']), 'write refusal was not reported')
  assert.equal(fs.readFileSync(victim, 'utf8'), 'untouched')
  fs.unlinkSync(path.join(dots, '1.md'))
  fs.writeFileSync(path.join(dots, '1.md'), 'external\n')
  await ipc('test', 'reload', '1')
  await until(() => fs.readFileSync(path.join(dots, '1.md'), 'utf8') === 'saved héllo 😀\nmust not escape\n', 'failed write lost pending text')
  // The active-state path must also refuse special files.
  await ipc('seven', 'show', '3')
  await wait(600)
  assert.ok(fs.lstatSync(path.join(data, 'omarchy-seven', 'active')).isFIFO())
  fs.unlinkSync(path.join(data, 'omarchy-seven', 'active'))
  fs.symlinkSync(victim, path.join(data, 'omarchy-seven', 'active'))
  await ipc('seven', 'show', '4')
  await wait(600)
  assert.equal(fs.readFileSync(victim, 'utf8'), 'untouched')
  assert.ok(fs.lstatSync(path.join(data, 'omarchy-seven', 'active')).isSymbolicLink())
  fs.unlinkSync(path.join(data, 'omarchy-seven', 'active'))
  await ipc('seven', 'show', '5')
  await until(() => fs.existsSync(path.join(data, 'omarchy-seven', 'active'))
    && fs.readFileSync(path.join(data, 'omarchy-seven', 'active'), 'utf8') === '5\n', 'active state did not save')
  // Unloading within the debounce window must still finish the final write.
  await ipc('seven', 'append', '3', 'final edit')
  await ipc('test', 'queue')
  await ipc('test', 'unload')
  await until(() => fs.existsSync(path.join(dots, '3.md')) && fs.readFileSync(path.join(dots, '3.md'), 'utf8') === 'final edit\n', 'unload lost the pending edit: ' + logs)
  await until(() => fs.existsSync(queuedFile) && fs.readFileSync(queuedFile, 'utf8') === 'latest', 'queued writes lost their order')
  assert.doesNotMatch(logs, /TypeError|ReferenceError|Unable to assign|Cannot assign/)
})
