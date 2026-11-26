#!/usr/bin/env python3
"""mx self-test. Speaks JSON-RPC to the mx binary over stdio (stdlib only).

Protocol checks always run. AX checks open a scratch TextEdit document this
script creates under tests/scratch/, act only on that window, and close it.
If mx is not trusted for Accessibility, the AX checks are reported NOT RUN.

usage: python3 tests/selftest.py   (after swift build -c release)
       MX_BIN=npm/mx-darwin-arm64/bin/mx python3 tests/selftest.py   (another build)
"""
import base64
import json
import os
import queue
import re
import subprocess
import sys
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# MX_BIN tests another copy, such as an npm package's bin/mx.
BIN = os.environ.get("MX_BIN") or os.path.join(ROOT, ".build", "release", "mx")
TOOLS = {"doctor", "start", "done", "list_apps", "snapshot", "screenshot", "click", "fill", "key", "read", "batch",
         "menu", "window", "app", "open", "scroll", "drag", "clipboard", "history", "settings"}
results = []
borrow_ms = []  # measured borrow durations, for the report
extra_actions = [0]  # actions run again by retries, so the done count stays exact


class Client:
    """One mx process; request() sends a JSON-RPC message and waits for its reply."""

    def __init__(self, env=None):
        self.p = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, env={**os.environ, **(env or {})},
                                  text=True, bufsize=1)
        self.q = queue.Queue()
        self.stderr = []
        self.next_id = 0
        threading.Thread(target=self._read, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()

    def _read(self):
        for line in self.p.stdout:
            self.q.put(json.loads(line))

    def _read_stderr(self):
        for line in self.p.stderr:
            sys.stderr.write(line)
            self.stderr.append(line.rstrip("\n"))

    def last_settle(self):
        """(ms, title wait on?) from the latest `mx: ... settled N ms (title wait on|off)` line."""
        time.sleep(0.05)  # let the stderr reader catch up
        for line in reversed(self.stderr):
            m = re.search(r"settled (\d+) ms \(title wait (on|off)\)", line)
            if m:
                return int(m.group(1)), m.group(2) == "on"
        return None, None

    def notify(self, method, params=None):
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "method": method, "params": params or {}}) + "\n")

    def request(self, method, params=None, timeout=30):
        self.next_id += 1
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.next_id, "method": method,
                                       "params": params or {}}) + "\n")
        while True:
            msg = self.q.get(timeout=timeout)
            if msg.get("id") == self.next_id:
                return msg

    def call(self, tool, **args):
        """Returns (text, is_error) of a tools/call."""
        res = self.request("tools/call", {"name": tool, "arguments": args})["result"]
        return res["content"][0]["text"], bool(res.get("isError"))

    def call_content(self, tool, **args):
        """Returns (content list, is_error) of a tools/call."""
        res = self.request("tools/call", {"name": tool, "arguments": args})["result"]
        return res["content"], bool(res.get("isError"))

    def close(self):
        self.p.stdin.close()
        self.p.wait(timeout=10)


def check(name, ok, detail=""):
    results.append((name, "PASS" if ok else "FAIL"))
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"\n      {detail}" if detail and not ok else ""))
    return ok


def not_run(name, why):
    results.append((name, "NOT RUN"))
    print(f"NOT RUN  {name}\n      {why}")


def read_until(c, ref, w, expected, timeout=1.0):
    """Reads the element until it shows `expected` or `timeout` passes; returns the last value.
    Reading back beats assuming the app has handled a key within some fixed time."""
    deadline = time.time() + timeout
    while True:
        text, _ = c.call("read", ref=ref, **w)
        if text == expected or time.time() > deadline:
            return text
        time.sleep(0.05)


def with_retry(name, run, expected, actions):
    """run() does the steps and returns what the scratch text shows. If that isn't
    `expected` (say, someone typed on the Mac and stray characters reached the scratch
    document, or cmd+a hadn't taken before the next key), run it once more.
    Each run starts once the user has paused, as mx's borrow does."""
    wait_user_idle()
    got = run()
    if got != expected:
        print(f"      retrying {name}: scratch text is {got!r}, expected {expected!r} (stray input from someone using the Mac?)")
        extra_actions[0] += actions
        wait_user_idle()
        got = run()
    return got


def user_idle_seconds():
    """Seconds since the last key down or mouse move/down on this Mac (hidSystemState).
    mx's own HID-tap events count here too; that only makes this wait a little longer."""
    out = jxa("ObjC.import('CoreGraphics'); Math.min(...[10, 5, 1, 3].map(t => "
              "$.CGEventSourceSecondsSinceLastEventType(1, t)))")
    try:
        return float(out)
    except ValueError:
        return 99.0


def user_moved_cursor(p0, p1, since):
    """True when the cursor ended up more than 2 px away and someone used the mouse or keys
    since `since` (epoch s): the hand-back can't be judged, so the check runs again."""
    moved = abs(p1[0] - p0[0]) > 2 or abs(p1[1] - p0[1]) > 2
    return moved and user_idle_seconds() < time.time() - since


def wait_user_idle(need=0.5, cap=3.0):
    """Before a check that needs TextEdit in front: wait until the user has paused for
    `need` seconds (up to `cap`), so their typing doesn't land in the scratch document."""
    deadline = time.time() + cap
    while user_idle_seconds() < need and time.time() < deadline:
        time.sleep(0.1)


def jxa(expr):
    """Evaluates a JavaScript-for-Automation expression in a fresh osascript; returns its text."""
    r = subprocess.run(["osascript", "-l", "JavaScript", "-e", "ObjC.import('AppKit');" + expr],
                       capture_output=True, text=True)
    return r.stdout.strip()


def frontmost():
    """Bundle id of the frontmost app, read fresh (not through mx)."""
    return jxa("$.NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier.js")


def cursor():
    """The real cursor position (Cocoa coordinates), as (x, y)."""
    x, y = jxa("var p = $.NSEvent.mouseLocation; p.x + ',' + p.y").split(",")
    return float(x), float(y)


def finder_front():
    """Makes Finder frontmost with a window of its own, as a user working elsewhere would have it.
    Returns True if this opened the window (so cleanup closes only that one)."""
    r = subprocess.run(["osascript", "-e", 'tell application "Finder"\n'
                        'set made to false\n'
                        'if (count of Finder windows) = 0 then\nmake new Finder window\nset made to true\nend if\n'
                        'activate\nreturn made\nend tell'], capture_output=True, text=True)
    deadline = time.time() + 2
    while frontmost() != "com.apple.finder" and time.time() < deadline:
        time.sleep(0.1)
    time.sleep(0.2)
    return r.stdout.strip() == "true"


def protocol_checks():
    c = Client()
    init = c.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                    "clientInfo": {"name": "selftest", "version": "0"}})["result"]
    check("initialize returns serverInfo mx and echoes protocolVersion",
          init["serverInfo"]["name"] == "mx" and init["protocolVersion"] == "2025-06-18", init)
    c.notify("notifications/initialized")
    names = {t["name"] for t in c.request("tools/list")["result"]["tools"]}
    check("tools/list has the 20 tools", names == TOOLS, names)
    err = c.request("nope/nothing")
    check("unknown method -> -32601", err.get("error", {}).get("code") == -32601, err)
    err = c.request("tools/call", {"name": "teleport", "arguments": {}})
    check("unknown tool -> -32602", err.get("error", {}).get("code") == -32602, err)
    text, is_err = c.call("snapshot")
    check("snapshot without app is a tool error", is_err, text)

    diff_checks(c)
    mode_arg_checks(c)
    gate_word_checks(c)
    pill_place_checks(c)
    clipboard_checks(c)
    c.close()

    e = Client(env={"MX_MODE": "watch", "MX_TYPING": "keys"})
    e.request("initialize", {"protocolVersion": "2025-06-18"})
    text, is_err = e.call("start", title="env defaults")
    check("start: MX_MODE / MX_TYPING set the defaults", not is_err and "(mode watch, typing keys)" in text, text)
    text, is_err = e.call("start", title="env defaults", mode="fast")
    check("start: an argument wins over the env default (fast means background)",
          not is_err and "(mode background, typing keys)" in text, text)
    e.close()

    f = Client(env={"MX_MODE": "fast"})
    f.request("initialize", {"protocolVersion": "2025-06-18"})
    text, is_err = f.call("start", title="old env value")
    check("MX_MODE=fast is accepted as background", not is_err and "(mode background, typing paste)" in text, text)
    f.close()

    u = Client(env={"MX_FORCE_UNTRUSTED": "1"})
    u.request("initialize", {"protocolVersion": "2025-06-18"})
    text, is_err = u.call("snapshot", app="TextEdit")
    check("untrusted: clear error naming the app to grant",
          is_err and "Accessibility" in text and "turn on" in text, text)
    print(f"      untrusted message: {text}")
    text, is_err = u.call("list_apps")
    check("untrusted: list_apps still works", not is_err and "pid=" in text, text)
    u.close()

    # Inside mx.mcpb the grant goes to the mx binary itself, so the error names its path.
    b = Client(env={"MX_FORCE_UNTRUSTED": "1", "MX_MCPB": "1"})
    b.request("initialize", {"protocolVersion": "2025-06-18"})
    text, is_err = b.call("snapshot", app="TextEdit")
    check("untrusted in mx.mcpb: names mx's own path and the steps to add it",
          is_err and os.path.realpath(BIN) in text and "Cmd+Shift+G" in text
          and "Claude Desktop runs mx as its own app" in text, text)
    b.close()
    cli_checks()


def pbpaste():
    return subprocess.run(["pbpaste"], capture_output=True, text=True).stdout


def clipboard_checks(c):
    """clipboard set is for pasting: done puts the user's clipboard back, unless the user
    copied something since, or keep=true. Ends with the user's text back on the clipboard."""
    mine = pbpaste()
    c.call("start", title="clipboard")
    c.call("clipboard", op="set", text="mx selftest paste")
    text, _ = c.call("done", summary="clipboard")
    check("clipboard: done puts the user's clipboard back", pbpaste() == mine and "clipboard back" in text, text)
    c.call("start", title="clipboard")
    c.call("clipboard", op="set", text="mx selftest paste")
    subprocess.run(["pbcopy"], input="mx selftest user copy", text=True)
    text, _ = c.call("done", summary="clipboard")
    check("clipboard: a copy made after mx's write is left alone", pbpaste() == "mx selftest user copy", text)
    c.call("start", title="clipboard")
    c.call("clipboard", op="set", text="mx selftest keep", keep=True)
    c.call("done", summary="clipboard")
    check("clipboard: keep=true leaves the text after done", pbpaste() == "mx selftest keep", pbpaste())
    subprocess.run(["pbcopy"], input=mine, text=True)  # text only: the checks above never saved more than that


def cli_checks():
    """mx --version and mx doctor (the doctor check fakes a missing grant, so it runs anywhere)."""
    r = subprocess.run([BIN, "--version"], capture_output=True, text=True, timeout=10)
    check("mx --version prints the version", r.returncode == 0 and re.fullmatch(r"mx \S+\n", r.stdout), r.stdout)
    r = subprocess.run([BIN, "doctor"], capture_output=True, text=True, timeout=10,
                       env={**os.environ, "MX_FORCE_UNTRUSTED": "1", "MX_FORCE_NO_SCREEN": "1"})
    check("mx doctor without Accessibility exits 1 and names the app to turn on",
          r.returncode == 1 and "FAIL Accessibility" in r.stdout and "warn Screen Recording" in r.stdout
          and "turn on" in r.stdout, r.stdout)
    r = subprocess.run([BIN, "doctor"], capture_output=True, text=True, timeout=10,
                       env={**os.environ, "MX_FORCE_UNTRUSTED": "1", "MX_FORCE_NO_SCREEN": "1", "MX_MCPB": "1"})
    me = os.path.realpath(BIN)
    check("mx doctor in mx.mcpb sends both grants to mx itself, by path",
          r.returncode == 1 and f"permissions go to: mx itself, {me}" in r.stdout
          and r.stdout.count(f"paste {me} ") == 2 and "> Accessibility, click +" in r.stdout
          and "> Screen & System Audio Recording, click +" in r.stdout, r.stdout)
    r = subprocess.run([BIN, "nope"], capture_output=True, text=True, timeout=10)
    check("an unknown argument prints usage and exits 2", r.returncode == 2 and "usage" in r.stderr, r.stderr)


def mode_arg_checks(c):
    """start's mode and typing arguments; no app involved."""
    text, is_err = c.call("start", title="modes", mode="watch")
    check("start with mode=watch is reflected in the session",
          not is_err and text == 'started "modes" (mode watch, typing paste)', text)
    text, is_err = c.call("start", title="modes", typing="keys")
    check("start again mid-session changes typing and keeps mode", not is_err
          and text == 'updated "modes" (mode watch, typing keys)', text)
    text, is_err = c.call("start", title="modes", mode="slow")
    check("start with an unknown mode is an error", is_err and "background, front or watch" in text, text)
    text, is_err = c.call("start", title="modes", mode="front")
    check("start mid-session switches to mode=front", not is_err and "(mode front," in text, text)
    text, _ = c.call("done", summary="modes")
    text, _ = c.call("start", title="after done")
    check("done resets mode and typing to the defaults", text == 'started "after done" (mode background, typing paste)', text)
    c.call("done", summary="x")


def diff_checks(c):
    """Diff rules through the hidden _debug_diff tool; no app involved."""
    base = [f"e{i} row \"item {i}\"" for i in range(1, 21)]
    text, _ = c.call("_debug_diff", before=base, after=base[:19] + ['e20 row "item 20 (2 new)"'],
                     old_title="* general (Channel) - Slack", new_title="general (Channel) - Slack")
    check("title flip alone: diff plus title line, no full snapshot",
          text == '~ e20 row "item 20 (2 new)"\ntitle: general (Channel) - Slack', text)
    text, _ = c.call("_debug_diff", before=base, after=base, old_title="a", new_title="a")
    check("no change -> 'no visible change'", text == "no visible change", text)
    text, _ = c.call("_debug_diff", before=base, after=base, same_window=False)
    check("different window -> full snapshot", text == "full snapshot", text)
    text, _ = c.call("_debug_diff", before=base, after=base[:8])
    check("element count drops >50% on the same window -> diff", text != "full snapshot" and text.startswith("- e"), text)
    rows = [f"e{i} row \"channel {i}\"" for i in range(1, 101)]
    text, _ = c.call("_debug_diff", before=rows, after=rows[:6] + ['e200 textbox "filter" = "mx"'])
    check("sidebar filter (100 rows -> 6) on the same window -> collapsed diff",
          text != "full snapshot" and "- … and 89 more removed" in text and "+ e200" in text, text)
    text, _ = c.call("_debug_diff", before=base, after=base[:8], same_window=False)
    check("different window with a count drop -> full snapshot", text == "full snapshot", text)

    big = [f"e{i} row \"r{i}\"" for i in range(1, 51)]
    text, _ = c.call("_debug_diff", before=big, after=big[:30])
    lines = text.splitlines()
    check("20 removals collapse to 5 lines + summary",
          len(lines) == 6 and all(l.startswith("- e") for l in lines[:5]) and lines[5] == "- … and 15 more removed", text)
    text, _ = c.call("_debug_diff", before=big, after=big[:35])
    check("15 removals are all listed", len(text.splitlines()) == 15, text)
    hundred = [f"e{i} row \"r{i}\"" for i in range(1, 101)]
    many = hundred + [f"e{i} row \"n{i}\"" for i in range(101, 146)]
    text, _ = c.call("_debug_diff", before=hundred, after=many)
    lines = text.splitlines()
    check("45 additions collapse to 30 lines + summary",
          len(lines) == 31 and all(l.startswith("+ e") for l in lines[:30]) and lines[30] == "+ … and 15 more added", text)
    text, _ = c.call("_debug_diff", before=hundred, after=many[:140])
    check("40 additions are all listed", len(text.splitlines()) == 40, text)


