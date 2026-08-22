const assert = require("node:assert/strict")
const test = require("node:test")
const path = require("node:path")
const fs = require("node:fs")

const model = require(path.join(__dirname, "..", "SevenModel.js"))

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
  assert.equal(model.dotsDir("/home/x", ""), "/home/x/.local/share/omarchy-seven/dots")
  assert.equal(model.dotsDir("/home/x", "/data"), "/data/omarchy-seven/dots")
  assert.equal(model.pathFor("/home/x", "", 2), "/home/x/.local/share/omarchy-seven/dots/3.md")
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
  const defaults = { monospace: true, showCounts: true, colorfulDot: true, shortcut: model.DEFAULT_SHORTCUT }
  assert.deepEqual(model.settingsFromEntry(null), defaults)
  assert.deepEqual(model.settingsFromEntry({}), defaults)
  assert.equal(model.settingsFromEntry({ monospace: false }).monospace, false)
  assert.equal(model.settingsFromEntry({ colorfulDot: false }).colorfulDot, false)
  // A missing key is not "false"; only an explicit false turns a toggle off.
  assert.equal(model.settingsFromEntry({ monospace: undefined }).monospace, true)
  assert.equal(model.settingsFromEntry({ showCounts: "yes" }).showCounts, false)
})

test("an absent shortcut means the default, an empty one means no binding", () => {
  assert.equal(model.settingsFromEntry({}).shortcut, model.DEFAULT_SHORTCUT)
  assert.equal(model.settingsFromEntry({ shortcut: null }).shortcut, model.DEFAULT_SHORTCUT)
  // Explicitly empty is a choice, not an omission, and must survive as one.
  assert.equal(model.settingsFromEntry({ shortcut: "" }).shortcut, "")
  assert.equal(model.settingsFromEntry({ shortcut: "   " }).shortcut, "")
})

test("shortcuts normalise to the one shape Hyprland wants", () => {
  assert.equal(model.normalizeShortcut("super, ctrl, m"), "SUPER + CTRL + M")
  assert.equal(model.normalizeShortcut("SUPER+CTRL+J"), "SUPER + CTRL + J")
  assert.equal(model.normalizeShortcut("  super   ctrl   j  "), "SUPER + CTRL + J")
  assert.equal(model.normalizeShortcut("SUPER + CTRL + J"), "SUPER + CTRL + J")
  assert.equal(model.normalizeShortcut(""), "")
})

test("a shortcut splits into the modmask and key hyprctl reports", () => {
  assert.deepEqual(model.shortcutChord("SUPER + CTRL + J"), { modmask: 68, key: "J" })
  assert.deepEqual(model.shortcutChord("SUPER"), { modmask: 64, key: "" })
  assert.deepEqual(model.shortcutChord("super shift alt k"), { modmask: 73, key: "K" })
  // A repeated modifier must not double the mask.
  assert.deepEqual(model.shortcutChord("CTRL + CONTROL + K"), { modmask: 4, key: "K" })
  assert.deepEqual(model.shortcutChord(""), { modmask: 0, key: "" })
})

test("shortcut state separates 'registered' from 'someone else owns this chord'", () => {
  const mine = { modmask: 68, key: "J", submap: "", description: "Seven notes" }
  const theirs = { modmask: 68, key: "N", submap: "", description: "Toggle nightlight" }
  const submapped = { modmask: 68, key: "J", submap: "resize", description: "Something else" }

  assert.deepEqual(model.shortcutState([mine, theirs], "SUPER + CTRL + J", "Seven notes"),
    { found: true, collision: false })
  assert.deepEqual(model.shortcutState([mine, theirs], "SUPER + CTRL + N", "Seven notes"),
    { found: false, collision: true })
  assert.deepEqual(model.shortcutState([mine, theirs], "SUPER + CTRL + Q", "Seven notes"),
    { found: false, collision: false })
  // A bind inside a submap does not contend for the global chord.
  assert.deepEqual(model.shortcutState([submapped], "SUPER + CTRL + J", "Seven notes"),
    { found: false, collision: false })
  assert.deepEqual(model.shortcutState(null, "SUPER + CTRL + J", "Seven notes"),
    { found: false, collision: false })
})

