#!/usr/bin/env bash
# Behavior tests for the prompt-wait signal (bin/fm-prompt-wait.sh): the record a
# worker raises when its harness is blocked on a human decision mid-turn. Before
# it, such a worker produced no turn-end and no status append, so nothing woke
# firstmate until the pane-staleness timer eventually fired half an hour later.
#
# Every case drives the REAL artifacts. The hook settings are whatever the real
# fm-spawn wrote into the task worktree, the hook command lines are executed out
# of that file with real harness payloads on stdin, and the real bin/fm-watch.sh
# turns the resulting record into queued wakes. Nothing asserts implementation
# source: the settings file is a runtime artifact of the spawn under test.
set -u

# shellcheck source=tests/fixtures.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

PROMPT_WAIT="$ROOT/bin/fm-prompt-wait.sh"
BUSY_EVENT="$ROOT/bin/fm-busy-event.sh"
WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-prompt-wait)
WATCHBIN="$TMP_ROOT/watchbin"
# The drain asserts the PRIMARY checkout is on its default branch, which this
# suite's own checkout is not while it is being validated. Point that check at a
# non-repository directory so its banner cannot drown the drain's rows.
NON_GIT_ROOT="$TMP_ROOT/non-git"
WATCH_PID=

cleanup() {
  [ -z "$WATCH_PID" ] || kill -KILL "$WATCH_PID" >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# The captain's own 2026-09-15 incident: a confirmation dialog on a destructive
# git command, which produced no turn-end and no status line for 30 minutes.
PERMISSION_PAYLOAD='{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"git reset --hard origin/main","description":"reset the branch"},"permission_mode":"default"}'
PERMISSION_SUMMARY='Bash: git reset --hard origin/main'
NOTIFICATION_PAYLOAD='{"hook_event_name":"Notification","message":"Claude needs your permission to use Bash","notification_type":"permission_prompt"}'
BATCH_PAYLOAD='{"hook_event_name":"PostToolBatch","tool_calls":[]}'

mkdir -p "$WATCHBIN" "$NON_GIT_ROOT"
cat > "$WATCHBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message) printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf 'fixture pane\n> \n'; exit 0 ;;
  list-windows) printf '%s\n' "${FM_FAKE_TMUX_WINDOW:-fm-task}"; exit 0 ;;
esac
exit 0
SH
cat > "$WATCHBIN/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "${FM_FAKE_CREW_STATE:-state: unknown · source: none · fake default}"
exit 0
SH
chmod +x "$WATCHBIN/tmux" "$WATCHBIN/fm-crew-state.sh"

# A claude ship spawn into an isolated worktree of a throwaway project, with the
# real per-task hook settings it writes. Echoes "<home>|<worktree>|<project>|<fakebin>".
make_claude_case() {  # <name> <id>
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  printf '%s\n' "$home|$wt|$proj|$fakebin"
}

