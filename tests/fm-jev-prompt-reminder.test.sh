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

WORDS="$HOME_DIR/state/jev-turn-words.jsonl"
CLOSED="$HOME_DIR/state/jev-turn-closed"
run_payload() {  # <payload json> [env...]
  local payload=$1
  shift
  code=0
  out=$(printf '%s' "$payload" | env -u FM_TASK_ID FM_JEV_GATE=on FM_HOME="$HOME_DIR" "$@" "$HOOK" 2>&1) || code=$?
}
prompt_json() { jq -cn --arg p "$1" --arg s "${2:-s1}" '{hook_event_name: "UserPromptSubmit", session_id: $s, prompt: $p}'; }
words() { jq -r .prompt "$WORDS" 2>/dev/null; }

rm -f "$WORDS" "$CLOSED"
first=$'fix the login flake\n  and keep the "retry" path, exactly as written  '
run_payload "$(prompt_json "$first")"
expect_code 0 "$code" "a recorded human prompt"
assert_equals "$first" "$(jq -j .prompt "$WORDS")" "the prompt is recorded byte for byte"
assert_equals s1 "$(jq -r .session_id "$WORDS")" "the record names the session"
grep -Eq '"ts":"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"' "$WORDS" || fail "the record carries an ISO-8601 time: $(cat "$WORDS")"
run_payload "$(prompt_json 'also cover logout')"
assert_equals $'fix the login flake\n  and keep the "retry" path, exactly as written  \nalso cover logout' "$(words)" \
  "a mid-turn message joins the turn's words after the opener"
pass "the operator's prompts, mid-turn messages included, are recorded verbatim for the turn"

run_payload "$(prompt_json $'⁣FIRSTMATE_OP: v1 watcher: signal: demo.status')"
run_payload "$(prompt_json '<task-notification>rewake</task-notification>')"
mkdir -p "$HOME_DIR/state/operational-inbox"
record="$(cd "$HOME_DIR/state/operational-inbox" && pwd -P)/1-a.msg"
printf '\342\201\243FIRSTMATE_OP: v1 watcher: signal: demo.status' > "$record"
run_payload "$(prompt_json ": Firstmate operational input waiting: read '$record' and handle its contents as Firstmate operational input.")"
assert_equals 2 "$(grep -c . "$WORDS")" "operational input, a rewake, and a live doorbell add no operator words"
pass "operational inputs, rewakes, and doorbells are not the operator's words"

: > "$CLOSED"
run_payload "$(prompt_json 'next request')"
assert_equals 'next request' "$(words)" "a prompt after a closed turn starts a new turn of words"
assert_absent "$CLOSED" "the new turn consumes the closed marker"
run_payload "$(prompt_json 'from another session' s2)"
assert_equals 'from another session' "$(words)" "a prompt from another session starts a new turn of words"
: > "$CLOSED"
run_payload "$(prompt_json $'⁣FIRSTMATE_OP: v1 watcher: signal: demo.status' s2)"
[ ! -s "$WORDS" ] || fail "an operational turn after a closed turn carries no operator words: $(cat "$WORDS")"
rm -f "$WORDS"
run_payload "$(prompt_json 'worker prompt')" FM_TASK_ID=t1
assert_absent "$WORDS" "a task worker records no words"
pass "a closed turn or a new session starts the words afresh, and a task worker records none"