test("settings are found on the bar layout entry first, then plugins[]", () => {
  const layoutOnly = { bar: { layout: { right: [{ id: "other" }, { id: "melonamin.seven", shortcut: "SUPER + ALT + M" }] } } }
  assert.equal(model.findSettingsEntry(layoutOnly, "melonamin.seven").shortcut, "SUPER + ALT + M")

  const pluginsOnly = { plugins: [{ id: "melonamin.seven", shortcut: "SUPER + ALT + P" }] }
  assert.equal(model.findSettingsEntry(pluginsOnly, "melonamin.seven").shortcut, "SUPER + ALT + P")

  // The layout entry is where the settings UI writes, so it wins.
  const both = {
    bar: { layout: { center: [{ id: "melonamin.seven", shortcut: "LAYOUT" }] } },
    plugins: [{ id: "melonamin.seven", shortcut: "PLUGINS" }]
  }
  assert.equal(model.findSettingsEntry(both, "melonamin.seven").shortcut, "LAYOUT")

  assert.equal(model.findSettingsEntry({}, "melonamin.seven"), null)
  assert.equal(model.findSettingsEntry(null, "melonamin.seven"), null)
})

test("withSetting writes one key without freezing the other defaults in", () => {
  // Only what the user already set is carried over, so a right click does not
  // bake monospace/showCounts/shortcut into their shell.json.
  assert.deepEqual(
    model.withSetting({ monospace: false }, "melonamin.seven", "colorfulDot", false),
    { id: "melonamin.seven", monospace: false, colorfulDot: false })

  assert.deepEqual(
    model.withSetting(null, "melonamin.seven", "colorfulDot", false),
    { id: "melonamin.seven", colorfulDot: false })

  // A stale id in the incoming settings must not survive.
  assert.equal(
    model.withSetting({ id: "stale" }, "melonamin.seven", "colorfulDot", true).id,
    "melonamin.seven")

  // Toggling twice returns the entry to where it started.
  const once = model.withSetting({}, "melonamin.seven", "colorfulDot", false)
  const twice = model.withSetting(once, "melonamin.seven", "colorfulDot", true)
  assert.equal(model.settingsFromEntry(twice).colorfulDot, true)
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
  const fromManifest = model.settingsFromEntry(manifest.barWidget.defaults)
  for (const [key, value] of Object.entries(manifest.barWidget.defaults)) {
    assert.equal(fromManifest[key], value, `manifest default for ${key} disagrees with the model`)
  }
  // shortcut is deliberately absent from the manifest: there is no string
  // control in the settings UI, so it is edited in shell.json by hand.
  assert.ok(!("shortcut" in manifest.barWidget.defaults))
})

// --------------------------------------------------------------- markdown

// Edit plans are "replace [start,end) with text"; applying one here keeps the
// assertions about documents rather than about offsets.
function apply(text, plan) {
  assert.ok(plan, "expected an edit plan")
  return text.slice(0, plan.start) + plan.text + text.slice(plan.end)
}

function pressEnter(text, cursor) {
  return apply(text, model.newlineEdit(text, cursor))
}

test("Enter continues a bullet list", () => {
  assert.equal(pressEnter("- milk", 6), "- milk\n- ")
  assert.equal(pressEnter("* milk", 6), "* milk\n* ")
  assert.equal(pressEnter("+ milk", 6), "+ milk\n+ ")
  // Indentation of a nested item is carried down with it.
  assert.equal(pressEnter("    - deep", 10), "    - deep\n    - ")
  assert.equal(pressEnter("\t- tabbed", 9), "\t- tabbed\n\t- ")
})

test("Enter numbers the next ordered item", () => {
  assert.equal(pressEnter("1. first", 8), "1. first\n2. ")
  assert.equal(pressEnter("9. ninth", 8), "9. ninth\n10. ")
  assert.equal(pressEnter("3) third", 8), "3) third\n4) ")
  assert.equal(pressEnter("  1. first", 10), "  1. first\n  2. ")
})

test("Enter on an empty list item ends the list instead of extending it", () => {
  assert.equal(pressEnter("- ", 2), "")
  assert.equal(pressEnter("- milk\n- ", 9), "- milk\n")
  assert.equal(pressEnter("  1. ", 5), "")
  assert.equal(pressEnter("- [ ] ", 6), "")
  // The caret lands where the marker was.
  assert.equal(model.newlineEdit("- milk\n- ", 9).cursorStart, 7)
})

