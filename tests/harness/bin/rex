#!/usr/bin/env -S python3 -I -S
"""Deterministic fake of the `rex` CLI for testing rex-orchestrator.sh.

State lives in $FAKE_REX_DIR: scenario.json (read-only), state.json (step pointers), calls.jsonl (call log).
Each block runs a list of steps. A step is served until `calls` calls of its `advance_on` method
(program_status | capture | process | any | none; the block's unless the step sets one) have been made in it,
or, with `secs`, until that many seconds have passed since it was first served (virtual seconds when FAKE_CLOCK
is set); then the next step starts (the last one sticks). send / send-key can jump to a named step (on_send /
on_key). Steps inherit records/screen/process fields from the previous step. fail / garbage inject transient
errors for the first N calls of a method within a step. With FAKE_LAUNCH set, every block serves its
`launch_step` and nothing advances: the harness opens panes through the real `launch` that way.
Block targets resolve as in Rex: full ID, bare UUID, an ID suffix of 4+ characters, or a unique label.
The scenario's `orch` block (the orchestrator's own pane) always exists.
Scenario-wide knobs: create_rc / create_out (split and window new fail or print that), split_delay (seconds a split or
window new waits, real time, after Rex made the pane and before it prints the ID; it touches split_started first, so a
signal can land then), close_fail (the first N block closes fail with rc 1) and close_delay (seconds each close takes).
A window new records its window label; window inspect and window rename resolve a window by its ID or label.
A split or window new records the new pane's -c folder, which every captured screen then names in place of the fixture
folders in DIR_TOKENS (scenario `dir_as` replaces that list), re-wrapped over the rows a fixture wraps its folder onto.
A send's text shows in the pane's input box (`echo_typed`) until a send-key with enter; a step with "echo": false
drops it, as a pane that never shows the text does. Claude draws a file prompt's path row relative to its folder: the
row naming the basename of a root record's "approve Tool: /path" msg shows that path relative to the pane's -c folder
(a step with "claude_row": false keeps the screen's own row). A step's key_writes {"KEYS": [[PATH, TEXT], ...]} writes
those files when send-key presses KEYS there, as an agent saves its trust store on an answer. A pane's child is, unless
a step sets pid or child_path, the harness's running stand-in for its argv0 ($FAKE_AGENTS: {name: {path, pid}}), so a
pane's child is a real process. `server status` reports rex_version fake-rex-1 (a step-less knob:
scenario `rex_version`).
"""
import fcntl, json, os, re, sys, time

D = os.environ["FAKE_REX_DIR"]
SCN = json.load(open(os.path.join(D, "scenario.json")))
ORCH = SCN["orch"]
BLOCKS = SCN["blocks"]
BLOCKS.setdefault(ORCH, {"label": SCN.get("orch_label", "shell"), "advance_on": "none",
                         "steps": [{"name": "orchestrator", "records": [], "screen": "$ ", "argv0": "claude", "pid": 3000}]})
LAUNCH = bool(os.environ.get("FAKE_LAUNCH"))
LOCK = open(os.path.join(D, "lock"), "w")
fcntl.flock(LOCK, fcntl.LOCK_EX)
SP = os.path.join(D, "state.json")
ST = json.load(open(SP)) if os.path.exists(SP) else {"blocks": {}, "seq": 0}
BLOCKS.update(ST.get("dynamic_blocks", {}))
AGENTS = json.loads(os.environ.get("FAKE_AGENTS") or "{}")
OWNER = {"claude-code": "claude", "antigravity": "antigravity", "codex": "codex", "grok-build": "grok", "muse": "muse"}
NOT_INHERITED = ("on_send", "on_key", "fail", "garbage", "goto", "calls", "secs", "advance_on", "name")
# The folders the live captures in fixtures/ name (their launch DIR), as shown or wrapped there.
_A = "/private/tmp/claude-501/-Users-alice/00000000-0000-4000-8000-000000000000/scratchpad/audit/"
DIR_TOKENS = [_A + "verify-R07-trace/t1-claude-80x9", _A + "verify-R07-repro/live/c80x9", _A + "verify-R07-trace/t2-claude-26x40",
              _A + "review-launch/live-agy-1", _A + "verify-R07-trace/t4-agy-80x8", "/private/tmp/x/proj", "/private/tmp/x"]


