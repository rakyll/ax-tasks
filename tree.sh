#!/usr/bin/env bash
# AX task tree: compose several Tasks into an execution tree and steer them.
#
# AX gives you one small primitive, the Task, and leaves composition to you.
# This demo builds a tree out of plain Tasks:
#
#   lead
#   ├── backend
#   │   └── backend-tests
#   └── docs
#
# - Structure: every Task carries an `ax.io/parent` label, so the tree is
#   recorded in AX itself, not only in this script.
# - Execution: parents are resumed before their children.
# - Steering: every agent watches /workspace/inbox. `steer <node> <msg>` writes
#   the message into the inbox of <node> and of every task below it, over
#   `ax ssh`. Steer the root and the whole tree changes course; steer
#   `backend` and only that subtree does.
#
# The agents are tiny shell loops so the demo runs on the default task image
# with no model credentials. A real agent (Claude Code, Gemini CLI, ...) only
# needs to read the same inbox file between turns.
#
# Usage:
#   ./tree.sh demo                 run everything below end to end
#   ./tree.sh up                   create and start the tree
#   ./tree.sh steer <node> <msg>   steer <node> and its subtree
#   ./tree.sh logs [node]          show what each agent in the subtree is doing
#   ./tree.sh down                 delete every task in the tree
#
# Environment:
#   AX_BIN         ax CLI         (default: ax)
#   ATESPACE       atespace       (default: default)
#   AX_TASK_IMAGE  digest-pinned task image (default: the server's default)
#   AX_LEGACY_SCHEMA  set for ax-servers built before #587 (no labels, `command`)

set -euo pipefail

AX_BIN="${AX_BIN:-ax}"
ATESPACE="${ATESPACE:-default}"
TASK_IMAGE="${AX_TASK_IMAGE:-}"

ax() { command "${AX_BIN}" -a "${ATESPACE}" "$@"; }

# The tree: "name parent goal", parents before children.
TREE=(
  "lead          -        ship release 1.0"
  "backend       lead     implement the /orders API"
  "backend-tests backend  write tests for /orders"
  "docs          lead     document the /orders API"
)

name_of()   { awk '{print $1}' <<<"$1"; }
parent_of() { awk '{print $2}' <<<"$1"; }
goal_of()   { awk '{$1 = $2 = ""; sub(/^ +/, ""); print}' <<<"$1"; }

# children prints the direct children of $1.
children() {
  local row
  for row in "${TREE[@]}"; do
    [[ "$(parent_of "$row")" == "$1" ]] && name_of "$row"
  done
  return 0
}

# subtree prints $1 and all of its descendants, depth first.
subtree() {
  echo "$1"
  local c
  for c in $(children "$1"); do subtree "$c"; done
}