test("Enter continues a task list unchecked", () => {
  assert.equal(pressEnter("- [ ] buy stamps", 16), "- [ ] buy stamps\n- [ ] ")
  // Carrying [x] down would tick a box nobody has done.
  assert.equal(pressEnter("- [x] done", 10), "- [x] done\n- [ ] ")
  assert.equal(pressEnter("- [X] done", 10), "- [X] done\n- [ ] ")
})

test("Enter carries indentation on ordinary lines", () => {
  assert.equal(pressEnter("    indented", 12), "    indented\n    ")
  assert.equal(pressEnter("plain", 5), "plain\n")
  assert.equal(pressEnter("", 0), "\n")
  // Splitting a line mid-way still carries the indent to the new one.
  assert.equal(pressEnter("  ab", 3), "  a\n  b")
})

test("Enter is unfazed by a cursor at either end of the document", () => {
  assert.equal(pressEnter("- milk", 999), "- milk\n- ")
  assert.equal(pressEnter("- milk", -5), "\n- milk")
})

test("Enter before the marker opens a line above instead of adding a bullet", () => {
  // Caret at the very start of "- milk".
  assert.equal(pressEnter("- milk", 0), "\n- milk")
  // Caret inside the marker itself.
  assert.equal(pressEnter("- milk", 1), "-\n milk")
  assert.equal(pressEnter("- ", 0), "\n- ")
  // Indentation the caret has not reached yet stays with the text below.
  assert.equal(pressEnter("    - deep", 2), "  \n  - deep")
})

test("bold, italic, and strikethrough wrap a selection", () => {
  assert.equal(apply("bold", model.toggleWrap("bold", 0, 4, "**")), "**bold**")
  assert.equal(apply("it", model.toggleWrap("it", 0, 2, "*")), "*it*")
  assert.equal(apply("gone", model.toggleWrap("gone", 0, 4, "~~")), "~~gone~~")
  // The words stay selected so a second shortcut can stack on the first.
  const plan = model.toggleWrap("say bold now", 4, 8, "**")
  assert.equal(apply("say bold now", plan), "say **bold** now")
  assert.equal(plan.cursorStart, 6)
  assert.equal(plan.cursorEnd, 10)
})

test("the same shortcut unwraps text it already wrapped", () => {
  // Markers just outside the selection.
  assert.equal(apply("**bold**", model.toggleWrap("**bold**", 2, 6, "**")), "bold")
  // Markers inside the selection.
  assert.equal(apply("**bold**", model.toggleWrap("**bold**", 0, 8, "**")), "bold")
  assert.equal(apply("~~gone~~", model.toggleWrap("~~gone~~", 2, 6, "~~")), "gone")
  assert.equal(apply("a *it* b", model.toggleWrap("a *it* b", 3, 5, "*")), "a it b")
})

test("italic does not cannibalise a bold pair", () => {
  // Ctrl+I inside **bold** must add italics, not strip one asterisk a side.
  assert.equal(apply("**bold**", model.toggleWrap("**bold**", 2, 6, "*")), "***bold***")
})

test("wrapping with no selection leaves the caret between the markers", () => {
  const plan = model.toggleWrap("ab", 1, 1, "**")
  assert.equal(apply("ab", plan), "a****b")
  assert.equal(plan.cursorStart, 3)
  assert.equal(plan.cursorEnd, 3)
})

test("a backwards selection wraps the same as a forwards one", () => {
  assert.equal(apply("bold", model.toggleWrap("bold", 4, 0, "**")), "**bold**")
})

test("headings are set, replaced, and toggled off", () => {
  assert.equal(apply("title", model.toggleHeading("title", 0, 2)), "## title")
  assert.equal(apply("## title", model.toggleHeading("## title", 4, 3)), "### title")
  // The level a line already has toggles it off.
  assert.equal(apply("## title", model.toggleHeading("## title", 4, 2)), "title")
  // Level 0 always clears.
  assert.equal(apply("### title", model.toggleHeading("### title", 5, 0)), "title")
  assert.equal(apply("title", model.toggleHeading("title", 0, 0)), "title")
  // Levels are capped at markdown's six.
  assert.equal(apply("title", model.toggleHeading("title", 0, 9)), "###### title")
})

test("headings act on the line the cursor is in, and keep its indentation", () => {
  const doc = "first\nsecond\nthird"
  assert.equal(apply(doc, model.toggleHeading(doc, 8, 1)), "first\n# second\nthird")
  assert.equal(apply("  note", model.toggleHeading("  note", 4, 1)), "  # note")
  assert.equal(apply("  # note", model.toggleHeading("  # note", 6, 1)), "  note")
})