read_case_record() {
  IFS='|' read -r HOME_DIR WT_DIR PROJ_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_spawn() {  # <home> <wt> <fakebin> <id> <project>
  local home=$1 wt=$2 fakebin=$3
  shift 3
  fm_test_run_spawn "$home" "$wt" "$fakebin" "$@" --mode no-mistakes --yolo off
}

# Run one hook command out of the settings file the spawn wrote, with <payload>
# on stdin. Hook commands are shell command lines, so they run under sh exactly
# as the harness runs them.
run_hook() {  # <settings.json> <hook-event> [payload] [index]
  local settings=$1 event=$2 payload=${3-} index=${4:-0} cmd
  cmd=$(jq -r ".hooks[\"$event\"][$index].hooks[0].command" "$settings")
  [ -n "$cmd" ] && [ "$cmd" != null ] || fail "no $event hook command in $settings"
  printf '%s' "$payload" | sh -c "$cmd"
}

# Present and acknowledge every queued wake exactly as a firstmate turn does,
# appending the raw rows to <state>/drained.log so a case can count what a whole
# sequence of polls produced. This is also what lets a case run more than one
# cycle: an unacknowledged queue makes the next watcher re-present it and exit
# instead of polling at all.
drain_queue() {  # <state>
  local state=$1 out seq gen
  out="$state/drain.out"
  FM_STATE_OVERRIDE="$state" FM_ROOT_OVERRIDE="$NON_GIT_ROOT" \
    "$DRAIN" > "$out" 2>&1 || fail "the wake drain failed:"$'\n'"$(cat "$out")"
  grep -E "^[0-9]+$(printf '\t')[0-9]+$(printf '\t')(signal|stale|check|heartbeat)$(printf '\t')" \
    "$out" >> "$state/drained.log" || true
  seq=$(sed -n 's/.*--ack-through \([0-9][0-9]*\).*/\1/p' "$out" | tail -1)
  [ -n "$seq" ] || return 0
  gen=$(sed -n 's/.*--recovery-generation \([^ ]*\).*/\1/p' "$out" | tail -1)
  FM_STATE_OVERRIDE="$state" FM_ROOT_OVERRIDE="$NON_GIT_ROOT" \
    "$DRAIN" --ack-through "$seq" ${gen:+--recovery-generation "$gen"} >/dev/null 2>&1 \
    || fail "the wake acknowledgement failed"
}

drained_prompt_waits() {  # <state>
  local n
  n=$(grep -c 'prompt-wait: worker ' "$1/drained.log" 2>/dev/null) || n=0
  printf '%s\n' "${n:-0}"
}

# The real watcher, polling <state> once a second with no coalescing grace.
watch_bg() {  # <state> [env assignment...]
  local state=$1
  shift
  PATH="$WATCHBIN:$PATH" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$WATCHBIN/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    env "$@" "$WATCH" > "$state/watch.out" 2>/dev/null &
  WATCH_PID=$!
}

# Wait for the watcher to deliver one wake, which is what exits its cycle
# (bin/fm-push-transition-lib.sh). 0 when it woke, 1 when the bound was spent
# with the watcher still polling - which is the shape of "nothing surfaced".
watch_one_wake() {  # <state> [env assignment...]
  local state=$1 i=0 rc=1
  watch_bg "$@"
  while [ "$i" -lt 200 ]; do
    if ! kill -0 "$WATCH_PID" 2>/dev/null; then
      rc=0
      break
    fi
    sleep 0.1
    i=$((i + 1))
  done
  kill -KILL "$WATCH_PID" >/dev/null 2>&1 || true
  wait "$WATCH_PID" >/dev/null 2>&1 || true
  WATCH_PID=
  return "$rc"
}

# Run watcher-and-turn pairs the way firstmate does - the watcher surfaces one
# wake and exits, the turn presents and acknowledges it - until the ledger holds
# <want> blocked-prompt wakes. A watcher restart's own recovery re-announcement
# is an ordinary wake on that path and is handled identically, so it neither
# counts as a blocked-prompt wake nor blocks the next poll. 1 when the cycle
# budget is spent first, so a case can assert either direction.
pump_until_wakes() {  # <state> <want> [env assignment...]
  local state=$1 want=$2 c=0
  shift 2
  while [ "$c" -lt 4 ]; do
    [ "$(drained_prompt_waits "$state")" -lt "$want" ] || return 0
    watch_one_wake "$state" "$@" || break
    drain_queue "$state"
    c=$((c + 1))
  done
  drain_queue "$state"
  [ "$(drained_prompt_waits "$state")" -ge "$want" ]
}

test_spawn_wires_the_blocked_prompt_hooks() {
  local rec out settings ev
  rec=$(make_claude_case wiring pw-wiring)
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" pw-wiring "$PROJ_DIR")
  expect_code 0 $? "claude spawn should succeed: $out"
  settings="$WT_DIR/.claude/settings.local.json"
  assert_present "$settings" "the claude spawn wrote no per-task hook settings"
  jq -e . "$settings" >/dev/null || fail "the claude hook settings are not valid JSON"

  for ev in PermissionRequest Notification PostToolBatch; do
    jq -e ".hooks[\"$ev\"]" "$settings" >/dev/null \
      || fail "no $ev hook is registered, so a blocked pane raises nothing"
  done
  # PermissionRequest is the immediate signal: it fires as Claude asks, with no
  # idle gate. The Notification matcher covers only the blocking dialogs that
  # event does not reach, and deliberately not idle_prompt, whose case Stop
  # already reports at once.
  jq -e '.hooks.Notification[0].matcher
    | test("permission_prompt") and test("elicitation")
      and (test("idle_prompt") | not)' "$settings" >/dev/null \
    || fail "the Notification matcher does not select exactly the blocking dialogs"
  # An open record must not outlive the turn it belongs to, whichever way that
  # turn ends.
  for ev in UserPromptSubmit Stop StopFailure SessionEnd PostToolBatch; do
    jq -e ".hooks[\"$ev\"][0].hooks[0].command | test(\"fm-prompt-wait\")" "$settings" >/dev/null \
      || fail "$ev does not close an open prompt-wait record"
  done
  # The project's own settings are never touched.
  assert_absent "$PROJ_DIR/.claude" "the spawn wrote into the project's own .claude"
  pass "a claude spawn wires the blocked-prompt hooks in the task worktree alone"
}

test_one_blocked_prompt_produces_exactly_one_wake() {
  local rec out settings state before after payload
  rec=$(make_claude_case onewake pw-onewake)
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" pw-onewake "$PROJ_DIR")
  expect_code 0 $? "claude spawn should succeed: $out"
  settings="$WT_DIR/.claude/settings.local.json"
  state="$HOME_DIR/state"

  run_hook "$settings" PermissionRequest "$PERMISSION_PAYLOAD" \
    || fail "the PermissionRequest hook command failed"
  assert_present "$state/pw-onewake.prompt-wait" "the blocked prompt raised no record"
  before=$(cat "$state/pw-onewake.prompt-wait")
  case "$before" in
    *"summary=$PERMISSION_SUMMARY"*) ;;
    *) fail "the record does not carry what the worker asked: $before" ;;
  esac

  # The same dialog is described again seconds later by the Notification hook.
  # One prompt is still one wake.
  run_hook "$settings" Notification "$NOTIFICATION_PAYLOAD" \
    || fail "the Notification hook command failed"
  after=$(cat "$state/pw-onewake.prompt-wait")
  [ "$before" = "$after" ] \
    || fail "a second event for the same dialog reopened the record: $after"

  pump_until_wakes "$state" 1 \
    || fail "the blocked prompt surfaced no wake:"$'\n'"$(cat "$state/drained.log" 2>/dev/null)"
  [ "$(drained_prompt_waits "$state")" = 1 ] \
    || fail "expected exactly one blocked-prompt wake, presented:"$'\n'"$(cat "$state/drained.log")"
  payload=$(grep 'prompt-wait: worker ' "$state/drained.log")
  case "$payload" in
    *"worker pw-onewake is waiting on a prompt: $PERMISSION_SUMMARY"*) ;;
    *) fail "the queued wake does not name the worker and its ask: $payload" ;;
  esac
  case "$payload" in
    *$'\t'"pw-onewake.prompt-wait"$'\t'*) ;;
    *) fail "the wake is not keyed distinguishably from a turn-end: $payload" ;;
  esac

  # A later poll over an unchanged record adds nothing: the wake is the prompt
  # appearing, not the prompt existing.
  ! pump_until_wakes "$state" 2 \
    || fail "an unchanged record produced a second wake:"$'\n'"$(cat "$state/drained.log")"
  pass "one blocked prompt produces exactly one wake naming the worker and the ask"
}

