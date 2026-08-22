# Dots

> Seven notes. No titles, no files, no fuss.

Dots is a scratchpad that lives in your Omarchy bar. There are exactly seven
notes, each one a coloured dot. You do not name them, file them, or decide
where they go. You click a dot and write.

Inspired by [Tot](https://tot.rocks) by The Iconfactory, which had the good
idea first. This is an independent implementation for Omarchy and is not
affiliated with or endorsed by The Iconfactory.

![Dots](preview.png)

## What it does

- **Seven dots, always the same seven.** A dot is solid when it holds
  something and hollow when it doesn't, so the row is the only index you get.
  You stop filing and start writing.
- **Opens where you are.** Click the bar icon or bind a key. The editor takes
  focus immediately, with the caret at the end of what you last wrote.
- **Markdown when you want it.** Tab flips the current dot between its plain
  source and a rendered preview. Rendering is Qt's own Markdown support, so
  headings, lists, task lists, and links all work and there is no parser here
  to disagree with CommonMark.
- **Plain files, plainly named.** Each dot is a `.md` file in one directory.
  `grep` them, open them in `nvim`, sync them with Syncthing, put them in git.
  Edits made outside the panel show up in it live.
- **Saves itself.** Text is written a moment after you stop typing, and again
  when the panel closes. There is no save key because there is nothing to save.
- **Scriptable.** Append to a dot, read one back, or capture a line into the
  first empty dot from any shell.

## Install

```bash
omarchy plugin add https://github.com/melonamin/omarchy-dots.git --enable
```

Runtime requirements are Omarchy's `omarchy-shell` and nothing else. Node is
required only for the tests.

Remove it with:

```bash
omarchy plugin remove melonamin.dots
```

Removing the plugin leaves your notes on disk. Delete
`~/.local/share/omarchy-dots` yourself if you want them gone.

## Use

Click the dot in the bar to open the panel. It opens on the dot you were last
using, ready to type.

| Key | Does |
| --- | --- |
| `Alt` + `1`…`7` | Jump to that dot |
| `Alt` + `←` / `→` | Previous / next dot, wrapping |
| `Tab` | Flip between the editor and the rendered preview |
| `Esc` | Close the panel |

In the preview, `1`…`7` and the bare arrow keys move between dots. Letters do
nothing there — a key press while you are reading should never move you to a
different note.

On the bar icon itself: left click opens, right click steps to the next dot,
middle click steps back, and the scroll wheel walks the row.

### A global shortcut

Dots does not claim a chord of its own. Bind one in `~/.config/hypr/hyprland.conf`
(or your `bindings.conf`) to whatever is free on your keyboard:

```conf
bindd = SUPER CTRL, N, Dots, exec, omarchy-shell -q dots toggle
```

## Where the notes live

```text
~/.local/share/omarchy-dots/dots/1.md … 7.md
```

`$XDG_DATA_HOME` is honoured if you set it. Files are written atomically, so a
crash mid-save cannot leave you with half a note. The panel watches the
directory, so this works and shows up immediately:

```bash
nvim ~/.local/share/omarchy-dots/dots/3.md
```

If you are typing into a dot at the moment its file changes underneath you,
your text wins and gets written back — the point is never to lose a sentence.

There is no sync built in, on purpose. The files are ordinary enough that
Syncthing, `git`, or `rclone` will do a better job than this plugin could.

## Settings

Settings live inline on this plugin's entry in `~/.config/omarchy/shell.json`,
and in the bar's widget settings UI:

```json
{
  "plugins": [
    {
      "id": "melonamin.dots",
      "monospace": true,
      "showCounts": true
    }
  ]
}
```

- `monospace` — draw the editor in your configured monospace font. Off uses the
  bar's font.
- `showCounts` — show the word and character count under the editor. The count
  ignores tokens that are only markdown punctuation, so `# Groceries` reads as
  one word rather than two.

## Scripting

```bash
omarchy-shell dots open              # open the panel
omarchy-shell dots close
omarchy-shell dots toggle
omarchy-shell dots show 4            # open on a specific dot

omarchy-shell dots read 3            # print dot 3
omarchy-shell dots append 3 "milk"   # add a line to dot 3
omarchy-shell dots capture "idea"    # add to the first empty dot, print which
omarchy-shell dots clear 3           # empty dot 3

omarchy-shell dots status            # JSON: ready, dir, active dot, lengths
```

`status` reports shape, not content: which dot is active, how many are filled,
and how long each one is. It never prints what you wrote, so it is safe to
paste into a bug report.

## Tests

Static checks and unit tests need no running shell:

```bash
tests/static.sh
node --test tests/model.test.js
```

The rest need Dots installed and enabled in a live Omarchy session. Both
snapshot all seven notes and restore them byte-for-byte on exit:

```bash
tests/integration.sh   # IPC round trips, writes to disk, external edits
tests/e2e.sh           # drives the real panel with wtype
```

`tests/e2e.sh` takes over the keyboard for a few seconds. Run it when you are
not mid-sentence somewhere else.

## License

MIT