def settle_checks():
    """settleLoop on a fake clock through the hidden _debug_settle tool. Events are
    [time, tree, title]; base is the state before the action."""
    c = Client()
    c.request("initialize", {"protocolVersion": "2025-06-18"})

    def settled(events, base=None):
        text, _ = c.call("_debug_settle", events=events, **({"base": base} if base else {}))
        return float(text.split()[-1])

    t = settled([[0, "a", "x"]], base=["a", "x"])
    check("settle: nothing changes -> done after 100 ms", 0.09 <= t < 0.15, t)
    t = settled([[0, "b", "x"], [0.5, "b", "y"]], base=["a", "x"])
    check("settle: tree changed, title lags 500 ms -> waits for the title, returns as it changes",
          0.49 <= t < 0.53, t)
    t = settled([[0, "a", "x"], [0.05, "b", "x"]], base=["a", "x"])
    check("settle: tree changed, title never does -> 100 ms + 700 ms more", 0.84 <= t < 0.9, t)
    t = settled([[0, "b", "y"]], base=["a", "x"])
    check("settle: tree and title both changed -> no title wait", 0.09 <= t < 0.15, t)
    t = settled([[i / 20, f"t{i}", "x"] for i in range(100)], base=["a", "x"])
    check("settle: tree never quiet -> 3 s cap", 2.99 <= t < 3.05, t)

    # Title wait opt-in (fix3): fills and keys skip it, clicks keep it.
    text, _ = c.call("_debug_settle", events=[[0, "a", "x"], [0.05, "b", "x"]], base=["a", "x"], title_wait=False)
    t = float(text.split()[-1])
    check("settle: tree changed, title wait off -> returns at ~100 ms after the change", 0.14 <= t < 0.2, t)
    text, _ = c.call("_debug_settle", events=[[0, "b", "x"]], base=["a", "x"], title_wait=False)
    t = float(text.split()[-1])
    check("settle: tree changed at once, title wait off -> ~0.1 s", 0.09 <= t < 0.15, t)
    text, _ = c.call("_debug_settle", events=[[0, "b", "x"], [0.5, "b", "y"]], base=["a", "x"], title_wait=True)
    t = float(text.split()[-1])
    check("settle: tree changed, title wait on, title lags 500 ms -> ~0.5 s", 0.49 <= t < 0.53, t)
    text, _ = c.call("_debug_settle", events=[[0, "b", "x"], [0.5, "b", "y"]], base=["a", "x"],
                     batch=["fill", "fill", "click"])
    print("      batch fill+fill+click:\n" + "\n".join("        " + l for l in text.splitlines()))
    rows = [re.match(r"(\w+): settled at ([\d.]+) \(title wait (on|off)\)", l) for l in text.splitlines()]
    ok = (len(rows) == 3 and all(rows)
          and [(m.group(1), m.group(3)) for m in rows] == [("fill", "off"), ("fill", "off"), ("click", "on")]
          and all(0.09 <= float(m.group(2)) < 0.15 for m in rows[:2]) and 0.49 <= float(rows[2].group(2)) < 0.53)
    check("settle: batch fill+fill+click -> title wait only on the final settle", ok, text)
    text, _ = c.call("_debug_settle", events=[[0, "b", "x"]], base=["a", "x"], batch=["fill", "key"])
    check("settle: batch with no click -> title wait off throughout", text.count("(title wait off)") == 2, text)
    c.close()


def press_checks():
    """A press-only control whose press changes nothing must not get a mouse click.
    Uses a scratch rich-text document: its format bar has an "align left" checkbox
    with AXPress; once left-aligned, pressing it again changes nothing."""
    path = os.path.join(ROOT, "tests", "scratch", f"mx-selftest-{os.getpid()}.rtf")
    with open(path, "w") as f:
        f.write("{\\rtf1\\ansi press test}")
    subprocess.run(["open", "-a", "TextEdit", path], check=True)
    c = Client()
    c.request("initialize", {"protocolVersion": "2025-06-18"})
    w = {"app": "TextEdit", "window": os.path.basename(path)}
    try:
        c.call("click", role="checkbox", name="align left", **w)  # waits up to 3 s for the window
        made = finder_front()
        text, is_err = c.call("click", role="checkbox", name="align left", **w)
        after = frontmost()
        print(f"      press, no change ({after} in front): {text.splitlines()[0]}")
        check("press with no visible effect says so, not \"pressed\", and a native control gets no mouse click",
              not is_err and 'checkbox "align left": no visible effect (tried AXPress)' in text
              and "pressed" not in text and "clicked at" not in text, text)
        check("a press works in the background and leaves Finder frontmost",
              after == "com.apple.finder" and "borrowed" not in text, (after, text))
        if made:
            subprocess.run(["osascript", "-e", 'tell application "Finder" to close front Finder window'], capture_output=True)
    finally:
        close_scratch(c, w, path)
        c.close()
        os.remove(path)


def ax_checks():
    scratch_dir = os.path.join(ROOT, "tests", "scratch")
    os.makedirs(scratch_dir, exist_ok=True)
    fname = f"mx-selftest-{os.getpid()}.txt"
    path = os.path.join(scratch_dir, fname)
    with open(path, "w") as f:
        f.write("seed text")

    c = Client()
    c.request("initialize", {"protocolVersion": "2025-06-18"})
    text, is_err = c.call("snapshot", app="TextEdit", window="no-such-window-xyz")
    if is_err and "not trusted" in text:
        print(f"NOT RUN  AX checks: {text}")
        results.append(("AX checks", "NOT RUN"))
        c.close()
        os.remove(path)
        return False

    subprocess.run(["open", "-a", "TextEdit", path], check=True)
    w = {"app": "TextEdit", "window": fname}
    try:
        text, is_err = c.call("start", title="mx self-test")
        check("start", not is_err and "mx self-test" in text, text)

        deadline = time.time() + 10
        while True:
            text, is_err = c.call("snapshot", **w)
            if not is_err or time.time() > deadline:
                break
            time.sleep(0.3)
        print("      snapshot:\n" + "\n".join("        " + l for l in text.splitlines()[:12]))
        m = re.search(r"(e\d+) textarea", text)
        check("snapshot shows the scratch textarea with its text", not is_err and m and '"seed text"' in text, text)
        ref = m.group(1)

        text, is_err = c.call("fill", ref=ref, text="hello from mx", **w)
        check("fill", not is_err and "filled textarea" in text and '"hello from mx"' in text, text)
        ms, wait = c.last_settle()
        print(f"      fill settled in {ms} ms (title wait {'on' if wait else 'off'})")
        check("live fill settles in under 300 ms with the title wait off", ms is not None and ms < 300 and not wait,
              (ms, wait))
        text, is_err = c.call("read", ref=ref, **w)
        check("read returns the filled text", not is_err and text == "hello from mx", text)

        out = {}

        def keys():
            out["a"] = c.call("key", ref=ref, key="cmd+a", **w)
            out["q"] = c.call("key", key="q", **w)
            return read_until(c, ref, w, "q")
        got = with_retry("cmd+a then q", keys, "q", actions=2)
        text, is_err = out["a"]
        check("key cmd+a", not is_err and "pressed cmd+a" in text, text)
        text, is_err = out["q"]
        check("key q replaces the selection", not is_err and "pressed q" in text, text)
        check("read after keys == 'q'", got == "q", got)

        def batch():
            out["b"] = c.call("batch", steps=[
                {"action": "fill", "role": "textarea", "text": "batch one"},
                {"action": "key", "key": "cmd+a"},
                {"action": "key", "key": "z"},
            ], **w)
            return read_until(c, ref, w, "z")
        got = with_retry("batch fill, cmd+a, z", batch, "z", actions=3)
        text, is_err = out["b"]
        print("      batch:\n" + "\n".join("        " + l for l in text.splitlines()[:6]))
        check("batch returns only the final diff", not is_err and "ran 3 steps" in text and "batch one" not in text, text)
        check("read after batch == 'z'", got == "z", got)

        text, is_err = c.call("snapshot", app="Terminal")
        check("refuses Terminal", is_err and "refuses" in text, text)
        text, is_err = c.call("click", role="button", name="Delete everything", **w)
        check("role+name waits, then reports a missing element", is_err and "within 3s" in text, text)

        text, is_err = c.call("done", summary="self-test passed")
        want = 6 + extra_actions[0]
        check(f"done returns duration and action count ({want})",
              not is_err and re.match(rf"done in \d+\.\ds with {want} actions", text), text)
        print(f"      done: {text}")

        # Mouse path: select all, then a real click in the text area must drop the
        # selection, so the next key inserts instead of replacing.
        def mouse():
            c.call("fill", ref=ref, text="abcdef", **w)
            read_until(c, ref, w, "abcdef")
            c.call("key", ref=ref, key="cmd+a", **w)
            out["m"] = c.call("click", ref=ref, force_mouse=True, **w)
            c.call("key", key="q", **w)
            return read_until(c, ref, w, "abcdefq")
        got = with_retry("mouse click", mouse, "abcdefq", actions=0)
        text, is_err = out["m"]
        print(f"      mouse click: {text.splitlines()[0]}")
        check("click force_mouse reports the mouse path", not is_err and "clicked at " in text, text)
        check("mouse click took effect (selection dropped, q inserted)", got == "abcdefq", got)
        c.call("fill", ref=ref, text="send now", **w)  # an unnamed textarea is labelled by its value
        text, is_err = c.call("click", ref=ref, force_mouse=True, **w)
        check("confirm gate also covers the mouse path", is_err and "refused" in text, text)

        submit_key_checks(c, ref, w)
        typing_checks(c, ref, w)
        background_checks(c, ref, w)
        borrow_checks(c, ref, w)
        idle_wait_checks(c, ref, w)
        indicator_checks(c, ref, w)
        mode_checks(c, ref, w)
        newline_field_checks(c, ref, w)
        timing_checks(c, ref, w)
        textedit_system_checks(c, ref, w, path)
    finally:
        close_scratch(c, w, path)
        c.close()
        os.remove(path)
    return True


def submit_key_checks(c, ref, w):
    """Return in a text box needs confirm (it can send in chat apps); the scratch textarea stands in."""
    c.call("fill", ref=ref, text="line", **w)
    text, is_err = c.call("key", ref=ref, key="return", **w)
    print(f"      return refusal: {text}")
    check("key return in the textarea is refused and says to ask the user",
          is_err and text.startswith("refused: return in a text box") and "ask the user" in text
          and "confirm=true" in text, text)
    text, _ = c.call("read", ref=ref, **w)
    check("refused return left the text unchanged", text == "line", repr(text))

    text, is_err = c.call("key", ref=ref, key="return", confirm=True, **w)
    check("key return with confirm=true is allowed", not is_err and "pressed return" in text, text)
    text, _ = c.call("read", ref=ref, **w)
    check("confirmed return inserted a newline", text == "line\n", repr(text))

    text, is_err = c.call("key", ref=ref, key="shift+return", **w)
    check("key shift+return is allowed without confirm", not is_err and "pressed shift+return" in text, text)
    text, _ = c.call("read", ref=ref, **w)
    check("shift+return inserted a newline", text == "line\n\n", repr(text))

    text, is_err = c.call("key", key="cmd+return", **w)
    check("key cmd+return (focused textarea, no ref) is refused", is_err and text.startswith("refused:"), text)

    text, is_err = c.call("batch", steps=[
        {"action": "fill", "ref": ref, "text": "batch fill"},
        {"action": "key", "ref": ref, "key": "return"},
    ], **w)
    print("      batch fill+return:\n" + "\n".join("        " + l for l in text.splitlines()[:4]))
    check("batch stops at the return step with the refusal and reports the fill",
          is_err and "step 2/2 (key) failed: refused: return in a text box" in text
          and "Ran 1 of 2 steps" in text and '"batch fill"' in text, text)
    text, _ = c.call("read", ref=ref, **w)
    check("batch: fill applied, return not pressed", text == "batch fill", repr(text))

    out = {}

    def keys():
        out["a"] = c.call("key", ref=ref, key="cmd+a", **w)
        out["q"] = c.call("key", key="q", **w)
        return read_until(c, ref, w, "q")
    got = with_retry("cmd+a then q (no confirm)", keys, "q", actions=2)
    text, is_err = out["a"]
    check("key cmd+a still needs no confirm", not is_err and "pressed cmd+a" in text, text)
    check("key q still needs no confirm", not out["q"][1] and got == "q", (out["q"], got))


def typing_checks(c, ref, w):
    """typing=keys: select all, then one key event per character; newlines need confirm."""
    text, is_err = c.call("start", title="typing", typing="keys")
    check("start typing=keys", not is_err and "typing keys" in text, text)
    exact = "Hello, mx! 123 (x+y) äé ✓"
    out = {}

    def typed():
        c.call("fill", ref=ref, text="Old text", **w)  # typed too; the next fill must clear it first
        out["t"] = c.call("fill", ref=ref, text=exact, **w)
        return read_until(c, ref, w, exact)
    got = with_retry("typing=keys fill", typed, exact, actions=0)
    text, is_err = out["t"]
    print(f"      keys fill: {text.splitlines()[0]}")
    check("typing=keys fill produces the exact text", not is_err and text.startswith("typed ") and got == exact,
          (text, got))

    text, is_err = c.call("fill", ref=ref, text="line one\nline two", **w)
    check("typing=keys text with \\n and no confirm is refused", is_err and text.startswith("refused:")
          and "confirm=true" in text, text)
    got, _ = c.call("read", ref=ref, **w)
    check("refused typing left the text unchanged", got == exact, repr(got))
    text, is_err = c.call("fill", ref=ref, text="one\ntwo", confirm=True, **w)
    got = read_until(c, ref, w, "one\ntwo")
    check("typing=keys text with \\n and confirm=true types the newline", not is_err and got == "one\ntwo", (text, got))
    c.call("start", title="typing", typing="paste")


def background_checks(c, ref, w):
    """With another app in front, cmd+a (a menu key equivalent) is dropped by TextEdit
    unless mx brings it to the front, and typing=keys must still replace the text."""
    out = {}

    def keys():
        c.call("fill", ref=ref, text="abc", **w)
        read_until(c, ref, w, "abc")
        finder_front()
        out["a"] = c.call("key", ref=ref, key="cmd+a", **w)
        c.call("key", key="q", **w)
        return read_until(c, ref, w, "q")
    got = with_retry("background cmd+a", keys, "q", actions=0)
    text, is_err = out["a"]
    print(f"      background cmd+a: {text.splitlines()[0]}")
    check("cmd+a with another app in front borrows the front and takes effect",
          not is_err and "borrowed front from Finder" in text and got == "q", (text, got))

    c.call("start", title="typing", typing="keys")

    def typed():
        # Capitalized, since TextEdit auto-capitalizes typed text as it would for a person.
        c.call("fill", ref=ref, text="Old", **w)
        read_until(c, ref, w, "Old")
        finder_front()
        c.call("fill", ref=ref, text="New text", **w)
        return read_until(c, ref, w, "New text")
    got = with_retry("background typing=keys", typed, "New text", actions=0)
    check("typing=keys replaces the text while another app is in front", got == "New text", got)
    c.call("start", title="typing", typing="paste")


def borrow_checks(c, ref, w):
    """Background by default: with Finder in front, fill, a plain key and reads leave Finder
    in front; cmd shortcuts and the mouse path borrow the front and hand it back, cursor too."""
    made = finder_front()
    try:
        before = frontmost()
        check("borrow: Finder is frontmost to start", before == "com.apple.finder", before)

        out = {}

        def plain():
            out["f"] = c.call("fill", ref=ref, text="bg", **w)
            out["k"] = c.call("key", ref=ref, key="x", **w)
            return read_until(c, ref, w, "bgx")
        got = with_retry("background fill + key", plain, "bgx", actions=0)
        after = frontmost()
        check("fill and a plain key work in the background", got == "bgx" and "borrowed" not in out["f"][0]
              and "borrowed" not in out["k"][0], (got, out))
        check("fill and a plain key leave Finder frontmost", after == "com.apple.finder", after)

        def cmd():
            c.call("fill", ref=ref, text="abc", **w)
            read_until(c, ref, w, "abc")
            finder_front()
            out["p0"], t = cursor(), time.time()
            out["a"] = c.call("key", ref=ref, key="cmd+a", **w)
            out["front"] = frontmost()
            out["p1"] = cursor()
            c.call("key", key="q", **w)
            got = read_until(c, ref, w, "q")
            return "(the user moved the mouse)" if user_moved_cursor(out["p0"], out["p1"], t) else got
        got = with_retry("borrowed cmd+a", cmd, "q", actions=0)
        text, is_err = out["a"]
        m = re.search(r"borrowed front from Finder for (\d+) ms", text)
        print(f"      cmd+a: {text.splitlines()[0]}")
        check("cmd+a borrows the front, takes effect and says so", not is_err and m and got == "q", (text, got))
        check("after cmd+a Finder is frontmost again", out["front"] == "com.apple.finder", out["front"])
        dx, dy = out["p1"][0] - out["p0"][0], out["p1"][1] - out["p0"][1]
        check("after cmd+a the cursor is back within 2 px", abs(dx) <= 2 and abs(dy) <= 2, (out["p0"], out["p1"]))
        borrow_ms.append(int(m.group(1)) if m else None)

        def mouse():
            c.call("fill", ref=ref, text="abcdef", **w)
            read_until(c, ref, w, "abcdef")
            finder_front()
            out["p0"], t = cursor(), time.time()
            out["m"] = c.call("click", ref=ref, force_mouse=True, **w)
            out["front"] = frontmost()
            out["p1"] = cursor()
            c.call("key", key="q", **w)  # the click put the caret after the text; q goes in, nothing replaced
            got = read_until(c, ref, w, "abcdefq")
            return "(the user moved the mouse)" if user_moved_cursor(out["p0"], out["p1"], t) else got
        got = with_retry("borrowed mouse click", mouse, "abcdefq", actions=0)
        text, is_err = out["m"]
        m = re.search(r"borrowed front from Finder for (\d+) ms", text)
        print(f"      force_mouse click: {text.splitlines()[0]}")
        check("force_mouse click borrows the front and takes effect", not is_err and m and "clicked at " in text
              and got == "abcdefq", (text, got))
        check("after the click Finder is frontmost again", out["front"] == "com.apple.finder", out["front"])
        dx, dy = out["p1"][0] - out["p0"][0], out["p1"][1] - out["p0"][1]
        check("after the click the cursor is back within 2 px", abs(dx) <= 2 and abs(dy) <= 2, (out["p0"], out["p1"]))
        borrow_ms.append(int(m.group(1)) if m else None)

        def batch():
            c.call("fill", ref=ref, text="abc", **w)
            read_until(c, ref, w, "abc")
            finder_front()
            out["b"] = c.call("batch", steps=[
                {"action": "key", "key": "cmd+a"},
                {"action": "key", "key": "cmd+left"},
                {"action": "key", "key": "z"},
            ], **w)
            out["front"] = frontmost()
            return read_until(c, ref, w, "zabc")
        got = with_retry("batch of two cmd steps", batch, "zabc", actions=0)
        text, is_err = out["b"]
        print(f"      batch cmd+a, cmd+left, z: {text.splitlines()[0]}")
        check("a batch with two consecutive cmd steps borrows once",
              not is_err and text.count("borrowed front") == 1 and got == "zabc", (text, got))
        check("after the batch Finder is frontmost again", out["front"] == "com.apple.finder", out["front"])

        # Screenshots never need the front: whatever is frontmost before stays frontmost.
        finder_front()
        before = frontmost()
        screenshot_checks(c, ref, w)
        after = frontmost()
        check("screenshots taken with Finder in front leave it frontmost",
              before == after == "com.apple.finder", (before, after))
    finally:
        if made:
            subprocess.run(["osascript", "-e", 'tell application "Finder" to close front Finder window'], capture_output=True)


