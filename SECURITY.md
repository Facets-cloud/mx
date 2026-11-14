# Security

mx gives coding agents control of the apps on your Mac. Read this before you
install it.

## What mx can do

macOS has one switch for this: the Accessibility grant in System Settings >
Privacy & Security. mx needs it, and macOS gives it to the app that launched
mx (your terminal, editor, Claude Desktop or Cursor), not to mx. With it, a
process can read the text of any window and press, type and click in any
app, as you. Any program that app starts gets the same power. The grant is
broad, and mx can't narrow it.

With Screen Recording as well, mx can take screenshots of windows, including
ones behind other windows.

## What limits it

Everything below is a rule mx applies to itself, inside that grant. It stops
an agent that is following mx's tools. It does not stop another program that
holds the same grant.

- **The confirm gate.** mx refuses to press anything labelled send, post,
  delete, pay, submit, publish, place order and similar words, to press
  Return in a text box, to type text with a newline, to press an unlabeled
  button beside a message box, to read the clipboard, or to change a
  sensitive System Settings pane, unless the call passes `confirm: true`.
  The tool descriptions and the skill tell the agent to ask you first. That
  part is the agent's discipline. mx can't tell whether it did ask.
- **Blocked apps.** mx refuses Keychain Access, password managers and
  terminals for every tool, screenshots included, and refuses to `open` a
  file or URL whose handler is one of them. Keys typed into a terminal would
  run shell commands outside the agent's own permission prompts.
- **Password fields.** mx never reads, fills or clicks a secure text field.
- **Permission prompts.** Buttons in macOS permission prompts are refused
  even with `confirm`, so an agent can't grant itself more access.
- **Visible work.** While a session is open, a blue border marks the window
  mx works in, and a pill or pointer shows each step.
- **Local only.** mx talks MCP on stdio to the app that started it. It
  listens on no port and sends nothing over the network. There is no
  telemetry.

## What it doesn't protect against

- **Prompt injection.** App text is untrusted data. An email, a Slack
  message or a web page can contain text that tells the agent to do
  something. The skill tells the agent to report such text, not follow it,
  but mx can't tell your instructions from an app's. Give agents narrow
  tasks, and say no when an agent asks to confirm something you didn't ask
  for.
- **Your own agent's mistakes.** mx does what it's told within the rules
  above. Close apps and windows you don't want touched.
- **Other software with the same grant.** Anything else the granted app
  runs can use the Accessibility API directly, with none of mx's rules.

## Reporting a problem

Report security issues privately through GitHub: open the repo's
**Security** tab and choose **Report a vulnerability**. For anything that
isn't sensitive, open a normal
[issue](https://github.com/Facets-cloud/mx/issues/new).

Only the latest release gets fixes. mx follows SemVer (`0.x.y` for now).