# print_tree draws the subtree under $1.
print_tree() {
  local node="$1" prefix="${2:-}" kids i n
  [[ -z "$prefix" ]] && echo "$node"
  kids=($(children "$node"))
  n=${#kids[@]}
  for ((i = 0; i < n; i++)); do
    if ((i == n - 1)); then
      echo "${prefix}└── ${kids[i]}"; print_tree "${kids[i]}" "${prefix}    "
    else
      echo "${prefix}├── ${kids[i]}"; print_tree "${kids[i]}" "${prefix}│   "
    fi
  done
}

# AGENT is the command every node runs. It works toward its own goal and,
# between steps, drains /workspace/inbox: each message there is added to the
# steering that shapes the rest of its work. The inbox is renamed before it is
# read, so a message that arrives mid-read lands in a fresh inbox instead of
# being lost.
read -r -d '' AGENT <<'SH' || true
cd /workspace
steer=""
echo "$(date +%T) [$NAME] started (parent: ${PARENT:-none}), goal: $GOAL" >> agent.log
while true; do
  if [ -s inbox ]; then
    mv inbox inbox.reading
    while IFS= read -r msg; do
      echo "$(date +%T) [$NAME] STEERED: $msg" >> agent.log
      steer="${steer:+$steer; }$msg"
    done < inbox.reading
    rm -f inbox.reading
  fi
  echo "$(date +%T) [$NAME] working on: $GOAL${steer:+ [$steer]}" >> agent.log
  sleep 5
done
SH

manifest() {
  local row name parent
  for row in "${TREE[@]}"; do
    name=$(name_of "$row"); parent=$(parent_of "$row")
    [[ "$parent" == "-" ]] && parent=""
    cat <<YAML
---
apiVersion: ax.io/v1alpha1
kind: Task
metadata:
  name: ${name}
  atespace: ${ATESPACE}
  labels:
    ax.io/tree: $(name_of "${TREE[0]}")
    ax.io/parent: "${parent}"
spec:
  debug: true # steering goes through ax ssh
  commands:
    - sh
    - -c
    - |
$(sed 's/^/      /' <<<"$AGENT")
  env:
    - {name: NAME, value: "${name}"}
    - {name: PARENT, value: "${parent}"}
    - {name: GOAL, value: "$(goal_of "$row")"}
YAML
    if [[ -n "$TASK_IMAGE" ]]; then
      printf '  profile:\n    image: "%s"\n' "$TASK_IMAGE"
    fi
  done
}

up() {
  if [[ -n "${AX_LEGACY_SCHEMA:-}" ]]; then
    # Servers built before #587 know neither labels nor `commands`.
    manifest | sed -e '/^  labels:/d' -e '/ax\.io\//d' -e 's/^  commands:/  command:/' | ax apply -f -
  else
    manifest | ax apply -f -
  fi
  # New tasks start Suspended. Resume parents before children.
  local row
  for row in "${TREE[@]}"; do
    ax resume task "$(name_of "$row")"
  done
  ax get tasks
}

steer() {
  local node="$1" msg="$2" t
  for t in $(subtree "$node"); do
    printf '  → %s\n' "$t"
    # The message travels on stdin, so it needs no shell quoting.
    printf '%s\n' "$msg" | ax ssh "$t" -- sh -c 'cat >> /workspace/inbox'
  done
}

logs() {
  local t
  for t in $(subtree "${1:-$(name_of "${TREE[0]}")}"); do
    ax ssh "$t" -- tail -n "${LINES_PER_TASK:-1}" /workspace/agent.log
  done
}

down() {
  local i
  # Children first, so no task outlives its parent.
  for ((i = ${#TREE[@]} - 1; i >= 0; i--)); do
    ax delete task "$(name_of "${TREE[i]}")" 2>/dev/null || true
  done
}

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then B=$'\e[1;36m' R=$'\e[0m'; else B="" R=""; fi
say() { printf '\n%s━━ %s%s\n\n' "$B" "$*" "$R"; }

demo() {
  local root
  root=$(name_of "${TREE[0]}")

  say "The execution tree"
  print_tree "$root"

  say "Create the tasks and start them, parents first"
  up

  say "Each agent works toward its own goal"
  sleep 6
  logs

  say "Steer the whole tree from the root"
  steer "$root" "freeze features: bug fixes only"
  sleep 6
  logs

  say "Steer one subtree: backend and backend-tests, not lead or docs"
  steer backend "paginate /orders"
  sleep 6
  logs

  say "Done. Clean up with: $0 down"
}

case "${1:-}" in
  demo)  demo ;;
  up)    up ;;
  steer) shift; [[ $# -eq 2 ]] || { echo "usage: $0 steer <node> <msg>" >&2; exit 2; }; steer "$@" ;;
  logs)  shift; logs "$@" ;;
  down)  down ;;
  tree)  print_tree "$(name_of "${TREE[0]}")" ;;
  manifest) manifest ;;
  about) printf 'Task tree\tEach box is a sandboxed AX Task. Pick one and steer it: the message reaches that task and every task below it.\n' ;;
  nodes) for row in "${TREE[@]}"; do
           printf '%s\t%s\t%s\n' "$(name_of "$row")" "$(parent_of "$row")" "$(goal_of "$row")"
         done ;;
  *)     sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 2 ;;
esac
