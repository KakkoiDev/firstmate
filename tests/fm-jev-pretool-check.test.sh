#!/usr/bin/env bash
# Behavior tests for bin/fm-jev-pretool-check.sh, the Claude Code PreToolUse
# guard that needs a Jev ask bound to a Notion or Slack target, and for its
# tracked registration.
#
# Each case feeds a Claude-shaped PreToolUse payload to the hook in a scratch
# primary home. A fake curl stands in for the Jev endpoint and a fake claude
# fails the detached duplicate query at once, so nothing touches the network.
# The asks are made with the exact --target the deny message prints.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-jev-pretool-check.sh"
JEV="$ROOT/bin/fm-jev.sh"
TMP_ROOT=$(fm_test_tmproot fm-jev-pretool)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
PRIMARY="$TMP_ROOT/primary"
RESPONSE="$TMP_ROOT/response.json"
SOURCE_FILE="$TMP_ROOT/pr-view.txt"
KEY='pretool-key-3a9c11d0-never-on-argv'
PAGE='26ab1f9f4c5f80b18d3bd10a6b1d2f4e'
OTHER_PAGE='195de9221179449fab8075a27c979105'
mkdir -p "$PRIMARY/bin" "$PRIMARY/state"
printf '# fixture\n' > "$PRIMARY/AGENTS.md"
git -C "$PRIMARY" init -q
printf '%s\n' 'state:   MERGED' 'mergedAt: 2026-09-28T10:00:00Z' > "$SOURCE_FILE"
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
[ "${FAKE_CURL_FAIL:-0}" = 1 ] && exit 7
cp "${FAKE_CURL_RESPONSE:?}" "$out"
printf '200'
SH
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKEBIN/claude"
chmod +x "$FAKEBIN/curl" "$FAKEBIN/claude"
export FAKE_CURL_RESPONSE="$RESPONSE" FM_JEV_GATE=on FM_JEV_TRANSCRIPT_WAIT=0 FM_JEV_CLAUDE_MODELS=claude-opus-5-5

answer() {  # <choice> <confidence>: the stub Jev answers a claim-check
  jq -n --arg c "$1" --argjson p "$2" '
    (["supported", "contradicted", "not-addressed"] | map(select(. != $c))) as $rest |
    {model: "jev-1.13.0", answers: {q: {type: "choice", choice: $c, confidence: $p,
      probabilities: ({($c): $p} + ($rest | map({(.): ((1 - $p) / 2)}) | add))}},
     usage: {input_tokens: 420, output_tokens: 55}}' > "$RESPONSE"
}

code='' out='' err=''
# hook <payload-json> [env...]
hook() {
  local payload=$1
  shift
  code=0
  out=$(printf '%s' "$payload" | env PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" "$@" \
    "$CHECK" --claude 2> "$TMP_ROOT/err") || code=$?
  err=$(cat "$TMP_ROOT/err")
}
# jev [env...] -- <args...>: runs bin/fm-jev.sh in the primary home.
jev() {
  local envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  env PATH="$FAKEBIN:$PATH" FM_HOME="$PRIMARY" ${envs[@]+"${envs[@]}"} "$JEV" "$@" > "$TMP_ROOT/jev-out" 2>&1
}
page_update() {  # <page-id> <properties-json>
  jq -cn --arg p "$1" --argjson props "$2" '{hook_event_name: "PreToolUse", tool_name: "mcp__claude_ai_Notion__notion-update-page",
    tool_input: {page_id: $p, command: "update_properties", properties: $props}}'
}
expect_allow() {  # <label>
  [ "$code" -eq 0 ] || fail "$1: expected allow, got exit $code: $err"
  [ -z "$out" ] || fail "$1: allow printed stdout: $out"
  [ -z "$err" ] || fail "$1: allow printed stderr: $err"
}
expect_deny() {  # <label> <message part>
  [ "$code" -eq 2 ] || fail "$1: expected deny with exit 2, got $code (out: $out, err: $err)"
  [ -z "$out" ] || fail "$1: deny printed stdout: $out"
  jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and .hookSpecificOutput.permissionDecision == "deny"' <<<"$err" >/dev/null \
    || fail "$1: deny is not Claude's deny object: $err"
  assert_contains "$(jq -r .systemMessage <<<"$err")" "$2" "$1"
}
printed_target() { jq -r .systemMessage <<<"$err" | sed -n 's/.* --target \([^ ]*\) .*/\1/p'; }