def idle_wait_checks(c, ref, w):
    """A borrow waits for the user to pause. _fake_idle_ms stands in for the user's idle
    time (real HID input from the test would count as mx's own): idle borrows at once,
    still active after 3 s refuses, and active-then-idle borrows after waiting."""
    made = finder_front()
    try:
        out = {}

        def idle():
            c.call("fill", ref=ref, text="abc", **w)
            read_until(c, ref, w, "abc")
            finder_front()
            out["i"] = c.call("key", ref=ref, key="cmd+a", _fake_idle_ms=1000, **w)
            c.call("key", key="q", **w)
            return read_until(c, ref, w, "q")
        got = with_retry("idle user: borrow at once", idle, "q", actions=0)
        text, is_err = out["i"]
        print(f"      idle user: {text.splitlines()[0]}")
        check("idle user: the borrow goes ahead with no wait",
              not is_err and "borrowed front from Finder" in text and "waited" not in text and got == "q", (text, got))

        c.call("fill", ref=ref, text="abc", **w)
        read_until(c, ref, w, "abc")
        finder_front()
        t0 = time.time()
        text, is_err = c.call("key", ref=ref, key="cmd+a", _fake_idle_ms=-5000, **w)
        secs = time.time() - t0
        front = frontmost()
        c.call("key", key="q", **w)
        got = read_until(c, ref, w, "abcq")
        print(f"      active user: {text.splitlines()[0][:150]} ({secs:.1f} s)")
        check("active user: the borrow is refused after 3 s with a retry hint",
              is_err and "the user is typing" in text and "retry this step once" in text and 2.9 <= secs < 4.5, (text, secs))
        # Not TextEdit, rather than Finder: the user may have switched apps during the 3 s.
        check("active user: mx never took the front and the shortcut never ran",
              front != "com.apple.TextEdit" and got == "abcq", (front, got))

        def later():
            c.call("fill", ref=ref, text="abc", **w)
            read_until(c, ref, w, "abc")
            finder_front()
            out["l"] = c.call("key", ref=ref, key="cmd+a", _fake_idle_ms=-1000, **w)
            c.call("key", key="q", **w)
            return read_until(c, ref, w, "q")
        got = with_retry("user pauses within 3 s", later, "q", actions=0)
        text, is_err = out["l"]
        m = re.search(r"waited (\d+\.\d) s for the user to pause; borrowed front from Finder", text)
        print(f"      user pauses: {text.splitlines()[0]}")
        check("user pauses within 3 s: mx waits (about 1.5 s), then borrows",
              not is_err and m and 1.3 <= float(m.group(1)) <= 2.0 and got == "q", (text, got))

        def own():
            c.call("fill", ref=ref, text="abcdef", **w)
            read_until(c, ref, w, "abcdef")
            finder_front()
            c.call("click", ref=ref, force_mouse=True, **w)  # mx posts mouse events through the HID tap; Finder is back in front after
            out["o"] = c.call("key", ref=ref, key="cmd+a", **w)
            c.call("key", key="q", **w)
            return read_until(c, ref, w, "q")
        got = with_retry("mx's own mouse events", own, "q", actions=0)
        text, is_err = out["o"]
        if "waited" in text:  # the user may really have been active; one more go
            wait_user_idle()
            got = own()
            text, is_err = out["o"]
        print(f"      after mx's own mouse click: {text.splitlines()[0]}")
        check("mx's own posted mouse events don't count as the user being active",
              not is_err and "borrowed front from Finder" in text and "waited" not in text and got == "q", (text, got))
    finally:
        if made:
            subprocess.run(["osascript", "-e", 'tell application "Finder" to close front Finder window'], capture_output=True)


SAMPLER = """ObjC.import('CoreGraphics');
var pid = %d, end = Date.now() + %d, out = [];
while (Date.now() < end) {
  var all = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0)));
  out.push([Date.now(), all.filter(w => w.kCGWindowOwnerPID == pid && w.kCGWindowAlpha > 0)
                           .map(w => [w.kCGWindowBounds.Width, w.kCGWindowBounds.Height])]);
  delay(0.02);
}
JSON.stringify(out);"""


def sample_overlays(c, seconds, action):
    """Samples mx's on-screen windows (CGWindowListCopyWindowInfo, owner = mx's pid) every
    ~20 ms while action() runs. Returns (samples, t0, t1): samples are (epoch s, kinds)
    with each window that carries a tag as "pointer" (screen-sized) or "wave" (24 pt
    high); the border has no text and is left out. t0/t1 bracket the action."""
    p = subprocess.Popen(["osascript", "-l", "JavaScript", "-e", SAMPLER % (c.p.pid, int(seconds * 1000))],
                         stdout=subprocess.PIPE, text=True)
    time.sleep(0.4)  # osascript start-up
    t0 = time.time()
    action()
    t1 = time.time()
    raw = json.loads(p.communicate(timeout=seconds + 10)[0] or "[]")
    sw, sh = screen_size()
    kinds = lambda ws: [("pointer" if (wd, ht) == (sw, sh) else "wave") for wd, ht in ws if (wd, ht) == (sw, sh) or ht == 24]
    return [(t / 1000, kinds(ws)) for t, ws in raw], t0, t1


def screen_size():
    """The main screen's size in points."""
    w, h = jxa("var f = $.NSScreen.screens.objectAtIndex(0).frame; f.size.width + ',' + f.size.height").split(",")
    return int(float(w)), int(float(h))


def one_indicator(name, samples, want=None):
    """Checks no sample had more than one tag-text window, and that `want` showed at some point."""
    most = max((len(k) for _, k in samples), default=0)
    seen = {x for _, k in samples for x in k}
    ok = samples and most <= 1 and (want is None or want in seen)
    check(f"one tag: {name}", ok, f"{len(samples)} samples, at most {most} tag windows at once, seen {sorted(seen)}")
    return seen


def indicator_checks(c, ref, w):
    """Exactly one tag at a time, read from the window list: the waveform alone in
    background mode, the pointer alone during a borrow and in front mode, the borrow toast
    on the waveform only after the pointer is gone, and Done on whichever is active."""
    made = finder_front()
    try:
        c.call("start", title="indicator", mode="background")
        samples, _, _ = sample_overlays(c, 1.5, lambda: c.call("fill", ref=ref, text="wave", **w))
        seen = one_indicator("background mode shows the waveform only", samples, "wave")
        check("one tag: no pointer in background mode", "pointer" not in seen, seen)

        out = {}

        def borrowed():
            wait_user_idle()
            finder_front()
            out["b"] = c.call("click", ref=ref, force_mouse=True, **w)
        samples, t0, t1 = sample_overlays(c, 3.0, borrowed)  # room after a slow (1.2 s) borrow
        print(f"      borrow under the sampler: {out['b'][0].splitlines()[0]}")
        seen = one_indicator("during a borrow (pointer) and after it (toast on the waveform)", samples, "pointer")
        last_pointer = max((t for t, k in samples if "pointer" in k), default=None)
        after = [k for t, k in samples if t > t1 + 0.3]
        check("one tag: the toast waveform follows the borrow, the pointer is gone",
              last_pointer is not None and after and all(k == ["wave"] for k in after), (last_pointer, t1, after[:3]))

        c.call("start", title="indicator", mode="front")
        samples, _, _ = sample_overlays(c, 1.5, lambda: c.call("fill", ref=ref, text="front", **w))
        one_indicator("front mode shows the pointer", samples, "pointer")
        first = min((t for t, k in samples if "pointer" in k), default=None)
        later = {x for t, k in samples if first is not None and t >= first for x in k}
        # The background waveform from before is up until the pointer replaces it, never after.
        check("one tag: no waveform once the pointer is up in front mode", later == {"pointer"}, later)
        samples, _, _ = sample_overlays(c, 1.0, lambda: c.call("done", summary="front done"))
        one_indicator("done in front mode (on the pointer)", samples, "pointer")

        finder_front()
        c.call("start", title="indicator", mode="background")
        c.call("fill", ref=ref, text="bg", **w)
        samples, _, _ = sample_overlays(c, 1.0, lambda: c.call("done", summary="background done"))
        seen = one_indicator("done in background mode (next to the waveform)", samples, "wave")
        check("one tag: no pointer at background done", "pointer" not in seen, seen)
        c.call("start", title="mx self-test", mode="background")
    finally:
        if made:
            subprocess.run(["osascript", "-e", 'tell application "Finder" to close front Finder window'], capture_output=True)


def mode_checks(c, ref, w):
    """Per-job modes: front brings TextEdit forward and keeps it there, background leaves
    Finder in front, and switching background -> front mid-session raises TextEdit at once."""
    made = finder_front()
    try:
        wait_user_idle()  # front mode keeps TextEdit in front, where the user's keys would land
        c.call("start", title="front mode", mode="front")
        fronts, texts = [], []
        for args in ({"tool": "fill", "text": "front"}, {"tool": "key", "key": "x"}, {"tool": "read"}):
            tool = args.pop("tool")
            texts.append(c.call(tool, ref=ref, **args, **w))
            fronts.append(frontmost())
        check("mode=front makes TextEdit frontmost and keeps it there across 3 actions",
              fronts == ["com.apple.TextEdit"] * 3 and all(not e and "borrowed" not in t for t, e in texts),
              (fronts, texts))

        finder_front()
        c.call("start", title="background mode", mode="background")
        out = c.call("fill", ref=ref, text="bg", **w), c.call("key", ref=ref, key="y", **w)
        got = read_until(c, ref, w, "bgy")
        after = frontmost()
        check("mode=background leaves Finder frontmost", after == "com.apple.finder" and got == "bgy", (after, got, out))

        text, is_err = c.call("start", title="background mode", mode="front")
        after = frontmost()
        check("switching background -> front mid-session raises TextEdit",
              not is_err and "(mode front," in text and after == "com.apple.TextEdit", (text, after))
        c.call("start", title="mx self-test", mode="background")
    finally:
        if made:
            subprocess.run(["osascript", "-e", 'tell application "Finder" to close front Finder window'], capture_output=True)


def newline_field_checks(c, ref, w):
    """Slack's empty message box reads "\n"; typing=keys must treat a field holding only a
    newline as clearable and type into it instead of aborting."""
    c.call("fill", ref=ref, text="\n", **w)
    seeded = read_until(c, ref, w, "\n")
    check('scratch field holds only "\\n"', seeded == "\n", repr(seeded))
    c.call("start", title="typing", typing="keys")
    text, is_err = c.call("fill", ref=ref, text="Typed", **w)
    got = read_until(c, ref, w, "Typed")
    check('typing=keys clears a "\\n"-only field and types', not is_err and got == "Typed", (text, got))
    c.call("start", title="typing", typing="paste")


def screenshot_checks(c, ref, w):
    """Marked screenshot of the scratch window, a ref crop, and the permission error."""
    content, is_err = c.call_content("screenshot", **w)
    text = content[0].get("text", "")
    if is_err and "record the screen" in text:
        not_run("screenshot (Screen Recording not granted)", text)
        return
    images = [x for x in content if x.get("type") == "image"]
    m = re.search(r"(\d+)x(\d+) PNG.*?(\d+) marks", text)
    print(f"      screenshot ({frontmost()} in front): {text}")
    ok = (not is_err and len(images) == 1 and images[0].get("mimeType") == "image/png" and m
          and int(m.group(1)) <= 1280 and int(m.group(3)) > 0)
    check("screenshot of the background scratch window returns a PNG with marks > 0", ok, text)
    if not ok:
        return
    data = base64.b64decode(images[0]["data"])
    check("screenshot data is a PNG", data[:8] == b"\x89PNG\r\n\x1a\n", data[:8])
    with open(os.path.join(ROOT, "tests", "scratch", "marked-example.png"), "wb") as f:
        f.write(data)
    full = int(m.group(1)) * int(m.group(2))

    content, is_err = c.call_content("screenshot", element=ref, **w)
    text = content[0].get("text", "")
    mc = re.search(r"(\d+)x(\d+) PNG", text)
    print(f"      crop: {text}")
    check("an element crop is smaller than the full image", not is_err and mc and int(mc.group(1)) * int(mc.group(2)) < full
          and any(x.get("type") == "image" for x in content), text)
    # A small control: the crop around it should be far smaller than the window.
    snap, _ = c.call("snapshot", **w)
    small = re.search(r"(e\d+) (?:button|menubutton)", snap)
    if small:
        content, is_err = c.call_content("screenshot", element=small.group(1), **w)
        mc = re.search(r"(\d+)x(\d+) PNG", content[0].get("text", ""))
        check("a button crop is under a tenth of the full image",
              not is_err and mc and int(mc.group(1)) * int(mc.group(2)) * 10 < full, content[0].get("text"))

    text, is_err = c.call("screenshot", role="textarea", **w)
    check("an element crop by role and name works", not is_err and "textarea in window" in text and " PNG" in text, text)

    text, is_err = c.call("screenshot", marks=False, **w)
    check("marks=false draws no marks", not is_err and text.endswith(" 0 marks"), text)

    content, is_err = c.call_content("screenshot", full=True, **w)
    text = content[0].get("text", "")
    mf = re.search(r"the main display: (\d+)x(\d+) PNG", text)
    dw, dh = (float(v) for v in jxa("var f = $.NSScreen.screens.objectAtIndex(0).frame; "
                                     "f.size.width + ',' + f.size.height").split(","))
    print(f"      full: {text} (display {dw:.0f}x{dh:.0f} pt)")
    check("full returns a display-sized PNG (display aspect, at most 1280 px wide)",
          not is_err and mf and int(mf.group(1)) == min(1280, int(mf.group(1)))
          and abs(int(mf.group(1)) / int(mf.group(2)) - dw / dh) < 0.01
          and int(mf.group(1)) * int(mf.group(2)) > full, text)

    u = Client(env={"MX_FORCE_NO_SCREEN": "1"})
    u.request("initialize", {"protocolVersion": "2025-06-18"})
    text, is_err = u.call("screenshot", **w)
    check("no Screen Recording: clear error naming the app to grant",
          is_err and "Screen & System Audio Recording" in text and "turn on" in text, text)
    print(f"      no-screen message: {text}")
    u.close()


def timing_checks(c, ref, w):
    """The same TextEdit batch in fast and in watch mode; watch must be slower."""
    steps = [
        {"action": "fill", "ref": ref, "text": "timing run"},
        {"action": "click", "ref": ref, "force_mouse": True},
        {"action": "key", "key": "cmd+a"},
        {"action": "key", "key": "z"},
    ]
    times = {}
    for mode in ("background", "watch"):
        c.call("start", title="timing", mode=mode)
        t0 = time.time()
        text, is_err = c.call("batch", steps=steps, **w)
        times[mode] = time.time() - t0
        check(f"{mode} batch runs", not is_err and "ran 4 steps" in text, text)
    print(f"      same 4-step batch: background {times['background']:.2f}s, watch {times['watch']:.2f}s")
    check("watch batch is slower than background (glides, 400 ms pauses)", times["watch"] > times["background"] + 1.0, times)
    c.call("done", summary="timing")


def close_scratch(c, w, path):
    """Closes only the scratch document, without saving, through AppleScript, so a dirty
    document or a save sheet can't block cleanup."""
    script = f'tell application "TextEdit" to close (every document whose path is "{path}") saving no'
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    if r.returncode:
        print(f"      cleanup: {r.stderr.strip()}")
    deadline = time.time() + 3
    while True:
        still_open, _ = c.call("snapshot", **w)
        if "no window matching" in still_open or time.time() > deadline:
            break
        time.sleep(0.2)
    check("scratch window closed", "no window matching" in still_open, still_open)


# ---------------------------------------------------------------------------
# Whole-Mac checks (fix8): system processes, scopes, Control Center, click actions,
# menus, windows, apps, open, scroll, drag, dialogs, clipboard, hardware keys, gates.
# Rules: only brightness and volume change, each restored in a finally; toggles are
# only read; System Settings is only navigated and read, and never gets confirm=true.