def put_dir(screen, tok, new):
    """SCREEN with every run of rows that spells TOK (one row, or rows a narrow pane wraps it onto) spelling NEW,
    re-wrapped at the same row widths."""
    rows, i = screen.split("\n"), 0
    while i < len(rows):
        acc, j = "", i
        while j < len(rows) and rows[j].strip() and tok.startswith(acc + rows[j].strip()):
            acc += rows[j].strip(); j += 1
            if acc == tok:
                break
        if acc != tok:
            i += 1
            continue
        old = rows[i:j]
        chunks, rest = [], new
        for r in old[:-1]:
            w = len(r.strip())
            if len(rest) <= w:
                break
            chunks.append(rest[:w]); rest = rest[w:]
        chunks.append(rest)
        ind = [r[:len(r) - len(r.lstrip())] for r in old]
        rows[i:j] = [ind[min(k, len(ind) - 1)] + c for k, c in enumerate(chunks)]
        i += len(chunks)
    return "\n".join(rows)


def claude_row(screen, cur, cwd):
    """SCREEN with the path row of claude's file dialog as claude draws it, relative to the pane's folder CWD."""
    for r in cur.get("records", []):
        m = r.get("msg") or ""
        if r.get("id") is None and r.get("app", cur.get("app", "claude-code")) == "claude-code" and m.startswith("approve ") \
                and ": /" in m:
            p = m.split(": ", 1)[1]
            b = os.path.basename(p)
            if b and f"\n {b}\n" in screen:
                return screen.replace(f"\n {b}\n", f"\n {os.path.relpath(p, cwd)}\n", 1)
    return screen


def echo_typed(screen, text):
    """SCREEN with TEXT in the agent's input box: grok's last ╭…╰ box, else the row after the second-last rule (claude,
    agy, muse), else codex's last › row."""
    rows = screen.split("\n")
    top = [i for i, r in enumerate(rows) if r.lstrip().startswith("╭")]
    bot = [i for i, r in enumerate(rows) if r.lstrip().startswith("╰")]
    rules = [i for i, r in enumerate(rows) if "─" * 10 in r and not r.lstrip().startswith(("╭", "╰"))]
    cdx = [i for i, r in enumerate(rows) if r.lstrip().startswith("›")]
    if top and bot and bot[-1] > top[-1] + 1:
        rows[top[-1] + 1] = "  │ ❯ " + text + " │"
    elif len(rules) >= 2:
        if rules[-1] == rules[-2] + 1:
            rows.insert(rules[-1], "❯ " + text)
        else:
            rows[rules[-2] + 1] = "❯ " + text
    elif cdx:
        rows[cdx[-1]] = "› " + text
    return "\n".join(rows)


def save():
    json.dump(ST, open(SP + ".tmp", "w"))
    os.replace(SP + ".tmp", SP)


def now():
    if os.environ.get("FAKE_CLOCK"):
        return float(open(os.path.join(D, "clock")).read())
    return time.time()


def resolved_steps(bdef):
    out, prev = [], {}
    for s in bdef["steps"]:
        cur = dict(prev)
        for k in NOT_INHERITED:
            cur.pop(k, None)
        cur.update(s)
        out.append(cur)
        prev = cur
    return out


def bstate(b):
    return ST["blocks"].setdefault(b, {"step": 0, "count": 0, "mcalls": {}, "closed": False, "visits": [], "since": None})


def step_of(b):
    bs = bstate(b)
    if LAUNCH and "launch_step" in BLOCKS[b]:
        return None, bs, dict({"argv0": bs["argv0"]} if "argv0" in bs else {}, **BLOCKS[b]["launch_step"], name="launch")
    steps = resolved_steps(BLOCKS[b])
    cur = steps[min(bs["step"], len(steps) - 1)]
    return steps, bs, dict({"argv0": bs["argv0"]} if "argv0" in bs else {}, **cur)