test_unanswered_prompt_is_re_rung_only_past_its_bound() {
  local rec out settings state due
  rec=$(make_claude_case rering pw-rering)
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" pw-rering "$PROJ_DIR")
  expect_code 0 $? "claude spawn should succeed: $out"
  settings="$WT_DIR/.claude/settings.local.json"
  state="$HOME_DIR/state"
  run_hook "$settings" PermissionRequest "$PERMISSION_PAYLOAD" \
    || fail "the PermissionRequest hook command failed"

  pump_until_wakes "$state" 1 FM_PROMPT_WAIT_RERING_SECS=999999 \
    || fail "the blocked prompt surfaced no wake"
  due=$(FM_PROMPT_WAIT_RERING_SECS=999999 "$PROMPT_WAIT" due "$state" pw-rering)
  [ "$due" = quiet ] || fail "the ladder reported a re-surface due inside its bound: $due"
  ! pump_until_wakes "$state" 2 FM_PROMPT_WAIT_RERING_SECS=999999 \
    || fail "an unanswered prompt inside its bound was re-rung:"$'\n'"$(cat "$state/drained.log")"

  due=$(FM_PROMPT_WAIT_RERING_SECS=0 "$PROMPT_WAIT" due "$state" pw-rering)
  case "$due" in
    resurface*) ;;
    *) fail "the ladder did not report a re-surface due past its bound: $due" ;;
  esac
  pump_until_wakes "$state" 2 FM_PROMPT_WAIT_RERING_SECS=0 \
    || fail "a prompt still unanswered past its bound was not re-rung:"$'\n'"$(cat "$state/drained.log")"
  pass "an unanswered prompt is re-rung only once it passes the ladder's bound"
}

