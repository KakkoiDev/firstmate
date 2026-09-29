#!/usr/bin/env bash
# Behavior tests for bin/fm-jev-prompt-reminder.sh: the UserPromptSubmit
# reminder prints one context line for a human prompt, stays silent for an
# operational input, inside a task worker, and with the gate off, and never
# exits nonzero.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOOK="$ROOT/bin/fm-jev-prompt-reminder.sh"

run_hook() {  # <prompt> [env...] -> sets code and out
  local prompt=$1
  shift
  code=0
  out=$(jq -cn --arg p "$prompt" '{hook_event_name: "UserPromptSubmit", prompt: $p}' \
    | env -u FM_TASK_ID FM_JEV_GATE=on "$@" "$HOOK" 2>&1) || code=$?
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
out=$(env -u FM_TASK_ID FM_JEV_GATE=on "$HOOK" < /dev/null 2>&1) || code=$?
expect_code 0 "$code" "empty stdin"
pass "the reminder never blocks, even on an empty payload"