def move(b, idx):
    bs = bstate(b)
    bs.update(step=idx, count=0, mcalls={}, since=None)
    bs["visits"].append(resolved_steps(BLOCKS[b])[idx].get("name", str(idx)))


def jump(b, name):
    if LAUNCH:
        return
    steps, bs, _ = step_of(b)
    move(b, next(i for i, s in enumerate(steps) if s.get("name") == name))


def advance(b, method):
    """Called before serving a call. The step changes lazily, at the first advancing call after the current step
    has been served `calls` times (or for `secs` seconds), so every call in between sees the same step."""
    if LAUNCH:
        return
    steps, bs, cur = step_of(b)
    adv = cur.get("advance_on", BLOCKS[b].get("advance_on", "program_status"))
    if adv != method and adv != "any":
        return
    t = now()
    if bs.get("since") is None:
        bs["since"] = t
    over = t - bs["since"] >= cur["secs"] if "secs" in cur else bs["count"] >= cur.get("calls", 1)
    if over and cur.get("goto"):
        jump(b, cur["goto"])
    elif over and bs["step"] < len(steps) - 1:
        move(b, bs["step"] + 1)
    if bs.get("since") is None:
        bs["since"] = t
    bs["count"] += 1


def log(entry):
    ST["seq"] += 1
    entry.update(seq=ST["seq"], t=round(time.time(), 3), vt=now())
    with open(os.path.join(D, "calls.jsonl"), "a") as f:
        f.write(json.dumps(entry) + "\n")


def opts(args):
    """Split argv into (options dict, positionals); '--' ends options."""
    o, pos, i = {}, [], 0
    while i < len(args):
        a = args[i]
        if a == "--":
            o["--"] = args[i + 1:]
            break
        if a.startswith("--") and "=" in a:
            k, v = a.split("=", 1); o[k] = v
        elif a in ("-s", "-b", "-c", "-w", "--label", "--ratio", "--split", "--session", "--block", "--cwd", "--shell",
                   "--timeout"):
            o[a] = args[i + 1]; i += 1
        elif a.startswith("-"):
            o[a] = True
        else:
            pos.append(a)
        i += 1
    return o, pos


def label(b):
    return bstate(b).get("label") or BLOCKS[b].get("label", "shell")


def live():
    return [b for b in BLOCKS if not bstate(b)["closed"]]


def resolve(t):
    """(block, error text) for a block target, the way Rex resolves it."""
    if t is None:
        return ORCH, None  # rex: REX_BLOCK, else the focused block
    ids = live()
    if t in ids:
        return t, None
    if "block:" + t in ids:
        return "block:" + t, None
    m = [b for b in ids if len(t) >= 4 and b.lower().endswith(t.lower())] or [b for b in ids if label(b) == t]
    if len(m) == 1:
        return m[0], None
    if m:
        return None, f'Error: block target "{t}" is ambiguous' + "".join(f"\n  {label(b)}  …{b[-6:]}  window 1" for b in m) + "\n"
    return None, f'Error: block target "{t}" not found\n'


def info(b):
    return dict({"block_id": b, "label": label(b), "creator_name": "com.superlogical.terminal",
                 "flavor": "com.superlogical.terminal.shell", "host_id": "fake-host", "placement": "placed",
                 "window_id": "window:fake"}, **BLOCKS[b].get("ls_extra", {}))


def inject(method, cur, bs):
    """Transient failure / garbage for the first N calls of METHOD in this step."""
    if LAUNCH:
        return None
    n = bs["mcalls"].get(method, 0)
    bs["mcalls"][method] = n + 1
    if n < cur.get("fail", {}).get(method, 0):
        sys.stderr.write("Error: transient failure (fake)\n")
        return "fail"
    if n < cur.get("garbage", {}).get(method, 0):
        return "garbage"
    return None


def child_pid(cur):
    """The pane's child pid: the step's, else the running stand-in for its argv0, else 4242."""
    name = os.path.basename(cur.get("argv0", "claude")).lstrip("-")
    return cur.get("pid", AGENTS.get(name, {}).get("pid", 4242))


