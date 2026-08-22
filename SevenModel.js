// Pure logic for Seven. No QML types are referenced here so the same source
// runs under Quickshell's JS engine and under node for the unit tests.

var PLUGIN_ID = "melonamin.seven"

// Seven dots. Not six, not eight, and never a "new note" button -- the fixed
// count is the whole idea: you stop filing and start writing.
var DOT_COUNT = 7

// One hue per dot, in spectrum order. Chosen mid-saturation so they stay
// legible against both a near-black and a near-white themed popup; the panel
// never recolors them per theme, because a dot's colour is its identity.
var DOT_COLORS = [
  "#e5534b",
  "#e2934a",
  "#d9bf4c",
  "#6fb86b",
  "#4fa8c7",
  "#6c7ee1",
  "#b57bd6"
]

function string(value) {
  return value === undefined || value === null ? "" : String(value)
}

function bool(value, fallback) {
  return value === undefined || value === null ? fallback : value === true
}

// Dots are addressed 1-7 by humans and 0-6 by arrays. Every entry point that
// takes a number funnels through here so an out-of-range IPC argument lands on
// a real dot instead of throwing deep inside a binding.
function clampIndex(index) {
  var value = Math.floor(Number(index))
  // NaN carries no position, so it starts at the first dot; an infinity is a
  // direction, and clamps to that end like any other out-of-range number.
  if (isNaN(value)) return 0
  if (value < 0) return 0
  if (value > DOT_COUNT - 1) return DOT_COUNT - 1
  return value
}

// Accepts the 1-based number a user types (`dots read 3`) and returns the
// 0-based index. Anything unparseable is rejected rather than clamped, so a
// typo reports an error instead of silently editing dot 1.
function indexFromNumber(value) {
  var raw = Number(value)
  if (!isFinite(raw)) return -1
  var number = Math.floor(raw)
  if (number < 1 || number > DOT_COUNT) return -1
  return number - 1
}

function colorFor(index) {
  return DOT_COLORS[clampIndex(index)]
}

function fileNameFor(index) {
  return (clampIndex(index) + 1) + ".md"
}

// Where the seven files live. Passed the environment rather than reading it so
// the tests can exercise the XDG branch without touching the real home dir.
function dotsDir(home, xdgDataHome) {
  var base = string(xdgDataHome)
  if (base === "") base = string(home) + "/.local/share"
  return base + "/omarchy-seven/dots"
}

function pathFor(home, xdgDataHome, index) {
  return dotsDir(home, xdgDataHome) + "/" + fileNameFor(index)
}

function isBlank(text) {
  return string(text).trim() === ""
}

// A dot is "filled" when it holds anything at all -- that is what the bar's
// solid-vs-hollow dot reports, so whitespace-only must read as empty.
function filledFlags(texts) {
  var result = []
  for (var i = 0; i < DOT_COUNT; i++) result.push(!isBlank(texts && texts[i]))
  return result
}

function filledCount(texts) {
  var flags = filledFlags(texts)
  var count = 0
  for (var i = 0; i < flags.length; i++) if (flags[i]) count++
  return count
}

// Tot's rule for "where does new text go": the first empty dot, or the last
// dot when every one of them is taken. Never silently overwrite.
function firstBlankIndex(texts) {
  for (var i = 0; i < DOT_COUNT; i++) {
    if (isBlank(texts && texts[i])) return i
  }
  return DOT_COUNT - 1
}

// A word has to contain a letter or a digit. Without that rule the markdown a
// note is written in inflates its own count -- "# Groceries\n- [ ] oat milk"
// reads as seven words when a person would say three.
function countWords(text) {
  var trimmed = string(text).trim()
  if (trimmed === "") return 0
  var tokens = trimmed.split(/\s+/)
  var count = 0
  for (var i = 0; i < tokens.length; i++) {
    // A task marker is punctuation whichever way it is ticked. Without this
    // "[x]" would count (it holds an x) while "[ ]" would not, so checking a
    // box off a list would quietly add a word.
    if (/^\[[ xX]\]$/.test(tokens[i])) continue
    if (/[0-9A-Za-z\u00c0-\uffff]/.test(tokens[i])) count++
  }
  return count
}

function countChars(text) {
  return string(text).length
}

function plural(count, word) {
  return count + " " + word + (count === 1 ? "" : "s")
}

