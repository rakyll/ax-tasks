#!/usr/bin/env bash
# AX collab: Antigravity and Claude Code fix a bug and test it together.
#
#   Workspace checkout-fix          one repo, one issue, one set of conventions
#   ├── antigravity   Task          fixes cart.py
#   └── claude-code   Task          writes the tests and reviews the fix
#
# Both agents bind the same AX Workspace, seeded with a small checkout
# service: cart.py (with a bug), its tests, the issue (ISSUE.md) and the
# team's conventions (AGENTS.md). Every Task gets its own copy of the
# Workspace, the way every developer gets their own clone, so the agents
# collaborate the way developers do: in commits. Each one hands its commits to
# the other as patches (`git format-patch`, `git am`), and `run` is the
# controller that carries them between the two sandboxes over `ax ssh`.
#
#   1. antigravity reproduces #142 and fixes it; claude-code writes regression
#      tests, which fail against the unfixed code.
#   2. claude-code tests the fix: quantity passes, but the coupon test shows
#      the discount is rounded down, not half up as AGENTS.md asks. It sends
#      its tests back with that review.
#   3. antigravity applies the tests, fixes the rounding and sends fix v2.
#   4. claude-code approves once every test passes. Both sandboxes end with
#      the same history: fixes by Antigravity, tests by Claude Code.
#
# Every agent has its own identity (its Substrate actor) and its own policy:
# a Gateway that lets it reach its own model API only (Antigravity the Gemini
# API, Claude Code the Anthropic API), and CPU and memory limits. On start
# each agent proves its policy by calling both APIs.
#
# The agents are small shell scripts, so the demo runs with no model
# credentials; the fixes, tests and git history in the sandboxes are real.
#
# Steering reaches one agent:
#   pause     hold at the current step     resume  carry on
#   also cover an empty cart
#             (claude-code) add one more test and hand it to antigravity
#
# Usage:
#   ./collab.sh up                     create the workspace and agents, then run
#   ./collab.sh run                    start the agents and carry their handoffs
#   ./collab.sh steer <agent> <msg>    e.g. steer claude-code 'also cover an empty cart'
#   ./collab.sh status                 show both agents
#   ./collab.sh down                   delete the agents, gateways and workspace
#
# Environment:
#   AX_BIN            ax CLI                    (default: ax)
#   ATESPACE          atespace                  (default: default)
#   AX_TASK_IMAGE     digest-pinned task image  (default: the server's default)
#   AX_LEGACY_SCHEMA  set for ax-servers built before #587 (no labels, `command`)
#   COLLAB_TICK       seconds per step          (default: 3)

set -euo pipefail

AX_BIN="${AX_BIN:-ax}"
ATESPACE="${ATESPACE:-default}"
TASK_IMAGE="${AX_TASK_IMAGE:-}"
TICK="${COLLAB_TICK:-3}"
WORKSPACE=checkout-fix
# STATE remembers, across runs, which agents were started and which handoffs
# were delivered.
STATE="${TMPDIR:-/tmp}/ax-collab-${ATESPACE}"

ax() { command "${AX_BIN}" -a "${ATESPACE}" "$@"; }

# The agents: "name role peer".
AGENTS=(
  "antigravity  fixer   claude-code"
  "claude-code  tester  antigravity"
)

name_of() { awk '{print $1}' <<<"$1"; }
role_of() { awk '{print $2}' <<<"$1"; }
peer_of() { awk '{print $3}' <<<"$(row_of "$1")"; }
names()   { local row; for row in "${AGENTS[@]}"; do name_of "$row"; done; }
row_of()  { local row; for row in "${AGENTS[@]}"; do [[ "$(name_of "$row")" == "$1" ]] && echo "$row"; done; return 0; }

goal_of() {
  case "$(role_of "$1")" in
    fixer) echo "fix #142 in cart.py" ;;
    *)     echo "test the fix for #142 and review it" ;;
  esac
}