def process_json(cur):
    """The real shape: child {name,path,pid,user,user_id}, foreground adds argv0, cwd and invoked_path."""
    p = cur.get("process", "alive")
    if p == "alive":
        argv0 = cur.get("argv0", "claude")
        name = os.path.basename(argv0).lstrip("-")
        path = cur.get("child_path", AGENTS.get(name, {}).get("path", "/fake/bin/" + name))
        who = {"pid": child_pid(cur), "user_id": 501, "user": "fake", "name": name, "path": path}
        fg = dict(who, invoked_path=path, argv0=argv0, cwd=cur.get("cwd", "/fake/cwd"))
        return {"last_exit": None, "child": who, "foreground": fg, "ancestors": [], "home": "/home/fake"}
    if p == "exited":
        code = cur.get("exit_code", 0)
        return {"last_exit": {"exit_code": code, "error": f"exit status {code}" if code else None}, "home": "/home/fake"}
    return p  # a literal dict from the scenario


def records_json(cur):
    recs = []
    for r in cur.get("records", []):
        r = dict(r)
        if not r.pop("noapp", False):
            r.setdefault("app", cur.get("app", "claude-code"))
            r.setdefault("effective_app", r["app"])
        r.setdefault("owner", {"pid": child_pid(cur), "name": OWNER.get(r.get("effective_app"), "claude")})
        recs.append(r)
    return {"records": recs}


def targeted(entry, t):
    """Resolve T into entry; returns (block, step, bstate) or None after writing rex's error."""
    b, err = resolve(t)
    entry.update(target=t, block=b)
    if err:
        sys.stderr.write(err)
        return None
    steps, bs, cur = step_of(b)
    return b, cur, bs


