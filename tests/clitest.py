#!/usr/bin/env python3
"""mx CLI test (stdlib only). Runs `mx <tool> ...` as a terminal agent would and checks
flag mapping, errors, exit codes, help, and the per-session background process
(`mx serve`): start, reuse, concurrent first calls, two sessions, stop, stale socket, idle exit.

The protocol group needs no Accessibility grant and no GUI. The AX group drives a scratch
TextEdit document this script creates under tests/scratch/ (and closes), with refs carried
across separate CLI calls; it is NOT RUN if the terminal isn't trusted for Accessibility.

usage: python3 tests/clitest.py                 (after swift build -c release)
       python3 tests/clitest.py --only protocol (CI)
"""
import concurrent.futures
import hashlib
import json
import os
import re
import socket
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.environ.get("MX_BIN") or os.path.join(ROOT, ".build", "release", "mx")
TAG = f"clitest-{os.getpid()}"
results = []
used_keys = set()


def check(name, ok, detail: object = ""):
    results.append((name, "PASS" if ok else "FAIL"))
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"\n      {detail}" if detail and not ok else ""))
    return ok


def not_run(name, why):
    results.append((name, "NOT RUN"))
    print(f"NOT RUN  {name}\n      {why}")


def mx(*args, key=None, env=None, stdin=None, timeout=60):
    """Runs the CLI; returns (exit code, stdout, stderr)."""
    e = {**os.environ, **(env or {})}
    if key is not None:
        e["MX_SESSION"] = key
        used_keys.add(key)
    r = subprocess.run([BIN, *args], input=stdin, capture_output=True, text=True, env=e, timeout=timeout)
    return r.returncode, r.stdout, r.stderr


def dry(*args, stdin=None):
    """The tools/call params the CLI would send, without sending them."""
    rc, out, err = mx(*args, env={"MX_CLI_DRY_RUN": "1"}, stdin=stdin)
    return json.loads(out)["arguments"] if rc == 0 else (rc, err)


def sock_path(key):
    tmp = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip()
    return os.path.join(tmp, "mx", hashlib.sha256(key.encode()).hexdigest()[:16] + ".sock")


def serve_pids(key):
    r = subprocess.run(["pgrep", "-f", f"serve --socket {sock_path(key)}"], capture_output=True, text=True)
    return sorted(int(p) for p in r.stdout.split())


def wait_until(cond, timeout=5.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if cond():
            return True
        time.sleep(0.05)
    return cond()


def tool_list():
    p = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    out, _ = p.communicate(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}) + "\n", timeout=20)
    return json.loads(out.splitlines()[0])["result"]["tools"]


# ---------------------------------------------------------------------------

def help_checks():
    tools = tool_list()
    rc, out, _ = mx("--help")
    check("mx --help lists every tool, grouped, with ENVIRONMENT and exit codes",
          rc == 0 and all(re.search(rf"^  {t['name']} ", out, re.M) for t in tools)
          and all(g + ":" in out for g in ("Session", "Look", "Act", "System", "History"))
          and "MX_SESSION" in out and "Exit codes" in out and "Workflows" in out, out[:400])
    bad = []
    for t in tools:
        rc, out, _ = mx(t["name"], "--help")
        flags = t["inputSchema"].get("properties", {}).keys()
        if rc != 0 or "Examples:\n  mx " not in out or not all(f"--{f}" in out for f in flags):
            bad.append(t["name"])
    check("mx <tool> --help has examples and every schema flag, for every tool", not bad, bad)
    rc, out, _ = mx("click", "--help")
    check("tool help shows enum values and required flags",
          "One of: press, showmenu" in out and "(required)" in out, out)
    rc, out, _ = mx("history", "--help")
    check("mx history --help shows the tool's flags and the positional forms",
          rc == 0 and "--pinned" in out and "mx history pin <session>" in out, out)


