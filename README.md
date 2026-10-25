# BeeNote

A notepad for Wayland, written entirely in x86-64 assembly (GNU as, Intel
syntax). It uses no libc, no libwayland and no toolkit. It talks to the kernel
through syscalls and to the compositor through the Wayland wire protocol. The
result is a ~56 KB static binary.

It is built to fit into [Omarchy](https://omarchy.org): it takes its colours from the current Omarchy
theme and its font from `omarchy font`, and both update live when they change.
It installs a launcher entry and a bar button, like BeeModel. The Wayland,
keyboard, TrueType and clipboard code comes from BeeModel.

```
scripts/build.sh            # assemble + link -> build/beenote, build/beenote.exe
scripts/build-all.sh        # build both, test both, pack dist/ (--deploy: install too)
scripts/release.sh          # tag v<VERSION> and push it: CI publishes the release
scripts/run.sh [file]       # rebuild if the sources changed, then start it
scripts/deploy-omarchy.sh   # install into Omarchy (see below)
tools/fakewl.py             # the tests: a fake compositor, screenshots in build/shots
```

Requirements: `as` and `ld` (binutils), and a Wayland compositor.

CI (`.github/workflows/ci.yml`) builds and tests every push and pull
request: the Linux build and its tests on Arch Linux, and the packed
`beenote.exe` on Windows. A `v<VERSION>` tag (`scripts/release.sh`) also
publishes a GitHub release with the Linux, Windows and source packages.

## On Windows 11

`scripts/build.sh` also writes **`build/beenote.exe`**, a native Windows
program (x86-64, no runtime, ~57 KB), when `ld` has the PE emulation
(`ld -V` lists `i386pep`, as Arch's binutils does; no mingw needed). It is
the same objects as the Linux build with `src/plat_win.s` in place of the
Wayland, keyboard and clipboard code: a Win32 window, the clipboard, dropped
files and per-monitor DPI, and the file calls answered by Windows.

- Paths: `C:\Users\you\notes.txt` is shown as `/C:/Users/you/notes.txt`; the
  Open dialog's top folder lists the drives. Typed paths may use either form.
- `~` is `%USERPROFILE%`, so the settings are in
  `%USERPROFILE%\.config\beenote\beenote.conf` and the recent files in
  `%USERPROFILE%\.local\state\beenote\recent`.
- The font: `font =` in that file, `BEENOTE_FONT`, else Consolas.

`tools/winvm-run.sh` runs a command in the Omarchy Windows VM
(`omarchy-windows-vm`) through its shared folder, e.g.
`tools/winvm-run.sh beenote.exe --version`. BeeNote has its own runner
there (`~/Windows/beenote-run`, from `tools/winvm/runner/`); set it up
once in an administrator PowerShell in the VM:
`powershell -ExecutionPolicy Bypass -File \\host.lan\Data\beenote-run\setup.ps1`.

## In Omarchy

`scripts/deploy-omarchy.sh` installs:

- `~/.local/bin/beenote`
- a **launcher entry** (Super + Space) and icon, which also lets text files open in BeeNote
- **`~/.config/beenote/beenote.conf`** with the Omarchy font, plus an Omarchy
  `font-set` hook that keeps it current after `omarchy font set`
- the **bar plugin** `bart.beenote`: a click focuses BeeNote, or starts it
  (`omarchy-shell bart.beenote app` does the same, for a key binding)

The colours need no setup. BeeNote reads
`~/.local/state/omarchy/current/theme/colors.toml` and checks it once a second,
so a theme switch shows straight away. `--no-plugin` skips the bar button, and
`--uninstall` removes everything the script installed.

## Using it

| | |
|---|---|
| Menus | **File, Edit, Search, View, Help**: click them, or press F10 / Alt+letter. Right-click opens the Edit menu |
| Files | Ctrl+N new, Ctrl+O the **Open dialog** (folders first, file sizes; type to filter or type a path, Backspace goes up, Ctrl+H shows hidden files, double-click opens), Ctrl+S save, Ctrl+Shift+S save as (Tab completes a path, `~` works). You can drop a file on the window. The File menu lists the **10 recent files** (Alt+F, then 1–9 or 0), kept in `~/.local/state/beenote/recent` and shared by every BeeNote window |
| Editing | Ctrl+Z / Ctrl+Shift+Z undo / redo, Ctrl+X / C / V cut / copy / paste through the system clipboard (with no selection, the whole line), Ctrl+A select all |
| Search | Ctrl+F finds as you type (Enter: next match, Shift+Enter: previous), F3 / Shift+F3, Ctrl+G go to line |
| Selecting | Shift with any movement key; mouse drag; double-click selects a word, triple-click a line |
| View | Ctrl++ / Ctrl+- / Ctrl+0 or Ctrl+wheel to zoom; line numbers can be turned off |
| Other | F1 lists every shortcut. Quitting, New and Open ask before discarding changes |

It handles UTF-8 text, dead keys and any keyboard layout (shortcuts follow the
letter printed on the key), CRLF files (saved back as CRLF), fractional scaling
and documents up to 16 MB.

## Source

| File | |
|---|---|
| `src/main.s` | start-up, the event loop |
| `src/input.s` | keyboard, mouse, menus, commands, the prompt bar, dialogs |
| `src/filedlg.s` | the Open dialog |
| `src/recent.s` | the recent files in the File menu |
| `src/view.s` | layout and drawing |
| `src/buffer.s` | the document: editing, undo, search, files |
| `src/omarchy.s` | the Omarchy theme and BeeNote's configuration |
| `src/plat_linux.s`, `src/plat_win.s` | the platform: system calls on Linux; on Windows also the window, input and clipboard |
| `src/gfx.s` | fonts and text drawing |
| `src/wayland.s`, `keyboard.s`, `ttf.s`, `clipboard.s`, `draw.s` | adapted from BeeModel |

`tui/beenote.s` is the first version: a terminal notepad in a single file.
Build it with `as tui/beenote.s -o tui/beenote.o && ld tui/beenote.o -o tui/beenote`.