function countsLabel(text) {
  return plural(countWords(text), "word") + " · " + plural(countChars(text), "char")
}

// One-line gist of a dot for the bar tooltip. Markdown leaders are stripped so
// a heading reads as its words rather than as "## words".
function titleFor(text) {
  var lines = string(text).split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
      .replace(/^\s*#{1,6}\s+/, "")
      .replace(/^\s*>\s+/, "")
      .replace(/^\s*[-*+]\s+\[[ xX]\]\s+/, "")
      .replace(/^\s*[-*+]\s+/, "")
      .replace(/^\s*\d+\.\s+/, "")
      .trim()
    if (line !== "") return line
  }
  return ""
}

function elide(text, limit) {
  var value = string(text)
  var max = Math.max(1, Math.floor(Number(limit) || 40))
  if (value.length <= max) return value
  return value.slice(0, max - 1).replace(/\s+$/, "") + "…"
}

// Tooltip text for the bar button: which dot is showing and what is in it.
function tooltipFor(texts, activeIndex) {
  var index = clampIndex(activeIndex)
  var title = titleFor(texts && texts[index])
  var label = "Dot " + (index + 1)
  if (title === "") return label + " · empty"
  return label + " · " + elide(title, 42)
}

// Appending from the CLI should read like appending in an editor: land on its
// own line, and never introduce a leading blank line in an empty dot.
function appendText(existing, addition) {
  var base = string(existing)
  var extra = string(addition)
  if (extra === "") return base
  if (base.trim() === "") return extra
  var separator = base.charAt(base.length - 1) === "\n" ? "" : "\n"
  return base + separator + extra
}

// Files on disk are the source of truth and a user may edit them in any editor,
// so normalize the line endings we accept rather than assuming we wrote them.
function normalize(text) {
  return string(text).replace(/\r\n/g, "\n").replace(/\r/g, "\n")
}

var DEFAULT_SHORTCUT = "SUPER + CTRL + J"

// Hyprland wants "SUPER + CTRL + J". Users write it every other way, so accept
// commas, plain spaces, and any casing, and hand Hyprland one shape.
function normalizeShortcut(value) {
  var raw = string(value).replace(/[,+]/g, " ")
  var parts = raw.split(/\s+/)
  var result = []
  for (var i = 0; i < parts.length; i++) {
    var part = parts[i].trim()
    if (part !== "") result.push(part.toUpperCase())
  }
  return result.join(" + ")
}

// Hyprland's modifier bitmask, as reported by `hyprctl binds`. Only the
// modifiers a person would actually put in a shortcut are listed.
var MODMASK = { SHIFT: 1, CAPS: 2, CTRL: 4, CONTROL: 4, ALT: 8, SUPER: 64, MOD5: 128 }

// Split a shortcut into the (modmask, key) pair `hyprctl binds` reports, so a
// registered binding can be found again and a collision can be spotted.
function shortcutChord(value) {
  var parts = normalizeShortcut(value).split(" + ")
  var modmask = 0
  var key = ""
  for (var i = 0; i < parts.length; i++) {
    var part = parts[i]
    if (part === "") continue
    if (MODMASK[part] !== undefined) modmask |= MODMASK[part]
    else key = part
  }
  return { modmask: modmask, key: key }
}

// This plugin's inline settings in shell.json, if the user has any. Absent is
// normal: an entry is only written once a setting is changed.
//
// A bar widget's settings live on its `bar.layout` entry, which is where the
// settings UI writes them and where the bar hands them to the panel. The
// `plugins[]` array is the other place a plugin's settings can live. The
// service reads both, layout first, so a user who puts `shortcut` next to
// their other Seven settings gets what they expect rather than silence.
function findSettingsEntry(config, pluginId) {
  var id = String(pluginId)
  var layout = config && config.bar && config.bar.layout
  if (layout) {
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var items = layout[sections[s]]
      if (!items || !items.length) continue
      for (var i = 0; i < items.length; i++) {
        if (items[i] && String(items[i].id) === id) return items[i]
      }
    }
  }
  var plugins = config && config.plugins
  if (plugins && plugins.length) {
    for (var j = 0; j < plugins.length; j++) {
      if (plugins[j] && String(plugins[j].id) === id) return plugins[j]
    }
  }
  return null
}