def flag_checks():
    check("strings, a bare boolean and a repeated array flag",
          dry("menu", "--app", "TextEdit", "--path", "Format", "--path", "Font", "--path", "Bold", "--confirm")
          == {"app": "TextEdit", "path": ["Format", "Font", "Bold"], "confirm": True})
    check("--flag=value and --bool=false",
          dry("snapshot", "--app=Finder", "--interactive=false") == {"app": "Finder", "interactive": False})
    got = dry("window", "--app", "T", "--op", "move", "--x", "3", "--y", "4.5")
    check("numbers parse as numbers", got == {"app": "T", "op": "move", "x": 3, "y": 4.5}, got)
    check("integers parse as integers", dry("click", "--app", "A", "--ref", "e1", "--count", "2") == {"app": "A", "ref": "e1", "count": 2})
    steps = [{"action": "fill", "ref": "e1", "text": "hi"}, {"action": "read", "ref": "e1"}]
    check("an array of objects takes JSON", dry("batch", "--app", "A", "--steps", json.dumps(steps)) == {"app": "A", "steps": steps})
    got = dry("drag", "--app", "A", "--from", "e3", "--to", '{"x": 10, "y": 20}')
    check("an untyped value takes JSON or a plain string", got == {"app": "A", "from": "e3", "to": {"x": 10, "y": 20}}, got)
    got = dry("window", "--args", '{"app": "A", "op": "list", "window": "w"}', "--window", "flag")
    check("--args sets any arguments and flags win", got == {"app": "A", "op": "list", "window": "flag"}, got)
    got = dry("batch", "--args", "-", stdin=json.dumps({"app": "A", "steps": steps}))
    check("--args - reads the JSON from stdin", got == {"app": "A", "steps": steps}, got)


def error_checks():
    rc, _, err = mx("click", "--app", "A", "--bogus", "1")
    check("an unknown flag exits 2 and names the valid flags", rc == 2 and "--bogus" in err and "--ref" in err and "--confirm" in err, err)
    rc, _, err = mx("fill", "--app", "A")
    check("a missing required flag exits 2 and names it", rc == 2 and "--text" in err, err)
    rc, _, err = mx("start", "--title", "t", "--mode", "fast")
    check("a value outside the enum exits 2 and lists the values", rc == 2 and "background, front, watch" in err, err)
    rc, _, err = mx("click", "--app", "A", "--count", "two")
    check("a non-number for an integer flag exits 2", rc == 2 and "--count" in err, err)
    rc, _, err = mx("click", "e12")
    check("a positional argument exits 2", rc == 2 and "e12" in err, err)
    rc, _, err = mx("frobnicate")
    check("an unknown command exits 2", rc == 2 and "unknown command" in err, err)
    rc, _, err = mx("batch", "--args", "[1]")
    check("--args that isn't a JSON object exits 2", rc == 2 and "JSON object" in err, err)
    rc, _, err = mx("history", "--bogus")
    check("mx history rejects an unknown flag with exit 2", rc == 2 and "--pinned" in err, err)


