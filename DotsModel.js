// Pure logic for Dots. No QML types are referenced here so the same source
// runs under Quickshell's JS engine and under node for the unit tests.

var PLUGIN_ID = "melonamin.dots"

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
  return base + "/omarchy-dots/dots"
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

function settingsFromEntry(entry) {
  var source = entry && typeof entry === "object" ? entry : {}
  return {
    monospace: bool(source.monospace, true),
    showCounts: bool(source.showCounts, true)
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
    stepIndex: stepIndex
  }
}
