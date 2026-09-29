#!/usr/bin/env bash
# Behavior tests for bin/fm-jev-prompt-reminder.sh: the UserPromptSubmit
# reminder prints one context line for a human prompt, stays silent for an
# operational input, inside a task worker, and with the gate off, and never
# exits nonzero.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOOK="$ROOT/bin/fm-jev-prompt-reminder.sh"
TMP_ROOT=$(fm_test_tmproot fm-jev-prompt-reminder)
HOME_DIR="$TMP_ROOT/home"
START="$HOME_DIR/state/jev-turn-start"
mkdir -p "$HOME_DIR/state"

run_hook() {  # <prompt> [env...] -> sets code and out
  local prompt=$1
  shift
  code=0
  out=$(jq -cn --arg p "$prompt" '{hook_event_name: "UserPromptSubmit", prompt: $p}' \
    | env -u FM_TASK_ID FM_JEV_GATE=on FM_HOME="$HOME_DIR" "$@" "$HOOK" 2>&1) || code=$?
}

run_hook 'please fix the login flake'
expect_code 0 "$code" "human prompt"
assert_contains "$out" "deliverable-class ask" "a human prompt gets the reminder"
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail "the reminder is one line: $out"
pass "a human prompt gets the one-line deliverable-class reminder"

run_hook $'⁣FIRSTMATE_OP: v1 watcher: signal: demo.status'
expect_code 0 "$code" "operational input"
[ -z "$out" ] || fail "an operational input got output: $out"
run_hook 'please fix the login flake' FM_TASK_ID=t1
expect_code 0 "$code" "task worker"
[ -z "$out" ] || fail "a task worker got output: $out"
run_hook 'please fix the login flake' FM_JEV_GATE=off
expect_code 0 "$code" "gate off"
[ -z "$out" ] || fail "gate off got output: $out"
pass "operational inputs, task workers, and the gate off get no reminder"

code=0
out=$(env -u FM_TASK_ID FM_JEV_GATE=on FM_HOME="$HOME_DIR" "$HOOK" < /dev/null 2>&1) || code=$?
expect_code 0 "$code" "empty stdin"
pass "the reminder never blocks, even on an empty payload"

iso='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
rm -f "$START"
run_hook 'please fix the login flake'
grep -Eq "$iso" "$START" || fail "a human prompt records an ISO-8601 turn start: $(cat "$START" 2>/dev/null)"
rm -f "$START"
run_hook $'\u2063FIRSTMATE_OP: v1 watcher: signal: demo.status'
grep -Eq "$iso" "$START" || fail "an operational input records the turn start too"
rm -f "$START"
run_hook 'please fix the login flake' FM_TASK_ID=t1
[ ! -e "$START" ] || fail "a task worker records no turn start"
run_hook 'please fix the login flake' FM_JEV_GATE=off
[ ! -e "$START" ] || fail "the gate off records no turn start"
run_hook 'please fix the login flake' FM_HOME="$TMP_ROOT/no-such-home"
expect_code 0 "$code" "a home without a state directory"
[ ! -e "$TMP_ROOT/no-such-home" ] || fail "the reminder created a home that did not exist"
pass "every prompt outside a task worker with the gate on records the ISO-8601 turn start"
