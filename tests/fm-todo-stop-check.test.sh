#!/usr/bin/env bash
# Behavior tests for bin/fm-todo-stop-check.sh, the Claude Code Stop hook that
# refuses a primary's turn end while a task touched this turn has no todo link
# or no-todo reason, or its linked todo's mark lags the task's state with no
# bridge call made this turn, and for its tracked registration.
#
# The notes file, the link and block stores, and the task records are fixtures;
# a fake config/notes-keeping-bridge prints a fixture status for `status`.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-todo-stop-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-todo-stop)
PRIMARY="$TMP_ROOT/primary"
STATE="$PRIMARY/state"
NOTES="$TMP_ROOT/notes.md"
STATUS_JSON="$TMP_ROOT/bridge-status.json"
mkdir -p "$PRIMARY/bin" "$STATE" "$PRIMARY/config"
printf '# fixture\n' > "$PRIMARY/AGENTS.md"
git -C "$PRIMARY" init -q
unset FM_TASK_ID

BRIDGE="$PRIMARY/config/notes-keeping-bridge"
cat > "$BRIDGE" <<SH
#!/usr/bin/env bash
[ "\$1" = status ] || exit 2
cat '$STATUS_JSON'
SH
chmod +x "$BRIDGE"

OLD=1000
NOW=0

reset() {  # fresh fixtures: a turn that started now, nothing touched yet
  find "$STATE" -maxdepth 1 -type f -delete
  date -u +%Y-%m-%dT%H:%M:%SZ > "$STATE/jev-turn-start"
  NOW=$(date -u +%s)
  printf '{"file": "%s", "at": %s}\n' "$NOTES" "$NOW" > "$STATE/notes-keeping-active.json"
  printf '{}\n' > "$STATUS_JSON"
  notes ' '
}
notes() {  # <mark of the 0of2pk9 item>
  printf '# Objectives\n\n- [ ] not a todo <!-- id:9zzzzzz -->\n\n# Todo\n\n- [%s] **PR review report**: JP/EN report on PR review system <!-- id:0of2pk9 -->\n- [ ] other item <!-- id:1aaaaaa -->\n' "$1" > "$NOTES"
}
task() {  # <id> <fresh|old> [meta line...]
  local id=$1 age=$2
  shift 2
  printf 'kind=scout\n' > "$STATE/$id.meta"
  for line in "$@"; do printf '%s\n' "$line" >> "$STATE/$id.meta"; done
  [ "$age" = fresh ] || touch -t 200001010000 "$STATE/$id.meta"
}
status_line() { printf '%s\n' "$2" >> "$STATE/$1.status"; }  # <id> <line>
link() { printf '{"task": "%s", "key": "id:0of2pk9", "id": "0of2pk9", "by": "firstmate", "at": %s}\n' "$1" "$2" >> "$STATE/notes-todo-links.jsonl"; }  # <id> <at>
bridge_says() { printf '{"id:0of2pk9": {"status": %s, "task": "%s", "id": "0of2pk9"}}\n' "$2" "$1" > "$STATUS_JSON"; }  # <id> <json status>

code='' err=''
stop() {  # [env...]
  code=0
  printf '{"hook_event_name": "Stop", "stop_hook_active": false, "last_assistant_message": "Done."}' \
    | env "$@" FM_HOME="$PRIMARY" FM_ROOT_OVERRIDE="$PRIMARY" "$CHECK" --claude > "$TMP_ROOT/out" 2> "$TMP_ROOT/err" || code=$?
  err=$(cat "$TMP_ROOT/err")
  [ ! -s "$TMP_ROOT/out" ] || fail "the check printed stdout: $(cat "$TMP_ROOT/out")"
}
expect_allow() { [ "$code" -eq 0 ] && [ -z "$err" ] || fail "$1: expected allow, got exit $code: $err"; }
expect_block() {  # <label> <reason part>
  [ "$code" -eq 2 ] || fail "$1: expected block with exit 2, got $code: $err"
  assert_contains "$err" "$2" "$1"
}

