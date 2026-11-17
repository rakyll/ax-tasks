#!/usr/bin/env bash
# AX rollout: a staged production deployment as a tree of AX Tasks.
#
#   canary                    1% of traffic, then bake
#   └── gate-check-1          may it go to production?
#       └── us-central        the first production region, then bake
#           └── gate-check-2  may it go to every region?
#               ├── us-east ────┐    fan out to three regions at once
#               ├── eu-west ────┼── validate   last step, once all three
#               └── asia-south ─┘              regions are DONE
#
# Every stage is its own sandboxed Task. Between stages a gate-check decides
# whether the release may go further (change window, approvals, error budget,
# incidents). After the fan-out, a single validate stage joins the regions and
# checks the release as a whole. All stages are created up front and stay
# Suspended (pending) until all of their parents report DONE; `run` is the
# controller that resumes them. A failed check stops everything below it.
#
# Every task has its own identity (its Substrate actor) and its own policy:
#   - a Gateway, installed as the egress policy of that actor. A deploy reaches
#     only its own region's endpoint, a gate only the approvals API, validate
#     only the metrics API. Anything else is refused.
#   - CPU and memory limits on its sandbox.
# On start every stage proves its policy: it calls the host it is allowed to
# reach and one it is not, and records both results in /workspace/policy.
#
# Each stage writes its progress to /workspace/status and reads
# /workspace/inbox between steps. Steering reaches a stage and every stage
# below it:
#   pause     hold at the current step     resume  carry on
#   rollforward [version]
#             fix forward: deploy an earlier version (default: the one being
#             replaced) as a new release, even after the stage has finished.
#             Goes bottom-up: a deploy starts only once every deploy below it
#             is ROLLED_FORWARD, so the regions go first and the canary last.
#
# validate is set up to fail its p99 latency check, so there is something to
# steer: roll forward from canary and every deploy moves to the earlier
# version. Set ROLLOUT_FAIL= for an all-green rollout.
#
# Usage:
#   ./rollout.sh up                     create every stage, then run
#   ./rollout.sh run                    start stages as their parents finish
#   ./rollout.sh steer <stage> <msg>    e.g. steer canary 'rollforward v1.41'
#   ./rollout.sh status                 show every stage
#   ./rollout.sh down                   delete every stage and its gateway
#
# Environment:
#   AX_BIN            ax CLI                    (default: ax)
#   ATESPACE          atespace                  (default: default)
#   AX_TASK_IMAGE     digest-pinned task image  (default: the server's default)
#   AX_LEGACY_SCHEMA  set for ax-servers built before #587 (no labels, `command`)
#   ROLLOUT_FROM, ROLLOUT_TO  versions          (default: v1.41 -> v1.42)
#   ROLLOUT_TICK      seconds per step          (default: 2)
#   ROLLOUT_FAIL      check stage that fails    (default: validate)

set -euo pipefail

AX_BIN="${AX_BIN:-ax}"
ATESPACE="${ATESPACE:-default}"
TASK_IMAGE="${AX_TASK_IMAGE:-}"
FROM="${ROLLOUT_FROM:-v1.41}"
TO="${ROLLOUT_TO:-v1.42}"
TICK="${ROLLOUT_TICK:-2}"
FAIL="${ROLLOUT_FAIL-validate}"

ax() { "${AX_BIN}" -a "${ATESPACE}" "$@"; }

# The tree: "name parents kind scope", parents before children. A stage with
# several parents (comma-separated) starts once all of them are DONE.
TREE=(
  "canary        -                           deploy    1% of traffic"
  "gate-check-1  canary                      gate      us-central"
  "us-central    gate-check-1                deploy    us-central"
  "gate-check-2  us-central                  gate      every region"
  "us-east       gate-check-2                deploy    us-east"
  "eu-west       gate-check-2                deploy    eu-west"
  "asia-south    gate-check-2                deploy    asia-south"
  "validate      us-east,eu-west,asia-south  validate  all regions"
)

