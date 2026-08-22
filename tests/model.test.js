const assert = require("node:assert/strict")
const test = require("node:test")
const path = require("node:path")
const fs = require("node:fs")

const model = require(path.join(__dirname, "..", "DotsModel.js"))

test("there are exactly seven dots, and seven colours for them", () => {
  assert.equal(model.DOT_COUNT, 7)
  assert.equal(model.DOT_COLORS.length, 7)
  assert.equal(new Set(model.DOT_COLORS).size, 7, "every dot needs its own colour")
  for (const color of model.DOT_COLORS) assert.match(color, /^#[0-9a-f]{6}$/)
})

test("clampIndex keeps every caller inside the seven dots", () => {
  assert.equal(model.clampIndex(0), 0)
  assert.equal(model.clampIndex(6), 6)
  assert.equal(model.clampIndex(-4), 0)
  assert.equal(model.clampIndex(99), 6)
  assert.equal(model.clampIndex("3"), 3)
  assert.equal(model.clampIndex(2.7), 2)
  assert.equal(model.clampIndex(NaN), 0)
  assert.equal(model.clampIndex(undefined), 0)
  assert.equal(model.clampIndex(Infinity), 6)
})

test("indexFromNumber rejects rather than clamps, so a typo is not a silent edit", () => {
  assert.equal(model.indexFromNumber(1), 0)
  assert.equal(model.indexFromNumber("7"), 6)
  assert.equal(model.indexFromNumber(0), -1)
  assert.equal(model.indexFromNumber(8), -1)
  assert.equal(model.indexFromNumber("x"), -1)
  assert.equal(model.indexFromNumber(""), -1)
  assert.equal(model.indexFromNumber(null), -1)
})

test("dot files are plain, predictable, 1-based names", () => {
  assert.equal(model.fileNameFor(0), "1.md")
  assert.equal(model.fileNameFor(6), "7.md")
  assert.equal(model.fileNameFor(50), "7.md")
})

test("storage honours XDG_DATA_HOME and falls back to ~/.local/share", () => {
  assert.equal(model.dotsDir("/home/x", ""), "/home/x/.local/share/omarchy-dots/dots")
  assert.equal(model.dotsDir("/home/x", "/data"), "/data/omarchy-dots/dots")
  assert.equal(model.pathFor("/home/x", "", 2), "/home/x/.local/share/omarchy-dots/dots/3.md")
})

test("a whitespace-only dot counts as empty", () => {
  assert.equal(model.isBlank(""), true)
  assert.equal(model.isBlank("   \n\t "), true)
  assert.equal(model.isBlank("."), false)
  assert.equal(model.isBlank(undefined), true)
})

test("filled flags drive the solid-vs-hollow dot in the bar", () => {
  const texts = ["hi", "", "  ", "x", "", "", ""]
  assert.deepEqual(model.filledFlags(texts), [true, false, false, true, false, false, false])
  assert.equal(model.filledCount(texts), 2)
  // A short array must still report seven flags -- the strip always draws seven.
  assert.equal(model.filledFlags(["a"]).length, 7)
  assert.equal(model.filledCount([]), 0)
})

test("capture targets the first empty dot, and the last one when all are taken", () => {
  assert.equal(model.firstBlankIndex(["a", "b", "", "d", "", "", ""]), 2)
  assert.equal(model.firstBlankIndex(["", "", "", "", "", "", ""]), 0)
  assert.equal(model.firstBlankIndex(["a", "b", "c", "d", "e", "f", "g"]), 6)
})

test("word counting ignores tokens that are only markdown punctuation", () => {
  assert.equal(model.countWords(""), 0)
  assert.equal(model.countWords("   "), 0)
  assert.equal(model.countWords("hello there world"), 3)
  assert.equal(model.countWords("# Groceries\n- [ ] oat milk"), 3)
  assert.equal(model.countWords("- [x] done"), 1)
  // Ticking a box must not change the word count.
  assert.equal(model.countWords("- [ ] done"), model.countWords("- [x] done"))
  assert.equal(model.countWords("- [X] done"), 1)
  // A bracketed word is still a word; only the task marker itself is not.
  assert.equal(model.countWords("[xyz]"), 1)
  assert.equal(model.countWords("---"), 0)
  // Non-ASCII words are words.
  assert.equal(model.countWords("привет мир"), 2)
  assert.equal(model.countWords("naïve café"), 2)
})

test("character counting is literal, including whitespace and newlines", () => {
  assert.equal(model.countChars("abc"), 3)
  assert.equal(model.countChars("a\nb"), 3)
  assert.equal(model.countChars(""), 0)
  assert.equal(model.countChars(undefined), 0)
})

test("the counts label singularises correctly", () => {
  assert.equal(model.countsLabel(""), "0 words · 0 chars")
  assert.equal(model.countsLabel("a"), "1 word · 1 char")
  assert.equal(model.countsLabel("ab cd"), "2 words · 5 chars")
})

test("titleFor strips markdown leaders and skips blank lines", () => {
  assert.equal(model.titleFor("## Groceries\n- milk"), "Groceries")
  assert.equal(model.titleFor("\n\n   \nfinally"), "finally")
  assert.equal(model.titleFor("- [ ] buy stamps"), "buy stamps")
  assert.equal(model.titleFor("- [x] buy stamps"), "buy stamps")
  assert.equal(model.titleFor("> quoted"), "quoted")
  assert.equal(model.titleFor("3. third"), "third")
  assert.equal(model.titleFor("* starred"), "starred")
  assert.equal(model.titleFor(""), "")
  assert.equal(model.titleFor("   "), "")
})

test("elide keeps short text intact and truncates long text with an ellipsis", () => {
  assert.equal(model.elide("short", 10), "short")
  assert.equal(model.elide("abcdefghij", 10), "abcdefghij")
  assert.equal(model.elide("abcdefghijk", 10), "abcdefghi…")
  assert.equal(model.elide("abcdefghijk", 10).length, 10)
})

test("the bar tooltip names the dot and its gist", () => {
  const texts = ["", "# Work\nnotes", "", "", "", "", ""]
  assert.equal(model.tooltipFor(texts, 0), "Dot 1 · empty")
  assert.equal(model.tooltipFor(texts, 1), "Dot 2 · Work")
  assert.equal(model.tooltipFor([], 0), "Dot 1 · empty")
})

test("append lands on its own line and never leads with a blank one", () => {
  assert.equal(model.appendText("", "first"), "first")
  assert.equal(model.appendText("   ", "first"), "first")
  assert.equal(model.appendText("a", "b"), "a\nb")
  assert.equal(model.appendText("a\n", "b"), "a\nb")
  assert.equal(model.appendText("a", ""), "a")
})

test("normalize folds CRLF and lone CR, since any editor may have written the file", () => {
  assert.equal(model.normalize("a\r\nb"), "a\nb")
  assert.equal(model.normalize("a\rb"), "a\nb")
  assert.equal(model.normalize("a\nb"), "a\nb")
  assert.equal(model.normalize(undefined), "")
})

test("settings default on, and only accept a real boolean as off", () => {
  assert.deepEqual(model.settingsFromEntry(null), { monospace: true, showCounts: true })
  assert.deepEqual(model.settingsFromEntry({}), { monospace: true, showCounts: true })
  assert.deepEqual(model.settingsFromEntry({ monospace: false }), { monospace: false, showCounts: true })
  // A missing key is not "false"; only an explicit false turns a toggle off.
  assert.equal(model.settingsFromEntry({ monospace: undefined }).monospace, true)
  assert.equal(model.settingsFromEntry({ showCounts: "yes" }).showCounts, false)
})

test("stepping between dots wraps in both directions", () => {
  assert.equal(model.stepIndex(0, 1), 1)
  assert.equal(model.stepIndex(6, 1), 0)
  assert.equal(model.stepIndex(0, -1), 6)
  assert.equal(model.stepIndex(3, 0), 3)
  assert.equal(model.stepIndex(0, 15), 1)
  assert.equal(model.stepIndex(0, -15), 6)
})

test("colorFor never returns undefined for any index a caller can produce", () => {
  for (let i = -3; i < 12; i++) assert.match(model.colorFor(i), /^#[0-9a-f]{6}$/)
})

// The manifest is part of the contract with the shell, so it gets asserted
// alongside the logic rather than only in the shell script.
test("the manifest declares each kind's entry point and the files exist", () => {
  const root = path.join(__dirname, "..")
  const manifest = JSON.parse(fs.readFileSync(path.join(root, "manifest.json"), "utf8"))

  assert.equal(manifest.schemaVersion, 1)
  assert.equal(manifest.id, model.PLUGIN_ID)
  assert.deepEqual(manifest.kinds.slice().sort(), ["bar-widget", "service"])
  assert.equal(manifest.entryPoints.service, "Service.qml")
  assert.equal(manifest.entryPoints.barWidget, "Panel.qml")

  for (const entry of Object.values(manifest.entryPoints)) {
    assert.ok(!entry.startsWith("/") && !entry.includes(".."), `unsafe entry point ${entry}`)
    assert.ok(fs.existsSync(path.join(root, entry)), `missing entry point ${entry}`)
  }

  // Every declared setting needs a default, or the panel reads undefined.
  for (const field of manifest.barWidget.schema) {
    assert.ok(field.key in manifest.barWidget.defaults, `${field.key} has no default`)
  }
  assert.deepEqual(
    model.settingsFromEntry(manifest.barWidget.defaults),
    manifest.barWidget.defaults,
    "manifest defaults must match the model's defaults")
})
