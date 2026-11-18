#!/usr/bin/env python3
"""Web view of AX task demos: ../tree.sh, ../rollout.sh, ../collab.sh.

A small stdlib-only server. Every script in TREE_SCRIPTS is a demo, shown in
its own tab. For each one it reads the tasks from `<script> nodes`, polls each
task's state (`ax get tasks`), identity (`ax get task`), and progress, log and
git history (`ax ssh <task> -- ...`) in the background, and runs `<script> up |
steer | down` when the page asks.

    AX_CONTEXT=kind-gemini-api AX_BIN=$PWD/.bin/ax web/server.py
    TREE_SCRIPTS=rollout.sh,collab.sh AX_CONTEXT=kind-gemini-api AX_BIN=$PWD/.bin/ax web/server.py

then open http://localhost:8377. Uses the same environment as the scripts
(AX_BIN, ATESPACE, AX_LEGACY_SCHEMA, ...).
"""

import json
import os
import re
import subprocess
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

HERE = Path(__file__).resolve().parent
SCRIPTS = os.environ.get("TREE_SCRIPTS") or os.environ.get("TREE_SCRIPT", "tree.sh")
AX_BIN = os.environ.get("AX_BIN", "ax")
ATESPACE = os.environ.get("ATESPACE", "default")
PORT = int(os.environ.get("PORT", "8377"))
POLL_SECONDS = 2

LOG_LINE = re.compile(r"^(\S+) \[([^\]]+)\] (.*)$")
HANDOFF = re.compile(r"^HANDOFF → (\S+): (.*)$")


def run(args, stdin=None, timeout=120):
    p = subprocess.run(args, input=stdin, capture_output=True, text=True, timeout=timeout)
    return p.returncode, (p.stdout + p.stderr).strip()


lock = threading.Lock()
# started: the task has been seen running, so a stopped one is suspended, not pending.
EMPTY = {"state": "Absent", "status": None, "steer": [], "log": [], "commits": [], "handoffs": [],
         "identity": None, "started": False}


class Demo:
    """One script and the live state of its tasks."""

    def __init__(self, script):
        self.script = str(HERE.parent / script)
        self.key = Path(script).stem
        self.nodes = []
        for line in run([self.script, "nodes"])[1].splitlines():
            # name, parents (comma-separated, "-" for a root), goal[, kind]
            name, parents, goal, *kind = line.split("\t")
            self.nodes.append({"name": name, "parents": [] if parents == "-" else parents.split(","),
                               "goal": goal, "kind": kind[0] if kind else ""})
        code, out = run([self.script, "presets"])
        self.presets = out.splitlines() if code == 0 else []
        # about: "title<TAB>description"; scripts without one are named after the file.
        code, out = run([self.script, "about"])
        self.title, self.about = (out.split("\t", 1) if code == 0 and "\t" in out else (self.key, ""))
        self.state = {n["name"]: dict(EMPTY) for n in self.nodes}
        self.activity = []  # [{time, text, kind}], newest last
        self.busy = None  # description of the up/down action in flight, if any

    def note(self, text, kind="info"):
        with lock:
            self.activity.append({"time": time.strftime("%H:%M:%S"), "text": text, "kind": kind})
            del self.activity[:-300]


DEMOS = {d.key: d for d in map(Demo, SCRIPTS.split(","))}


def poll_states():
    code, out = run([AX_BIN, "-a", ATESPACE, "get", "tasks"], timeout=30)
    if code != 0:
        return None
    states = {}
    for line in out.splitlines()[1:]:
        cols = line.split()
        if len(cols) >= 3:
            states[cols[0]] = cols[2]
    return states


def poll_identity(name):
    """The task's identity (its Substrate actor) and the policy AX applied to it."""
    code, out = run([AX_BIN, "-a", ATESPACE, "get", "task", name], timeout=30)
    if code != 0:
        return None
    field = lambda key: (re.search(rf"^\s+{key}: \"?([^\s\"]+)", out, re.M) or [None, ""])[1]
    ref = lambda key: (re.search(rf"^\s+{key}:\n\s+name: (\S+)", out, re.M) or [None, ""])[1]
    return {
        "actor": field("actor") or name,
        "gateway": ref("gateway"),
        "workspace": ref("workspace"),
        "cpu": field("cpu"),
        "memory": field("memory"),
        "actorUid": field("actorUid"),
        # status.id on servers before #587, metadata.uid after.
        "taskId": field("uid") or field("id"),
        "worker": field("workerIP"),
    }


def poll_task(name):
    # Progress (if the agent reports any), every steering message it has
    # received, every handoff it has made to another agent, its git history
    # (if it keeps one), then its most recent log lines.
    script = ("cd /workspace; cat status 2>/dev/null; echo; echo ---; grep -F STEERED agent.log; echo ---; "
              "grep -F ' HANDOFF ' agent.log; echo ---; "
              "git log --format='%h|%an|%s' -n 6 2>/dev/null; echo ---; tail -n 4 agent.log")
    code, out = run([AX_BIN, "-a", ATESPACE, "ssh", name, "--", "sh", "-c", script], timeout=30)
    if code != 0 or out.count("\n---") < 4:
        return None
    status_part, steered, handoffs, commits, recent = out.split("\n---", 4)
    status = None
    if status_part.strip():
        phase, pct, detail = (status_part.strip().split(" ", 2) + ["", ""])[:3]
        status = {"phase": phase, "pct": int(pct) if pct.isdigit() else None, "detail": detail}
    steer = []
    for line in steered.strip().splitlines():
        m = LOG_LINE.match(line)
        if m and "STEERED: " in m.group(3):
            steer.append(m.group(3).split("STEERED: ", 1)[1])
    log = [{"time": m.group(1), "text": m.group(3)}
           for m in map(LOG_LINE.match, recent.strip().splitlines()) if m]
    sent = []
    for m in map(LOG_LINE.match, handoffs.strip().splitlines()):
        h = m and HANDOFF.match(m.group(3))
        if h:
            sent.append({"time": m.group(1), "to": h.group(1), "text": h.group(2)})
    history = [dict(zip(("hash", "author", "subject"), c.split("|", 2)))
               for c in commits.strip().splitlines() if c.count("|") >= 2]
    return {"status": status, "steer": steer, "log": log, "handoffs": sent, "commits": history}