test_quiet_when_nothing_changed() {
  reset
  stop
  expect_allow "no task touched this turn"
  task scout-old old
  status_line scout-old "working [at=$OLD]: started"
  stop
  expect_allow "an unlinked task untouched this turn"
  rm -f "$STATE/jev-turn-start"
  task scout-new fresh
  stop
  expect_allow "no turn start recorded"
  reset
  task scout-new fresh
  stop FM_TASK_ID=scout-new
  expect_allow "inside a task worker"
  mv "$BRIDGE" "$BRIDGE.off"
  stop
  mv "$BRIDGE.off" "$BRIDGE"
  expect_allow "a home without the notes-keeping bridge"
  pass "the check is silent when nothing this turn touched a task, and inert outside its scope"
}

test_unlinked_task_blocks() {
  reset
  task scout-new fresh
  stop
  expect_block "a task spawned this turn with no link" "scout-new"
  assert_contains "$err" "$BRIDGE link scout-new id:<todo id> --by firstmate" "the block names the link command"
  task scout-new fresh 'no_todo=captain asked for a one-off check'
  stop
  expect_allow "a recorded no-todo reason"
  reset
  task scout-old old
  status_line scout-old "done [at=$((NOW + 1))]: report written"
  stop
  expect_block "a task that finished this turn with no link" "scout-old"
  pass "a task touched this turn needs a todo link or a recorded no-todo reason"
}

test_in_flight_mark() {
  reset
  task scout-new fresh
  link scout-new "$OLD"
  stop
  expect_block "a linked in-flight task whose todo reads [ ]" "todo 0of2pk9"
  assert_contains "$err" "$BRIDGE link scout-new id:0of2pk9 --by firstmate" "the block names the exact bridge command"
  assert_contains "$err" "[~]" "the block names the expected mark"
  notes '~'
  stop
  expect_allow "the todo reads [~]"
  notes ' '
  link scout-new "$((NOW + 1))"
  stop
  expect_allow "a bridge link call made this turn"
  pass "an in-flight task's todo must read [~] or have a bridge call this turn"
}

test_bridge_already_reports() {
  reset
  task scout-new fresh
  link scout-new "$OLD"
  bridge_says scout-new '"in-progress"'
  stop
  expect_allow "the bridge already reports the task in progress; the plugin owns writing it"
  pass "a lagging mark the bridge already reports is the plugin's to write"
}

test_blocked_mark() {
  reset
  task scout-old old
  link scout-old "$OLD"
  notes '~'
  bridge_says scout-old '"in-progress"'
  status_line scout-old "blocked [at=$((NOW + 1))]: needs a Notion login"
  stop
  expect_block "a task blocked this turn whose todo reads [~]" "[!]"
  assert_contains "$err" "$BRIDGE block scout-old --reason 'needs a Notion login' --by firstmate" "the block names the block command"
  printf '{"task": "scout-old", "reason": "needs a Notion login", "lines": 1, "at": %s}\n' "$((NOW + 1))" > "$STATE/notes-todo-blocks.jsonl"
  stop
  expect_allow "a bridge block call made this turn"
  pass "a blocked task's todo must read [!] or have a bridge block call this turn"
}

test_ready_not_landed() {
  reset
  task ship-ready old
  link ship-ready "$OLD"
  notes '~'
  status_line ship-ready "done [at=$((NOW + 1))]: PR ready https://github.com/KakkoiDev/dotfiles/pull/62"
  stop
  expect_allow "a task whose PR is ready but not merged, whose todo reads [~]"
  notes ' '
  stop
  expect_block "a ready, unlanded task whose todo reads [ ]" "[~]"
  notes x
  stop
  expect_block "a ready, unlanded task whose todo reads [x]" "premature"
  assert_contains "$err" "still in-progress" "the premature block names the in-progress state"
  pass "a done line for a ready PR or branch that has not landed keeps its todo at [~]"
}

test_finished_mark() {
  reset
  link scout-gone "$OLD"
  printf '{"task": "scout-gone", "outcome": "done", "at": %s}\n' "$((NOW + 1))" >> "$STATE/notes-todo-links.jsonl"
  stop
  expect_block "a task torn down this turn whose todo reads [ ]" "scout-gone"
  assert_contains "$err" "$BRIDGE link scout-gone id:0of2pk9 --by firstmate" "the torn-down block names the link command"
  notes '-'
  stop
  expect_allow "a todo the captain declined"
  pass "a torn-down task's todo must read [x] or have a bridge call this turn"
}

