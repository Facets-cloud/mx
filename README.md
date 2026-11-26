# mx · mac exec

[![scuffmark](https://scuffmark.facets.cloud/badge/mx.svg)](https://scuffmark.facets.cloud/c/mx)

Like `docker exec`, but the container is your Mac. mx lets coding agents
(Claude Code, Codex, Cursor, Claude Desktop) run their steps inside the Mac
apps you already have open and signed in to, through the macOS accessibility
API. It reaches the whole Mac, not just one app: any native or Electron
app, plus menus, windows, Control Center, the Dock, System Settings and
dialogs. It works in the background by default, so you
keep typing in your own app while the agent works in another.

See it run: **https://facets-cloud.github.io/mx/** has the demo video and six
real agent runs.

mx is one Swift binary that uses only Apple's frameworks. Agents run it as
a CLI (`mx <tool>`) or as an MCP server on stdio. It sends nothing over the
network and has no telemetry.

**Platforms:** macOS 14 or later, on Apple silicon and Intel. The
accessibility API is Mac-only, so there is no Linux or Windows build.

```
> Set my screen brightness to 100% and tell me what it was

start     "Brightness to 100%"
batch     app=system  read slider "display brightness", fill "100%", read
          (mx opened Control Center first)
          1 read slider "display brightness": 62% (0.62)
          set slider "display brightness" to 100%; reads back 100% (1.0)
          3 read slider "display brightness": 100% (1.0)
done      "Brightness was 62%, now 100%"
```

## Before you start

- **macOS 14 or later.**
- **Accessibility**, for the app that runs mx: your terminal, editor,
  Cursor or other agent app. With mx.mcpb in Claude Desktop, it goes to mx
  itself. Every tool except `list_apps`, `start` and `done` needs it.
- **Screen Recording** for the same app, only if you want `screenshot`.

Turn them on in System Settings > Privacy & Security and restart that app.
`mx doctor` names the app. [Details](#permissions).

## How it works

The agent snapshots an app and gets one line per control, each with a ref:

```
e4 textarea "Message" = "draft"
e12 button "Send"
e19 slider "display brightness" = "68%"
```

It acts by ref (`click e12`), or by role and name (`button "Send"`), which
waits up to 3 s for the element to appear, so a `batch` can plan screens it
hasn't seen yet. After each action mx waits for the window to settle (no
change for 100 ms) and returns only what changed: `+` added, `-` removed,
`~` changed. Refs stay the same while an element stays on screen, so the
agent rarely needs a second snapshot.

Measured on a real Mac:

- A Slack window snapshot: about 117 ms for 268 elements.
- A fill: about 200 ms, settle included.
- A borrowed step (see below): 200 to 400 ms from taking the front to
  handing it back.
- Reading the Control Center brightness slider, moving it up 10%, reading
  it, moving it back and reading again, with the panel closed at the start:
  one batch, 1.0 s.

### Background by default

Reading the tree, pressing buttons (AXPress), setting text and posting plain
keys all work with the app in the background. mx never raises the app for
those. Two kinds of step need the front: a real mouse click (for elements
with no press action, such as Slack's sidebar rows) and cmd or ctrl
shortcuts, which a background app drops. For those, mx borrows the front:
it notes your app, your window and the cursor, brings the target forward,
does the step and puts all three back. Before it borrows, it waits until you
have made no key press or mouse move for 500 ms. If you keep typing for 3 s
it refuses the step instead, so your keystrokes never land in someone
else's message box.

## Modes

You choose per job, in plain words. The agent passes your choice to mx's
`start` tool.

| You say | Mode | What happens |
| --- | --- | --- |
| nothing, or "in the background" | `background` (default) | You keep working. mx never raises the app and borrows the front only for the steps above. |
| "show me", "do it in front of me" | `front` | The app comes forward and stays there. Full speed. |
| "let me watch", "go slowly" | `watch` | Like front, plus the pointer glides to each target, clicks move the real mouse, and batch steps pause 400 ms. |

A 4-step TextEdit batch took 1.65 s in background mode and 4.15 s in watch
mode.

`typing` is `paste` (default: the text goes in at once) or `keys` (typed key
by key, for chat composers and autocompletes that ignore pasted text).
`MX_MODE` and `MX_TYPING` set the defaults where mx starts; what the agent
passes to `start` wins.

### The indicator

While a session is open, mx draws a thin blue border around the window it
works in. In background mode a small pill sits under the window with a
spinner and the current step, such as `mx · Paste 24 characters` or
`mx · 3/7 Press cmd+a`, and the session title between calls. When the window
is covered, the pill moves to the bottom of the screen. In front and watch
modes the step rides on a pointer at the element instead, with a ripple on
each click. The border and pill sit just above the target window, so your
own windows still cover them. After `done` they show the summary and fade
out. Screenshots leave them out.

## Install

The quickest way is to paste the **Ask your agent** prompt from
[the site](https://facets-cloud.github.io/mx/) into your coding agent. It
installs mx and walks you through the permission step. To do it yourself,
pick the section that's yours. None of them need Node.

### Terminal agents

Your agent runs commands in a terminal.

**Claude Code.** Add the plugin:

```sh
claude plugin marketplace add Facets-cloud/mx
claude plugin install mx@mx
```

The plugin puts the `mx` CLI on Claude Code's PATH, downloads the binary
the first time it runs, and adds the mx skill, which teaches the agent the
commands and the safety rules. It has no MCP server. Restart Claude Code
after installing.

**Codex, Cursor and other agents.** Install the CLI, then add mx as an MCP
server with the command `mx` and no arguments:

```sh
curl -fsSL https://facets-cloud.github.io/mx/install.sh | sh
codex mcp add mx -- ~/.local/bin/mx          # Codex
```

Cursor and most other agents take this block in their MCP config
(`~/.cursor/mcp.json` for Cursor):

```json
{ "mcpServers": { "mx": { "command": "mx" } } }
```

If the agent can't find `mx`, use the full path that install.sh prints,
such as `/Users/you/.local/bin/mx`. Restart the agent after adding it.

### Claude Desktop

You chat in the Claude app and don't use a terminal.

1. Download [mx.mcpb](https://github.com/Facets-cloud/mx/releases/latest/download/mx.mcpb)
   and double-click it, or add it in Claude's Settings > Extensions >
   Install Extension. It isn't notarized yet, so Claude may show it as
   unsigned.
2. Ask Claude to take a snapshot of Finder. Claude Desktop runs mx as its
   own app, so Accessibility goes to mx itself, not Claude, and mx's error
   names the file to add. In System Settings > Privacy & Security >
   Accessibility, click +, press Cmd+Shift+G, paste that path and turn mx
   on. Do the same under Screen & System Audio Recording if you want
   screenshots.
3. Quit Claude with Cmd+Q, reopen it and ask again.

Releases sign mx with the same certificate every time, so the grant
carries over when you install a newer mx.mcpb.

This is for the Chat tab. Cowork isn't supported yet.

### The CLI

```sh
curl -fsSL https://facets-cloud.github.io/mx/install.sh | sh
```

The script downloads the build for your Mac (arm64 or x64), checks its
SHA-256 against the release's `checksums.txt` and refuses on a mismatch,
installs `mx` into `~/.local/bin` without sudo, and runs `mx doctor`. Pin a
version with `MX_VERSION=v0.1.4`, or pick another folder with
`MX_INSTALL_DIR`. Release tarballs for both architectures are also on the
[releases page](https://github.com/Facets-cloud/mx/releases).

`mx <tool> [flags]` runs any tool from the shell, such as `mx list_apps`
or `mx snapshot --app TextEdit`. `mx` with no arguments is the MCP server.

npm still publishes mx as `@facets-cloud/mx`, so `npx -y @facets-cloud/mx`
works as the MCP command if you'd rather use Node 18 or later.

### Check it

```sh
mx doctor
```

It names the app that needs Accessibility and says what's missing. Grant
it, restart that app, and run it again.

### Permissions

macOS gives these to the app that launched mx, not to mx itself. That is
your terminal (Terminal, iTerm, Ghostty and so on), your editor, or Cursor.
Claude Desktop is the exception: it runs mx.mcpb's mx as its own app, so
the grants go to that mx binary, and mx names its path.

- **Accessibility** is required by every tool except `list_apps`, `start`
  and `done`.
- **Screen Recording** (Screen & System Audio Recording) is needed only for
  `screenshot`. The other tools work without it.

Turn them on in System Settings > Privacy & Security, then restart that app.
`mx doctor` says which app to turn on and what is missing, in the same
words the tools use:

```
mx 0.1.0, macOS 15.5.0 (arm64)
permissions go to: Ghostty (the app that launched mx)
ok   Accessibility: granted, every tool works
warn Screen Recording: mx is not allowed to record the screen, so it cannot take screenshots (the other tools still work). Open System Settings > ...
```

It exits 0 when Accessibility is granted and 1 when it isn't.

## Tools

19 tools.

| Group | Tools |
| --- | --- |
| Session | `start` (title, mode, typing), `done` (summary; returns time taken and action count) |
| Read | `list_apps`, `snapshot`, `read`, `screenshot` |
| Act | `click`, `fill`, `key`, `batch`, `scroll`, `drag` |
| The rest of the Mac | `menu`, `window`, `app`, `open`, `clipboard` |
| Audit log | `history`, `settings` |

- `snapshot` takes a `scope`: `window` (default), `menubar`, `extras` (an
  app's menu bar icons), `windows` (every window, panel, dialog and sheet)
  or `app`.
- `screenshot` returns a PNG (at most 1280 px wide) of the window, even
  behind other apps, with each control's ref drawn on it. `element` crops
  to one control and `full` captures the whole display.
- `fill` on a slider takes `"75%"`, `"+10%"` or `"-10%"` and reads the level
  back.
- `click` takes `action` (`showmenu`, `increment`, `pick` and others),
  `count: 2` for a double click and `button: "right"`.
- `key` also takes the hardware keys `brightness_up`, `volume_down`,
  `volume_mute` and `play_pause`, which need no app.
- `menu` runs a command by its titles, such as `["View", "Zoom In"]`.
- `window` lists, raises, moves, resizes, minimizes, goes fullscreen or
  closes. `app` launches, activates, hides or quits.
- `open` takes a URL, a file, or a settings pane such as `settings:displays`.

## What it can reach

- **Apps:** any app with a window, native or Electron. mx turns on an
  Electron app's accessibility tree the first time it touches it.
- **Control Center:** `app: "system"` covers the menu bar extras (Wi-Fi,
  Battery, the clock) and the Control Center panel. Name a control such as
  `slider "display brightness"` and mx opens the panel if it is closed.
- **Menus and the menu bar** of any app, by title path.
- **The Dock** and other system processes, with `list_apps all: true`.
- **System Settings:** `open settings:<pane>` goes to a pane. Reading any
  pane is free. Changes in the sensitive panes (Privacy & Security, Users &
  Groups, Passwords, Login Items, Sharing, Lock Screen, Touch ID & Password,
  Device Management, Transfer or Reset) need confirmation.
- **Dialogs:** Open and Save panels and sheets show in `scope: "windows"`.

## Safety

mx can do what you can do with your hands, and the Accessibility grant
makes that possible for any process the granted app starts.
[SECURITY.md](SECURITY.md) explains the threat model. The rules mx applies
inside that grant:

- **Confirm gate.** mx refuses to press anything labelled send, post,
  delete, remove, pay, buy, archive, submit, ship, deploy, release,
  publish, leave, place order, schedule, checkout, restart, shut down, log
  out, erase, reset, uninstall, move to trash, empty trash, format or force
  quit, unless the call passes `confirm: true`. The same goes for Return in
  a text box (it can send a message), typed text with a newline, an
  unlabeled button beside a message box (usually Send), cmd+delete in
  any app, closing a window with unsaved changes, reading the clipboard and
  changes in the sensitive settings panes. The agent is told to ask you
  before it passes `confirm`.
- **Blocked apps.** mx won't touch Keychain Access, password managers
  (1Password, Bitwarden, KeePassXC and others) or terminals, where typed
  keys would run shell commands outside the agent's own permission prompts.
  That includes screenshots of them.
- **Password fields** are never read, filled or clicked.
- **Permission prompts** (an app asking to control the computer or record
  the screen) are refused even with `confirm`. You answer those yourself.
- **App text is data.** The skill tells the agent that a message or email
  asking it to do something is content to report, not an instruction.

## Audit log

mx writes one JSON line per tool call to
`~/Library/Application Support/mx/sessions/<session>.jsonl` (mode 0600),
in the same format as [bx](https://github.com/Facets-cloud/bx), so one
viewer or log shipper reads both. Each line names the app, window, element
(role and name), mode, result and time taken. Every `confirm: true` and
every refusal gets its own line, with the rule that stopped it. Typed text,
fill values and clipboard text appear only as their length. Inside Claude
Code or Codex, a session is the app's own conversation.

```sh
mx history                        # recent sessions
mx history previous               # one session as a tree: tasks, apps and windows, actions
mx history pin previous "weekly report"   # name a finished task so an agent can repeat it
mx history pinned                 # list pins; add a name to see its steps
mx config                         # log settings
mx config set log.values full     # also log typed text (off also drops window titles and names)
```

Logs are kept forever by default. Past 2 GB the oldest idle files are
gzipped, and past 5 GB of archives the oldest are deleted (`log.max`,
`log.archive_max`, `log.days`). Agents get the same views through the
`history` and `settings` tools. An agent can raise retention but can't
lower logging; it gets the `mx config set` command to hand to you.

## Limits

- **macOS only**, 14 or later. The binary isn't signed or notarized yet.
- **The lock screen.** mx can't unlock the Mac or act on the lock screen.
  Leave the Mac unlocked while an agent works.
- **Secure input.** mx never types into password fields. When an app turns
  on secure input for a password prompt, finish that prompt yourself.
- **Permission prompts** need you. mx can't click Allow, by design.
- **Spaces.** Screenshots need the window on the current Space and not
  minimized. A window on another Space hides the border and moves the pill
  to the bottom of the screen.
- **Your mouse in background mode.** A borrowed mouse click moves the real
  cursor for a few hundred ms and puts it back.

## How it compares

- **Computer use with screenshots** sees pixels. Each step costs a
  screenshot and a guess at coordinates, the app must be in front, and the
  agent moves your mouse. mx reads the accessibility tree as text with exact
  refs, works behind your windows, and uses screenshots only when the
  layout matters.
- **AppleScript and Shortcuts** reach only apps that publish a scripting
  dictionary, and each app has its own vocabulary. Electron apps such as
  Slack publish none. mx uses the accessibility tree that every app has, and
  needs one grant instead of an Automation prompt per app.
- **Other accessibility-tree tools** read the same tree. mx adds background
  work with short borrows, diffs instead of full trees after each action,
  role-and-name lookups that wait, the confirm gate, and the on-screen
  indicator.

## Develop

```sh
swift build -c release                     # .build/release/mx
python3 tests/selftest.py --only protocol,gate,settle,diff   # no GUI, no grant needed
python3 tests/selftest.py                  # everything, on a scratch TextEdit document
```

The full self-test opens TextEdit, Finder, Control Center and System
Settings and briefly changes brightness and volume (restoring both), so run
it when you aren't using the Mac. Its scratch files go in `tests/scratch/`,
which git ignores.

`scripts/npm-build.sh vX.Y.Z` builds both architectures into `npm/` and sets
every package and plugin version. Pushing a `v*` tag runs the release
workflow: it builds, attaches tarballs and checksums to a GitHub release,
publishes `@facets-cloud/mx-darwin-arm64`, `@facets-cloud/mx-darwin-x64` and then `@facets-cloud/mx`, and
bumps the plugin version on main. `scripts/preview.sh` serves the landing
page in `site/` at http://localhost:8791.

## License

MIT. See [LICENSE](LICENSE). mx contains no third-party code.