test_blocked_prompt_survives_the_working_absorb() {
  local rec out settings state
  rec=$(make_claude_case absorb pw-absorb)
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" pw-absorb "$PROJ_DIR")
  expect_code 0 $? "claude spawn should succeed: $out"
  settings="$WT_DIR/.claude/settings.local.json"
  state="$HOME_DIR/state"
  # A worker blocked on a dialog is mid-turn, so every absorb proof the watcher
  # owns reads it as working. Put the batch in the strongest absorbable shape
  # there is: a bare turn-end marker beside the record, and an authoritative
  # working verdict for the task. Without the prompt-wait carve-out this batch
  # is absorbed and nothing is queued.
  rm -f "$state/pw-absorb.status"
  touch "$state/pw-absorb.turn-ended"
  run_hook "$settings" PermissionRequest "$PERMISSION_PAYLOAD" \
    || fail "the PermissionRequest hook command failed"

  pump_until_wakes "$state" 1 \
    FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' \
    || fail "a blocked prompt was absorbed as a working crew:"$'\n'"$(cat "$state/drained.log" 2>/dev/null)"
  pass "a blocked prompt surfaces even when every absorb proof reads the crew as working"
}

test_the_prompt_being_over_ends_the_episode() {
  local rec out settings state
  rec=$(make_claude_case clear pw-clear)
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" pw-clear "$PROJ_DIR")
  expect_code 0 $? "claude spawn should succeed: $out"
  settings="$WT_DIR/.claude/settings.local.json"
  state="$HOME_DIR/state"

  run_hook "$settings" PermissionRequest "$PERMISSION_PAYLOAD" \
    || fail "the PermissionRequest hook command failed"
  assert_present "$state/pw-clear.prompt-wait" "the blocked prompt raised no record"
  # PostToolBatch fires once after every call in the batch has resolved, so no
  # call in it is still sitting at a dialog.
  run_hook "$settings" PostToolBatch "$BATCH_PAYLOAD" \
    || fail "the PostToolBatch hook command failed"
  assert_absent "$state/pw-clear.prompt-wait" "the answered prompt left its record open"

  run_hook "$settings" PermissionRequest "$PERMISSION_PAYLOAD" \
    || fail "the second PermissionRequest hook command failed"
  assert_present "$state/pw-clear.prompt-wait" "a later blocked prompt raised no record"
  rm -f "$state/pw-clear.turn-ended"
  run_hook "$settings" Stop || fail "the Stop hook command failed"
  assert_absent "$state/pw-clear.prompt-wait" "a finished turn left an open record behind"
  assert_present "$state/pw-clear.turn-ended" "the prompt-wait clear displaced the turn-end signal"
  pass "the harness proving the prompt is over ends the episode without disturbing turn-end"
}

