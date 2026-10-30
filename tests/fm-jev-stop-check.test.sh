#!/usr/bin/env bash
# Behavior tests for bin/fm-jev-stop-check.sh, the Claude Code Stop hook that
# refuses a primary's turn end while the final message leaves out this turn's
# Jev asks section or an unmentioned disagreement, and for its tracked
# registration.
#
# The asks are real bin/fm-jev.sh asks answered by a fake curl standing in for
# the Jev endpoint; a fake claude fails the detached duplicate query at once.
# The turn start is written by the real bin/fm-jev-prompt-reminder.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-jev-stop-check.sh"
JEV="$ROOT/bin/fm-jev.sh"
REMINDER="$ROOT/bin/fm-jev-prompt-reminder.sh"
TMP_ROOT=$(fm_test_tmproot fm-jev-stop)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
PRIMARY="$TMP_ROOT/primary"
RESPONSE="$TMP_ROOT/response.json"
KEY='stop-key-5be02c7a-never-on-argv'
mkdir -p "$PRIMARY/bin" "$PRIMARY/state"
printf '# fixture\n' > "$PRIMARY/AGENTS.md"
git -C "$PRIMARY" init -q
unset TYPESAFE_API_KEY DD_API_KEY DD_SITE FM_TASK_ID

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
set -u
out=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    *) shift ;;
  esac
done
cat > /dev/null
cp "${FAKE_CURL_RESPONSE:?}" "$out"
printf '200'
SH
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKEBIN/claude"
chmod +x "$FAKEBIN/curl" "$FAKEBIN/claude"
export FAKE_CURL_RESPONSE="$RESPONSE" FM_JEV_GATE=on FM_JEV_TRANSCRIPT_WAIT=0 FM_JEV_CLAUDE_MODELS=claude-opus-5-5