def gate_word_checks(c):
    """The confirm keyword list through the hidden _debug_dangerous hook; no app involved."""
    words = ["Restart…", "Shut Down…", "Log Out Sam…", "Sleep", "Erase All Content", "Reset",
             "Uninstall", "Move to Trash", "Move to Bin", "Empty Trash", "Format Disk", "Force Quit"]
    text, _ = c.call("_debug_dangerous", labels=words + ["Formatting help", "Show Tab Bar", "Zoom In"])
    got = dict(line.rsplit(": ", 1) for line in text.splitlines())
    check("confirm gate covers restart, shut down, log out, sleep, erase, reset, uninstall, trash, format, force quit",
          all(got.get(w) == "yes" for w in words), text)
    check("confirm gate leaves ordinary labels alone",
          got.get("Formatting help") == "no" and got.get("Show Tab Bar") == "no" and got.get("Zoom In") == "no", text)


def pill_place_checks(c):
    """fix19: where the background pill goes, through the hidden _debug_pill hook (no GUI).
    Cocoa coordinates (y up); the visible frame starts above an 80 px Dock."""
    vis, box, win = [0, 80, 1512, 870], [200, 24], [400, 300, 600, 400]
    cases = [{"id": 1, "frame": win, "box": box, "visible": vis, "front": []},
             {"id": 2, "frame": win, "box": box, "visible": vis, "front": [[400, 100, 600, 190]]},
             {"id": 3, "frame": win, "box": box, "visible": vis, "front": [[1100, 100, 300, 300], [400, 500, 600, 400]]},
             {"id": 4, "frame": [400, 82, 600, 400], "box": box, "visible": vis, "front": []},
             {"id": 5, "frame": [0, 0, 1512, 982], "box": box, "visible": vis, "front": []},
             # fix21: the 504 pt done pill. Inside a 300 pt window it shrinks to fit; below a
             # narrow window near the screen edge it keeps its width and shifts onto the screen.
             {"id": 6, "frame": [400, 300, 300, 400], "box": [504, 24], "visible": vis, "front": [[400, 100, 600, 190]]},
             {"id": 7, "frame": [1300, 300, 200, 400], "box": [504, 24], "visible": vis, "front": []},
             {"id": 8, "frame": [600, 300, 300, 400], "box": [504, 24], "visible": vis, "front": [[860, 100, 400, 190]]}]
    text, _ = c.call("_debug_pill", cases=cases)
    got = dict(line.split(": ", 1) for line in text.splitlines())
    check("pill: room below and nothing in front -> 6 px below the window", got.get("1") == "below 600,270 200", text)
    check("pill: a window in front over the spot below -> inside, 8 px above the bottom edge",
          got.get("2") == "inside 600,308 200", text)
    check("pill: windows in front that miss the spot below leave it below", got.get("3") == "below 600,270 200", text)
    check("pill: window at the screen bottom -> inside", got.get("4") == "inside 600,90 200", text)
    check("pill: full-screen window -> inside, above the Dock", got.get("5") == "inside 656,84 200", text)
    check("pill: a pill wider than the window goes inside at the window's width less 8 px a side",
          got.get("6") == "inside 408,308 284", text)
    check("pill: a wide pill below a window at the screen edge shifts left to stay on screen",
          got.get("7") == "below 1004,270 504", text)
    check("pill: the wide pill's full width counts against windows in front (only its end is covered -> inside)",
          got.get("8") == "inside 608,308 284", text)
    text2, _ = c.call("_debug_pill", cases=cases)
    check("pill: the same layout gives the same answer", text2 == text, (text, text2))


LABELS = os.path.join(ROOT, "tests", "gate-labels.jsonl")
# gate-labels.jsonl (42 hand-labeled actions) has no geometry. Case 7 is an "unlabeled send button in a composer",
# so it gets a button 20 px right of a message box, the layout of Discord's and Slack's composers.
COMPOSER_GEOMETRY = {7: {"frame": [600, 700, 28, 28], "text_boxes": [[100, 690, 480, 48]]}}


def gate_table_checks(c):
    """fix10 rule gaps through the hidden _debug_gate hook (no GUI): the new keywords, the
    trash shortcuts (in any app), the composer-button geometry, and the gate-labels.jsonl score."""
    words = ["Ship it", "Deploy", "Release 4.2", "Publish", "Leave channel", "Place order", "Schedule message", "Checkout"]
    text, _ = c.call("_debug_dangerous", labels=words + ["Shipping address help", "Leaves", "Scheduled"])
    got = dict(line.rsplit(": ", 1) for line in text.splitlines())
    check("confirm gate covers ship, deploy, release, publish, leave, place order, schedule, checkout",
          all(got.get(w) == "yes" for w in words), text)
    check("the new keywords match whole words only",
          all(got.get(w) == "no" for w in ["Shipping address help", "Leaves", "Scheduled"]), text)

    finder = {"app": "Finder", "window": "Documents", "action": "key", "role": "row", "label": "report.pdf"}
    cases = [dict(finder, id=1, key="cmd+delete"), dict(finder, id=2, key="cmd+option+delete"),
             dict(finder, id=3, key="delete"), dict(finder, id=4, key="cmd+delete", app="Files Pro"),
             dict(finder, id=9, key="cmd+shift+delete", app="Files Pro"),
             {"id": 5, "app": "Discord", "window": "#team", "action": "click", "role": "button", "label": "",
              "frame": [600, 700, 28, 28], "text_boxes": [[100, 690, 480, 48]]},
             {"id": 6, "app": "Discord", "window": "#team", "action": "click", "role": "button", "label": "",
              "frame": [600, 300, 28, 28], "text_boxes": [[100, 690, 480, 48]]},
             {"id": 7, "app": "Discord", "window": "#team", "action": "click", "role": "button", "label": "",
              "frame": [600, 300, 28, 28], "text_boxes": [], "same_group": True},
             {"id": 8, "app": "Discord", "window": "#team", "action": "click", "role": "button", "label": "Emoji",
              "frame": [600, 700, 28, 28], "text_boxes": [[100, 690, 480, 48]]}]
    text, _ = c.call("_debug_gate", cases=cases)
    got = dict(line.split(": ", 1) for line in text.splitlines())
    check("cmd+delete and cmd+option+delete need confirm",
          got["1"].startswith("confirm") and got["2"].startswith("confirm"), text)
    check("cmd+delete and cmd+shift+delete need confirm in any app, with no app named",
          all(got[i] == "confirm: %s trashes or deletes the selection" % k
              for i, k in (("1", "cmd+delete"), ("4", "cmd+delete"), ("9", "cmd+shift+delete"))), text)
    check("plain delete is allowed", got["3"] == "allow", text)
    check("an unlabeled button within 80 px of a text box, or in its group, needs confirm",
          got["5"].startswith("confirm") and got["7"].startswith("confirm"), text)
    check("an unlabeled button far from any text box, and a labeled one beside it, are allowed",
          got["6"] == "allow" and got["8"] == "allow", text)

    if not os.path.exists(LABELS):
        not_run("gate-labels.jsonl through _debug_gate", f"{LABELS} missing")
        return
    rows = [json.loads(l) for l in open(LABELS) if l.strip()]
    cases = [{"id": r["id"], "app": r["app"], "window": r["window"], "action": r["action"], "role": r["role"],
              "label": r["label"], "key": r["key_or_text"] if r["action"] == "key" else "",
              **COMPOSER_GEOMETRY.get(r["id"], {})} for r in rows]
    text, _ = c.call("_debug_gate", cases=cases)
    got = {int(k): v for k, v in (line.split(": ", 1) for line in text.splitlines())}
    misses = [(r["id"], r["label_decision"], got.get(r["id"])) for r in rows
              if got.get(r["id"], "").split(":")[0] != r["label_decision"]]
    print(f"      _debug_gate on gate-labels.jsonl: {len(rows) - len(misses)}/{len(rows)} correct; misses: {misses}")
    check(f"_debug_gate scores {len(rows)}/{len(rows)} on gate-labels.jsonl", not misses, misses)


def checkbox_states(text):
    """{name: on|off} for every checkbox line of a snapshot."""
    return dict(re.findall(r'checkbox "([^"]*)" = "(on|off|mixed)"', text))


def window_frame(c, w):
    """(x, y, width, height) of the scratch window from window(op: list)."""
    text, _ = c.call("window", app=w["app"], op="list")
    for line in text.splitlines():
        if w["window"] in line:
            m = re.search(r"at (-?\d+),(-?\d+) size (\d+)x(\d+)", line)
            return tuple(int(v) for v in m.groups())
    return None


def textedit_system_checks(c, ref, w, path):
    """Menus, windows, dialogs, scroll, drag and click actions on the scratch document."""
    sw = {**w, "scope": "window"}
    c.call("start", title="mx whole-Mac checks", mode="background")

    text, is_err = c.call("snapshot", scope="menubar", **w)
    check("snapshot scope menubar lists the Apple and File menus",
          not is_err and 'menubaritem "Apple"' in text and 'menubaritem "File"' in text, text[:300])

    # A snapshot of another scope replaces the refs, so take the text area's ref afresh.
    snap, _ = c.call("snapshot", **sw)
    ref = re.search(r"(e\d+) textarea", snap).group(1)
    text, is_err = c.call("menu", path=["View", "Zoom In"], **sw)
    print(f"      menu: {text.splitlines()[0]}")
    check("menu View > Zoom In runs (borrowing the front for a background app)", not is_err and text.startswith("ran View > Zoom In"), text)
    text, is_err = c.call("menu", path=["view", "actual"], **sw)
    check("menu matches by prefix, ignoring case", not is_err and text.startswith("ran View > Actual Size"), text)
    text, is_err = c.call("menu", path=["Apple", "No Such Item"], **sw)
    check("menu reaches the Apple menu and lists its items on a miss",
          is_err and "under Apple" in text and "About This Mac" in text, text)
    text, is_err = c.call("menu", path=["Edit", "Delete"], **sw)
    check("menu refuses a delete-style item without confirm", is_err and text.startswith("refused:"), text)

    # Dialogs: Export as PDF… shows a save sheet. Snapshot it, type a name, check the
    # permission-prompt phrase gate on it, then Cancel.
    text, is_err = c.call("menu", path=["File", "Export as PDF"], **sw)
    check("menu with an ellipsis title opens the save sheet", not is_err and "sheet" in text, text)
    text, is_err = c.call("snapshot", scope="windows", **w)
    # The sheet's name field by its name: the first textbox can be a file in the browser,
    # and filling that renames the user's file.
    m = re.search(r'(e\d+) textbox "Save As:"', text)
    check("scope windows shows the sheet with its Cancel button and name field",
          not is_err and "sheet" in text and 'button "Cancel"' in text and m, text)
    if m:
        name_ref = m.group(1)
        text, is_err = c.call("fill", ref=name_ref, text="Agent would like to access your Mac", scope="windows", **w)
        check("fill types into the save sheet's name field", not is_err and "filled textbox" in text, text)
        text, is_err = c.call("click", role="button", name="Show Details", scope="windows", **w)
        check("a sheet whose text asks to access the Mac is treated as a permission prompt",
              is_err and "permission prompt" in text, text)
    text, is_err = c.call("click", role="button", name="Cancel", scope="windows", **w)
    check("Cancel closes the sheet", not is_err and re.search(r"- e\d+ sheet", text), text)

    # Click actions on the text area.
    c.call("fill", ref=ref, text="\n".join(f"line {i}" for i in range(1, 301)), **sw)
    text, is_err = c.call("click", ref=ref, action="showmenu", **sw)
    check("click action showmenu opens the context menu", not is_err and re.search(r"\+ e\d+ menu", text), text[:200])
    text, is_err = c.call("click", role="menu", action="cancel", scope="app", **w)
    check("click action cancel closes the context menu", not is_err and re.search(r"- e\d+ menu", text), text[:200])
    text, is_err = c.call("click", ref=ref, button="right", **sw)
    check("click button right opens the context menu with a right-click",
          not is_err and "right-clicked at" in text and re.search(r"\+ e\d+ menu", text), text[:200])
    c.call("click", role="menu", action="cancel", scope="app", **w)
    text, is_err = c.call("click", ref=ref, count=2, **sw)
    check("click count 2 double-clicks", not is_err and "double-clicked at" in text, text)
    text, is_err = c.call("click", ref=ref, action="increment", **sw)
    check("click with an action the element lacks names the ones it has", is_err and "has no AXIncrement" in text, text)

    # Scroll.
    text, is_err = c.call("scroll", direction="down", amount=2, **sw)
    print(f"      scroll: {text.splitlines()[0]}")
    m = re.search(r"(\d+)% -> (\d+)%", text)
    check("scroll down moves the scroll bar", not is_err and m and int(m.group(2)) > int(m.group(1)), text)
    text, is_err = c.call("scroll", direction="up", amount=50, **sw)
    check("scroll up returns to the top", not is_err and text.split("\n")[0].endswith("-> 0%"), text)
    c.call("scroll", direction="down", amount=3, **sw)
    text, is_err = c.call("scroll", role="textarea", **sw)
    check("scroll without direction brings the element into view (no AXScrollToVisible: moves its scroll area)",
          not is_err and ("into view" in text or "already in view" in text), text)

    # Windows: list, move, resize, minimize, fullscreen, drag by the title bar, restore.
    orig = window_frame(c, w)
    check("window list shows the scratch window with its frame", orig is not None, orig)
    try:
        text, is_err = c.call("window", op="move", x=120, y=110, **w)
        check("window move reads back the new position", not is_err and "at 120,110" in text, text)
        text, is_err = c.call("window", op="resize", w=620, h=420, **w)
        check("window resize reads back the new size", not is_err and "size 620x420" in text, text)
        text, is_err = c.call("window", op="minimize", **w)
        check("window minimize", not is_err and "minimized" in text, text)
        text, is_err = c.call("window", op="unminimize", **w)
        check("window unminimize", not is_err and "minimized" not in text, text)
        x, y, wd, _ = window_frame(c, w)
        # Grab the title bar left of the title, clear of the traffic lights and the document button.
        text, is_err = c.call("drag", **{"from": {"x": x + 100, "y": y + 12}, "to": {"x": x + 160, "y": y + 62}}, **sw)
        moved = window_frame(c, w)
        print(f"      drag: {text.splitlines()[0]}; window {x},{y} -> {moved[0]},{moved[1]}")
        check("drag by the title bar moves the window by about (60, 50)",
              not is_err and abs(moved[0] - x - 60) <= 10 and abs(moved[1] - y - 50) <= 10, (text, moved))
        text, is_err = c.call("window", op="fullscreen", **w)
        check("window fullscreen", not is_err and "fullscreen)" in text, text)
        text, is_err = c.call("window", op="exit_fullscreen", **w)
        check("window exit_fullscreen", not is_err and "fullscreen" not in text.split("now ", 1)[-1], text)
        c.call("key", ref=ref, key="x", **sw)  # an unsaved change
        listed, _ = c.call("window", app=w["app"], op="list")
        if check("a typed key marks the window edited", any(w["window"] in l and "edited" in l for l in listed.splitlines()), listed):
            text, is_err = c.call("window", op="close", **w)
            check("window close refuses a window with unsaved changes", is_err and "unsaved changes" in text, text)
    finally:
        if orig:
            c.call("window", op="move", x=orig[0], y=orig[1], **w)
            c.call("window", op="resize", w=orig[2], h=orig[3], **w)
    c.call("snapshot", scope="window", **w)  # later calls use the window scope again
    c.call("done", summary="whole-Mac TextEdit checks")


def system_ui_checks():
    """list_apps all, the system scope, Control Center (brightness end to end, volume, toggles
    read only), hardware keys, the Dock, Notification Center and Spotlight, read only."""
    c = Client()
    c.request("initialize", {"protocolVersion": "2025-06-18"})
    c.call("start", title="mx system UI checks")
    try:
        text, is_err = c.call("list_apps", all=True)
        check("list_apps all lists system processes and the system pseudo-app",
              not is_err and "\nsystem (" in text and "com.apple.dock" in text and "(system:" in text, text[:400])
        text, is_err = c.call("list_apps")
        check("list_apps without all lists only regular apps", not is_err and "(system:" not in text, text[:200])

        text, is_err = c.call("snapshot", app="Dock")
        check("the Dock reads as dock items (read only)", not is_err and text.count("dockitem") >= 3, text[:300])
        text, is_err = c.call("snapshot", app="Notification Center")
        check("Notification Center resolves and reads (read only)", not is_err and text.startswith("Notification Center"), text[:200])
        text, is_err = c.call("snapshot", app="ControlCenter")
        check("ControlCenter resolves by bundle id tail", not is_err, text[:200])

        text, is_err = c.call("snapshot", app="system")
        check("app system lists the menu bar extras", not is_err and "menubaritem" in text and "Control Cent" in text, text[:400])
        control_center_checks(c)
        spotlight_check(c)
    finally:
        c.call("done", summary="system UI checks")
        c.close()