test_retired_incarnation_cannot_speak_for_its_replacement() {
  local rec out settings state old_gen
  rec=$(make_claude_case stale pw-stale)
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" pw-stale "$PROJ_DIR")
  expect_code 0 $? "claude spawn should succeed: $out"
  settings="$WT_DIR/.claude/settings.local.json"
  state="$HOME_DIR/state"
  old_gen=$(cat "$state/pw-stale.busy-gen")

  run_hook "$settings" PermissionRequest "$PERMISSION_PAYLOAD" \
    || fail "the PermissionRequest hook command failed"
  "$BUSY_EVENT" arm "$state" pw-stale >/dev/null \
    || fail "could not arm a replacement incarnation"
  [ "$(cat "$state/pw-stale.busy-gen")" != "$old_gen" ] \
    || fail "the replacement incarnation reused the retired token"

  # The retired agent's hooks are still on disk in its worktree and can still
  # fire. They must exit 0 so its own lifecycle is never broken, and change
  # nothing that now belongs to the live incarnation.
  run_hook "$settings" Stop || fail "a retired incarnation's hook must still exit 0"
  assert_present "$state/pw-stale.prompt-wait" \
    "a retired incarnation's hook closed the live record"
  run_hook "$settings" PermissionRequest \
    '{"hook_event_name":"PermissionRequest","tool_name":"Write","tool_input":{"file_path":"/tmp/other"}}' \
    || fail "a retired incarnation's record hook must still exit 0"
  [ "$("$PROMPT_WAIT" summary "$state" pw-stale)" = "$PERMISSION_SUMMARY" ] \
    || fail "a retired incarnation rewrote the live record"
  pass "a retired incarnation's hooks can neither open nor close its replacement's record"
}

test_a_relaunched_task_starts_with_no_open_prompt() {
  local rec out settings state
  rec=$(make_claude_case retire pw-retire)
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" pw-retire "$PROJ_DIR")
  expect_code 0 $? "claude spawn should succeed: $out"
  settings="$WT_DIR/.claude/settings.local.json"
  state="$HOME_DIR/state"

  run_hook "$settings" PermissionRequest "$PERMISSION_PAYLOAD" \
    || fail "the PermissionRequest hook command failed"
  "$PROMPT_WAIT" resurfaced "$state" pw-retire >/dev/null || fail "could not advance the ladder"
  assert_present "$state/pw-retire.prompt-wait.ring" "the ladder did not persist"

  # Relaunching the task is what retires the record its dead agent can no longer
  # close, so the replacement does not inherit a dialog nobody is sitting at.
  # The dead agent's window is gone, which is what lets the same task id spawn again.
  : > "$FAKEBIN_DIR/.spawn-window"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" pw-retire "$PROJ_DIR")
  expect_code 0 $? "the relaunch should succeed: $out"
  assert_absent "$state/pw-retire.prompt-wait" "the relaunch inherited a dead agent's open prompt"
  assert_absent "$state/pw-retire.prompt-wait.ring" "the relaunch inherited a dead agent's ladder"
  pass "a relaunched task starts with no open prompt and no ladder"
}

test_spawn_wires_the_blocked_prompt_hooks
test_one_blocked_prompt_produces_exactly_one_wake
test_unanswered_prompt_is_re_rung_only_past_its_bound
test_blocked_prompt_survives_the_working_absorb
test_the_prompt_being_over_ends_the_episode
test_retired_incarnation_cannot_speak_for_its_replacement
test_a_relaunched_task_starts_with_no_open_prompt

echo "all fm-prompt-wait tests passed"