answer() {  # <choice> <confidence>: the stub Jev's next answer over the ask-scope options
  jq -n --arg c "$1" --argjson p "$2" '
    (["login", "signup", "several", "unclear"] | map(select(. != $c))) as $rest |
    {model: "jev-1.13.0",
    answers: {q: {type: "choice", choice: $c, confidence: $p,
      probabilities: ({($c): $p} + ($rest | map({(.): ((1 - $p) / 3)}) | add))}},
    usage: {input_tokens: 300, output_tokens: 40}}' > "$RESPONSE"
}
env_run() { env PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" TYPESAFE_API_KEY="$KEY" "$@"; }
turn_start() { printf '{"prompt": "fix the login flake"}' | env_run "$REMINDER" > /dev/null; }
scope_ask() {  # <words> <jev answer> <mine>
  answer "$2" 0.8
  env_run "$JEV" ask --template ask-scope --words "$1" --candidate login --candidate signup --mine "$3" > /dev/null 2>&1 \
    || fail "the fixture ask '$1' failed"
}

code='' err=''
stop() {  # <final message> [env...]
  local msg=$1
  shift
  code=0
  jq -cn --arg m "$msg" '{hook_event_name: "Stop", stop_hook_active: false, last_assistant_message: $m}' \
    | env_run "$@" "$CHECK" --claude > "$TMP_ROOT/out" 2> "$TMP_ROOT/err" || code=$?
  err=$(cat "$TMP_ROOT/err")
  [ ! -s "$TMP_ROOT/out" ] || fail "the check printed stdout: $(cat "$TMP_ROOT/out")"
}
expect_allow() { [ "$code" -eq 0 ] && [ -z "$err" ] || fail "$1: expected allow, got exit $code: $err"; }
expect_block() {  # <label> <reason part>
  [ "$code" -eq 2 ] || fail "$1: expected block with exit 2, got $code"
  assert_contains "$err" "$2" "$1"
}
section() { env_run "$JEV" turn --since "$(cat "$PRIMARY/state/jev-turn-start")"; }

test_no_asks_allows() {
  rm -f "$PRIMARY/state/jev-turn-start" "$PRIMARY/state/jev-usage.jsonl"
  stop 'Done.'
  expect_allow "no turn start recorded"
  turn_start
  stop 'Done.'
  expect_allow "a turn with no asks"
  pass "a turn with no Jev asks, or no recorded turn start, ends freely"
}

test_section_required() {
  local sec since
  rm -f "$PRIMARY/state/jev-usage.jsonl"
  scope_ask 'an ask from the turn before' login login
  sleep 1
  turn_start
  scope_ask 'fix the login flake' login login
  sec=$(section)
  since=$(cat "$PRIMARY/state/jev-turn-start")
  assert_equals 'Jev asks this turn (1)
firstmate ask-scope: fix the login flake - jev login (0.8), mine login' "$sec" "the section holds only this turn's ask"
  stop "Fixed the login flake.

Jev asks this turn (1)"
  expect_allow "the header alone, with the right count"
  stop 'Fixed the login flake.'
  expect_block "a final message without the header" "lacks the line \"Jev asks this turn (1)\""
  assert_contains "$err" "bin/fm-jev.sh turn --since $since" "the block names the command that prints the section"
  stop "Fixed the login flake.

Jev asks this turn (2)
- firstmate ask-scope: fix the login flake - jev login (0.8), mine login"
  expect_block "a wrong count" "lacks the line \"Jev asks this turn (1)\""
  stop "Fixed the login flake.

\`\`\`
  - Jev asks this turn (1)  
\`\`\`"
  expect_allow "the header in a code block with a bullet and padding"
  stop 'Fixed the login flake.' FM_TASK_ID=t1
  expect_allow "a task worker"
  stop 'Fixed the login flake.' FM_JEV_GATE=off
  expect_allow "the gate off"
  code=0
  printf '{"hook_event_name": "Stop"}' | env_run "$CHECK" --claude 2> "$TMP_ROOT/err" || code=$?
  [ "$code" -eq 0 ] || fail "a payload without last_assistant_message must pass, got $code"
  pass "asks made this turn block the turn end until the final message holds the section header with their count"
}

test_disagreement_must_be_mentioned() {
  local sec
  rm -f "$PRIMARY/state/jev-usage.jsonl"
  turn_start
  scope_ask 'fix the login flake' login login
  scope_ask 'also the signup one' several signup
  sec=$(section)
  assert_contains "$sec" 'firstmate ask-scope: also the signup one - jev several (0.8), mine signup [DISAGREE]' "the disagreement is marked"
  stop "Fixed both flakes.

$sec"
  expect_block "an unmentioned disagreement" "firstmate disagreed with Jev this turn (ask-scope (firstmate))"
  stop "Fixed both flakes.

Jev asks this turn (2)"
  expect_block "the header alone with a disagreement" "firstmate disagreed with Jev this turn (ask-scope (firstmate))"
  stop "Fixed both flakes. I disagree with Jev on the scope of the signup ask.

Jev asks this turn (2)"
  expect_block "a mention without the type" "(ask-scope (firstmate))"
  stop "Fixed both flakes. I disagree with Jev on ask-scope for the signup ask.

Jev asks this turn (2)"
  expect_block "a mention without the asker" "(ask-scope (firstmate))"
  stop "Fixed both flakes.
I disagree with Jev on ask-scope (firstmate): the operator named signup alone.

Jev asks this turn (2)"
  expect_allow "the header and a mention with the word, the type, and the asker"
  stop "Fixed both flakes.
Jev answered several on the ask-scope for the signup flake; firstmate's call differs, I disagree, because the operator named signup alone.

$sec"
  expect_allow "the whole section and a mention outside it"
  pass "a [DISAGREE] ask blocks the turn end until the final message names that disagreement, its type, and its asker"
}

test_turn_close_marker() {
  local closed="$PRIMARY/state/jev-turn-closed"
  rm -f "$PRIMARY/state/jev-usage.jsonl" "$closed"
  turn_start
  scope_ask 'fix the login flake' login login
  stop 'Fixed the login flake.'
  expect_block "a final message without the header" "lacks"
  assert_absent "$closed" "a blocked turn end leaves the turn open"
  stop "Fixed the login flake.

$(section)"
  expect_allow "the section in the final message"
  assert_present "$closed" "an allowed turn end closes the turn of operator words"
  rm -f "$closed"
  stop 'Done.' FM_TASK_ID=t1
  assert_absent "$closed" "a task worker closes no turn"
  pass "an allowed turn end writes the turn-closed marker, a blocked one does not"
}

test_shell_command_opens_a_turn() {
  local transcript="$TMP_ROOT/shell-transcript.jsonl" ts
  rm -f "$PRIMARY/state/jev-usage.jsonl" "$PRIMARY/state/jev-turn-closed"
  : > "$transcript"
  jq -cn --arg t "$transcript" '{hook_event_name: "UserPromptSubmit", session_id: "s9", transcript_path: $t, prompt: "fix the login flake"}' \
    | env_run "$REMINDER" > /dev/null
  scope_ask 'fix the login flake' login login
  printf '{"type":"system","subtype":"stop_hook_summary","hookCount":1,"hookErrors":[],"preventedContinuation":false}\n' >> "$transcript"
  ts=$(jq -rn 'now + 2 | strftime("%Y-%m-%dT%H:%M:%S")')
  jq -cn --arg ts "$ts.385Z" '{parentUuid: "a1", type: "user", uuid: "b1", timestamp: $ts, sessionId: "s9",
    message: {role: "user", content: "<bash-input>git push origin HEAD</bash-input>"}}' >> "$transcript"
  jq -cn --arg ts "$ts.900Z" '{parentUuid: "b1", type: "user", uuid: "b2", timestamp: $ts, sessionId: "s9",
    message: {role: "user", content: "<bash-stdout>Everything up-to-date</bash-stdout><bash-stderr></bash-stderr>"}}' >> "$transcript"
  code=0
  jq -cn --arg t "$transcript" '{hook_event_name: "Stop", session_id: "s9", transcript_path: $t, last_assistant_message: "Pushed."}' \
    | env_run "$CHECK" --claude > "$TMP_ROOT/out" 2> "$TMP_ROOT/err" || code=$?
  err=$(cat "$TMP_ROOT/err")
  expect_allow "a ! shell command after the asking turn ended"
  assert_equals "${ts}Z" "$(cat "$PRIMARY/state/jev-turn-start")" "the shell command's time is the turn start"
  pass "a ! shell command opens its own turn, so the turn end does not demand the previous turn's asks"
}

test_tracked_registration() {
  local entry
  entry=$(jq -c '[.hooks.Stop[].hooks[] | select(.command | contains("fm-jev-stop-check.sh"))]' "$ROOT/.claude/settings.json")
  assert_equals 1 "$(jq 'length' <<<"$entry")" "one tracked Stop entry runs the check"
  assert_equals '[ -z "${GROK_AGENT:-}${GROK_HOOK_EVENT:-}" ] || exit 0; exec "$CLAUDE_PROJECT_DIR"/bin/fm-jev-stop-check.sh --claude' \
    "$(jq -r '.[0].command' <<<"$entry")" "the tracked command"
  pass "the tracked settings register the check on Stop"
}

test_no_asks_allows
test_section_required
test_disagreement_must_be_mentioned
test_turn_close_marker
test_shell_command_opens_a_turn
test_tracked_registration