def process_checks():
    key = f"{TAG}-a"
    path = sock_path(key)
    check("the socket path fits sun_path (under 104 bytes)", len(path.encode()) < 104, path)
    rc, out, err = mx("list_apps", key=key)
    check("the first call starts the background process and answers", rc == 0 and out.strip() != "", err)
    pids = serve_pids(key)
    check("one mx serve runs for the session, on a 0600 socket in a 0700 dir",
          len(pids) == 1 and oct(os.stat(path).st_mode & 0o777) == "0o600"
          and oct(os.stat(os.path.dirname(path)).st_mode & 0o777) == "0o700", (pids, path))
    mx("list_apps", key=key)
    check("a second call reuses the same process", serve_pids(key) == pids, (pids, serve_pids(key)))

    rc, out, _ = mx("list_apps", "--json", key=key)
    try:
        ok = rc == 0 and json.loads(out)["content"][0]["type"] == "text"
    except (ValueError, KeyError, IndexError):
        ok = False
    check("--json prints the raw MCP result object", ok, out[:200])

    rc, out, err = mx("clipboard", "--op", "get", key=key)
    check("a gate refusal that confirm lifts exits 3, message on stderr",
          rc == 3 and out == "" and "confirm=true" in err, (rc, out, err))
    rc, out, err = mx("settings", "--key", "log.days", "--value", "1", key=key)
    check("a refusal confirm can't lift (lowering logging) exits 1", rc == 1 and "mx config set" in err, (rc, err))
    rc, out, err = mx("snapshot", "--app", "NoSuchAppXyz123", key=key)
    check("a tool error exits 1 with the message on stderr", rc == 1 and out == "" and err.strip() != "", (rc, err))

    # Two session keys, two processes.
    key_b = f"{TAG}-b"
    mx("list_apps", key=key_b)
    pb = serve_pids(key_b)
    check("another session key gets its own process", len(pb) == 1 and pb != pids, (pids, pb))

    # Concurrent first calls start one process.
    key_c = f"{TAG}-c"
    with concurrent.futures.ThreadPoolExecutor(8) as ex:
        rcs = list(ex.map(lambda _: mx("list_apps", key=key_c)[0], range(8)))
    check("8 concurrent first calls all answer and start exactly one process",
          rcs == [0] * 8 and len(serve_pids(key_c)) == 1, (rcs, serve_pids(key_c)))

    # Stop.
    rc, out, _ = mx("stop", key=key)
    check("mx stop ends the session's process and removes its socket",
          rc == 0 and "stopped" in out and wait_until(lambda: not serve_pids(key)) and not os.path.exists(path), (out, serve_pids(key)))
    rc, out, _ = mx("stop", key=key)
    check("mx stop with no process says so and exits 0", rc == 0 and "no mx process" in out, out)
    check("stopping one session leaves the other running", serve_pids(key_b) == pb)

    # A stale socket file (nobody listening) is replaced.
    key_s = f"{TAG}-stale"
    sp = sock_path(key_s)
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.bind(sp)
    s.close()  # the file stays, nobody answers
    rc, out, err = mx("list_apps", key=key_s)
    check("a stale socket file is removed and replaced", rc == 0 and len(serve_pids(key_s)) == 1, (rc, err))

    # Idle exit.
    key_i = f"{TAG}-idle"
    rc, _, _ = mx("list_apps", key=key_i, env={"MX_IDLE_SECONDS": "1"})
    started = len(serve_pids(key_i)) == 1
    check("an idle process exits after MX_IDLE_SECONDS and removes its socket",
          rc == 0 and started and wait_until(lambda: not serve_pids(key_i), 6) and not os.path.exists(sock_path(key_i)),
          (rc, started, serve_pids(key_i)))
    rc, _, _ = mx("list_apps", key=key_i, env={"MX_IDLE_SECONDS": "1"})
    check("the next call after an idle exit starts a fresh process", rc == 0)

    # The process is detached: a call returns even though mx serve keeps running.
    p = subprocess.run(f"MX_SESSION={TAG}-detach {BIN} list_apps | cat", shell=True, capture_output=True, text=True, timeout=15)
    used_keys.add(f"{TAG}-detach")
    check("a call through a pipe returns while the process keeps running (no inherited stdout)",
          p.returncode == 0 and len(serve_pids(f"{TAG}-detach")) == 1)


def protocol_group():
    help_checks()
    flag_checks()
    error_checks()
    process_checks()


# ---------------------------------------------------------------------------