# Identity and policy: whose agent it is (the git author of its commits), the
# one model API its gateway lets it reach, and its sandbox limits.
author_of() {
  case "$1" in
    antigravity) echo "Antigravity" ;;
    *) echo "Claude Code" ;;
  esac
}
allow_of() {
  case "$1" in
    antigravity) echo generativelanguage.googleapis.com ;;
    *) echo api.anthropic.com ;;
  esac
}
limits_of() {
  case "$1" in
    antigravity) echo "2 2Gi" ;;
    *) echo "1 1Gi" ;;
  esac
}

# The workspace both agents start from.
read -r -d '' ISSUE <<'MD' || true
# #142 Cart total ignores quantity

Reported by support: a customer bought 3 mugs at $12.50 and was charged
$12.50.

    cart_total([{"price": 1250, "qty": 3}])  # 1250, should be 3750

Fix it and cover it with tests.
MD

read -r -d '' CONVENTIONS <<'MD' || true
# Working in this repo

- Prices are integer cents. Discounts round half up to the nearest cent.
- antigravity owns fixes in cart.py; claude-code owns the tests in
  test_cart.py.
- Every change is a commit. Hand commits to each other as patches
  (git format-patch, git am). A change is done when claude-code approves it
  and every test passes.
- Run the tests with: python3 run_tests.py
MD

read -r -d '' CART <<'PY' || true
"""Shopping cart pricing. All amounts are integer cents."""


def cart_total(items, coupon_pct=0):
    """Total of the items in cents, after a percentage coupon."""
    subtotal = 0
    for item in items:
        subtotal += item["price"]
    discount = subtotal * coupon_pct // 100
    return subtotal - discount
PY

read -r -d '' TESTS <<'PY' || true
from cart import cart_total


def check(got, want):
    assert got == want, f"got {got}, want {want}"


def test_single_item():
    check(cart_total([{"price": 1250, "qty": 1}]), 1250)
PY

read -r -d '' RUNNER <<'PY' || true
"""Runs every test_* function in test_cart.py. Exits 1 if any fails."""
import sys

import test_cart

failed = 0
for name in sorted(n for n in dir(test_cart) if n.startswith("test_")):
    try:
        getattr(test_cart, name)()
        print("PASS", name)
    except AssertionError as e:
        failed += 1
        print("FAIL", name, e)
sys.exit(1 if failed else 0)
PY

read -r -d '' IGNORE <<'TXT' || true
# Agent and AX state, not part of the repo.
.ax/
lost+found/
__pycache__/
agent.log
inbox*
status*
policy
received
steering
outbox/
handoff/
TXT

# AGENT is the command both agents run; ROLE picks the part they play.
# Between steps an agent drains /workspace/inbox, which holds operator
# steering and handoffs from its peer ("from <peer>: <file> <note>", the patch
# itself already copied into handoff/). It hands work to its peer by
# appending "<file> <note>" to outbox/queue.
read -r -d '' AGENT <<'SH' || true
cd /workspace
paused="" seq=0
export GIT_AUTHOR_NAME="$AUTHOR" GIT_COMMITTER_NAME="$AUTHOR"
export GIT_AUTHOR_EMAIL="$NAME@agents.ax" GIT_COMMITTER_EMAIL="$NAME@agents.ax"
log() { echo "$(date +%T) [$NAME] $*" >> agent.log; }
report() { echo "$1 - $2" > status.new && mv status.new status; }

inbox() {
  [ -s inbox ] || return 0
  mv inbox inbox.reading
  while IFS= read -r msg; do
    case "$msg" in
      "from $PEER: "*)
        echo "${msg#"from $PEER: "}" >> received
        log "RECEIVED from $PEER: ${msg#"from $PEER: "}" ;;
      *)
        log "STEERED: $msg"
        case "$msg" in
          pause*) paused=1 ;;
          resume*) paused="" ;;
          *) echo "$msg" >> steering ;;
        esac ;;
    esac
  done < inbox.reading
  rm -f inbox.reading
}

# step reports what the agent is doing, then works on it for a tick. It holds
# while paused.
step() {
  report "$1" "$2"
  log "$1 $2"
  sleep "$TICK"; inbox
  while [ -n "$paused" ]; do
    report PAUSED "paused by operator at: $2"
    sleep 1; inbox
  done
}