test_raw_text_link_is_unlinked() {
  reset
  task todo-blocked-status old 'todo=JP/EN report on PR review system <!-- id:0of2pk9 -->'
  printf '{"task": "todo-blocked-status", "key": "jp/en report on pr review system <!-- id:0of2pk9 -->", "text": "JP/EN report on PR review system <!-- id:0of2pk9 -->", "at": %s}\n' "$OLD" > "$STATE/notes-todo-links.jsonl"
  status_line todo-blocked-status "done [at=$((NOW + 1))]: PR opened"
  stop
  expect_block "a task linked only by raw todo text" "todo-blocked-status: no todo link"
  assert_contains "$err" "$BRIDGE link todo-blocked-status id:0of2pk9 --by firstmate" "the block names the id link command from the raw text"
  pass "a link by raw todo text, which the plugin cannot match to an id, counts as no link"
}

test_merged_not_cleaned_up() {
  reset
  task todo-blocked-status old
  link todo-blocked-status "$OLD"
  status_line todo-blocked-status "done [at=$OLD]: PR ready"
  status_line todo-blocked-status "working [at=$OLD]: fixing review"
  notes '~'
  stop
  expect_allow "a merged marker is absent; nothing touched this turn"
  printf 'fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\nKakkoiDev/dotfiles\n51\n' > "$STATE/todo-blocked-status.pr-poll-merge-notified"
  stop
  expect_block "a task whose PR merged this turn, not yet cleaned up, whose todo reads [~]" "[x]"
  assert_contains "$err" "todo-blocked-status: todo 0of2pk9" "the block names the task and todo"
  notes 'x'
  stop
  expect_allow "the todo reads [x]"
  pass "a task whose PR merged but is not cleaned up needs its todo at [x]"
}

test_premature_done() {
  local marked
  reset
  task token-economizer fresh
  link token-economizer "$NOW"
  bridge_says token-economizer '"in-progress"'
  notes x
  marked=$(date -u -r "$((NOW + 2))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$((NOW + 2))" +%Y-%m-%dT%H:%M:%SZ)
  printf '\n# Logs\n\n- %s | laya | status | id:0of2pk9 PR review report | in-progress -> done | finished 0.38\n' "$marked" >> "$NOTES"
  stop
  expect_block "a todo marked [x] while its task is in flight, though the bridge reports in-progress" "premature"
  assert_contains "$err" "laya" "the block names the actor from the Logs row"
  assert_contains "$err" "$BRIDGE link token-economizer id:0of2pk9 --by firstmate" "the block names the bridge command"
  link token-economizer "$((NOW + 3))"
  stop
  expect_allow "a bridge call made after the done mark"
  reset
  task token-economizer fresh
  printf '{"task": "token-economizer", "key": "jp/en report on pr review system <!-- id:0of2pk9 -->", "text": "JP/EN report on PR review system <!-- id:0of2pk9 -->", "at": %s}\n' "$NOW" > "$STATE/notes-todo-links.jsonl"
  notes x
  printf '\n# Logs\n\n- %s | laya | status | id:0of2pk9 PR review report | in-progress -> done | finished 0.38\n' "$marked" >> "$NOTES"
  stop
  expect_block "a raw-text link whose todo reads [x] while the task is in flight" "premature"
  assert_contains "$err" "token-economizer: no todo link" "the raw-text link is still reported unlinked"
  pass "a todo marked done while its task is still in flight is a premature done mark"
}

test_tracked_registration() {
  local entry
  entry=$(jq -c '[.hooks.Stop[].hooks[] | select(.command | contains("fm-todo-stop-check.sh"))]' "$ROOT/.claude/settings.json")
  assert_equals 1 "$(jq 'length' <<<"$entry")" "one tracked Stop entry runs the check"
  # shellcheck disable=SC2016 # The tracked command string is compared literally.
  assert_equals '[ -z "${GROK_AGENT:-}${GROK_HOOK_EVENT:-}" ] || exit 0; exec "$CLAUDE_PROJECT_DIR"/bin/fm-todo-stop-check.sh --claude' \
    "$(jq -r '.[0].command' <<<"$entry")" "the tracked command"
  pass "the tracked settings register the check on Stop"
}

test_quiet_when_nothing_changed
test_unlinked_task_blocks
test_in_flight_mark
test_bridge_already_reports
test_blocked_mark
test_ready_not_landed
test_finished_mark
test_raw_text_link_is_unlinked
test_merged_not_cleaned_up
test_premature_done
test_tracked_registration