def control_center_checks(c):
    """Opens Control Center, runs the brightness scenario and the volume checks (each
    restored to the original raw value), reads the toggles, and closes the panel."""
    text, is_err = c.call("click", app="system", role="menubaritem", name="Control Cent")
    check("pressing the Control Center extra opens its panel", not is_err and "slider" in text, text[:300])
    snap, _ = c.call("snapshot", app="system")
    toggles = checkbox_states(snap)
    print(f"      toggles (read only): {toggles}")
    check("toggles read as on or off", any(n.startswith("Wi") for n in toggles) and any(n.startswith("Bluetooth") for n in toggles), toggles)
    bright = {"app": "system", "role": "slider", "name": "display brightness"}
    vol = {"app": "system", "role": "slider", "name": "sound volume"}

    text, is_err = c.call("read", **bright)
    m = re.match(r"(\d+)% \(([\d.]+)\)", text)
    check("the brightness slider reads as a percent and a raw value", not is_err and m, text)
    if m:
        pct, raw = int(m.group(1)), m.group(2)
        target = min(pct + 10, 100)
        try:
            text, is_err = c.call("fill", text=f"{target}%", **bright)
            back, _ = c.call("read", **bright)
            print(f"      brightness: {pct}% ({raw}) -> {text.splitlines()[0]} -> read {back}")
            check(f"brightness set to the original + 10 ({target}%) reads back",
                  not is_err and back.startswith(f"{target}%"), (text, back))
        finally:
            text, _ = c.call("fill", text=raw, **bright)
            back, _ = c.call("read", **bright)
            print(f"      brightness restored: {text.splitlines()[0]} -> read {back}")
            check("brightness restored to the original raw value", back.endswith(f"({float(raw):.4g})"), (raw, back))

    text, _ = c.call("read", **vol)
    mv = re.match(r"(\d+)% \(([\d.]+)\)", text)
    check("the volume slider reads as a percent", mv, text)
    if mv:
        raw = mv.group(2)
        try:
            text, is_err = c.call("click", action="increment", **vol)
            check("click action increment raises the volume slider", not is_err and "AXIncrement" in text and "slider" in text, text)
            text, is_err = c.call("click", action="decrement", **vol)
            check("click action decrement lowers it", not is_err and "AXDecrement" in text, text)
            before, _ = c.call("read", **vol)
            text, is_err = c.call("key", key="volume_down" if float(raw) > 0.5 else "volume_up")
            after = before
            deadline = time.time() + 1.5
            while time.time() < deadline:
                after, _ = c.call("read", **vol)
                if after != before:
                    break
                time.sleep(0.1)
            print(f"      volume hardware key: {before} -> {after}")
            check("hardware volume key changes the volume and says it can't read back",
                  not is_err and "can't be read back" in text and after != before, (text, before, after))
        finally:
            c.call("fill", text=raw, **vol)
            back, _ = c.call("read", **vol)
            check("volume restored to the original raw value", back.endswith(f"({float(raw):.4g})"), (raw, back))

    text, is_err = c.call("key", app="system", key="escape")
    deadline = time.time() + 2
    while time.time() < deadline:
        snap, _ = c.call("snapshot", app="system")
        if 'window "Control' not in snap:
            break
        time.sleep(0.2)
    check("escape closes the Control Center panel", 'window "Control' not in snap, snap[:300])
    check("toggles unchanged after the checks", checkbox_states_after(c, toggles), toggles)


def checkbox_states_after(c, before):
    """Reopens nothing: compares toggles only if the panel is still open. Toggles are never
    pressed in these checks, so this guards against an accidental flip."""
    snap, _ = c.call("snapshot", app="system")
    now_states = checkbox_states(snap)
    return all(now_states.get(k, v) == v for k, v in before.items())


def spotlight_check(c):
    """Spotlight: open it from its menu extra, read it, Escape. Read only."""
    text, is_err = c.call("snapshot", app="Spotlight", scope="extras")
    m = re.search(r'(e\d+) menubaritem "Spotlight"', text)
    if is_err or not m:
        not_run("Spotlight opens, reads and closes", f"no Spotlight menu extra: {text[:120]}")
        return
    c.call("click", app="Spotlight", ref=m.group(1), scope="extras")
    time.sleep(0.8)
    text, is_err = c.call("snapshot", app="Spotlight", scope="windows")
    if is_err:
        not_run("Spotlight opens, reads and closes",
                f"pressing (and clicking) its menu extra opens no window on this Mac: {text}")
        return
    print("      spotlight:\n" + "\n".join("        " + l for l in text.splitlines()[:6]))
    check("Spotlight's window reads", "textbox" in text or "searchbox" in text or "textfield" in text, text[:300])
    c.call("key", app="Spotlight", key="escape")
    deadline = time.time() + 2
    while time.time() < deadline and "has no windows" not in c.call("window", app="Spotlight", op="list")[0]:
        time.sleep(0.2)
    check("escape closes Spotlight", "has no windows" in c.call("window", app="Spotlight", op="list")[0])


def app_open_clipboard_checks():
    """app launch/hide/unhide/quit on Calculator (only if it wasn't running), refusals,
    open, and the clipboard (restored afterwards)."""
    c = Client()
    c.request("initialize", {"protocolVersion": "2025-06-18"})
    c.call("start", title="mx app checks")
    try:
        apps, _ = c.call("list_apps")
        if "com.apple.calculator" in apps:
            not_run("app launch/hide/unhide/quit", "Calculator is already running; not quitting the user's copy")
        else:
            front0 = frontmost()
            text, is_err = c.call("app", op="launch", name="Calculator")
            check("app launch starts Calculator in the background", not is_err and "launched Calculator" in text
                  and "(in the background)" in text, text)
            time.sleep(0.5)
            check("background launch leaves the front app alone", frontmost() == front0, (front0, frontmost()))
            text, is_err = c.call("app", op="hide", name="Calculator")
            check("app hide", not is_err and text == "hid Calculator", text)
            text, is_err = c.call("app", op="unhide", name="Calculator")
            check("app unhide", not is_err and text == "unhid Calculator", text)
            text, is_err = c.call("app", op="force_quit", name="Calculator")
            check("app force_quit needs confirm", is_err and text.startswith("refused:"), text)
            text, is_err = c.call("app", op="quit", name="Calculator")
            check("app quit", not is_err and text == "quit Calculator", text)
        text, is_err = c.call("app", op="launch", name="Terminal")
        check("app launch refuses a terminal and says why", is_err and "shell commands" in text, text)
        text, is_err = c.call("open", target="https://example.com", **{"with": "Terminal"})
        check("open refuses a target that would open in a terminal", is_err and "terminal" in text, text)
        text, is_err = c.call("open", target="settings:no-such-pane")
        check("open settings: with an unknown pane lists the known ones", is_err and "displays" in text and "lock-screen" in text, text)
        text, is_err = c.call("open", target="/no/such/file.txt")
        check("open a missing file is an error", is_err and "no such file" in text, text)

        orig = subprocess.run(["pbpaste"], capture_output=True).stdout
        try:
            text, is_err = c.call("clipboard", op="set", text="mx clipboard check")
            check("clipboard set", not is_err and "18 characters" in text, text)
            text, is_err = c.call("clipboard", op="get")
            check("clipboard get needs confirm", is_err and text.startswith("refused:"), text)
            text, is_err = c.call("clipboard", op="get", confirm=True)
            check("clipboard get with confirm returns the text", not is_err and text == "mx clipboard check", text)
        finally:
            subprocess.run(["pbcopy"], input=orig)

        text, is_err = c.call("click", app="universalAccessAuthWarn", role="menubar")
        if "app not running" in text:
            not_run("permission prompt process is refused", "universalAccessAuthWarn is not running")
        else:
            check("anything in universalAccessAuthWarn is refused as a permission prompt", is_err and "permission prompt" in text, text)
    finally:
        c.call("done", summary="app checks")
        c.close()


# Panes and the title each must show (General has an empty title; its sidebar row names it).
PANES = {"displays": "Displays", "sound": "Sound", "network": "Network", "wifi": "Wi", "bluetooth": "Bluetooth",
         "keyboard": "Keyboard", "trackpad": "Trackpad", "mouse": "Mouse", "dock": "Desktop & Dock",
         "desktop": "Desktop & Dock", "appearance": "Appearance", "notifications": "Notifications", "focus": "Focus",
         "battery": "Battery", "general": "General", "privacy": "Privacy & Security", "users": "Users & Groups",
         "login-items": "Login Items", "sharing": "Sharing", "lock-screen": "Lock Screen"}


def settings_checks():
    """Opens each settings pane mx ships and checks the title; then the gate test in
    Privacy & Security. Navigate and read only; confirm=true is never passed here."""
    c = Client()
    c.request("initialize", {"protocolVersion": "2025-06-18"})
    c.call("start", title="mx settings checks")
    was_running = "com.apple.systempreferences" in c.call("list_apps")[0]
    verified, unverified = [], []
    try:
        for name, want in PANES.items():
            text, is_err = c.call("open", target=f"settings:{name}")
            ok = not is_err and f"System Settings > {want}" in text
            if name == "mouse" and not ok and "pane didn't change" in text:
                unverified.append(name)
                not_run("settings:mouse opens Mouse", f"no mouse connected, so macOS doesn't show the pane: {text}")
                continue
            (verified if ok else unverified).append(name)
            check(f"open settings:{name} shows {want}", ok, text)
        print(f"      panes verified: {', '.join(verified)}; not verified: {', '.join(unverified) or 'none'}")

        # Scroll into view without AXScrollToVisible: the sidebar's last row, then the first.
        snap, _ = c.call("snapshot", app="System Settings")
        rows = re.findall(r"^(e\d+) row", snap, re.M)
        text, is_err = c.call("scroll", app="System Settings", ref=rows[-1])
        print(f"      scroll into view: {text.splitlines()[0]}")
        check("scroll a sidebar row into view (no AXScrollToVisible) reveals rows below",
              not is_err and "into view" in text and re.search(r"\+ e\d+ button", text), text[:300])
        text, is_err = c.call("scroll", app="System Settings", ref=rows[0])
        check("scroll the first row back into view", not is_err and "into view" in text, text[:200])

        text, is_err = c.call("open", target="x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")
        print(f"      gate pane: {text}")
        snap, _ = c.call("snapshot", app="System Settings")
        m = re.search(r"(e\d+) checkbox", snap)
        if not m:
            not_run("Privacy & Security gate", f"no toggle in the pane: {snap[:200]}")
            return
        ref = m.group(1)
        # Probe with an action a toggle doesn't have: if the gate were broken, nothing changes.
        text, is_err = c.call("click", app="System Settings", ref=ref, action="increment")
        probe_ok = is_err and text.startswith("refused:") and "Privacy & Security" in text
        check("Privacy & Security gate refuses a change without confirm (safe probe)", probe_ok, text)
        if probe_ok:
            text, is_err = c.call("click", app="System Settings", ref=ref)
            check("pressing a Privacy & Security toggle without confirm is refused", is_err and text.startswith("refused:"), text)
            text, is_err = c.call("key", app="System Settings", key="z")
            check("a key in Privacy & Security without confirm is refused", is_err and text.startswith("refused:"), text)
            text, is_err = c.call("key", app="System Settings", key="tab")
            check("navigation keys stay allowed there", not is_err, text)
        snap2, _ = c.call("snapshot", app="System Settings")
        check("no toggle changed in the gate pane", checkbox_states(snap2) == checkbox_states(snap),
              (checkbox_states(snap), checkbox_states(snap2)))
    finally:
        if not was_running:
            c.call("app", op="quit", name="System Settings")
        c.call("done", summary="settings checks")
        c.close()


# ---------------------------------------------------------------------------
# fix10 GUI checks. The user works on this Mac, so each group runs once, only after
# 5 s without their keyboard or mouse (60 s at most), and is NOT RUN otherwise.

def gui_idle_gate(name, need=5.0, cap=60.0):
    """Waits for the user to be idle `need` seconds, up to `cap`. False (and NOT RUN) if not."""
    deadline = time.time() + cap
    while time.time() < deadline:
        if user_idle_seconds() >= need:
            return True
        time.sleep(0.5)
    not_run(name, f"user active: not idle for {need:.0f} s within {cap:.0f} s")
    return False


WINDOWS = """ObjC.import('CoreGraphics');
JSON.stringify(ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0)))
  .filter(w => w.kCGWindowAlpha > 0)
  .map(w => [w.kCGWindowNumber, w.kCGWindowOwnerPID, w.kCGWindowOwnerName, w.kCGWindowLayer,
             w.kCGWindowBounds.X, w.kCGWindowBounds.Y, w.kCGWindowBounds.Width, w.kCGWindowBounds.Height]));"""


def window_list():
    """On-screen windows front to back: (id, pid, owner, layer, (x, y, w, h)) in global top-left coordinates."""
    return [(r[0], r[1], r[2], r[3], tuple(r[4:])) for r in json.loads(jxa(WINDOWS) or "[]")]


def mx_windows(c, wins):
    """mx's windows in `wins`, as (index, kind, frame): pointer (screen-sized), wave (24 pt high) or border."""
    sw, sh = screen_size()
    out = []
    for i, (_, pid, _, _, f) in enumerate(wins):
        if pid == c.p.pid:
            out.append((i, "pointer" if f[2:] == (sw, sh) else "wave" if f[3] == 24 else "border", f))
    return out


def new_finder_window(bounds):
    """Opens a Finder window of our own at bounds {left, top, right, bottom} and brings
    Finder forward. Returns its id, so cleanup closes only that window."""
    r = subprocess.run(["osascript", "-e", 'tell application "Finder"\nset w to make new Finder window\n'
                        f'set bounds of w to {{{", ".join(map(str, bounds))}}}\nactivate\nreturn id of w\nend tell'],
                       capture_output=True, text=True)
    time.sleep(0.5)
    return r.stdout.strip()


def move_finder_window(wid, bounds):
    """Moves our Finder window to bounds {left, top, right, bottom}."""
    subprocess.run(["osascript", "-e", f'tell application "Finder" to set bounds of (first Finder window whose id is {wid}) '
                    f'to {{{", ".join(map(str, bounds))}}}'], capture_output=True)
    time.sleep(0.5)


def close_finder_window(wid):
    """Closes our Finder window, if we opened one."""
    if wid:
        subprocess.run(["osascript", "-e", f'tell application "Finder" to close (first Finder window whose id is {wid})'],
                       capture_output=True)


def indicator_group():
    """Border + waveform on a scratch TextEdit window: the border is ordered directly above
    the window; a Finder window covering it hides the border and shows the pill at the
    bottom of the screen; uncovered, the border and the waveform below the window come
    back; at most one tag-text overlay at a time (indicator_checks); one screenshot."""
    if not gui_idle_gate("indicator checks (border, waveform, pill, screenshot)"):
        return
    scratch_dir = os.path.join(ROOT, "tests", "scratch")
    os.makedirs(scratch_dir, exist_ok=True)
    fname = f"mx-selftest-{os.getpid()}.txt"
    path = os.path.join(scratch_dir, fname)
    with open(path, "w") as f:
        f.write("seed text")
    c = Client()
    c.request("initialize", {"protocolVersion": "2025-06-18"})
    subprocess.run(["open", "-a", "TextEdit", path], check=True)
    w = {"app": "TextEdit", "window": fname}
    fw = None
    try:
        c.call("start", title="mx indicator check", mode="background")
        deadline = time.time() + 10
        while True:
            text, is_err = c.call("snapshot", **w)
            if not is_err or time.time() > deadline:
                break
            time.sleep(0.3)
        ref = re.search(r"(e\d+) textarea", text).group(1)
        x, y, ww, wh = 80, 120, 760, 480
        c.call("window", op="move", x=x, y=y, **w)
        c.call("window", op="resize", w=ww, h=wh, **w)
        frame = window_frame(c, w)
        sw, sh = screen_size()

        # Covered: a Finder window over the whole scratch window.
        fw = new_finder_window([x - 20, y - 20, x + ww + 40, y + wh + 40])
        c.call("fill", ref=ref, text="covered", **w)
        time.sleep(0.5)
        mine = mx_windows(c, window_list())
        kinds = [k for _, k, _ in mine]
        wave = next((f for _, k, f in mine if k == "wave"), None)
        print(f"      covered: mx windows {[(k, f) for _, k, f in mine]}")
        check("covered window: the border hides", "border" not in kinds, mine)
        check("covered window: the waveform shows as a pill at the bottom center of the screen",
              wave is not None and abs(wave[0] + wave[2] / 2 - sw / 2) <= 2 and wave[1] > sh - 200, (wave, sw, sh))
        # fix20: the fallback says why on stderr, naming the covering app, so a recording that
        # leaves Finder out (the target looks uncovered there) can be explained.
        hidden = [l for l in c.stderr if "border hidden" in l]
        check("covered window: stderr says the border is hidden and names Finder",
              any("TextEdit window is covered by" in l and "Finder" in l for l in hidden), hidden)

        # Visible again: the border directly above the window, the waveform below it.
        move_finder_window(fw, [sw - 520, 120, sw - 40, 480])
        c.call("fill", ref=ref, text="visible", **w)
        time.sleep(0.5)
        wins = window_list()
        mine = mx_windows(c, wins)
        border = next(((i, f) for i, k, f in mine if k == "border"), None)
        wave = next((f for _, k, f in mine if k == "wave"), None)
        below = wins[border[0] + 1] if border and border[0] + 1 < len(wins) else None
        print(f"      visible: border {border}, next window {below and below[2:]}, wave {wave}, scratch frame {frame}")
        check("border window is ordered directly above the target window",
              border and below and below[2] == "TextEdit" and below[4] == tuple(frame), (border, below, frame))
        check("border is the window frame plus 3 pt each side",
              border and border[1] == (frame[0] - 3, frame[1] - 3, frame[2] + 6, frame[3] + 6), (border, frame))
        check("waveform sits centered just below the window",
              wave and abs(wave[0] + wave[2] / 2 - (frame[0] + frame[2] / 2)) <= 1 and 0 <= wave[1] - (frame[1] + frame[3]) <= 10,
              (wave, frame))
        check("at most one tag-text overlay (border carries no text)", sum(k != "border" for _, k, _ in mine) <= 1, mine)
        check("the hidden-border line is logged once, not every tick",
              sum("border hidden" in l for l in c.stderr) == len(hidden), [l for l in c.stderr if "border hidden" in l])

        content, is_err = c.call_content("screenshot", full=True, marks=False, _with_overlay=True, **w)
        img = next((x for x in content if x.get("type") == "image"), None)
        if not is_err and img:
            out = os.path.join(scratch_dir, "indicator-example.png")
            with open(out, "wb") as f:
                f.write(base64.b64decode(img["data"]))
            print(f"      saved {out}")
        check("indicator screenshot saved", not is_err and img is not None, content[0].get("text", "")[:200])

        indicator_checks(c, ref, w)

        text, _ = c.call("done", summary="indicator check")
        time.sleep(3.8)
        left = mx_windows(c, window_list())
        check("everything hides after done", not left, left)
    finally:
        close_finder_window(fw)
        close_scratch(c, w, path)
        c.close()
        if os.path.exists(path):
            os.remove(path)