def poller():
    pool = ThreadPoolExecutor(max_workers=2 * sum(len(d.nodes) for d in DEMOS.values()))
    while True:
        states = poll_states()
        if states is not None:
            for demo in DEMOS.values():
                poll_demo(demo, states, pool)
        time.sleep(POLL_SECONDS)


def poll_demo(demo, states, pool):
    names = [n["name"] for n in demo.nodes]
    running = [name for name in names if states.get(name) in ("Running", "Working")]
    tasks = dict(zip(running, pool.map(poll_task, running)))
    # Identity and policy change only when a task is (re)created or changes
    # state. Pending tasks have both too.
    with lock:
        stale = [name for name in names if name in states and
                 (not demo.state[name]["identity"] or demo.state[name]["state"] != states[name])]
    identities = dict(zip(stale, pool.map(poll_identity, stale)))
    with lock:
        for name in names:
            s = demo.state[name]
            s["state"] = states.get(name, "Absent")
            s["started"] = s["started"] or name in running
            if name in identities:
                s["identity"] = identities[name]
            if tasks.get(name):
                s.update(tasks[name])
            elif s["state"] == "Absent":
                s.update(EMPTY)


def stream(demo, desc, argv, shown):
    """Run a command, copying its output into the demo's activity feed as it goes."""
    demo.note("$ " + " ".join(json.dumps(a) if " " in a else a for a in shown), "cmd")
    p = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    for line in p.stdout:
        demo.note(line.rstrip(), "out")
    code = p.wait()
    demo.note(f"{desc}: {'done' if code == 0 else 'failed (exit %d)' % code}", "ok" if code == 0 else "err")


def start(demo, desc, args, exclusive, ax_cmd=False):
    """Run a script command (or, with ax_cmd, an ax command) in the background.
    Only one exclusive action runs at a time per demo."""
    if exclusive:
        with lock:
            if demo.busy:
                return False
            demo.busy = desc

    def work():
        try:
            if ax_cmd:
                stream(demo, desc, [AX_BIN, "-a", ATESPACE] + args, ["ax"] + args)
            else:
                stream(demo, desc, [demo.script] + args, ["./" + Path(demo.script).name] + args)
        finally:
            if exclusive:
                with lock:
                    demo.busy = None

    threading.Thread(target=work, daemon=True).start()
    return True


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        url = urlparse(self.path)
        if url.path == "/":
            self.send(200, (HERE / "index.html").read_bytes(), "text/html; charset=utf-8")
        elif url.path == "/axel.svg":
            self.send(200, (HERE / "axel.svg").read_bytes(), "image/svg+xml")
        elif url.path == "/api/demos":
            self.send(200, [{"key": d.key, "title": d.title} for d in DEMOS.values()])
        elif url.path == "/api/state":
            demo = DEMOS.get(parse_qs(url.query).get("demo", [""])[0]) or next(iter(DEMOS.values()))
            with lock:
                nodes = [{**n, **demo.state[n["name"]]} for n in demo.nodes]
                self.send(200, {"key": demo.key, "script": Path(demo.script).name, "about": demo.about,
                                "atespace": ATESPACE, "presets": demo.presets, "nodes": nodes,
                                "activity": demo.activity[-120:], "busy": demo.busy})
        else:
            self.send(404, {"error": "not found"})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or "{}")
        demo = DEMOS.get(body.get("demo", ""))
        if not demo:
            return self.send(400, {"error": "need a known demo"})
        if self.path == "/api/up":
            ok = start(demo, "start", ["up"], exclusive=True)
        elif self.path == "/api/down":
            ok = start(demo, "tear down", ["down"], exclusive=True)
        elif self.path == "/api/steer":
            # Steering is never blocked: it is how you change a rollout while it runs.
            node, msg = body.get("node", ""), body.get("msg", "").strip()
            if node not in demo.state or not msg:
                return self.send(400, {"error": "need a known node and a message"})
            ok = start(demo, f"steer {node}", ["steer", node, msg], exclusive=False)
        elif self.path == "/api/task":
            # Suspend or resume a single task, straight through ax.
            node, op = body.get("node", ""), body.get("op", "")
            if node not in demo.state or op not in ("suspend", "resume"):
                return self.send(400, {"error": "need a known node and op suspend|resume"})
            ok = start(demo, f"{op} {node}", [op, "task", node], exclusive=False, ax_cmd=True)
        else:
            return self.send(404, {"error": "not found"})
        self.send(202 if ok else 409, {"ok": ok})


if __name__ == "__main__":
    threading.Thread(target=poller, daemon=True).start()
    print(f"AX tasks ({', '.join(DEMOS)}): http://localhost:{PORT}")
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