// Does `bindings` (from `hyprctl binds -j`) contain our described bind, and is
// anything else sitting on the same chord?
function shortcutState(bindings, shortcut, description) {
  var chord = shortcutChord(shortcut)
  var list = Array.isArray(bindings) ? bindings : []
  var found = false
  var collision = false
  for (var i = 0; i < list.length; i++) {
    var bind = list[i] || {}
    if (Number(bind.modmask || 0) !== chord.modmask) continue
    if (String(bind.key || "").toUpperCase() !== chord.key) continue
    if (String(bind.submap || "") !== "") continue
    if (String(bind.description || "") === description) found = true
    else collision = true
  }
  return { found: found, collision: collision }
}

// Build the inline shell.json entry for this widget with one setting changed.
// Only keys the user already has are carried over, so toggling one thing does
// not freeze every other default into their config file.
function withSetting(settings, moduleName, key, value) {
  var entry = { id: String(moduleName) }
  var source = settings && typeof settings === "object" ? settings : {}
  for (var name in source) {
    if (name !== "id") entry[name] = source[name]
  }
  entry[String(key)] = value
  return entry
}

function settingsFromEntry(entry) {
  var source = entry && typeof entry === "object" ? entry : {}
  // An absent shortcut means "use the default"; an explicit empty string means
  // "I do not want a global binding", so those two cannot collapse together.
  var shortcut = source.shortcut === undefined || source.shortcut === null
    ? DEFAULT_SHORTCUT
    : normalizeShortcut(source.shortcut)
  return {
    monospace: bool(source.monospace, true),
    showCounts: bool(source.showCounts, true),
    // true  -> the bar dot takes the active note's colour, hollow when empty.
    // false -> a solid dot in the bar's own foreground, like every other item.
    colorfulDot: bool(source.colorfulDot, true),
    shortcut: shortcut
  }
}

// The step a left/right move or a next/prev IPC call makes. Wraps, because
// seven dots in a row have no natural end to stop at.
function stepIndex(activeIndex, delta) {
  var index = clampIndex(activeIndex)
  var step = Math.floor(Number(delta) || 0)
  var next = (index + step) % DOT_COUNT
  if (next < 0) next += DOT_COUNT
  return next
}

// ---------------------------------------------------------------- markdown
//
// Small editing affordances for the editor. Every one of these returns an
// "edit plan" -- replace [start, end) with `text`, then put the selection at
// [cursorStart, cursorEnd) -- rather than a whole new document, so the editor
// can apply it through TextArea.remove/insert and keep its undo history.

function clampPos(pos, length) {
  var value = Math.floor(Number(pos))
  if (isNaN(value) || value < 0) return 0
  return value > length ? length : value
}

function lineStartOf(text, pos) {
  var index = text.lastIndexOf("\n", pos - 1)
  return index < 0 ? 0 : index + 1
}

function lineEndOf(text, pos) {
  var index = text.indexOf("\n", pos)
  return index < 0 ? text.length : index
}

function edit(start, end, text, cursorStart, cursorEnd) {
  return {
    start: start,
    end: end,
    text: text,
    cursorStart: cursorStart,
    cursorEnd: cursorEnd === undefined ? cursorStart : cursorEnd
  }
}

// Indent, then either a bullet or a number, then whitespace, then an optional
// task box. Kept as one expression so the pieces stay aligned with the group
// numbers used below.
var LIST_MARKER = /^([ \t]*)(?:([-*+])|(\d+)([.)]))([ \t]+)(\[[ xX]\][ \t]+)?/

// What Enter should do. Inside a list it writes the next marker; on an empty
// list item it takes the marker away instead of making another one; anywhere
// else it carries the current indentation down, which is the whole reason
// nested lists survive being typed.
function newlineEdit(text, cursor) {
  var value = string(text)
  var pos = clampPos(cursor, value.length)
  var lineStart = lineStartOf(value, pos)
  var line = value.slice(lineStart, lineEndOf(value, pos))
  var match = LIST_MARKER.exec(line)

  // Only continue the list when the caret is past the marker. With the caret
  // sitting before or inside "- ", Enter means "push this item down and open a
  // line above it", not "start another bullet".
  if (match && pos >= lineStart + match[0].length) {
    var prefixLength = match[0].length
    if (line.slice(prefixLength).trim() === "") {
      // "- " with nothing after it means the list is finished. Clearing the
      // marker is what every editor does here, and it leaves Enter free to
      // make a blank line on the next press.
      return edit(lineStart, lineStart + prefixLength, "", lineStart)
    }
    var indent = match[1]
    var marker = match[2]
      ? match[2] + match[5]
      : String(Number(match[3]) + 1) + match[4] + match[5]
    // A continued task item starts unchecked; carrying [x] down would tick a
    // box nobody has done yet.
    var box = match[6] ? "[ ] " : ""
    var inserted = "\n" + indent + marker + box
    return edit(pos, pos, inserted, pos + inserted.length)
  }

  // Same reasoning for plain lines: indentation the caret has not reached yet
  // is still ahead of it and stays with the text being pushed down.
  var indentOnly = /^[ \t]*/.exec(line)
  var indent = indentOnly ? indentOnly[0] : ""
  var carried = pos >= lineStart + indent.length ? "\n" + indent : "\n"
  return edit(pos, pos, carried, pos + carried.length)
}