def done_pill_group():
    """fix21, on screen: done puts the summary pill on the window of the last action, not on
    an app only read after it; and the wide done pill inside a narrow window at the screen
    bottom is no wider than the window. TextEdit and Calculator only; saves two screenshots
    to tests/scratch. Needs the user idle 60 s."""
    if not gui_idle_gate("done pill checks", need=60.0, cap=600.0):
        return
    scratch_dir = os.path.join(ROOT, "tests", "scratch")
    os.makedirs(scratch_dir, exist_ok=True)
    fname = f"mx-donepill-{os.getpid()}.txt"
    path = os.path.join(scratch_dir, fname)
    with open(path, "w") as f:
        f.write("seed text")
    had_calc = subprocess.run(["pgrep", "-x", "Calculator"], capture_output=True).returncode == 0
    c = Client()
    c.request("initialize", {"protocolVersion": "2025-06-18"})
    subprocess.run(["open", "-a", "TextEdit", path], check=True)
    subprocess.run(["open", "-a", "Calculator"], check=True)
    w = {"app": "TextEdit", "window": fname}
    sw, sh = screen_size()

    def border_and_wave():
        mine = mx_windows(c, window_list())
        return (next((f for _, k, f in mine if k == "border"), None), next((f for _, k, f in mine if k == "wave"), None))

    try:
        c.call("start", title="mx done pill check", mode="background")
        deadline = time.time() + 10
        while True:
            text, is_err = c.call("snapshot", **w)
            if not is_err or time.time() > deadline:
                break
            time.sleep(0.3)
        ref = re.search(r"(e\d+) textarea", text).group(1)
        c.call("window", app="Calculator", op="move", x=sw - 400, y=120)
        c.call("window", op="move", x=80, y=120, **w)
        c.call("window", op="resize", w=700, h=400, **w)
        frame = window_frame(c, w)
        c.call("fill", ref=ref, text="last action", **w)
        c.call("snapshot", app="Calculator")  # a read of another app after the last action
        c.call("done", summary="the pill stays on TextEdit, where the last action ran")
        time.sleep(0.6)
        border, wave = border_and_wave()
        shot = os.path.join(scratch_dir, "done-pill-last-target.png")
        subprocess.run(["screencapture", "-x", shot])
        print(f"      last target: border {border}, wave {wave}, TextEdit {frame}; saved {shot}")
        check("done: the border goes back to the window of the last action, not the app read after it",
              border == (frame[0] - 3, frame[1] - 3, frame[2] + 6, frame[3] + 6),
              (border, frame, [l for l in c.stderr if "border hidden" in l]))
        check("done: the summary pill sits under that window",
              wave is not None and abs(wave[0] + wave[2] / 2 - (frame[0] + frame[2] / 2)) <= 1, (wave, frame))
        time.sleep(3.5)

        # A narrow window at the screen bottom: the wide summary pill goes inside and fits.
        c.call("start", title="mx done pill check", mode="background")
        c.call("window", op="resize", w=320, h=300, **w)
        c.call("window", op="move", x=200, y=sh - 300, **w)
        frame = window_frame(c, w)
        c.call("fill", ref=ref, text="narrow", **w)
        c.call("done", summary="a summary long enough to make the pill far wider than this narrow window")
        time.sleep(0.6)
        border, wave = border_and_wave()
        shot = os.path.join(scratch_dir, "done-pill-narrow-window.png")
        subprocess.run(["screencapture", "-x", shot])
        print(f"      narrow: border {border}, wave {wave}, TextEdit {frame}; saved {shot}")
        check("done: the wide pill inside a narrow window is no wider than the window less 8 px a side",
              wave is not None and wave[0] >= frame[0] + 7 and wave[0] + wave[2] <= frame[0] + frame[2] - 7, (wave, frame))
        time.sleep(3.5)
    finally:
        close_scratch(c, w, path)
        c.close()
        if not had_calc:
            subprocess.run(["osascript", "-e", 'tell application "Calculator" to quit'], capture_output=True)
        if os.path.exists(path):
            os.remove(path)


def cc_group():
    """Control Center auto-open: with the panel closed, one batch of role+name steps reads
    the brightness, raises it 10 points, reads it, lowers it 10 points and reads it; the
    raw value is then checked (and set back if it drifted). Escape closes the panel."""
    if not gui_idle_gate("Control Center auto-open (brightness read, +10, restore)"):
        return
    c = Client()
    c.request("initialize", {"protocolVersion": "2025-06-18"})
    c.call("start", title="mx CC auto-open check")
    bright = {"role": "slider", "name": "display brightness"}
    raw0 = None
    try:
        snap, _ = c.call("snapshot", app="system")
        check("the Control Center panel is closed at the start", 'window "Control' not in snap, snap[:300])
        t0 = time.time()
        text, is_err = c.call("batch", app="system", steps=[
            {"action": "read", **bright}, {"action": "fill", "text": "+10%", **bright}, {"action": "read", **bright},
            {"action": "fill", "text": "-10%", **bright}, {"action": "read", **bright}])
        secs = time.time() - t0
        reads = re.findall(r"read slider \S+.*?: (\d+)% \(([\d.]+)\)", text)
        print(f"      batch in {secs:.1f} s: " + " | ".join(text.splitlines()[:6]))
        check("one batch opens the closed panel itself and runs read, +10, read, -10, read",
              not is_err and "opened Control Center" in text and len(reads) == 3, text[:500])
        if len(reads) == 3:
            (p0, raw0), (p1, _), (p2, raw2) = [(int(p), r) for p, r in reads]
            check("brightness +10 reads back 10 points up (capped at 100)", p1 == min(p0 + 10, 100), reads)
            if p0 > 90:
                print("      brightness was above 90%, so -10 doesn't land on the original; restored by raw value below")
            check("-10 brings brightness back to the original percent", p0 > 90 or p2 == p0, reads)
    finally:
        if raw0 is not None:
            back, _ = c.call("read", app="system", **bright)
            if not back.endswith(f"({float(raw0):.4g})"):
                c.call("fill", app="system", text=raw0, **bright)
                back, _ = c.call("read", app="system", **bright)
            check("brightness restored to the original raw value", back.endswith(f"({float(raw0):.4g})"), (raw0, back))
        c.call("key", app="system", key="escape")
        c.call("done", summary="CC check")
        c.close()


def with_client(fn):
    """Runs fn(c) on a fresh mx process."""
    def run():
        c = Client()
        c.request("initialize", {"protocolVersion": "2025-06-18"})
        try:
            fn(c)
        finally:
            c.close()
    return run


def fix11_group(borrows=True):
    """Borrow speed and pill text with the indicator up: three force_mouse clicks on a
    scratch TextEdit window, each borrowing the front from Finder (≤ 400 ms each, with
    mx's per-phase stderr line printed), then three rapid tag changes and a screenshot,
    cropped to the pill wherever it is (tests/scratch/pill-after-rapid-changes.png).
    borrows=False runs only the pill part."""
    if not gui_idle_gate("fix11 checks (3 borrows, pill after rapid tag changes)"):
        return
    scratch_dir = os.path.join(ROOT, "tests", "scratch")
    fname = f"mx-selftest-{os.getpid()}.txt"
    path = os.path.join(scratch_dir, fname)
    with open(path, "w") as f:
        f.write("seed text")
    c = Client()
    c.request("initialize", {"protocolVersion": "2025-06-18"})
    subprocess.run(["open", "-a", "TextEdit", path], check=True)
    w = {"app": "TextEdit", "window": fname}
    fw = None
    try:
        c.call("start", title="mx fix11 check", mode="background")
        deadline = time.time() + 10
        while True:
            text, is_err = c.call("snapshot", **w)
            if not is_err or time.time() > deadline:
                break
            time.sleep(0.3)
        ref = re.search(r"(e\d+) textarea", text).group(1)
        x, y, ww, wh = 80, 120, 760, 480
        c.call("window", op="move", x=x, y=y, **w)
        c.call("window", op="resize", w=ww, h=wh, **w)
        sw, _ = screen_size()
        fw = new_finder_window([sw - 520, 120, sw - 40, 480])  # beside the scratch window, Finder in front

        ms = []
        for i in range(3 if borrows else 0):
            c.call("fill", ref=ref, text=f"wave {i}", **w)  # as in the fix10 borrow that took 1.1 s
            wait_user_idle()
            subprocess.run(["osascript", "-e", 'tell application "Finder" to activate'], capture_output=True)
            deadline = time.time() + 2
            while frontmost() != "com.apple.finder" and time.time() < deadline:
                time.sleep(0.1)
            time.sleep(0.3)
            text, is_err = c.call("click", ref=ref, force_mouse=True, **w)
            m = re.search(r"borrowed front from Finder for (\d+) ms", text)
            ms.append(int(m.group(1)) if m else None)
            time.sleep(0.05)
            phases = next((l for l in reversed(c.stderr) if l.startswith("mx: borrow ")), "")
            settled = next((l for l in reversed(c.stderr) if "settled" in l), "")
            print(f"      borrow {i + 1}: {text.splitlines()[0]}\n        {phases}\n        {settled}")
        if borrows:
            print(f"      borrow durations (ms): {ms}")
            check("three borrows with the indicator up each take ≤ 400 ms", all(v is not None and v <= 400 for v in ms), ms)

            time.sleep(3)  # let the borrow toast clear
        for t in ("a", "bb", "ccc"):
            c.call("fill", ref=ref, text=t, **w)
        content, is_err = c.call_content("screenshot", full=True, marks=False, _with_overlay=True, **w)
        img = next((x for x in content if x.get("type") == "image"), None)
        pill = next((f for _, k, f in mx_windows(c, window_list()) if k == "wave"), None)
        saved = False
        if not is_err and img and pill:
            full = os.path.join(scratch_dir, "pill-full.png")
            with open(full, "wb") as f:
                f.write(base64.b64decode(img["data"]))
            px = int(re.search(r"pixelWidth: (\d+)", subprocess.run(["sips", "-g", "pixelWidth", full],
                     capture_output=True, text=True).stdout).group(1))
            s = px / sw
            out = os.path.join(scratch_dir, "pill-after-rapid-changes.png")
            subprocess.run(["sips", "-c", str(int((pill[3] + 16) * s)), str(int((pill[2] + 40) * s)), "--cropOffset",
                            str(int((pill[1] - 8) * s)), str(int((pill[0] - 20) * s)), full, "--out", out], capture_output=True)
            os.remove(full)
            saved = os.path.exists(out)
            print(f"      saved {out}, pill at {pill} (read it: the tag must be legible)")
        check("pill crop after 3 rapid tag changes saved", saved, (pill, content[0].get("text", "")[:200]))
        c.call("done", summary="fix11 check")
    finally:
        close_finder_window(fw)
        close_scratch(c, w, path)
        c.close()
        if os.path.exists(path):
            os.remove(path)


def gone_within(c, limit, since):
    """Seconds from `since` until mx's process has no window on screen, or None after limit + 3 s."""
    while time.time() - since < limit + 3:
        if not mx_windows(c, window_list()):
            return time.time() - since
        time.sleep(0.1)
    return None


def fix12_group(front_eof=True):
    """Spinner pill, "mx · " prefix, 10 s idle hide and hide on stdin EOF, on a scratch
    TextEdit window: three rapid tag changes then a screenshot cropped to the pill
    (tests/scratch/spinner-pill.png), the pill's text; no done, so the overlay must be gone
    within 10.5 s of the last call; front mode, the pointer tag; then stdin EOF, gone within 1 s.
    front_eof=False stops after the idle hide."""
    if not gui_idle_gate("fix12 checks (spinner pill, mx prefix, idle and EOF hide)"):
        return
    scratch_dir = os.path.join(ROOT, "tests", "scratch")
    fname = f"mx-selftest-{os.getpid()}.txt"
    path = os.path.join(scratch_dir, fname)
    with open(path, "w") as f:
        f.write("seed text")
    c = Client()
    c.request("initialize", {"protocolVersion": "2025-06-18"})
    subprocess.run(["open", "-a", "TextEdit", path], check=True)
    w = {"app": "TextEdit", "window": fname}
    try:
        c.call("start", title="mx fix12 check", mode="background")
        deadline = time.time() + 10
        while True:
            text, is_err = c.call("snapshot", **w)
            if not is_err or time.time() > deadline:
                break
            time.sleep(0.3)
        ref = re.search(r"(e\d+) textarea", text).group(1)
        c.call("window", op="move", x=80, y=120, **w)
        c.call("window", op="resize", w=760, h=480, **w)

        for t in ("a", "bb", "ccc"):
            c.call("fill", ref=ref, text=t, **w)
        last = time.time()
        # The pill window itself, by id: a window of the user's can cover the pill in a screen capture.
        pid_wins = [r for r in window_list() if r[1] == c.p.pid and r[4][3] == 24]
        out = os.path.join(scratch_dir, "spinner-pill.png")
        if pid_wins:
            subprocess.run(["screencapture", "-x", "-o", f"-l{pid_wins[0][0]}", out], capture_output=True)
        tags, _ = c.call("_debug_tags")
        print(f"      saved {out} (read it: legible, \"mx · \", a spinner, no bars); {tags!r}")
        check("pill capture after 3 rapid tag changes saved", bool(pid_wins) and os.path.exists(out), pid_wins)
        check("pill text starts with \"mx · \"", "\npill: mx · " in tags, tags)

        took = gone_within(c, 10.5, last)
        print(f"      no done: overlay gone {took if took is None else round(took, 2)} s after the last call")
        check("no done: overlay windows gone within 10.5 s of the last call", took is not None and took <= 10.5, took)

        if not front_eof:
            return
        c.call("start", title="mx fix12 check", mode="front")
        c.call("fill", ref=ref, text="front", **w)
        tags, _ = c.call("_debug_tags")
        check("front mode: pointer tag starts with \"mx · \"", tags.startswith("pointer: mx · "), tags)

        up = bool(mx_windows(c, window_list()))
        c.p.stdin.close()
        eof = time.time()
        took = gone_within(c, 1, eof)
        print(f"      stdin EOF: overlay up before {up}, gone {took if took is None else round(took, 2)} s after")
        check("stdin EOF: overlay windows gone within 1 s", up and took is not None and took <= 1, (up, took))
        c.p.wait(timeout=10)
    finally:
        c2 = Client()
        c2.request("initialize", {"protocolVersion": "2025-06-18"})
        close_scratch(c2, w, path)
        c2.close()
        if c.p.poll() is None:
            c.close()
        if os.path.exists(path):
            os.remove(path)