TITLE_ONLY='{"title": "Login flake notes"}'
STATUS_MERGED='{"Status": "Merged"}'

test_scope() {
  hook "$(page_update "$PAGE" "$TITLE_ONLY")" FM_TASK_ID=t1
  expect_allow "a task worker is never guarded"
  hook "$(page_update "$PAGE" "$TITLE_ONLY")" FM_JEV_GATE=off
  expect_allow "the gate off is inert"
  local linked="$TMP_ROOT/linked"
  git -C "$PRIMARY" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -q --allow-empty -m init
  git -C "$PRIMARY" worktree add -q "$linked"
  [ -f "$linked/.git" ] || fail "the fixture linked worktree was not created"
  mkdir -p "$linked/bin" "$linked/state"
  printf '# fixture\n' > "$linked/AGENTS.md"
  code=0
  out=$(page_update "$PAGE" "$TITLE_ONLY" | env PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$linked" FM_HOME="$linked" "$CHECK" --claude 2> "$TMP_ROOT/err") || code=$?
  err=$(cat "$TMP_ROOT/err")
  expect_allow "a linked task worktree is not a primary home"
  hook "$(page_update "$PAGE" "$TITLE_ONLY")"
  [ "$code" -eq 2 ] || fail "the same write in the primary home must be refused, got exit $code"
  hook '{"tool_name": "Read", "tool_input": {"file_path": "/etc/hosts"}}'
  expect_allow "an unclassified tool passes"
  hook 'not json'
  expect_allow "a malformed payload passes"
  pass "the guard acts only in a primary home, outside task workers, with the gate on"
}

test_notion_write_needs_a_bound_ask() {
  local target
  rm -f "$PRIMARY/state/jev-asks.jsonl"
  hook "$(page_update "$PAGE" "$TITLE_ONLY")"
  expect_deny "a Notion write with no ask" "needs a Jev ask bound to notion:$PAGE from the last 30 minutes; run: bin/fm-jev.sh ask --template ask-scope --target notion:$PAGE "
  target=$(printed_target)
  assert_equals "notion:$PAGE" "$target" "the deny message names the normalized target"
  jev -- ask --template ask-scope --target "$target" --words 'rename the login page' --candidate "$PAGE=the login page" --mine "$PAGE"
  assert_contains "$(cat "$TMP_ROOT/jev-out")" 'jev: off' "the ask finds Jev off"
  hook "$(page_update "$PAGE" "$TITLE_ONLY")"
  expect_allow "an ask that found Jev off counts as asked"
  hook "$(page_update "$OTHER_PAGE" "$TITLE_ONLY")"
  expect_deny "an ask bound to another page" "needs a Jev ask bound to notion:$OTHER_PAGE"
  hook "$(jq -cn --arg p "$PAGE" '{tool_name: "mcp__notion__notion-create-comment", tool_input: {page_id: ("https://www.notion.so/Login-" + $p), markdown: "Looks good."}}')"
  expect_allow "the same page by URL under another Notion server name is the same target"
  hook "$(jq -cn --arg p "$PAGE" '{tool_name: "mcp__claude_ai_Notion__notion-create-pages", tool_input: {parent: {page_id: $p}, pages: [{content: "notes"}]}}')"
  expect_allow "a page created under an asked parent"
  jq -c '.ts = "2026-01-01T00:00:00Z"' "$PRIMARY/state/jev-asks.jsonl" > "$TMP_ROOT/aged" && mv "$TMP_ROOT/aged" "$PRIMARY/state/jev-asks.jsonl"
  hook "$(page_update "$PAGE" "$TITLE_ONLY")"
  expect_deny "an ask older than 30 minutes" "needs a Jev ask bound to notion:$PAGE"
  pass "a Notion write needs a recent ask bound to its page, Jev off included, and the deny prints the command to run"
}

test_state_write_needs_claim_check() {
  local target id
  rm -f "$PRIMARY/state/jev-asks.jsonl"
  jev -- ask --template ask-scope --target "notion:$PAGE" --words 'mark it merged' --candidate "$PAGE" --mine "$PAGE"
  hook "$(page_update "$PAGE" "$STATUS_MERGED")"
  expect_deny "a status write with only an ask-scope" "asserts a state (merged, done, released, decided, or closed, or a status property), so it needs a claim-check on notion:$PAGE"
  assert_contains "$(jq -r .systemMessage <<<"$err")" "run: bin/fm-jev.sh ask --template claim-check --target notion:$PAGE --claim" "the claim-check command is printed"
  hook "$(jq -cn --arg p "$PAGE" '{tool_name: "mcp__claude_ai_Notion__notion-update-page", tool_input: {page_id: $p, command: "insert_content", content: "The fix was Released today."}}')"
  expect_deny "content asserting a state" "so it needs a claim-check on notion:$PAGE"
  target=$(printed_target)
  answer contradicted 0.8
  jev TYPESAFE_API_KEY="$KEY" -- ask --template claim-check --target "$target" --claim 'PR 42 is released.' \
    --source "$SOURCE_FILE" --evidence 'state: MERGED' --mine supported
  id=$(sed -n 's/^  decision_id: //p' "$TMP_ROOT/jev-out")
  [ -n "$id" ] || fail "the answered claim-check printed no decision id: $(cat "$TMP_ROOT/jev-out")"
  hook "$(page_update "$PAGE" "$STATUS_MERGED")"
  expect_deny "a confident contradiction" "Jev answered contradicted at confidence 0.8 to claim-check $id on notion:$PAGE, so writes to it stay refused"
  assert_contains "$(jq -r .systemMessage <<<"$err")" "bin/fm-jev.sh record-outcome $id " "the block names the operator-confirmation way out"
  hook "$(page_update "$PAGE" "$TITLE_ONLY")"
  expect_deny "a plain write to a blocked page" "to claim-check $id"
  answer supported 0.9
  jev TYPESAFE_API_KEY="$KEY" -- ask --template claim-check --target "$target" --claim 'PR 42 is released.' \
    --source "$SOURCE_FILE" --evidence 'state: MERGED' --mine supported
  hook "$(page_update "$PAGE" "$STATUS_MERGED")"
  expect_deny "supported on the same evidence" "to claim-check $id"
  jev -- record-outcome "$id" 'the operator confirmed PR 42 shipped in the release notes'
  hook "$(page_update "$PAGE" "$STATUS_MERGED")"
  expect_allow "the operator's confirmation recorded on the blocking decision"
  answer not-addressed 0.3
  jev TYPESAFE_API_KEY="$KEY" -- ask --template claim-check --target "$target" --claim 'PR 42 is merged.' \
    --source "$SOURCE_FILE" --evidence 'mergedAt: 2026-09-28T10:00:00Z' --mine supported
  hook "$(page_update "$PAGE" "$STATUS_MERGED")"
  [ "$code" -eq 0 ] || fail "a contradiction below the floor must proceed, got exit $code: $err"
  assert_contains "$(jq -r .systemMessage <<<"$out")" "[jev-claim-check] warning: Jev answered not-addressed at confidence 0.3, below the claim-check floor" "below the floor warns"
  assert_equals "$(jq -r .systemMessage <<<"$out")" "$(jq -r .hookSpecificOutput.additionalContext <<<"$out")" "the warning reaches the model too"
  answer contradicted 0.9
  jev TYPESAFE_API_KEY="$KEY" -- ask --template claim-check --target "$target" --claim 'PR 42 is merged.' \
    --source "$SOURCE_FILE" --evidence 'state: MERGED' --mine supported
  id=$(sed -n 's/^  decision_id: //p' "$TMP_ROOT/jev-out")
  hook "$(page_update "$PAGE" "$STATUS_MERGED")"
  expect_deny "a second confident contradiction" "to claim-check $id"
  answer supported 0.7
  jev TYPESAFE_API_KEY="$KEY" -- ask --template claim-check --target "$target" --claim 'PR 42 is merged.' \
    --source "$SOURCE_FILE" --evidence 'mergedAt: 2026-09-28T10:00:00Z' --mine supported
  hook "$(page_update "$PAGE" "$STATUS_MERGED")"
  expect_allow "a fresh claim-check on new evidence answered supported"
  jev FAKE_CURL_FAIL=1 TYPESAFE_API_KEY="$KEY" -- ask --template claim-check --target "notion:$OTHER_PAGE" --claim 'PR 7 is closed.' \
    --source https://github.com/o/r/pull/7 --evidence 'Closed' --mine supported
  assert_contains "$(cat "$TMP_ROOT/jev-out")" 'jev: error' "the Jev call fails"
  hook "$(page_update "$OTHER_PAGE" "$STATUS_MERGED")"
  expect_allow "a claim-check that found Jev failing counts as asked"
  pass "a state-asserting write needs a claim-check; a confident contradiction blocks until new supported evidence or the operator's recorded word, and below the floor warns"
}

test_slack_send() {
  rm -f "$PRIMARY/state/jev-asks.jsonl"
  local send
  send=$(jq -cn '{tool_name: "mcp__claude_ai_Slack__slack_send_message", tool_input: {channel_id: "C07ABC", message: "PR 42 is merged"}}')
  hook "$send"
  expect_deny "a Slack send with no ask" "needs a Jev ask bound to slack:c07abc"
  jev -- ask --template ask-scope --target "$(printed_target)" --words 'tell the team' --candidate c07abc --mine c07abc
  hook "$send"
  expect_allow "a Slack send with an ask bound to its channel"
  hook "$(jq -cn '{tool_name: "mcp__claude_ai_Slack__slack_schedule_message", tool_input: {channel_id: "C999", message: "x", post_at: 1}}')"
  expect_deny "a scheduled send to another channel" "needs a Jev ask bound to slack:c999"
  hook "$(jq -cn '{tool_name: "mcp__claude_ai_Slack__slack_read_channel", tool_input: {channel_id: "C999"}}')"
  expect_allow "a Slack read is not a send"
  pass "a Slack send needs an ask bound to its channel"
}

test_bash_gate_switch() {
  local c
  for c in 'FM_JEV_GATE=off bin/fm-spawn.sh t1 projects/p' 'export FM_JEV_GATE=off; bin/fm-send.sh t1 hi' \
    'env FM_JEV_GATE=0 "$PWD"/bin/fm-control.sh t1 interrupt'; do
    hook "$(jq -cn --arg c "$c" '{tool_name: "Bash", tool_input: {command: $c}}')"
    expect_deny "$c" "[jev-gate] this command sets FM_JEV_GATE beside an action script"
  done
  for c in 'bin/fm-spawn.sh t1 projects/p --concurrency parallel' 'FM_JEV_GATE=off bash tests/fm-jev.test.sh' 'ls'; do
    hook "$(jq -cn --arg c "$c" '{tool_name: "Bash", tool_input: {command: $c}}')"
    expect_allow "$c"
  done
  pass "a Bash command that would switch off an action script's Jev gate is refused; the script gates own the rest"
}

test_tracked_registration() {
  local entry matcher tool
  entry=$(jq -c '[.hooks.PreToolUse[] | select(any(.hooks[]; .command | contains("fm-jev-pretool-check.sh")))]' "$ROOT/.claude/settings.json")
  assert_equals 1 "$(jq 'length' <<<"$entry")" "one tracked PreToolUse group runs the guard"
  assert_equals '[ -z "${GROK_AGENT:-}${GROK_HOOK_EVENT:-}" ] || exit 0; exec "$CLAUDE_PROJECT_DIR"/bin/fm-jev-pretool-check.sh --claude' \
    "$(jq -r '.[0].hooks[0].command' <<<"$entry")" "the tracked command"
  matcher=$(jq -r '.[0].matcher' <<<"$entry")
  for tool in Bash mcp__claude_ai_Notion__notion-update-page mcp__notion__notion-create-pages mcp__claude_ai_Slack__slack_send_message; do
    jq -en --arg m "$matcher" --arg t "$tool" '$t | test("^(" + $m + ")$")' >/dev/null || fail "the tracked matcher '$matcher' misses $tool"
  done
  pass "the tracked settings register the guard for Bash and every MCP tool"
}

test_scope
test_notion_write_needs_a_bound_ask
test_state_write_needs_claim_check
test_slack_send
test_bash_gate_switch
test_tracked_registration