# share hands commit $2 (default HEAD) to the peer as a patch, with note $1.
share() {
  seq=$((seq + 1)) f="$NAME-$seq.patch"
  git format-patch -1 --stdout "${2:-HEAD}" > "outbox/$f"
  echo "$f $1" >> outbox/queue
  log "HANDOFF → $PEER: $1 ($f)"
}
# note sends the peer a note with no patch.
note() {
  echo "- $1" >> outbox/queue
  log "HANDOFF → $PEER: $1"
}

# await reports $1, if given, and waits for the next handoff: its patch lands
# in $file ("-" for none) and its note in $msg.
await() {
  [ -n "$1" ] && report WAITING "$1"
  while [ ! -s received ]; do sleep 1; inbox; done
  line=$(head -n 1 received)
  sed -i 1d received
  file=${line%% *} msg=${line#* }
}

# apply applies the patch from the last handoff, if it carried one.
apply() {
  [ "$file" = - ] && return 0
  if git am -q "handoff/$file"; then
    log "APPLIED $file: $(git log -1 --format='%an: %s')"
  else
    git am --abort
    report FAILED "could not apply $file"
    log "FAILED: could not apply $file"
    exec sleep infinity
  fi
}

# tests runs the suite and sets passed, total and failures.
tests() {
  out=$(python3 run_tests.py 2>&1) && ok=1 || ok=""
  passed=$(echo "$out" | grep -c '^PASS' || true)
  total=$(echo "$out" | grep -c -E '^(PASS|FAIL)' || true)
  failures=$(echo "$out" | awk '/^FAIL/ {print $2}' | xargs)
  echo "$out" | while IFS= read -r l; do log "  $l"; done
  log "TESTS: $passed/$total pass"
  [ -n "$ok" ]
}

fixer() {
  step READING "ISSUE.md: #142 cart total ignores quantity"
  step REPRODUCING "3 mugs at 12.50 should total 37.50"
  got=$(python3 -c 'from cart import cart_total; print(cart_total([{"price": 1250, "qty": 3}]))')
  log "REPRODUCED: cart_total(3 x 1250) = $got, want 3750"
  step FIXING "cart.py: multiply each price by its quantity"
  sed -i 's/subtotal += item\["price"\]$/subtotal += item["price"] * item.get("qty", 1)/' cart.py
  git commit -qam "cart: multiply price by quantity (#142)"
  share "fix v1: price × quantity"
  await "fix v1 sent to $PEER, waiting for tests and review"
  apply
  step TESTING "running $PEER's tests"
  if ! tests; then
    step FIXING "cart.py: round discounts half up, per review"
    sed -i 's|discount = subtotal \* coupon_pct // 100|discount = (subtotal * coupon_pct + 50) // 100  # round half up|' cart.py
    git commit -qam "cart: round coupon discounts half up (#142)"
    tests || true
    share "fix v2: round discounts half up, $passed/$total tests pass"
    await "fix v2 sent to $PEER, waiting for review"
  fi
  tests || true
  report DONE "approved by $PEER, $passed/$total tests pass, ready to merge"
  log "DONE: $(git log --format='%an: %s' | head -n 4 | paste -sd ';' -)"
  # Later handoffs (more tests, after steering) are applied and run too.
  while true; do
    await ""
    apply
    step TESTING "running $PEER's new tests"
    tests || true
    report DONE "approved by $PEER, $passed/$total tests pass, ready to merge"
  done
}

tester() {
  step READING "ISSUE.md and AGENTS.md"
  step WRITING_TESTS "regression tests: quantity, coupon rounding"
  cat >> test_cart.py <<'PY'


def test_quantity():
    # #142: three mugs cost three times one mug.
    check(cart_total([{"price": 1250, "qty": 3}]), 3750)


def test_coupon_rounds_half_up():
    # AGENTS.md: discounts round half up. 15% of 59.97 is 8.9955, so 9.00 off.
    check(cart_total([{"price": 1999, "qty": 3}], coupon_pct=15), 5097)
PY
  git commit -qam "test: cover quantity and coupon rounding (#142)"
  tcommit=$(git rev-parse HEAD)
  step TESTING "running the new tests against the unfixed cart"
  tests || true
  log "RED: $passed/$total pass before the fix, as expected"
  await "tests ready ($passed/$total pass), waiting for a fix from $PEER"
  while true; do
    apply
    step TESTING "testing $PEER's $(echo "$msg" | cut -d: -f1)"
    tests && break
    if [ -n "$tcommit" ]; then
      step REVIEWING "$failures fails"
      share "tests + review: $failures fails, 15% off 59.97 must be 9.00 (AGENTS.md: round half up)" "$tcommit"
      tcommit=""
    else
      note "review: $failures still fails"
    fi
    await "review sent, waiting for $PEER's next fix"
  done
  note "approved: $passed/$total tests pass"
  report DONE "approved: $passed/$total tests pass"
  # Steering can ask for more tests; they go to the peer like the first ones.
  while true; do
    while [ ! -s steering ]; do sleep 1; inbox; done
    ask=$(head -n 1 steering)
    sed -i 1d steering
    case "$ask" in
      *empty*)
        step WRITING_TESTS "test: an empty cart costs nothing (steered)"
        printf '\n\ndef test_empty_cart():\n    check(cart_total([]), 0)\n' >> test_cart.py
        git commit -qam "test: cover an empty cart"
        tests || true
        share "new test: empty cart, $passed/$total pass" ;;
      *) log "NOTED: $ask" ;;
    esac
    report DONE "approved: $passed/$total tests pass"
  done
}