def fix13_group():
    """Background mode keeps one indicator in one place: on a scratch TextEdit window that
    is frontmost, three fills while mx's windows are sampled (no pointer ever, the pill up
    throughout), the pill's step text right after the last fill
    (tests/scratch/fix13-pill-step.png) and the title 1.5 s later; a force_mouse click
    that borrows the front from a Finder window of our own (pointer during the borrow,
    gone after with the pill back); a screenshot whose capture never answers
    (`_fake_capture_hang`) errors in about 5 s and a read right after works."""
    if not gui_idle_gate("fix13 checks (background pill only, screenshot timeout)"):
        return
    scratch_dir = os.path.join(ROOT, "tests", "scratch")
    fname = f"mx-selftest-{os.getpid()}.txt"
    path = os.path.join(scratch_dir, fname)
    with open(path, "w") as f:
        f.write("seed text")
    c = Client()
    c.request("initialize", {"protocolVersion": "2025-06-18"})
    subprocess.run(["open", "-a", "TextEdit", path], check=True)
    w = {"app": "TextEdit", "window": fname}
    fw = None
    try:
        c.call("start", title="mx fix13 check", mode="background")
        deadline = time.time() + 10
        while True:
            text, is_err = c.call("snapshot", **w)
            if not is_err or time.time() > deadline:
                break
            time.sleep(0.3)
        ref = re.search(r"(e\d+) textarea", text).group(1)
        c.call("window", op="move", x=80, y=120, **w)
        c.call("window", op="resize", w=760, h=480, **w)
        front = frontmost()
        print(f"      frontmost before the fills: {front}")

        out = os.path.join(scratch_dir, "fix13-pill-step.png")
        got = {}

        def fills():
            for t in ("a", "bb", "ccc"):
                c.call("fill", ref=ref, text=t, **w)
            pill = [r for r in window_list() if r[1] == c.p.pid and r[4][3] == 24]
            if pill:
                subprocess.run(["screencapture", "-x", "-o", f"-l{pill[0][0]}", out], capture_output=True)
            got["step"] = c.call("_debug_tags")[0]

        samples, t0, t1 = sample_overlays(c, 4, fills)
        during = [k for t, k in samples if t0 <= t <= t1]
        print(f"      {len(samples)} samples, {len(during)} during the fills; right after: {got.get('step')!r}")
        check("background, TextEdit frontmost: no pointer window during 3 fills",
              front == "com.apple.TextEdit" and samples and not any("pointer" in k for _, k in samples),
              (front, sorted({x for _, k in samples for x in k})))
        check("background: the pill is up throughout the fills", during and all("wave" in k for k in during),
              sum("wave" not in k for k in during))
        check("pill reads \"mx · Paste 3 characters\" right after a fill",
              "\npill: mx · Paste 3 characters" in got.get("step", "") and os.path.exists(out), got.get("step"))
        time.sleep(1.5)
        tags, _ = c.call("_debug_tags")
        check("1.5 s later the pill reads the title", "\npill: mx · mx fix13 check" in tags and "pointer: -" in tags, tags)

        sw, _ = screen_size()
        fw = new_finder_window([sw - 520, 120, sw - 40, 480])  # Finder in front, so the click borrows
        wait_user_idle()
        samples, t0, t1 = sample_overlays(c, 3, lambda: got.update(click=c.call("click", ref=ref, force_mouse=True, **w)))
        text, is_err = got["click"]
        during = [k for t, k in samples if t0 <= t <= t1]
        after = [k for t, k in samples if t > t1 + 0.1]
        print(f"      click: {text.splitlines()[0]}; {len(during)} samples during, {len(after)} after")
        check("force_mouse click: the pointer shows during the borrow",
              not is_err and "borrowed front" in text and any("pointer" in k for k in during), text.splitlines()[0])
        check("force_mouse click: pointer gone after, pill back",
              after and not any("pointer" in k for k in after) and all("wave" in k for k in after), after[:3])

        t = time.time()
        text, is_err = c.call("screenshot", _fake_capture_hang=True, **w)
        took = time.time() - t
        print(f"      hung capture: {round(took, 2)} s, {text!r}")
        check("hung capture errors in about 5 s", is_err and "didn't respond within 5 s" in text and 4.5 <= took <= 6.5,
              (round(took, 2), text))
        text, is_err = c.call("read", ref=ref, **w)
        check("a read right after the hung capture works", not is_err, text[:120])
        c.call("done", summary="fix13 check")
    finally:
        close_finder_window(fw)
        close_scratch(c, w, path)
        c.close()
        if os.path.exists(path):
            os.remove(path)


# MARK: audit log (no GUI: start, refused clipboard get and _debug_audit only, in a scratch HOME)

def audit_env(home, **extra):
    # Empty counts as unset in mx; Client merges os.environ, so blank the agent app's own ids.
    return {**os.environ, "CLAUDE_CODE_SESSION_ID": "", "CODEX_THREAD_ID": "", "CLAUDE_PROJECT_DIR": "", "HOME": home, **extra}


def audit_client(home, **extra):
    c = Client(env=audit_env(home, **extra))
    c.request("initialize", {"protocolVersion": "2025-06-18", "clientInfo": {"name": "claude-code", "version": "0"}})
    return c


def audit_files(home):
    d = os.path.join(home, "Library", "Application Support", "mx", "sessions")
    return sorted(os.path.join(d, f) for f in os.listdir(d) if ".jsonl" in f) if os.path.isdir(d) else []


def audit_lines(path):
    with open(path) as f:
        return [json.loads(l) for l in f if l.strip()]


def mx_cli(home, *args, **extra):
    return subprocess.run([BIN, *args], capture_output=True, text=True, timeout=30, env=audit_env(home, **extra))


def write_config(home, cfg):
    d = os.path.join(home, "Library", "Application Support", "mx")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "config.json"), "w") as f:
        json.dump(cfg, f)


def audit_checks():
    import hashlib
    import tempfile
    tmp = tempfile.mkdtemp(prefix="mx-audit-")

    # Session ids: derived from the agent app's session, else mx-<yyyymmdd>-<6 hex> per connection.
    home = os.path.join(tmp, "ids")
    for env, harness in (({"CLAUDE_CODE_SESSION_ID": "abc-123"}, "claude-code"), ({"CODEX_THREAD_ID": "th-9"}, "codex")):
        c = audit_client(home, **env)
        c.call("start", title="id check")
        c.close()
        want = "mx-" + hashlib.sha256(f"{harness}/{list(env.values())[0]}".encode()).hexdigest()[:12]
        files = [os.path.basename(f) for f in audit_files(home)]
        check(f"audit: {harness} session id is mx- + sha256(harness/id)[:12]", f"{want}.jsonl" in files, files)
        r = mx_cli(home, "history", "current", **env)
        check(f"audit: mx history current finds the {harness} session", r.returncode == 0 and want in r.stdout, r.stdout + r.stderr)
    c = audit_client(home)
    c.call("start", title="no harness")
    c.close()
    plain = [f for f in audit_files(home) if re.search(r"/mx-\d{8}-[0-9a-f]{6}\.jsonl$", f)]
    check("audit: outside an agent app the id is mx-<yyyymmdd>-<6 hex>", len(plain) == 1, audit_files(home))
    h = audit_lines(plain[0])[0] if plain else {}
    check("audit: header line has v 1, type session, tool mx", h.get("v") == 1 and h.get("type") == "session" and h.get("tool") == "mx", h)

    # Two processes appending to one session at once: no torn or lost lines. Some lines are
    # longer than PIPE_BUF (512), which takes the flock path.
    home = os.path.join(tmp, "concurrent")
    env = {"CLAUDE_CODE_SESSION_ID": "shared"}
    cs = [audit_client(home, **env) for _ in range(2)]
    n = 1500
    for i, c in enumerate(cs):
        long = "x" * (600 if i else 10)
        c.p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 99, "method": "tools/call", "params": {
            "name": "_debug_audit", "arguments": {"op": "start", "n": n, "args": {"title": f"p{i} {long}"}}}}) + "\n")
    times = [c.q.get(timeout=60)["result"]["content"][0]["text"] for c in cs]
    for c in cs:
        c.close()
    files = audit_files(home)
    raw = open(files[0]).read().splitlines() if len(files) == 1 else []
    parsed = []
    for l in raw:
        try:
            parsed.append(json.loads(l))
        except ValueError:
            pass
    check("audit: 2 processes x 1500 appends to one file, every line whole",
          len(files) == 1 and len(raw) == 2 * n + 1 and len(parsed) == len(raw)
          and sum(1 for e in parsed if e.get("type") == "session") == 1, (files, len(raw), len(parsed)))
    print(f"      write cost: {times}")

    # Values: lengths only by default; full keeps them; off also drops window titles and names.
    home = os.path.join(tmp, "values")
    fill = {"op": "fill", "app": "Slack", "window": "DM - Alex", "to": "Thread", "element": ["textbox", "Message to Alex"],
            "args": {"text": "hunter2 secret"}}
    for level in ("on", "full", "off"):
        write_config(home, {"log": {"values": level}})
        c = audit_client(home, CLAUDE_CODE_SESSION_ID=f"values-{level}")
        c.call("_debug_audit", **fill)
        c.call("_debug_audit", op="clipboard", args={"op": "set", "text": "hunter2"})
        c.close()
    by = {}
    for f in audit_files(home):
        es = audit_lines(f)
        by[es[0]["harness_session"].split("-")[1]] = es[1:]
    on, full, off = by.get("on", []), by.get("full", []), by.get("off", [])
    check("audit: values on logs lengths, never the text",
          len(on) == 2 and on[0]["target"] == 'textbox "Message to Alex" text (14 chars)' and on[1]["target"] == "set text (7 chars)"
          and "hunter2" not in json.dumps(on), on)
    check("audit: values full keeps the text", len(full) == 2 and "hunter2 secret" in full[0]["target"] and "hunter2" in full[1]["target"], full)
    check("audit: values off drops window, to and element names",
          len(off) == 2 and off[0]["target"] == "textbox text (14 chars)" and "window" not in off[0] and "to" not in off[0]
          and "Alex" not in json.dumps(off), off)

    # URLs given to open lose query, fragment and user:password; full keeps them.
    home = os.path.join(tmp, "urls")
    url = "https://user:pw@example.com/reset/confirm?token=abc123#step2"
    c = audit_client(home, CLAUDE_CODE_SESSION_ID="urls")
    c.call("_debug_audit", op="open", args={"target": url})
    c.call("_debug_audit", op="open", args={"target": "settings:privacy"})
    c.close()
    es = audit_lines(audit_files(home)[0])[1:]
    check("audit: open URL scrubbed to https://example.com/reset/confirm, settings panes kept",
          [e["target"] for e in es] == ["https://example.com/reset/confirm", "settings:privacy"], es)

    # Settings: the agent can raise retention only; the user at a terminal can do anything.
    home = os.path.join(tmp, "settings")
    c = audit_client(home, CLAUDE_CODE_SESSION_ID="settings")
    raise_text, raise_err = c.call("settings", key="log.max", value="10GB")
    lower_text, lower_err = c.call("settings", key="log.days", value="30")
    values_text, values_err = c.call("settings", key="log.values", value="off")
    small_text, small_err = c.call("settings", key="log.archive_max", value="1GB")
    read_text, _ = c.call("settings")
    c.close()
    check("audit: settings tool raises log.max", not raise_err and "10GB" in read_text, raise_text)
    check("audit: settings tool can't lower log.days, log.archive_max or change log.values, and names the command",
          lower_err and values_err and small_err and "mx config set log.days 30" in lower_text
          and "mx config set log.values off" in values_text, (lower_text, values_text, small_text))
    es = audit_lines(audit_files(home)[0])[1:]
    check("audit: each refused settings change is logged as refused",
          sum(1 for e in es if e.get("refused") == "agent lowers logging") == 3, es)
    r = mx_cli(home, "config", "set", "log.days", "30")
    r2 = mx_cli(home, "config")
    check("audit: mx config set at the terminal lowers it", r.returncode == 0 and re.search(r"log.days\s+30", r2.stdout), r.stdout + r.stderr + r2.stdout)

    # A refusal from a real safety rule gets its own line, with the rule.
    home = os.path.join(tmp, "refusal")
    c = audit_client(home, CLAUDE_CODE_SESSION_ID="refusal")
    c.call("clipboard", op="get")
    c.close()
    es = audit_lines(audit_files(home)[0])[1:]
    check("audit: a refused call is logged with refused: <rule>", len(es) == 1 and es[0].get("refused") == "clipboard read", es)

    # Pins: name the latest finished task, list, show, and never overwrite.
    home = os.path.join(tmp, "pins")
    env = {"CLAUDE_CODE_SESSION_ID": "pins"}
    c = audit_client(home, **env)
    c.call("start", title="Send the weekly report")
    c.call("_debug_audit", op="fill", app="Mail", window="New Message", element=["textbox", "To:"], args={"text": "team@example.com"})
    c.call("_debug_audit", op="click", app="Mail", window="New Message", element=["button", "Send"], args={"confirm": True})
    c.call("_debug_audit", op="done", args={"summary": "sent it"})
    c.close()
    r = mx_cli(home, "history", "pin", "current", "weekly report", **env)
    check("audit: mx history pin names the task", r.returncode == 0 and 'pinned "weekly report"' in r.stdout and "2 steps" in r.stdout,
          r.stdout + r.stderr)
    r = mx_cli(home, "history", "pin", "current", "weekly report", **env)
    check("audit: pinning an existing name is refused (pins are kept forever)", r.returncode == 1 and "exists" in r.stderr, r.stderr)
    r = mx_cli(home, "history", "pinned")
    check("audit: mx history pinned lists it", '"weekly report"  "Send the weekly report"  2 steps  Mail' in r.stdout, r.stdout)
    r = mx_cli(home, "history", "pinned", "weekly report")
    check("audit: mx history pinned <name> shows the steps and how to repeat",
          'fill textbox "To:" text (16 chars)' in r.stdout and '[confirmed]' in r.stdout and "to repeat" in r.stdout, r.stdout)

    # The tree, on a fixture (times in UTC so the text is fixed).
    home = os.path.join(tmp, "tree")
    d = os.path.join(home, "Library", "Application Support", "mx", "sessions")
    os.makedirs(d)
    with open(os.path.join(ROOT, "tests", "audit-fixture.jsonl")) as src, open(os.path.join(d, "mx-fixture000001.jsonl"), "w") as dst:
        dst.write(src.read())
    r = mx_cli(home, "history", "mx-fixture", TZ="UTC")
    want = open(os.path.join(ROOT, "tests", "audit-tree.txt")).read()
    got = re.sub(r"^log: .*\n", "", r.stdout, flags=re.M)
    check("audit: history tree on the fixture matches tests/audit-tree.txt", got == want, "\n" + got)
    r = mx_cli(home, "history", TZ="UTC")
    check("audit: history list line", r.stdout.startswith("mx-fixture000001  claude-code  mx  Nov 14 09:00:00-09:00:09  \"Reply to Alex\"  5 actions, 1 failed, 1 refused  Slack"),
          r.stdout)

    # Retention at server start: past log.max the oldest idle file is gzipped, and history still reads it.
    write_config(home, {"log": {"max": "1KB"}})
    old = os.path.join(d, "mx-fixture000001.jsonl")
    os.utime(old, (time.time() - 7200, time.time() - 7200))
    c = audit_client(home, CLAUDE_CODE_SESSION_ID="retention")
    c.call("start", title="tick")
    c.close()
    r = mx_cli(home, "history", "mx-fixture", TZ="UTC")
    check("audit: retention gzips the oldest idle file past log.max; history reads the .gz",
          os.path.exists(old + ".gz") and not os.path.exists(old) and re.sub(r"^log: .*\n", "", r.stdout, flags=re.M) == want,
          (os.listdir(d), r.stdout[:200]))


def finder_rename_group():
    """fill renames a new Finder folder and the name sticks (fix17): with Finder in front,
    File > New Folder leaves Finder's inline name editor open on "untitled folder"; fill must
    close it before renaming, or the next drag commits the old name over the new one. Works
    in a scratch folder under tests/scratch/ in a Finder window of its own, closed after."""
    if not gui_idle_gate("finder rename check (New Folder, fill, drag)"):
        return
    d = os.path.join(ROOT, "tests", "scratch", f"mx-finder-{os.getpid()}")
    os.makedirs(d)
    open(os.path.join(d, "a.pdf"), "w").write("x")
    name = os.path.basename(d)
    prev = frontmost()
    def osa(s):
        return subprocess.run(["osascript", "-e", s], capture_output=True, text=True)
    osa(f'tell application "Finder"\nset w to make new Finder window to (POSIX file "{d}" as alias)\n'
        'set current view of w to icon view\nactivate\nend tell')
    c = Client()
    c.request("initialize", {"protocolVersion": "2025-06-18"})
    w = {"app": "Finder", "window": name}
    try:
        c.call("start", title="mx finder rename check", mode="background")
        time.sleep(1)
        c.call("menu", path=["File", "New Folder"], **w)
        time.sleep(1)
        snap, _ = c.call("snapshot", interactive=False, **w)
        folder = re.search(r'(e\d+) image "untitled folder"', snap)
        text, is_err = c.call("fill", ref=folder.group(1), text="Receipts", **w) if folder else ("no folder", True)
        check("file item: fill renames the new folder", not is_err and "renamed" in text, text)
        snap, _ = c.call("snapshot", interactive=False, **w)
        pdf, dest = re.search(r'(e\d+) image "a.pdf"', snap), re.search(r'(e\d+) image "(?:Receipts|untitled folder)"', snap)
        if pdf and dest:
            c.call("drag", **{"from": pdf.group(1), "to": dest.group(1)}, **w)
            time.sleep(1)
        got = sorted(x for x in os.listdir(d) if not x.startswith("."))
        inside = os.listdir(os.path.join(d, "Receipts")) if os.path.isdir(os.path.join(d, "Receipts")) else None
        check("file item: the name sticks after the next drag (no \"untitled folder\")",
              got == ["Receipts"] and inside == ["a.pdf"], (got, inside))
        c.call("done", summary="finder rename check")
    finally:
        c.close()
        osa(f'tell application "Finder"\nrepeat with fw in (get every Finder window)\nif name of fw is "{name}" then close fw\nend repeat\nend tell')
        subprocess.run(["rm", "-rf", "--", d])
        if prev:
            osa(f'tell application id "{prev}" to activate')