def ax_group():
    """The README's terminal workflow on a scratch TextEdit document, through separate CLI calls."""
    key = f"{TAG}-ax"
    rc, out, err = mx("snapshot", "--app", "TextEdit", "--window", "no-such-window-xyz", key=key)
    if "not trusted" in err:
        not_run("AX checks", err.strip())
        return
    log = sock_path(key)[:-5] + ".log"
    with open(log) as f:
        line = f.read()
    check("mx serve reports Accessibility trusted (attributed to the terminal that started it)",
          "accessibility trusted" in line, line)

    scratch = os.path.join(ROOT, "tests", "scratch")
    os.makedirs(scratch, exist_ok=True)
    fname = f"mx-clitest-{os.getpid()}.txt"
    path = os.path.join(scratch, fname)
    with open(path, "w") as f:
        f.write("seed text")
    subprocess.run(["open", "-a", "TextEdit", path], check=True)
    w = ["--app", "TextEdit", "--window", fname]
    try:
        rc, out, err = mx("start", "--title", "mx cli test", "--mode", "background", key=key)  # keeps the user's typing out of the scratch doc
        check("mx start", rc == 0 and "mx cli test" in out, err)
        deadline = time.time() + 10
        while True:
            rc, out, err = mx("snapshot", *w, key=key)
            if rc == 0 or time.time() > deadline:
                break
            time.sleep(0.3)
        m = re.search(r"(e\d+) textarea", out)
        if not check("mx snapshot shows the scratch textarea", rc == 0 and m and "seed text" in out, out + err):
            return
        ref = m.group(1)
        rc, out, err = mx("fill", *w, "--ref", ref, "--text", "hi", key=key)
        check("mx fill by a ref from the earlier call", rc == 0 and out.startswith("filled textarea"), out + err)
        got = ""
        for _ in range(20):
            rc, got, _ = mx("read", *w, "--ref", ref, key=key)
            if got.strip() == "hi":
                break
            time.sleep(0.05)
        check("mx read gives the filled text", got.strip() == "hi", got)
        rc, out, err = mx("key", *w, "--ref", ref, "--key", "return", key=key)
        check("return in the text box is refused with exit 3", rc == 3 and "confirm=true" in err, (rc, out, err))
        rc, out, err = mx("key", *w, "--key", "cmd+a", key=key)
        check("mx key cmd+a", rc == 0 and "pressed cmd+a" in out, out + err)
        steps = {"app": "TextEdit", "window": fname,
                 "steps": [{"action": "fill", "ref": ref, "text": "batched"}, {"action": "read", "ref": ref}]}
        rc, out, err = mx("batch", "--args", "-", stdin=json.dumps(steps), key=key)
        check("mx batch --args - runs the steps", rc == 0 and "ran 2 steps" in out and "batched" in out, out + err)
        shot = os.path.join(scratch, "clitest-shot.png")
        rc, out, err = mx("screenshot", *w, "--out", shot, key=key)
        if rc != 0 and "Screen Recording" in err:
            not_run("mx screenshot --out", err.strip())
        else:
            with open(shot, "rb") as f:
                png = f.read(8) == b"\x89PNG\r\n\x1a\n"
            check("mx screenshot --out writes the PNG and prints its path", rc == 0 and png and out.strip().endswith(shot), out + err)
        rc, out, err = mx("done", "--summary", "ok", key=key)
        # fill, key cmd+a and batch act; reads, the refused return and the screenshot don't count.
        check("mx done counts the actions from every call", rc == 0 and "with 3 actions" in out, out + err)
    finally:
        script = f'tell application "TextEdit" to close (every document whose path is "{path}") saving no'
        subprocess.run(["osascript", "-e", script], capture_output=True)
        if os.path.exists(path):
            os.remove(path)


GROUPS = {"protocol": protocol_group, "ax": ax_group}

if __name__ == "__main__":
    if not os.path.exists(BIN):
        sys.exit(f"build first: swift build -c release ({BIN} missing)")
    names = sys.argv[2].split(",") if sys.argv[1:2] == ["--only"] else list(GROUPS)
    try:
        for n in names:
            GROUPS[n]()
    finally:
        for k in used_keys:
            mx("stop", key=k)
    fails = [n for n, s in results if s == "FAIL"]
    print(f"\n{sum(s == 'PASS' for _, s in results)} passed, {len(fails)} failed, "
          f"{sum(s == 'NOT RUN' for _, s in results)} not run")
    sys.exit(1 if fails else 0)
