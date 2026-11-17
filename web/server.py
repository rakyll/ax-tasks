#!/usr/bin/env python3
"""Web view of an AX task tree: ../tree.sh, or ../rollout.sh with TREE_SCRIPT.

A small stdlib-only server. It reads the tree from `<script> nodes`, polls
each task's state (`ax get tasks`), identity (`ax get task`), and progress and
log (`ax ssh <task> -- ...`) in the background, and runs `<script> up | steer |
down` when the page asks.

    AX_CONTEXT=kind-gemini-api AX_BIN=$PWD/.bin/ax web/server.py
    TREE_SCRIPT=rollout.sh AX_CONTEXT=kind-gemini-api AX_BIN=$PWD/.bin/ax web/server.py

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

HERE = Path(__file__).resolve().parent
SCRIPT = str(HERE.parent / os.environ.get("TREE_SCRIPT", "tree.sh"))
AX_BIN = os.environ.get("AX_BIN", "ax")
ATESPACE = os.environ.get("ATESPACE", "default")
PORT = int(os.environ.get("PORT", "8377"))
POLL_SECONDS = 2

LOG_LINE = re.compile(r"^(\S+) \[([^\]]+)\] (.*)$")


def run(args, stdin=None, timeout=120):
    p = subprocess.run(args, input=stdin, capture_output=True, text=True, timeout=timeout)
    return p.returncode, (p.stdout + p.stderr).strip()


def load_nodes():
    _, out = run([SCRIPT, "nodes"])
    nodes = []
    for line in out.splitlines():
        # name, parents (comma-separated, "-" for the root), goal[, kind]
        name, parents, goal, *kind = line.split("\t")
        nodes.append({"name": name, "parents": [] if parents == "-" else parents.split(","),
                      "goal": goal, "kind": kind[0] if kind else ""})
    return nodes


def load_presets():
    code, out = run([SCRIPT, "presets"])
    return out.splitlines() if code == 0 else []


NODES = load_nodes()
PRESETS = load_presets()

lock = threading.Lock()
# started: the task has been seen running, so a stopped one is suspended, not pending.
EMPTY = {"state": "Absent", "status": None, "steer": [], "log": [], "identity": None, "started": False}
state = {n["name"]: dict(EMPTY) for n in NODES}
activity = []  # [{time, text, kind}], newest last
busy = None  # description of the up/down action in flight, if any


def note(text, kind="info"):
    with lock:
        activity.append({"time": time.strftime("%H:%M:%S"), "text": text, "kind": kind})
        del activity[:-300]


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
    gw = (re.search(r"^\s+gateway:\n\s+name: (\S+)", out, re.M) or [None, ""])[1]
    return {
        "actor": field("actor") or name,
        "gateway": gw,
        "cpu": field("cpu"),
        "memory": field("memory"),
        "actorUid": field("actorUid"),
        # status.id on servers before #587, metadata.uid after.
        "taskId": field("uid") or field("id"),
        "worker": field("workerIP"),
    }


def poll_task(name):
    # Progress (if the agent reports any), every steering message it has
    # received, then its most recent log lines.
    script = ("cat /workspace/status 2>/dev/null; echo; echo ---; "
              "grep -F STEERED /workspace/agent.log; echo ---; tail -n 4 /workspace/agent.log")
    code, out = run([AX_BIN, "-a", ATESPACE, "ssh", name, "--", "sh", "-c", script], timeout=30)
    if code != 0 or out.count("---") < 2:
        return None
    status_part, steered, recent = out.split("---", 2)
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
    return status, steer, log


def poller():
    pool = ThreadPoolExecutor(max_workers=2 * len(NODES))
    while True:
        states = poll_states()
        if states is not None:
            running = [n["name"] for n in NODES if states.get(n["name"]) in ("Running", "Working")]
            tasks = dict(zip(running, pool.map(poll_task, running)))
            # Identity and policy change only when a task is (re)created or
            # changes state. Pending tasks have both too.
            with lock:
                stale = [n["name"] for n in NODES if n["name"] in states and
                         (not state[n["name"]]["identity"] or state[n["name"]]["state"] != states[n["name"]])]
            identities = dict(zip(stale, pool.map(poll_identity, stale)))
            with lock:
                for n in NODES:
                    s, name = state[n["name"]], n["name"]
                    s["state"] = states.get(name, "Absent")
                    s["started"] = s["started"] or name in running
                    if name in identities:
                        s["identity"] = identities[name]
                    if tasks.get(name):
                        s["status"], s["steer"], s["log"] = tasks[name]
                    elif s["state"] == "Absent":
                        s.update(EMPTY)
        time.sleep(POLL_SECONDS)


def stream(desc, argv, shown):
    """Run a command, copying its output into the activity feed as it goes."""
    note("$ " + " ".join(json.dumps(a) if " " in a else a for a in shown), "cmd")
    p = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    for line in p.stdout:
        note(line.rstrip(), "out")
    code = p.wait()
    note(f"{desc}: {'done' if code == 0 else 'failed (exit %d)' % code}", "ok" if code == 0 else "err")


def start(desc, args, exclusive, ax_cmd=False):
    """Run a script command (or, with ax_cmd, an ax command) in the background.
    Only one exclusive action runs at a time."""
    global busy
    if exclusive:
        with lock:
            if busy:
                return False
            busy = desc

    def work():
        global busy
        try:
            if ax_cmd:
                stream(desc, [AX_BIN, "-a", ATESPACE] + args, ["ax"] + args)
            else:
                stream(desc, [SCRIPT] + args, ["./" + Path(SCRIPT).name] + args)
        finally:
            if exclusive:
                with lock:
                    busy = None

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
        if self.path == "/":
            self.send(200, (HERE / "index.html").read_bytes(), "text/html; charset=utf-8")
        elif self.path == "/axel.svg":
            self.send(200, (HERE / "axel.svg").read_bytes(), "image/svg+xml")
        elif self.path == "/api/state":
            with lock:
                nodes = [{**n, **state[n["name"]]} for n in NODES]
                self.send(200, {"script": Path(SCRIPT).name, "atespace": ATESPACE, "presets": PRESETS,
                                "nodes": nodes, "activity": activity[-120:], "busy": busy})
        else:
            self.send(404, {"error": "not found"})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or "{}")
        if self.path == "/api/up":
            ok = start("start", ["up"], exclusive=True)
        elif self.path == "/api/down":
            ok = start("tear down", ["down"], exclusive=True)
        elif self.path == "/api/steer":
            # Steering is never blocked: it is how you change a rollout while it runs.
            node, msg = body.get("node", ""), body.get("msg", "").strip()
            if node not in state or not msg:
                return self.send(400, {"error": "need a known node and a message"})
            ok = start(f"steer {node}", ["steer", node, msg], exclusive=False)
        elif self.path == "/api/task":
            # Suspend or resume a single task, straight through ax.
            node, op = body.get("node", ""), body.get("op", "")
            if node not in state or op not in ("suspend", "resume"):
                return self.send(400, {"error": "need a known node and op suspend|resume"})
            ok = start(f"{op} {node}", [op, "task", node], exclusive=False, ax_cmd=True)
        else:
            return self.send(404, {"error": "not found"})
        self.send(202 if ok else 409, {"ok": ok})


if __name__ == "__main__":
    threading.Thread(target=poller, daemon=True).start()
    print(f"AX task tree ({Path(SCRIPT).name}): http://localhost:{PORT}")
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