def main(argv):
    o, pos = opts(argv)
    entry = {"argv": argv, "env_session": os.environ.get("REX_SESSION"), "env_block": os.environ.get("REX_BLOCK")}
    rc, out = 0, ""
    if argv[:1] == ["new"]:
        entry.update(cmd="session-new")
        name = pos[1]; sid = "session:" + name
        anchor = "block:01a1c0de-0000-7000-8000-00000000a111"
        definition = {"label": "anchor", "steps": [{"name": "anchor", "records": [], "screen": "$ ", "argv0": "bash"}]}
        BLOCKS[anchor] = definition
        ST.setdefault("dynamic_blocks", {})[anchor] = definition
        bstate(anchor).update(session=sid, closed=False)
        ST.setdefault("sessions", {})[sid] = {"session_id": sid, "label": name}
        out = json.dumps({"session_id": sid, "initial_windows": [{"block_ids": [anchor]}]}) + "\n"
    elif argv[:1] == ["ls"]:
        entry.update(cmd="session-ls")
        sessions = [{"session_id": "session:fake", "label": "fake"}]
        sessions += list(ST.get("sessions", {}).values()) + SCN.get("sessions", [])
        out = json.dumps({"sessions": sessions}) + "\n"
    elif argv[:1] == ["kill"]:
        entry.update(cmd="session-kill")
        target = o.get("-s") or (pos[1] if len(pos) > 1 else "")
        sessions = ST.setdefault("sessions", {})
        sid = next((k for k, v in sessions.items() if k == target or v["label"] == target), target)
        sessions.pop(sid, None)
        for b in list(ST["blocks"]):
            if ST["blocks"][b].get("session") == sid: ST["blocks"][b]["closed"] = True
    elif argv[:2] == ["block", "call"]:
        method = pos[2] if len(pos) > 2 else None
        entry.update(cmd="call", method=method)
        tb = targeted(entry, o.get("-b"))
        if not tb:
            rc = 3
        else:
            b = tb[0]
            advance(b, method)
            _, bs, cur = step_of(b)
            entry["step"] = cur.get("name", str(bs["step"]))
            how = inject(method, cur, bs)
            if how == "fail":
                rc = 1
            elif how == "garbage":
                out = cur.get("garbage_text", "<html>garbage") + "\n"
            elif method == "program_status":
                out = json.dumps(records_json(cur)) + "\n"
            elif method == "process":
                out = json.dumps(process_json(cur)) + "\n"
            elif method == "title":
                out = json.dumps({"title": cur.get("title", "")}) + "\n"
            elif method == "size":
                out = json.dumps({"columns": cur.get("cols", 80), "rows": cur.get("rows", 24)}) + "\n"
            else:
                rc = 1; sys.stderr.write(f"Error: unknown method {method}\n")
    elif argv[:1] == ["capture"]:
        entry.update(cmd="capture")
        tb = targeted(entry, o.get("-b"))
        if not tb:
            rc = 3
        else:
            b = tb[0]
            advance(b, "capture")
            _, bs, cur = step_of(b)
            entry["step"] = cur.get("name", str(bs["step"]))
            if inject("capture", cur, bs) == "fail":
                rc = 1
            else:
                scr = cur.get("screen", "")
                if bs.get("cwd"):
                    for tok in sorted(SCN.get("dir_as", DIR_TOKENS), key=len, reverse=True):
                        scr = put_dir(scr, tok, bs["cwd"])
                if bs.get("cwd") and cur.get("claude_row", True):
                    scr = claude_row(scr, cur, bs["cwd"])
                if bs.get("typed") is not None and cur.get("echo", True):
                    scr = echo_typed(scr, bs["typed"])
                # Real `capture --trim` keeps the blank rows below short content (REX-AGENTS.md gotcha 6).
                out = scr.rstrip("\n") + "\n" + "\n" * cur.get("pad", 8)
    elif argv[:2] == ["block", "ls"]:
        entry.update(cmd="ls")
        order = [ORCH] + [b for b in BLOCKS if b != ORCH]
        out = json.dumps({"blocks": [info(b) for b in order if b in live() and not BLOCKS[b].get("unlisted") and
                                   (not ST.get("sessions") or bstate(b).get("session", "session:fake") == o.get("-s", "session:fake"))]}) + "\n"
    elif argv[:2] == ["block", "inspect"]:
        entry.update(cmd="inspect")
        tb = targeted(entry, pos[2] if len(pos) > 2 else None)
        if not tb:
            rc = 3
        else:
            b, cur, bs = tb
            how = inject("inspect", cur, bs)
            if how == "fail":
                rc = 1
            elif how == "garbage":
                out = cur.get("garbage_text", "<html>garbage") + "\n"
            else:
                out = json.dumps({"session_id": o.get("-s", "session:fake"), "block": info(b)}) + "\n"
    elif argv[:2] == ["block", "rename"]:
        entry.update(cmd="rename")
        args = pos[2:] + o.get("--", [])  # rename [BLOCK] LABEL; '--' may come before either
        tb = targeted(entry, args[0] if len(args) > 1 else None)
        if not tb:
            rc = 3
        elif inject("rename", tb[1], tb[2]) == "fail":
            rc = 1
        else:
            bstate(tb[0])["label"] = args[-1]
    elif argv[:1] == ["send"]:
        # Bytes, so typed text that isn't UTF-8 (a Latin-1 file) is logged instead of crashing the fake.
        text = " ".join(o["--"]) if "--" in o else pos[1] if len(pos) > 1 else sys.stdin.buffer.read().decode("utf-8", "replace")
        entry.update(cmd="send", stdin=text)
        tb = targeted(entry, o.get("-b"))
        if not tb:
            rc = 3
        else:
            b, cur, bs = tb
            entry["step"] = cur.get("name", str(bs["step"]))
            if inject("send", cur, bs) == "fail":
                rc = 1
            else:
                bs["typed"] = (bs.get("typed") or "") + text
                if cur.get("on_send"):
                    jump(b, cur["on_send"])
    elif argv[:1] == ["send-key"]:
        keys = pos[1:] + o.get("--", [])
        entry.update(cmd="send-key", keys=keys)
        tb = targeted(entry, o.get("-b"))
        if not tb:
            rc = 3
        else:
            b, cur, bs = tb
            entry["step"] = cur.get("name", str(bs["step"]))
            if inject("send-key", cur, bs) == "fail":
                rc = 1
            else:
                if "enter" in keys:
                    bs["typed"] = None
                for path, text in cur.get("key_writes", {}).get(" ".join(keys), []):
                    open(path, "w").write(text)
            if rc == 0 and cur.get("on_key", {}).get(" ".join(keys)):
                jump(b, cur["on_key"][" ".join(keys)])
    elif argv[:1] == ["split"] or argv[:2] == ["window", "new"]:
        entry.update(cmd="split" if argv[0] == "split" else "window-new", opts=o, pos=pos)
        nb = SCN["new_block"]
        anchor_err = resolve(o["-b"])[1] if "-b" in o else None
        if anchor_err:
            rc = 3; sys.stderr.write(anchor_err)
        elif SCN.get("create_rc"):
            rc = SCN["create_rc"]; sys.stderr.write("Error: create failed (fake)\n")
        elif "create_out" in SCN:
            out = SCN["create_out"] + "\n"
        else:
            bstate(nb)["cwd"] = o.get("-c")
            bstate(nb)["session"] = o.get("-s", "session:fake")
            # The agent the pane runs, by name: its spawn command's first word that names a stand-in (after env's VAR=).
            agent = next((os.path.basename(w) for w in o.get("--", []) if os.path.basename(w) in AGENTS), None)
            if agent:
                bstate(nb)["argv0"] = agent
            if argv[0] == "split":
                bstate(nb)["label"] = o.get("--label", "shell")
            else:
                ST.setdefault("windows", {})["window:fake"] = {"label": pos[2] if len(pos) > 2 else "", "block": nb}
            res = {"block_ids": [nb], "revision": 1}
            res.update({"window_id": "window:fake"} if argv[0] == "window" else {"anchor_id": o.get("-b"), "split_ids": ["split:fake"]})
            out = json.dumps(res, indent=2) + "\n"
            if SCN.get("split_delay"):
                # Rex has made the pane: a CLI killed now never prints its ID.
                entry.update(rc=0, out=out[:300]); log(entry); save()
                open(os.path.join(D, "split_started"), "w").close()
                time.sleep(SCN["split_delay"])
                sys.stdout.write(out)
                return 0
    elif argv[:2] in (["window", "inspect"], ["window", "rename"]):
        entry.update(cmd="window-" + argv[1])
        ws = ST.setdefault("windows", {})
        t = pos[2] if len(pos) > 2 else None
        w = next((k for k, v in ws.items() if (t in (k, v["label"])) and not bstate(v["block"])["closed"]), None)
        entry.update(target=t, window=w)
        if not w:
            rc = 3; sys.stderr.write(f'Error: window target "{t}" not found\n')
        elif argv[1] == "rename":
            ws[w]["label"] = pos[3] if len(pos) > 3 else o.get("--", [""])[-1]
        else:
            out = json.dumps({"window_id": w, "label": ws[w]["label"], "focused_block_id": ws[w]["block"],
                              "layers": [{"layout": {"block_id": ws[w]["block"]}, "blocks": [{"block_id": ws[w]["block"]}]}]}) + "\n"
    elif argv[:2] == ["block", "close"]:
        entry.update(cmd="close")
        tb = targeted(entry, pos[2] if len(pos) > 2 else None)
        if not tb:
            rc = 3
        elif ST.setdefault("close_fails", 0) < SCN.get("close_fail", 0):
            ST["close_fails"] += 1
            rc = 1; sys.stderr.write("Error: transient failure (fake close)\n")
        else:
            time.sleep(SCN.get("close_delay", 0))
            bstate(tb[0])["closed"] = True
    elif argv[:2] == ["server", "status"]:
        entry.update(cmd="server-status")
        out = json.dumps({"rex_version": SCN.get("rex_version", "fake-rex-1"), "api_revision": 1}) + "\n"
    else:
        entry.update(cmd="unknown")
        rc = 1; sys.stderr.write("fake rex: unsupported command\n")
    entry.update(rc=rc, out=out[:300])
    log(entry)
    save()
    sys.stdout.write(out)
    return rc


sys.exit(main(sys.argv[1:]))