# probe checks the task's egress policy from inside the sandbox.
probe() {
  if code=$(curl -sS -o /dev/null -m 5 -w '%{http_code}' "https://$1/" 2>/dev/null); then
    echo "reached (HTTP $code)"
  else
    echo blocked
  fi
}

mkdir -p outbox handoff
touch outbox/queue
report STARTING "checking policy"
a=$(probe "$ALLOW") d=$(probe "$DENY")
printf 'allow %s %s\ndeny %s %s\n' "$ALLOW" "$a" "$DENY" "$d" > policy
log "POLICY: $ALLOW $a; $DENY $d"
git init -q -b main
git add -A
GIT_AUTHOR_NAME="$WORKSPACE" GIT_AUTHOR_EMAIL="$WORKSPACE@workspaces.ax" git commit -qm "checkout service at #142"
log "started: $ROLE in workspace $WORKSPACE, peer $PEER"
"$ROLE"
SH

# indent prints stdin indented by $1 spaces.
indent() { sed "s/^/$(printf "%${1}s")/"; }

manifest() {
  local row name limits image="" f v
  [[ -n "$TASK_IMAGE" ]] && image=$'\n    image: "'"$TASK_IMAGE"'"'
  cat <<YAML
---
apiVersion: ax.io/v1alpha1
kind: Workspace
metadata:
  name: ${WORKSPACE}
  atespace: ${ATESPACE}
spec:
  setup:
    files:
YAML
  for f in ISSUE.md:ISSUE AGENTS.md:CONVENTIONS cart.py:CART test_cart.py:TESTS run_tests.py:RUNNER .gitignore:IGNORE; do
    v=${f#*:}
    printf '      - path: %s\n        content: |\n' "${f%%:*}"
    indent 10 <<<"${!v}"
  done
  for row in "${AGENTS[@]}"; do
    name=$(name_of "$row")
    limits=($(limits_of "$name"))
    cat <<YAML
---
apiVersion: ax.io/v1alpha1
kind: Gateway
metadata:
  name: gw-${name}
  atespace: ${ATESPACE}
spec:
  egress:
    - https:
        hostnames: ["$(allow_of "$name")"]
---
apiVersion: ax.io/v1alpha1
kind: Task
metadata:
  name: ${name}
  atespace: ${ATESPACE}
  labels:
    ax.io/tree: collab
    ax.io/parent: ""
spec:
  debug: true # handoffs and steering go through ax ssh
  workspace: {name: ${WORKSPACE}}
  gateway: {name: gw-${name}}
  profile:${image}
    resources:
      limits: {cpu: "${limits[0]}", memory: "${limits[1]}"}
  commands:
    - sh
    - -c
    - |
$(indent 6 <<<"$AGENT")
  env:
    - {name: NAME, value: "${name}"}
    - {name: ROLE, value: "$(role_of "$row")"}
    - {name: PEER, value: "$(peer_of "$name")"}
    - {name: AUTHOR, value: "$(author_of "$name")"}
    - {name: WORKSPACE, value: "${WORKSPACE}"}
    - {name: TICK, value: "${TICK}"}
    - {name: ALLOW, value: "$(allow_of "$name")"}
    - {name: DENY, value: "$(allow_of "$(peer_of "$name")")"}
YAML
  done
}

# snapshot writes the task list to $1/tasks and, for every running agent, its
# status line to $1/<agent> and its outbox queue to $1/<agent>.queue.
snapshot() {
  local dir="$1" name
  ax get tasks > "$dir/tasks"
  for name in $(names); do
    rm -f "$dir/$name" "$dir/$name.queue"
    if is_running "$dir" "$name"; then
      (ax ssh "$name" -- sh -c 'cat /workspace/status; echo; echo ---; cat /workspace/outbox/queue' \
        </dev/null 2>/dev/null | awk -v s="$dir/$name" -v q="$dir/$name.queue" \
        '/^---$/ {f = 1; next} !f && NF {print > s} f {print > q}' || true) &
    fi
  done
  wait
}

is_running() { awk -v n="$2" '$1 == n && ($3 == "Running" || $3 == "Working") {f = 1} END {exit !f}' "$1/tasks"; }
is_present() { awk -v n="$2" 'NR > 1 && $1 == n {f = 1} END {exit !f}' "$1/tasks"; }

# phase prints an agent's phase: PENDING until it is started, SUSPENDED when it
# was started and is no longer running, STARTING until it reports.
phase() {
  if ! is_running "$1" "$2"; then
    if [[ -e "$STATE/$2.started" ]]; then echo SUSPENDED; else echo PENDING; fi
  elif [[ -s "$1/$2" ]]; then awk '{print $1; exit}' "$1/$2"
  else echo STARTING
  fi
}

detail() { [[ -s "$1/$2" ]] && cut -d' ' -f3- "$1/$2" || true; }

# deliver carries agent $2's new handoffs to its peer: the patch into the
# peer's handoff/, then the note into its inbox. It sets undelivered when a
# handoff has to wait (the peer is not running).
deliver() {
  local dir="$1" a="$2" peer sent n=0 line f msg
  peer=$(peer_of "$a")
  sent=$(cat "$STATE/$a.sent" 2>/dev/null || echo 0)
  [[ -s "$dir/$a.queue" ]] || return 0
  while IFS= read -r line <&3; do
    n=$((n + 1))
    ((n <= sent)) && continue
    if ! is_running "$dir" "$peer"; then undelivered=1; return 0; fi
    f=${line%% *} msg=${line#* }
    if [[ "$f" != - ]]; then
      ax ssh "$a" -- cat "/workspace/outbox/$f" </dev/null |
        ax ssh "$peer" -- sh -c "mkdir -p /workspace/handoff && cat > /workspace/handoff/$f" ||
        { undelivered=1; return 0; }
    fi
    printf 'from %s: %s %s\n' "$a" "$f" "$msg" | ax ssh "$peer" -- sh -c 'cat >> /workspace/inbox' ||
      { undelivered=1; return 0; }
    echo "$n" > "$STATE/$a.sent"
    printf '⇄ %s → %s: %s%s\n' "$a" "$peer" "$msg" "$([[ "$f" != - ]] && echo " ($f)")"
  done 3< "$dir/$a.queue"
}

# run starts both agents and carries their handoffs until both are done and
# nothing is left to deliver. One controller runs at a time.
run() {
  local dir name p prev active quiet=0 undelivered
  mkdir -p "$STATE"
  if ! mkdir "$STATE/lock" 2>/dev/null; then
    echo "a controller is already carrying handoffs"
    return 0
  fi
  dir=$(mktemp -d)
  trap "rmdir '$STATE/lock' 2>/dev/null; rm -rf '$dir'" EXIT
  while true; do
    snapshot "$dir"
    active=0 undelivered=0
    for name in $(names); do
      is_present "$dir" "$name" || { echo "${name} is gone"; return 0; }
      is_running "$dir" "$name" && touch "$STATE/$name.started"
      p=$(phase "$dir" "$name")
      if [[ "$p" == PENDING ]]; then
        echo "▶ ${name}: starting"
        touch "$STATE/$name.started"
        ax resume task "$name" >/dev/null &
        p=STARTING
      fi
      prev=$(cat "$STATE/$name.prev" 2>/dev/null || echo PENDING)
      if [[ "$p" != "$prev" ]]; then
        printf '  %-12s %s → %s  %s\n' "$name" "$prev" "$p" "$(detail "$dir" "$name")"
        echo "$p" > "$STATE/$name.prev"
      fi
      case "$p" in
        DONE | FAILED) ;;
        *) active=1 ;;
      esac
    done
    for name in $(names); do deliver "$dir" "$name"; done
    wait
    # Done once both agents have been done, with nothing left to deliver, for
    # two snapshots in a row: a handoff just delivered gets time to land.
    if ((active || undelivered)); then quiet=0; else quiet=$((quiet + 1)); fi
    ((quiet >= 2)) && break
    sleep 2
  done
  echo "both agents are done:"
  for name in $(names); do printf '  %-12s %s  %s\n' "$name" "$(phase "$dir" "$name")" "$(detail "$dir" "$name")"; done
}