test("the caret follows the words when a heading prefix changes width", () => {
  // Caret on "t" of title (index 3); adding "## " shifts it right by three.
  assert.equal(model.toggleHeading("title", 3, 2).cursorStart, 6)
  // Removing the prefix shifts it back.
  assert.equal(model.toggleHeading("## title", 6, 2).cursorStart, 3)
  // A caret inside the hashes is pushed to the start of the words, never
  // stranded in the middle of the marker.
  assert.equal(model.toggleHeading("title", 0, 2).cursorStart, 3)
})

test("Tab inserts four spaces, replacing any selection", () => {
  assert.equal(model.TAB_WIDTH, 4)
  assert.equal(apply("ab", model.tabEdit("ab", 2, 2)), "ab    ")
  assert.equal(model.tabEdit("ab", 2, 2).cursorStart, 6)
  // A selection is replaced, not indented around.
  assert.equal(apply("a12b", model.tabEdit("a12b", 1, 3)), "a    b")
  // Backwards selections behave the same.
  assert.equal(apply("a12b", model.tabEdit("a12b", 3, 1)), "a    b")
  assert.equal(apply("", model.tabEdit("", 0, 0)), "    ")
})

test("shortcuts are written for people on the sheet", () => {
  assert.equal(model.prettyShortcut("SUPER + CTRL + J"), "Super + Ctrl + J")
  assert.equal(model.prettyShortcut("super,alt,m"), "Super + Alt + M")
  assert.equal(model.prettyShortcut(""), "")
})

test("the sheet shows the shortcut that is actually configured", () => {
  const sheet = model.shortcutSheet("SUPER + ALT + M")
  assert.equal(sheet.left[0].items[0].keys, "Super + Alt + M")
  // With no global binding the row says so rather than showing a blank.
  assert.equal(model.shortcutSheet("").left[0].items[0].keys, "not set")
})

test("the sheet is well formed and covers both columns", () => {
  const sheet = model.shortcutSheet("SUPER + CTRL + J")
  assert.ok(sheet.left.length > 0 && sheet.right.length > 0)
  for (const group of [...sheet.left, ...sheet.right]) {
    assert.ok(group.title, "every group needs a title")
    assert.ok(group.items.length > 0, `${group.title} has no rows`)
    for (const item of group.items) {
      assert.ok(item.keys, `a row in ${group.title} has no keys`)
      assert.ok(item.label, `a row in ${group.title} has no label`)
    }
  }
})

// The sheet is the only place the keymap is written down for the user. If a
// binding is renamed in the QML and not here, the sheet starts lying -- so
// check each documented chord against what the QML actually binds.
test("every key the sheet documents is really bound in the QML", () => {
  const root = path.join(__dirname, "..")
  const sources = ["Panel.qml", path.join("components", "DotEditor.qml")]
    .map((f) => fs.readFileSync(path.join(root, f), "utf8"))
    .join("\n")

  const named = { Esc: "Escape", Enter: "Return", Tab: "Tab", F1: "F1" }
  const sheet = model.shortcutSheet("SUPER + CTRL + J")

  for (const group of [...sheet.left, ...sheet.right]) {
    // The global chord is registered with Hyprland, not bound in QML, and the
    // mouse rows are wired to onPressed rather than to a key.
    if (group.title === "Anywhere" || group.title === "The bar dot") continue

    for (const item of group.items) {
      // "Enter on empty" is the same key as "Enter" in a different state.
      const chord = item.keys.replace(/ on empty$/, "")
      const last = chord.split(" + ").pop().trim()

      let symbols
      if (named[last]) symbols = [`Qt.Key_${named[last]}`]
      else if (/^[0-9A-Z]$/.test(last)) symbols = [`Qt.Key_${last}`]
      else if (/^\d…\d$/.test(last)) symbols = [`Qt.Key_${last[0]}`]   // "1…7"
      else if (last === "← →") symbols = ["Qt.Key_Left", "Qt.Key_Right"]
      else throw new Error(`the test cannot map "${item.keys}" to a Qt key`)

      for (const symbol of symbols) {
        assert.ok(sources.includes(symbol),
          `the sheet documents "${item.keys}" but ${symbol} is not bound in the QML`)
      }
    }
  }
})