// Wrap the selection in `marker`, or unwrap it if it is already wrapped --
// whether the markers sit just outside the selection or inside it. With no
// selection it drops in an empty pair and puts the caret between the halves.
function toggleWrap(text, selectionStart, selectionEnd, marker) {
  var value = string(text)
  var mark = string(marker)
  var width = mark.length
  if (width === 0) return null

  var from = clampPos(selectionStart, value.length)
  var to = clampPos(selectionEnd, value.length)
  if (to < from) {
    var swap = from
    from = to
    to = swap
  }

  // "*" must not treat the inner half of a "**" pair as its own marker, or
  // asking for italics inside bold text would quietly demote it to italics.
  var boldGuard = mark === "*" && (value.slice(from - 2, from) === "**" || value.slice(to, to + 2) === "**")

  if (!boldGuard && from >= width && value.slice(from - width, from) === mark
      && value.slice(to, to + width) === mark) {
    var inner = value.slice(from, to)
    return edit(from - width, to + width, inner, from - width, from - width + inner.length)
  }

  var selected = value.slice(from, to)
  if (!boldGuard && selected.length >= width * 2
      && selected.slice(0, width) === mark && selected.slice(-width) === mark) {
    var stripped = selected.slice(width, selected.length - width)
    return edit(from, to, stripped, from, from + stripped.length)
  }

  if (from === to) {
    return edit(from, from, mark + mark, from + width)
  }

  var wrapped = mark + selected + mark
  return edit(from, to, wrapped, from + width, from + width + selected.length)
}