up() {
  rm -rf "$STATE"
  if [[ -n "${AX_LEGACY_SCHEMA:-}" ]]; then
    # Servers built before #587 know neither labels nor `commands`, and take
    # image and resources directly under spec.
    manifest | sed -E -e '/^  labels:/d' -e '/^    ax\.io\//d' -e 's/^  commands:/  command:/' \
      -e '/^  profile:$/d' -e 's/^    (image|resources):/  \1:/' -e 's/^      limits:/    limits:/' |
      ax apply -f -
  else
    manifest | ax apply -f -
  fi
  run
}

# steer writes $2 into the inbox of agent $1, then carries any handoffs the
# steering leads to.
steer() {
  local dir
  dir=$(mktemp -d)
  ax get tasks > "$dir/tasks"
  if is_running "$dir" "$1"; then
    printf '  → %s\n' "$1"
    printf '%s\n' "$2" | ax ssh "$1" -- sh -c 'cat >> /workspace/inbox'
  else
    printf '  · %s (not running)\n' "$1"
  fi
  rm -rf "$dir"
  sleep $((TICK + 1))
  run
}

status() {
  local dir name
  dir=$(mktemp -d)
  snapshot "$dir"
  for name in $(names); do
    printf '%-12s %-14s %s\n' "$name" "$(phase "$dir" "$name")" "$(detail "$dir" "$name")"
  done
  rm -rf "$dir"
}

down() {
  local name
  for name in $(names); do
    ax delete task "$name" 2>/dev/null || true
    ax delete gateway "gw-$name" 2>/dev/null || true
  done
  ax delete workspace "$WORKSPACE" 2>/dev/null || true
  rm -rf "$STATE"
}

case "${1:-}" in
  up)       up ;;
  run)      run ;;
  steer)    shift; [[ $# -eq 2 ]] || { echo "usage: $0 steer <agent> <msg>" >&2; exit 2; }; steer "$@" ;;
  status)   status ;;
  down)     down ;;
  manifest) manifest ;;
  about)    printf 'Agents collaborating\tAntigravity and Claude Code, each in its own sandboxed AX Task, start from the same AX Workspace and hand commits to each other until the fix and its tests are done. Pick an agent to steer it.\n' ;;
  nodes)    for row in "${AGENTS[@]}"; do
              printf '%s\t-\t%s\t%s\n' "$(name_of "$row")" "$(goal_of "$row")" "$(role_of "$row")"
            done ;;
  presets)  printf '%s\n' pause resume "also cover an empty cart" ;;
  *)        sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 2 ;;
esac