def drag_target_group():
    """drag never drops on the wrong target (fix18): a second Finder window over the drop
    target must make drag refuse, with nothing moved; with the cover gone the same drag
    lands in the folder and says where. Scratch folders under tests/scratch/, in Finder
    windows of its own, closed after."""
    if not gui_idle_gate("drag target check (covered drop target)"):
        return
    base = os.path.join(ROOT, "tests", "scratch")
    d, cover = os.path.join(base, f"mx-drag-{os.getpid()}"), os.path.join(base, f"mx-cover-{os.getpid()}")
    os.makedirs(os.path.join(d, "Receipts"))
    os.makedirs(cover)
    open(os.path.join(d, "a.pdf"), "w").write("x")
    name, cname = os.path.basename(d), os.path.basename(cover)
    prev = frontmost()
    def osa(s):
        return subprocess.run(["osascript", "-e", s], capture_output=True, text=True)
    # Icons placed by hand: a.pdf on the left, Receipts on the right half, which the cover window hides.
    osa(f'tell application "Finder"\nset w to make new Finder window to (POSIX file "{d}" as alias)\n'
        'set current view of w to icon view\nset arrangement of icon view options of w to not arranged\n'
        'set bounds of w to {200, 150, 900, 550}\nset position of item "a.pdf" of w to {80, 80}\n'
        'set position of item "Receipts" of w to {480, 80}\n'
        f'set c to make new Finder window to (POSIX file "{cover}" as alias)\nset bounds of c to {{560, 150, 1060, 550}}\n'
        'activate\nend tell')
    time.sleep(1)
    c = Client()
    c.request("initialize", {"protocolVersion": "2025-06-18"})
    w = {"app": "Finder", "window": name}
    def moved():
        return sorted(x for x in os.listdir(d) if not x.startswith(".")), \
            sorted(x for x in os.listdir(os.path.join(d, "Receipts")) if not x.startswith(".")), \
            sorted(x for x in os.listdir(cover) if not x.startswith("."))
    def refs():
        snap, _ = c.call("snapshot", interactive=False, **w)
        pdf, dest = re.search(r'(e\d+) image "a.pdf"', snap), re.search(r'(e\d+) image "Receipts"', snap)
        return (pdf.group(1), dest.group(1)) if pdf and dest else (None, None)
    try:
        c.call("start", title="mx drag target check", mode="background")
        pdf, dest = refs()
        text, is_err = c.call("drag", **{"from": pdf, "to": dest}, **w) if pdf else ("no refs", False)
        time.sleep(1)
        check("drag: refuses when another window covers the drop target",
              is_err and "drop target" in text and "not dragging" in text and moved() == (["Receipts", "a.pdf"], [], []),
              (text, moved()))
        osa(f'tell application "Finder"\nrepeat with fw in (get every Finder window)\nif name of fw is "{cname}" then close fw\nend repeat\nend tell')
        time.sleep(1)
        pdf, dest = refs()
        text, is_err = c.call("drag", **{"from": pdf, "to": dest}, **w) if pdf else ("no refs", True)
        time.sleep(1)
        check("drag: with the cover gone it drops into Receipts and says where",
              not is_err and os.path.join(d, "Receipts", "a.pdf") + " is there now" in text and moved() == (["Receipts"], ["a.pdf"], []),
              (text, moved()))
        c.call("done", summary="drag target check")
    finally:
        c.close()
        osa('tell application "Finder"\nrepeat with fw in (get every Finder window)\n'
            f'if name of fw is "{name}" or name of fw is "{cname}" then close fw\nend repeat\nend tell')
        subprocess.run(["rm", "-rf", "--", d, cover])
        if prev:
            osa(f'tell application id "{prev}" to activate')


def fix22_rule_checks(c):
    """fix22's pure rules through the hidden _debug_fix22 hook (no GUI): when a fill took,
    which window changes are only counts ticking, and which entered texts Escape removed."""
    cases = [
        {"id": 1, "rule": "same_text", "want": "hello", "got": "hello"},
        {"id": 2, "rule": "same_text", "want": "a  b\nc", "got": "a b\u2028c\n"},
        {"id": 3, "rule": "same_text", "want": "hi there", "got": "hi\ufffc there"},
        {"id": 4, "rule": "same_text", "want": "hello", "got": ""},
        {"id": 5, "rule": "same_text", "want": "hello", "got": "hello\nhello"},
        {"id": 6, "rule": "counts_only", "a": ['3 button "Inbox, 3 unread"', '4 text "2m"'],
         "b": ['3 button "Inbox, 4 unread"', '4 text "3m"']},
        {"id": 7, "rule": "counts_only", "a": ['3 row "Sam"'], "b": ['3 row "Sam"', '4 heading "Sam"']},
        {"id": 8, "rule": "counts_only", "a": ['3 text "General"'], "b": ['3 text "Random"']},
        {"id": 9, "rule": "lost", "texts": ["draft reply", "kept"],
         "before": ['e1 textbox "Reply" = "draft reply"', 'e2 textbox = "kept"'], "after": ['e2 textbox = "kept"']},
        {"id": 10, "rule": "lost", "texts": ["draft reply"],
         "before": ['e1 textbox "Reply" = "draft reply"'], "after": ['e1 textbox "Reply"']},
        {"id": 11, "rule": "lost", "texts": ["draft reply"],
         "before": ['e1 textbox "Reply" = "draft reply"'], "after": ['e1 textbox "Reply" = "draft reply"']},
        {"id": 12, "rule": "lost", "texts": ["line one\nline two"],
         "before": ['e1 textarea = "line one\\nline two"'], "after": []},
    ]
    text, _ = c.call("_debug_fix22", cases=cases)
    got = dict(line.split(": ", 1) for line in text.splitlines())
    check("fill check: the same text, give or take whitespace, line separators and attachment marks, took",
          [got.get(str(i)) for i in (1, 2, 3)] == ["yes"] * 3, text)
    check("fill check: an empty or different read-back didn't take", got.get("4") == "no" and got.get("5") == "no", text)
    check("press check: digits ticking over (badges, times) are not an effect", got.get("6") == "yes", text)
    check("press check: added elements or changed words are an effect", got.get("7") == "no" and got.get("8") == "no", text)
    check("escape: an entered field that disappears or loses its text is reported",
          got.get("9") == '["draft reply"]' and got.get("10") == '["draft reply"]' and got.get("12") == '["line one\\nline two"]', text)
    check("escape: entered text still showing is not reported", got.get("11") == "[]", text)


def press_effect_checks(c):
    """fix23's press effect rule through the hidden _debug_fix22 hook (no GUI): icon-glyph
    churn, recreated elements and an empty diff are no effect; a selection, title or
    content change is."""
    row = 'e1 row "Sam (you)"'
    glyph = 'text "\ue506"'
    cases = [
        # Glyph-only churn: icon texts recreated, or swapped for other icon glyphs.
        {"id": 1, "rule": "press_effect", "before": [row, "e2 " + glyph], "after": [row, "e9 " + glyph]},
        {"id": 2, "rule": "press_effect", "before": [row, "e2 " + glyph], "after": [row, 'e2 text "\ue507"', 'e8 text "\U000f0001 3"']},
        # Recreated with the same text, not changed.
        {"id": 3, "rule": "press_effect", "before": [row, 'e2 heading "General"'], "after": ['e7 row "Sam (you)"', 'e2 heading "General"']},
        # Nothing the diff would show: no effect.
        {"id": 4, "rule": "press_effect", "before": [row], "after": [row],
         "before_target": ["0", "-", "-"], "after_target": ["0", "-", "-"]},
        # A row whose AXSelected turns on with nothing else changing (Slack's sidebar under
        # AXPress) had no effect; the same selection change on a native control is one.
        {"id": 12, "rule": "press_effect", "before": [row], "after": [row],
         "before_target": ["0", "", "0"], "after_target": ["1", "", "0"]},
        # Real effects: selection (native), title, new content, changed words.
        {"id": 5, "rule": "press_effect", "fallback": False, "before": [row], "after": [row],
         "before_target": ["0", "-", "-"], "after_target": ["1", "-", "-"]},
        {"id": 6, "rule": "press_effect", "before": [row], "after": [row], "before_title": "General", "after_title": "Sam (you)"},
        {"id": 7, "rule": "press_effect", "before": [row], "after": [row, 'e5 heading "Sam (you)"']},
        {"id": 8, "rule": "press_effect", "before": [row, 'e2 text "General"'], "after": [row, 'e2 text "Random"']},
        # Digits ticking over are noise for rows, but an effect for a native stepper.
        {"id": 9, "rule": "press_effect", "before": [row, 'e2 text "2m"'], "after": [row, 'e2 text "3m"']},
        {"id": 10, "rule": "press_effect", "fallback": False,
         "before": ['e3 stepper "Copies" = "1"'], "after": ['e3 stepper "Copies" = "2"']},
        # An element removed for good is an effect even when a glyph churns beside it.
        {"id": 11, "rule": "press_effect", "before": [row, "e2 " + glyph, 'e4 button "Close"'], "after": [row, "e9 " + glyph]},
    ]
    text, _ = c.call("_debug_fix22", cases=cases)
    got = dict(line.split(": ", 1) for line in text.splitlines())
    check("press effect: icon-glyph churn is not an effect", got.get("1") == "no" and got.get("2") == "no", text)
    check("press effect: an element recreated with the same text is not an effect", got.get("3") == "no", text)
    check("press effect: an empty diff with the same title and target state is not an effect", got.get("4") == "no", text)
    check("press effect: a row's own selection turning on with an empty diff is not an effect", got.get("12") == "no", text)
    check("press effect: a native selection, title, new content and changed words are effects",
          [got.get(str(i)) for i in (5, 6, 7, 8)] == ["yes"] * 4, text)
    check("press effect: digits ticking are noise for rows, an effect for native controls",
          got.get("9") == "no" and got.get("10") == "yes", text)
    check("press effect: a removed element counts beside glyph churn", got.get("11") == "yes", text)


def file_item_checks(c):
    """fix24: which elements stand for a file (fill renames it, a drop names its folder),
    through the hidden _debug_fix22 hook (no GUI). The decision takes no app: a file item in
    any app is treated like one in Finder."""
    item = {"rule": "file_item", "url": "file:///tmp/mx-x/a%20b.pdf", "filename": "a b.pdf"}
    cases = [dict(item, id=1, app="Finder"), dict(item, id=2, app="Files Pro"),
             # A path bar entry (URL, no file name), a web link, and an inline name editor (neither).
             {"id": 3, "rule": "file_item", "app": "Files Pro", "url": "file:///tmp/mx-x/"},
             {"id": 4, "rule": "file_item", "app": "Files Pro", "url": "https://example.com/a.pdf", "filename": "a.pdf"},
             {"id": 5, "rule": "file_item", "app": "Files Pro", "filename": ""}]
    text, _ = c.call("_debug_fix22", cases=cases)
    got = dict(line.split(": ", 1) for line in text.splitlines())
    check("file item: a file-URL item with a file name is a file in Finder and in any other app",
          got.get("1") == got.get("2") == "/tmp/mx-x/a b.pdf", text)
    check("file item: a path bar entry, a web link and a name editor are not file items",
          [got.get(i) for i in ("3", "4", "5")] == ["none"] * 3, text)


def fix22_group():
    """fix22, on screen in TextEdit (scratch document only): the Escape gate refuses Escape
    in a field mx filled, passes with confirm, and reports entered text that Escape removed
    (TextEdit's Find and Replace bar); fill falls back to typing when the value didn't take.
    Needs the user idle 60 s."""
    if not gui_idle_gate("fix22 escape gate and fill checks", need=60.0, cap=900.0):
        return
    scratch_dir = os.path.join(ROOT, "tests", "scratch")
    os.makedirs(scratch_dir, exist_ok=True)
    fname = f"mx-fix22-{os.getpid()}.txt"
    path = os.path.join(scratch_dir, fname)
    with open(path, "w") as f:
        f.write("seed text")
    c = Client()
    c.request("initialize", {"protocolVersion": "2025-06-18"})
    subprocess.run(["open", "-a", "TextEdit", path], check=True)
    w = {"app": "TextEdit", "window": fname}
    try:
        c.call("start", title="mx fix22 check")
        deadline = time.time() + 10
        while True:
            text, is_err = c.call("snapshot", **w)
            if not is_err or time.time() > deadline:
                break
            time.sleep(0.3)
        ref = re.search(r"(e\d+) textarea", text).group(1)

        # Escape gate on the field mx filled.
        c.call("fill", ref=ref, text="keep this draft", **w)
        text, is_err = c.call("key", key="escape", **w)
        print(f"      escape refusal: {text}")
        check("escape in a field mx filled is refused and says to pass confirm",
              is_err and text.startswith("refused: escape can discard the edit in") and "confirm=true" in text, text)
        text, is_err = c.call("batch", steps=[{"action": "key", "ref": ref, "key": "escape"}], **w)
        check("a batch escape step on that field is refused too", is_err and "refused: escape" in text, text)
        text, is_err = c.call("key", ref=ref, key="escape", confirm=True, **w)
        check("escape with confirm=true passes", not is_err and "pressed escape" in text, text)
        c.call("key", ref=ref, key="escape", confirm=True, **w)  # closes the completion list the first one opened
        got = read_until(c, ref, w, "keep this draft")
        check("the confirmed escape left the text alone", got == "keep this draft", got)
        c.call("done", summary="escape gate")
        c.call("start", title="mx fix22 check")
        text, is_err = c.call("key", ref=ref, key="escape", **w)
        check("a new session doesn't gate escape on the last session's fills", not is_err, text)
        c.call("key", ref=ref, key="escape", **w)

        # Entered text that Escape removed: the Find and Replace bar's replace field.
        c.call("menu", app="TextEdit", path=["Edit", "Find", "Find and Replace"])
        text, is_err = c.call("fill", role="textbox", name="Replace", text="zebra entered", **w)
        if is_err:
            snap, _ = c.call("snapshot", **w)
            not_run("escape reports the entered text it removed", f"no replace field to fill: {text}\n{snap[:600]}")
        else:
            text, is_err = c.call("key", key="escape", **w)
            check("escape in the filled replace field is refused", is_err and "refused: escape" in text, text)
            text, is_err = c.call("key", key="escape", confirm=True, **w)
            shot = os.path.join(scratch_dir, "fix22-escape-removed.png")
            subprocess.run(["screencapture", "-x", shot])
            print(f"      escape removed: {text.splitlines()[:6]}; saved {shot}")
            check("escape that closes the bar says it removed the text mx entered",
                  not is_err and 'escape removed "zebra entered", which you entered' in text, text)

        # Fill that didn't take falls back to typing (the hidden flag skips the AXValue set).
        text, is_err = c.call("fill", ref=ref, text="plain fill", **w)
        check("a fill that takes says filled", not is_err and text.startswith("filled textarea"), text)
        text, is_err = c.call("fill", ref=ref, text="typed instead\nsecond line", _fake_fill_ignored=True, **w)
        got, _ = c.call("read", ref=ref, **w)
        shot = os.path.join(scratch_dir, "fix22-fill-typed.png")
        subprocess.run(["screencapture", "-x", shot])
        print(f"      fill fallback: {text.splitlines()[0]}; read {got!r}; saved {shot}")
        check("a fill that didn't take types the text instead and says so, newline and all, without confirm",
              not is_err and text.startswith("fill didn't take; typed it instead: typed 25 characters")
              and got.replace("\u2028", "\n") == "typed instead\nsecond line", (text, got))
        c.call("done", summary="fix22 checks")
    finally:
        close_scratch(c, w, path)
        c.close()
        if os.path.exists(path):
            os.remove(path)


# Check groups `--only` can run on their own (fix10 and later).
ONLY = {"protocol": protocol_checks, "settle": settle_checks, "diff": with_client(diff_checks), "gate": with_client(gate_table_checks),
        "indicator": indicator_group, "cc": cc_group, "fix11": fix11_group,
        "pill": lambda: fix11_group(borrows=False), "fix12": fix12_group,
        "fix12-idle": lambda: fix12_group(front_eof=False), "fix13": fix13_group,
        "audit": audit_checks, "finder": finder_rename_group, "drag": drag_target_group,
        "placement": with_client(pill_place_checks), "donepill": done_pill_group,
        "fix22rules": with_client(fix22_rule_checks), "fix23rules": with_client(press_effect_checks),
        "fileitem": with_client(file_item_checks), "fix22": fix22_group, "press": press_checks}


if __name__ == "__main__":
    if not os.path.exists(BIN):
        sys.exit(f"build first: swift build -c release ({BIN} missing)")
    if sys.argv[1:2] == ["--only"]:
        # Runs only the named check groups, for when the full run would disturb someone on this Mac.
        for name in sys.argv[2].split(","):
            ONLY[name]()
        fails = [n for n, s in results if s == "FAIL"]
        print(f"\n{sum(s == 'PASS' for _, s in results)} passed, {len(fails)} failed, "
              f"{sum(s == 'NOT RUN' for _, s in results)} not run")
        sys.exit(1 if fails else 0)
    protocol_checks()
    settle_checks()
    if ax_checks():
        press_checks()
        system_ui_checks()
        app_open_clipboard_checks()
        settings_checks()
    fails = [n for n, s in results if s == "FAIL"]
    if borrow_ms:
        print(f"borrow durations (ms): {borrow_ms}")
    print(f"\n{sum(s == 'PASS' for _, s in results)} passed, {len(fails)} failed, "
          f"{sum(s == 'NOT RUN' for _, s in results)} not run")
    sys.exit(1 if fails else 0)