var HEADING = /^([ \t]*)(#{1,6})([ \t]+)/

// Set the current line's heading level. Asking for the level it already has
// removes it, so the same key toggles both ways; level 0 always clears.
function toggleHeading(text, cursor, level) {
  var value = string(text)
  var pos = clampPos(cursor, value.length)
  var lineStart = lineStartOf(value, pos)
  var line = value.slice(lineStart, lineEndOf(value, pos))
  var match = HEADING.exec(line)

  var indent = match ? match[1] : /^[ \t]*/.exec(line)[0]
  var current = match ? match[2].length : 0
  var oldPrefix = match ? match[0].length : indent.length

  var wanted = Math.floor(Number(level))
  if (isNaN(wanted) || wanted < 0) wanted = 0
  if (wanted > 6) wanted = 6

  var newPrefix = indent
  if (wanted !== 0 && wanted !== current) {
    for (var i = 0; i < wanted; i++) newPrefix += "#"
    newPrefix += " "
  }

  // Keep the caret where it was relative to the words, not to the hashes.
  var shifted = pos + (newPrefix.length - oldPrefix)
  var floor = lineStart + newPrefix.length
  return edit(lineStart, lineStart + oldPrefix, newPrefix, shifted < floor ? floor : shifted)
}

// Where the caret belongs after a dot is refilled from outside.
//
// If everything before the caret survived the change -- someone appended to the
// file, or an IPC append added a line -- staying put is what the writer expects.
// If the text before it changed, the old offset is meaningless and would drop
// the caret into the middle of a word nobody typed, so it goes to the end.
function caretAfterReload(oldText, newText, caret) {
  var previous = string(oldText)
  var next = string(newText)
  var pos = clampPos(caret, previous.length)
  var prefix = previous.slice(0, pos)
  if (next.slice(0, prefix.length) === prefix) return Math.min(pos, next.length)
  return next.length
}

// A tab is four spaces. Markdown nesting is defined in spaces, and a literal
// tab renders at whatever width the next program feels like.
var TAB_WIDTH = 4

function tabEdit(text, selectionStart, selectionEnd) {
  var value = string(text)
  var from = clampPos(selectionStart, value.length)
  var to = clampPos(selectionEnd, value.length)
  if (to < from) {
    var swap = from
    from = to
    to = swap
  }
  var spaces = ""
  for (var i = 0; i < TAB_WIDTH; i++) spaces += " "
  return edit(from, to, spaces, from + TAB_WIDTH)
}

// "SUPER + CTRL + J" is how Hyprland wants it written; this is how a person
// wants to read it.
function prettyShortcut(value) {
  var parts = normalizeShortcut(value).split(" + ")
  var result = []
  for (var i = 0; i < parts.length; i++) {
    var part = parts[i]
    if (part === "") continue
    result.push(part.charAt(0) + part.slice(1).toLowerCase())
  }
  return result.join(" + ")
}

// Every binding the plugin has, in the two columns the cheat sheet draws. This
// is the single place they are written down; the tests check it against what
// the QML actually binds, so the sheet cannot quietly go stale.
function shortcutSheet(shortcut) {
  var global = string(shortcut) === ""
    ? "not set"
    : prettyShortcut(shortcut)

  return {
    left: [
      {
        title: "Anywhere",
        items: [
          { keys: global, label: "Open or close Seven" }
        ]
      },
      {
        title: "Notes",
        items: [
          { keys: "Alt + 1…7", label: "Jump to that note" },
          { keys: "Alt + ← →", label: "Previous, next" },
          { keys: "Alt + P", label: "Source or preview" },
          { keys: "Esc", label: "Close" }
        ]
      },
      {
        title: "The bar dot",
        items: [
          { keys: "Click", label: "Open or close" },
          { keys: "Right click", label: "Dot colour on or off" },
          { keys: "Middle click", label: "Next note" },
          { keys: "Wheel", label: "Walk the notes" }
        ]
      }
    ],
    right: [
      {
        title: "Writing",
        items: [
          { keys: "Enter", label: "Continue the list" },
          { keys: "Enter on empty", label: "End the list" },
          { keys: "Shift + Enter", label: "Plain newline" },
          { keys: "Tab", label: "Four spaces" },
          { keys: "Ctrl + B", label: "Bold" },
          { keys: "Ctrl + I", label: "Italic" },
          { keys: "Ctrl + Shift + X", label: "Strikethrough" },
          { keys: "Ctrl + 1…6", label: "Heading level" },
          { keys: "Ctrl + 0", label: "Clear heading" }
        ]
      },
      {
        title: "This sheet",
        items: [
          { keys: "F1", label: "Show or hide" },
          { keys: "Esc", label: "Hide" }
        ]
      }
    ]
  }
}

// Node's test runner imports this file; Quickshell just evaluates it.
if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    PLUGIN_ID: PLUGIN_ID,
    DOT_COUNT: DOT_COUNT,
    DOT_COLORS: DOT_COLORS,
    clampIndex: clampIndex,
    indexFromNumber: indexFromNumber,
    colorFor: colorFor,
    fileNameFor: fileNameFor,
    dotsDir: dotsDir,
    pathFor: pathFor,
    isBlank: isBlank,
    filledFlags: filledFlags,
    filledCount: filledCount,
    firstBlankIndex: firstBlankIndex,
    countWords: countWords,
    countChars: countChars,
    countsLabel: countsLabel,
    titleFor: titleFor,
    elide: elide,
    tooltipFor: tooltipFor,
    appendText: appendText,
    normalize: normalize,
    settingsFromEntry: settingsFromEntry,
    withSetting: withSetting,
    newlineEdit: newlineEdit,
    tabEdit: tabEdit,
    caretAfterReload: caretAfterReload,
    TAB_WIDTH: TAB_WIDTH,
    prettyShortcut: prettyShortcut,
    shortcutSheet: shortcutSheet,
    toggleWrap: toggleWrap,
    toggleHeading: toggleHeading,
    lineStartOf: lineStartOf,
    lineEndOf: lineEndOf,
    normalizeShortcut: normalizeShortcut,
    shortcutChord: shortcutChord,
    findSettingsEntry: findSettingsEntry,
    shortcutState: shortcutState,
    DEFAULT_SHORTCUT: DEFAULT_SHORTCUT,
    stepIndex: stepIndex
  }
}