name_of()   { awk '{print $1}' <<<"$1"; }
parent_of() { awk '{print $2}' <<<"$1"; }
kind_of()   { awk '{print $3}' <<<"$1"; }
scope_of()  { awk '{$1 = $2 = $3 = ""; sub(/^ +/, ""); print}' <<<"$1"; }

goal_of() {
  case "$(kind_of "$1")" in
    validate) echo "validate ${TO} across $(scope_of "$1")" ;;
    gate)     echo "may ${TO} go to $(scope_of "$1")?" ;;
    *)        echo "deploy ${TO} to $(scope_of "$1")" ;;
  esac
}

# Policy. region_of maps a deploy to its cloud region, whose endpoint is the
# only host its gateway allows.
region_of() {
  case "$1" in
    canary | us-central) echo us-central1 ;;
    us-east) echo us-east1 ;;
    eu-west) echo europe-west1 ;;
    asia-south) echo asia-south1 ;;
  esac
}

# allow_of prints the host a stage's gateway lets it reach; deny_of, a host it
# must not reach (another region, or for checks, any deploy endpoint).
allow_of() {
  case "$(kind_of "$(row_of "$1")")" in
    gate) echo api.github.com ;;
    validate) echo monitoring.googleapis.com ;;
    *) echo "$(region_of "$1")-run.googleapis.com" ;;
  esac
}
deny_of() {
  case "$(kind_of "$(row_of "$1")")/$(region_of "$1")" in
    deploy/europe-west1) echo us-central1-run.googleapis.com ;;
    deploy/*) echo europe-west1-run.googleapis.com ;;
    *) echo us-central1-run.googleapis.com ;;
  esac
}

# limits_of prints the CPU and memory limits of a stage's sandbox.
limits_of() {
  case "$(kind_of "$(row_of "$1")")" in
    gate) echo "500m 256Mi" ;;
    validate) echo "2 1Gi" ;;
    *) echo "1 512Mi" ;;
  esac
}

names() { local row; for row in "${TREE[@]}"; do name_of "$row"; done; }
row_of() { local row; for row in "${TREE[@]}"; do [[ "$(name_of "$row")" == "$1" ]] && echo "$row"; done; return 0; }

children() {
  local row
  for row in "${TREE[@]}"; do
    [[ ",$(parent_of "$row")," == *",$1,"* ]] && name_of "$row"
  done
  return 0
}

# subtree prints $1 and every stage below it, once each.
subtree() {
  _subtree() {
    echo "$1"
    local c
    for c in $(children "$1"); do _subtree "$c"; done
  }
  _subtree "$1" | awk '!seen[$0]++'
}

# AGENT is the command every stage runs. A deploy stage shifts traffic to the
# new version step by step and bakes; a gate stage checks whether the release
# may go further, and validate checks the whole release.
# Between steps it drains /workspace/inbox for operator steering, and it stays
# up after finishing so a completed stage can still be rolled forward.
read -r -d '' AGENT <<'SH' || true
cd /workspace
pct=0 paused="" target="" detail=""
log() { echo "$(date +%T) [$NAME] $*" >> agent.log; }
report() { echo "$1 $2 $3" > status.new && mv status.new status; }

inbox() {
  [ -s inbox ] || return 0
  mv inbox inbox.reading
  while IFS= read -r msg; do
    log "STEERED: $msg"
    case "$msg" in
      pause*) paused=1 ;;
      resume*) paused="" ;;
      rollforward*)
        target=$(echo ${msg#rollforward})
        target=${target:-$FROM} ;;
    esac
  done < inbox.reading
  rm -f inbox.reading
}

# step reports progress, then waits one tick. It holds while paused and fails
# once a roll-forward has been asked for.
step() {
  phase=$1 pct=$2 detail=$3
  report "$phase" "$pct" "$detail"
  log "$phase $pct% $detail"
  sleep "$TICK"; inbox
  while [ -n "$paused" ] && [ -z "$target" ]; do
    report PAUSED "$pct" "paused by operator at: $detail"
    sleep 1; inbox
  done
  [ -z "$target" ]
}

deploy() {
  for p in 10 25 50 100; do
    step DEPLOYING "$p" "$TO on $p% of $SCOPE" || return 1
  done
  for i in 1 2 3; do
    step BAKING 100 "baking $TO: error rate 0.0$i%, p99 $((180 + i * 7))ms" || return 1
  done
  report DONE 100 "$SCOPE serving $TO"
  log "DONE: $SCOPE serving $TO"
}

# forward deploys $target as a new release: traffic moves onto it step by
# step, the same way it moved onto the bad version.
forward() {
  to=$target target=""
  log "rolling forward $SCOPE to $to"
  for p in 10 25 50 100; do
    report ROLLING_FORWARD "$p" "$to on $p% of $SCOPE"
    log "ROLLING_FORWARD $p% $to on $p% of $SCOPE"
    sleep "$TICK"; inbox
  done
  report ROLLED_FORWARD 100 "$SCOPE serving $to"
  log "ROLLED_FORWARD: $SCOPE serving $to"
}

check() {
  n=0 checks="e2e-journeys cross-region error-rate p99-latency slo-burn" phase=VALIDATING
  [ "$KIND" = gate ] && checks="change-window approvals error-budget incidents" phase=GATING
  set -- $checks
  for check; do
    n=$((n + 100 / $#))
    step "$phase" "$n" "checking $check" || return 1
    if [ "$check" = p99-latency ] && [ -n "$FAIL" ]; then
      report FAILED "$n" "p99 latency 870ms > 500ms budget"
      log "FAILED: p99 latency 870ms > 500ms budget"
      return 0
    fi
    case "$check" in
      e2e-journeys) log "PASS: end-to-end journeys 18/18" ;;
      cross-region) log "PASS: cross-region failover" ;;
      change-window) log "PASS: inside the change window, no freeze" ;;
      approvals) log "PASS: release approved by 2 owners" ;;
      error-budget) log "PASS: 74% of the error budget left" ;;
      incidents) log "PASS: no open incidents" ;;
      error-rate) log "PASS: error rate 0.02% < 0.1%" ;;
      p99-latency) log "PASS: p99 latency 212ms < 500ms" ;;
      slo-burn) log "PASS: SLO burn rate 0.4x" ;;
    esac
  done
  report DONE 100 "all checks passed"
  log "DONE: all checks passed"
}

# probe checks the task's egress policy from inside the sandbox.
probe() {
  if code=$(curl -sS -o /dev/null -m 5 -w '%{http_code}' "https://$1/" 2>/dev/null); then
    echo "reached (HTTP $code)"
  else
    echo blocked
  fi
}

report STARTING 0 "checking policy"
a=$(probe "$ALLOW") d=$(probe "$DENY")
printf 'allow %s %s\ndeny %s %s\n' "$ALLOW" "$a" "$DENY" "$d" > policy
log "POLICY: $ALLOW $a; $DENY $d"
log "started: $KIND $SCOPE (parent: ${PARENT:-none})"
if [ "$KIND" = deploy ]; then
  deploy || true
  while true; do
    while [ -z "$target" ]; do sleep 1; inbox; done
    forward
  done
else
  check || report ABORTED 0 "stopped: rolling forward to $target"
fi
while true; do sleep 3600; done
SH

manifest() {
  local row name parent limits image=""
  [[ -n "$TASK_IMAGE" ]] && image=$'\n    image: "'"$TASK_IMAGE"'"'
  for row in "${TREE[@]}"; do
    name=$(name_of "$row"); parent=$(parent_of "$row")
    [[ "$parent" == "-" ]] && parent=""
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
    ax.io/tree: rollout
    ax.io/parent: "${parent//,/.}"
spec:
  debug: true # steering goes through ax ssh
  gateway: {name: gw-${name}}
  profile:${image}
    resources:
      limits: {cpu: "${limits[0]}", memory: "${limits[1]}"}
  commands:
    - sh
    - -c
    - |
$(sed 's/^/      /' <<<"$AGENT")
  env:
    - {name: NAME, value: "${name}"}
    - {name: PARENT, value: "${parent}"}
    - {name: KIND, value: "$(kind_of "$row")"}
    - {name: SCOPE, value: "$(scope_of "$row")"}
    - {name: FROM, value: "${FROM}"}
    - {name: TO, value: "${TO}"}
    - {name: TICK, value: "${TICK}"}
    - {name: FAIL, value: "$([[ "$name" == "$FAIL" ]] && echo 1)"}
    - {name: ALLOW, value: "$(allow_of "$name")"}
    - {name: DENY, value: "$(deny_of "$name")"}
YAML
  done
}

# snapshot writes the task list to $1/tasks and, for every running stage, its
# status line to $1/<stage>. Stages are read in parallel.
snapshot() {
  local dir="$1" name
  ax get tasks > "$dir/tasks"
  for name in $(names); do
    rm -f "$dir/$name"
    if is_running "$dir" "$name"; then
      (ax ssh "$name" -- cat /workspace/status > "$dir/$name" 2>/dev/null || true) &
    fi
  done
  wait
}

is_running() { awk -v n="$2" '$1 == n && ($3 == "Running" || $3 == "Working") {f = 1} END {exit !f}' "$1/tasks"; }

# phase prints a stage's phase: PENDING until it is started, SUSPENDED when it
# was started and is no longer running, STARTING until it reports.
phase() {
  if ! is_running "$1" "$2"; then
    if [[ -e "$1/$2.started" ]]; then echo SUSPENDED; else echo PENDING; fi
  elif [[ -s "$1/$2" ]]; then awk '{print $1; exit}' "$1/$2"
  else echo STARTING
  fi
}

detail() { [[ -s "$1/$2" ]] && cut -d' ' -f2- "$1/$2" | sed 's/^\([0-9]*\) /\1% /' || true; }

run() {
  local dir row name parent p pp q prev active
  dir=$(mktemp -d)
  echo "rolling out ${TO} (replacing ${FROM})"
  while true; do
    snapshot "$dir"
    active=0
    for row in "${TREE[@]}"; do
      name=$(name_of "$row"); parent=$(parent_of "$row")
      # A stage is started once. If someone suspends it later, it stays
      # suspended, and its children wait, until it is resumed.
      is_running "$dir" "$name" && touch "$dir/$name.started"
      p=$(phase "$dir" "$name")
      if [[ "$p" == PENDING ]]; then
        # pp: DONE once every parent is, FAILED if any parent cannot finish.
        pp=DONE
        for q in ${parent//,/ }; do
          [[ "$q" == "-" ]] && continue
          case "$(phase "$dir" "$q")" in
            DONE) ;;
            FAILED | ROLLING_FORWARD | ROLLED_FORWARD | ABORTED | SKIPPED) pp=FAILED; break ;;
            *) pp=WAITING ;;
          esac
        done
        case "$pp" in
          DONE) if [[ "$parent" == "-" ]]; then echo "▶ ${name}: starting"
                else echo "▶ ${name}: ${parent//,/, } done, starting"; fi
                touch "$dir/$name.started"
                ax resume task "$name" >/dev/null &
                p=STARTING active=1 ;;
          FAILED) p=SKIPPED ;;
          *) active=1 ;;
        esac
      fi
      prev=$(cat "$dir/$name.prev" 2>/dev/null || echo PENDING)
      if [[ "$p" != "$prev" ]]; then
        printf '  %-20s %s → %s  %s\n' "$name" "$prev" "$p" "$(detail "$dir" "$name")"
        echo "$p" > "$dir/$name.prev"
      fi
      case "$p" in
        DONE | FAILED | ROLLED_FORWARD | ABORTED | SKIPPED) ;;
        *) active=1 ;;
      esac
    done
    wait
    ((active)) || break
    sleep 2
  done
  echo "rollout finished:"
  for name in $(names); do printf '  %-20s %s\n' "$name" "$(cat "$dir/$name.prev")"; done
  if grep -qx FAILED "$dir"/*.prev; then
    echo "a check failed. Roll every deploy forward to ${FROM} with: $0 steer canary 'rollforward ${FROM}'"
  fi
  rm -rf "$dir"
}

up() {
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

# send writes $3 into the inbox of stage $2, if it is running.
send() {
  if is_running "$1" "$2"; then
    printf '  → %s\n' "$2"
    # The message travels on stdin, so it needs no shell quoting.
    # It may have been suspended since the snapshot; carry on with the rest.
    printf '%s\n' "$3" | ax ssh "$2" -- sh -c 'cat >> /workspace/inbox' 2>/dev/null ||
      printf '  ! %s (not reachable)\n' "$2"
  else
    printf '  · %s (not running)\n' "$2"
  fi
}

steer() {
  local node="$1" msg="$2" dir t
  [[ "$msg" == rollforward* ]] && { rollforward "$@"; return; }
  dir=$(mktemp -d)
  ax get tasks > "$dir/tasks"
  for t in $(subtree "$node"); do send "$dir" "$t" "$msg"; done
  rm -rf "$dir"
}

# rollforward steers $1 and its subtree onto an earlier version, bottom-up: a
# deploy gets the message once every running deploy below it is
# ROLLED_FORWARD. Checks get it right away, so one that is still running stops.
rollforward() {
  local node="$1" msg="$2" dir t d left next ready
  dir=$(mktemp -d)
  left=$(subtree "$node")
  while [[ -n "$left" ]]; do
    snapshot "$dir"
    next=""
    for t in $left; do
      ready=1
      if [[ "$(kind_of "$(row_of "$t")")" == deploy ]]; then
        for d in $(subtree "$t" | tail -n +2); do
          [[ "$(kind_of "$(row_of "$d")")" == deploy ]] && is_running "$dir" "$d" || continue
          [[ "$(phase "$dir" "$d")" == ROLLED_FORWARD ]] || ready=0
        done
      fi
      if ((ready)); then send "$dir" "$t" "$msg"; else next="$next $t"; fi
    done
    left=$next
    [[ -n "$left" ]] && sleep 2
  done
  rm -rf "$dir"
}

status() {
  local dir name
  dir=$(mktemp -d)
  snapshot "$dir"
  for name in $(names); do
    printf '%-20s %-12s %s\n' "$name" "$(phase "$dir" "$name")" "$(detail "$dir" "$name")"
  done
  rm -rf "$dir"
}

down() {
  local i
  for ((i = ${#TREE[@]} - 1; i >= 0; i--)); do
    ax delete task "$(name_of "${TREE[i]}")" 2>/dev/null || true
    ax delete gateway "gw-$(name_of "${TREE[i]}")" 2>/dev/null || true
  done
}

case "${1:-}" in
  up)       up ;;
  run)      run ;;
  steer)    shift; [[ $# -eq 2 ]] || { echo "usage: $0 steer <stage> <msg>" >&2; exit 2; }; steer "$@" ;;
  status)   status ;;
  down)     down ;;
  manifest) manifest ;;
  nodes)    for row in "${TREE[@]}"; do
              printf '%s\t%s\t%s\t%s\n' "$(name_of "$row")" "$(parent_of "$row")" "$(goal_of "$row")" "$(kind_of "$row")"
            done ;;
  presets)  printf '%s\n' pause resume "rollforward ${FROM}" ;;
  *)        sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 2 ;;
esac
