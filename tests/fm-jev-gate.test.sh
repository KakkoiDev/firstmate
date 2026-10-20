#!/usr/bin/env bash
# Behavior tests for the Jev decision gate (bin/fm-jev-gate-lib.sh) as the
# action scripts enforce it: fm-spawn, fm-send, fm-teardown, fm-control,
# fm-pr-merge, and fm-merge-local.
#
# Each case arms the gate (FM_JEV_GATE=on) in a scratch home and drives the
# script's argv. A fake curl answers as Jev, a fake tmux records every call so
# a refused steer or control action can be proven to have touched nothing,
# and a fake claude fails the detached duplicate query at once. Jev off is the
# absent key; a refusal must name what to run and change nothing, and Jev off
# must never block.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-jev-gate)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
LOG="$TMP_ROOT/log"
RESPONSE="$TMP_ROOT/response.json"
KEY='gate-key-7d1e0b55-never-on-argv'
mkdir -p "$LOG"
unset TYPESAFE_API_KEY DD_API_KEY DD_SITE

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
cat > "${FAKE_CURL_LOG:?}/body"
[ -z "${FAKE_CURL_USAGE:-}" ] || cp "$FAKE_CURL_USAGE" "$FAKE_CURL_LOG/usage-at-post" 2>/dev/null || true
cp "${FAKE_CURL_RESPONSE:?}" "$out"
printf '200'
SH
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_CURL_LOG:?}/tmux"
case "${1:-}" in
  display-message) printf '%s\n' "${FAKE_TMUX_PANE_CMD:-fakepane}" ;;
  capture-pane) printf '%s\n' "${FAKE_TMUX_SCREEN:-}" ;;
  list-windows) printf 'fm-t1\n' ;;
esac
exit 0
SH
cat > "$FAKEBIN/claude" <<'SH'
#!/usr/bin/env bash
exit 1
SH
cat > "$FAKEBIN/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKEBIN/curl" "$FAKEBIN/tmux" "$FAKEBIN/claude" "$FAKEBIN/sleep"

write_response() {  # <choice> <confidence> <other-option>
  jq -n --arg c "$1" --argjson p "$2" --arg o "$3" '
    {model: "jev-1.13.0",
     answers: {q: {type: "choice", choice: $c, confidence: $p,
       probabilities: {($c): $p, ($o): (1 - $p)}}},
     usage: {input_tokens: 420, output_tokens: 55}}' > "$RESPONSE"
}

# write_response_all <choice> <id>...: an answer whose probabilities cover every option.
write_response_all() {
  local choice=$1
  shift
  printf '%s\n' "$@" | jq -Rn --arg c "$choice" '
    [inputs] as $ids |
    {model: "jev-1.13.0",
     answers: {q: {type: "choice", choice: $c, confidence: 0.9,
       probabilities: ([$ids[] | {key: ., value: (if . == $c then 0.9 else (0.1 / (($ids | length) - 1)) end)}] | from_entries)}},
     usage: {input_tokens: 420, output_tokens: 55}}' > "$RESPONSE"
}
export FAKE_CURL_LOG="$LOG" FAKE_CURL_RESPONSE="$RESPONSE" FM_JEV_GATE=on FM_JEV_TRANSCRIPT_WAIT=0

new_home() {  # <name> <kind> -> echoes a home with a t1 task of <kind>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data/t1" "$TMP_ROOT/$1-proj"
  fm_write_meta "$home/state/t1.meta" "window=sess:fm-t1" "kind=$2" "harness=claude"
  printf '# Task\n\n## Captain'\''s intent\n\nFix the flaky login test.\n\n## Firstmate spec\n\n- Keep it small.\n' \
    > "$home/data/t1/brief.md"
  printf '# Report\n\nThe flake is a race in the fixture.\n' > "$home/data/t1/report.md"
  printf '%s\n' "$home"
}

code='' out=''
# run <home> <code-var> <out-var> [env...] -- <script> [args...]
run() {
  local home=$1 __c=$2 __o=$3 envs=() __out __code=0
  shift 3
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  : > "$LOG/tmux"
  __out=$(env PATH="$FAKEBIN:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    ${envs[@]+"${envs[@]}"} "$ROOT/bin/$1" "${@:2}" 2>&1) || __code=$?
  printf -v "$__c" '%s' "$__code"
  printf -v "$__o" '%s' "$__out"
}

# --- fm-spawn ---------------------------------------------------------------

H=$(new_home spawn ship)
P="$TMP_ROOT/spawn-proj"
SPAWN=(fm-spawn.sh t1 "$P" --mode direct-PR --yolo off --harness claude)

run "$H" code out -- "${SPAWN[@]}"
expect_code 2 "$code" "spawn without --decision"
assert_contains "$out" "fm-spawn.sh: refused: a fresh ship spawn needs --decision project-match=<decision-id|off>" "spawn refusal names the missing decision"
assert_contains "$out" "  run: bin/fm-jev.sh ask --type project-match " "spawn refusal names the exact ask command"
assert_contains "$out" "--mine <your choice>" "spawn refusal ask command records the blind choice"
assert_absent "$H/state/jev-usage.jsonl" "a refused spawn asks nothing"
pass "fm-spawn refuses a fresh spawn without the project-match decision and names the ask"

run "$H" code out -- "${SPAWN[@]}" --decision project-match=off --decision deliverable-class=off --concurrency parallel
expect_code 2 "$code" "spawn with an off decision nobody asked"
assert_contains "$out" "fm-spawn.sh: refused: project-match=off needs a project-match ask from the last 30 minutes that found Jev off or failing, and none is recorded; ask first" \
  "an off decision needs a ledgered off ask"
assert_contains "$out" "  run: bin/fm-jev.sh ask --type project-match " "the off refusal names the ask"
printf 'Fix the flaky login test.\n' > "$TMP_ROOT/off-context"
run "$H" code out -- fm-jev.sh ask --type project-match --summary "which project" --question q \
  --source "$TMP_ROOT/off-context" --mine spawn-proj
expect_code 2 "$code" "project-match with an empty registry"
assert_contains "$out" "project-match needs registered projects" "an empty registry refuses the project-match ask"
printf -- '- spawn-proj [direct-PR] - The login service and its flaky tests\n- other-proj [no-mistakes] - Billing exports\n' > "$H/data/projects.md"
run "$H" code out -- fm-jev.sh ask --type project-match --summary "which project" --question q \
  --option spawn-proj --option none --source "$TMP_ROOT/off-context" --mine spawn-proj
expect_code 2 "$code" "project-match with caller options"
assert_contains "$out" "project-match options come from the project registry" "caller options are refused for project-match"
run "$H" code out -- fm-jev.sh ask --type project-match --summary "which project" --question q \
  --source "$TMP_ROOT/off-context" --mine spawn-proj
assert_contains "$out" "jev: off (TYPESAFE_API_KEY absent" "the project-match ask finds Jev off"
run "$H" code out -- fm-jev.sh ask --type deliverable-class --summary "which deliverable" --question q \
  --option ship --option scout --source "$TMP_ROOT/off-context" --mine ship
pass "fm-spawn refuses an off decision until an ask that found Jev off is in the ask ledger"

run "$H" code out -- "${SPAWN[@]}" --decision project-match=off --decision deliverable-class=off
expect_code 2 "$code" "spawn without --concurrency"
assert_contains "$out" "needs --concurrency <parallel|semantic-dependency|shared-external-state|migration-conflict>" "spawn refusal names concurrency"
pass "fm-spawn refuses a fresh spawn without --concurrency"

run "$H" code out -- "${SPAWN[@]}" --decision project-match=off --decision deliverable-class=off --concurrency semantic-dependency
expect_code 2 "$code" "spawn with a serializing concurrency call"
assert_contains "$out" "jev concurrency not recorded (off or failed); semantic-dependency acts" "jev off lets firstmate's concurrency call act"
assert_contains "$out" "concurrency for task t1 acts as 'semantic-dependency'; keep it queued until that clears" "a serializing call refuses the spawn"
pass "fm-spawn refuses when the acting concurrency answer is not parallel, with Jev off"

run "$H" code out -- "${SPAWN[@]}" --decision project-match=off --decision deliverable-class=off --concurrency parallel
assert_contains "$out" "jev project-match not recorded (off or failed)" "jev off project-match accepted"
assert_contains "$out" "jev effort-level not recorded (off or failed); default acts" "jev off effort-level accepted"
assert_not_contains "$out" "refused:" "jev off never blocks the spawn"
pass "fm-spawn with Jev off passes the gate on firstmate's own choices"

for level in xhigh max ultra; do
  run "$H" code out -- "${SPAWN[@]}" --decision project-match=off --decision deliverable-class=off --concurrency parallel --effort "$level"
  expect_code 1 "$code" "worker spawn at --effort $level"
  assert_contains "$out" "error: --effort $level is not allowed for a ship worker; use low, medium, or high" "the $level refusal names the allowed levels"
  assert_not_contains "$out" "jev " "a refused effort asks nothing"
done
run "$H" code out -- fm-spawn.sh t1 --relaunch --effort max
expect_code 1 "$code" "worker relaunch at --effort max"
assert_contains "$out" "error: --effort max is not allowed for a ship worker" "a relaunch refuses max too"
run "$H" code out FM_JEV_GATE=off -- "${SPAWN[@]}" --effort xhigh
assert_not_contains "$out" "is not allowed for a" "the gate off keeps every effort level"
pass "with the gate on, a worker spawn or relaunch refuses xhigh, max, and ultra"

fm_write_meta "$H/state/t2.meta" "window=sess:fm-t2" "kind=scout" "harness=claude" "project=$TMP_ROOT/other-proj"
fm_write_meta "$H/state/mate.meta" "window=sess:fm-mate" "kind=secondmate" "harness=claude"
# The fake Jev gives one answer per run, so each ask is answered in its own run.
write_response_all parallel parallel semantic-dependency shared-external-state migration-conflict
run "$H" code out TYPESAFE_API_KEY="$KEY" -- "${SPAWN[@]}" --decision project-match=off --decision deliverable-class=off --concurrency parallel --effort medium
CONC_ID=$(sed -n 's/.*jev concurrency decision \([^:]*\):.*/\1/p' <<<"$out" | head -n 1)
[ -n "$CONC_ID" ] || fail "the spawn recorded no concurrency decision: $out"
write_response_all medium low medium high default
run "$H" code out TYPESAFE_API_KEY="$KEY" -- "${SPAWN[@]}" --decision project-match=off --decision deliverable-class=off --concurrency parallel --effort medium
EFFORT_ID=$(sed -n 's/.*jev effort-level decision \([^:]*\):.*/\1/p' <<<"$out" | head -n 1)
[ -n "$EFFORT_ID" ] || fail "the spawn recorded no effort decision: $out"
CONC_CTX=$(jq -r .context "$H/state/jev-audit/$CONC_ID.json")
assert_contains "$CONC_CTX" $'Task being spawned:\nBrief kind: ship (a project change)\nDelivery mode: direct-PR' "the concurrency ask carries the kind and delivery mode"
assert_contains "$CONC_CTX" "t2 project=other-proj kind=scout" "the concurrency ask lists other work by id, project, and kind"
assert_not_contains "$CONC_CTX" "mate project=" "a secondmate is not listed as work under way"
assert_not_contains "$CONC_CTX" "t1 project=" "the task being spawned is not listed as other work"
EFFORT_CTX=$(jq -r .context "$H/state/jev-audit/$EFFORT_ID.json")
assert_contains "$EFFORT_CTX" $'Brief kind: ship (a project change)\nDelivery mode: direct-PR' "the effort ask carries the kind and delivery mode"
assert_not_contains "$EFFORT_CTX" "t2 project=" "the effort ask carries no work list"
[ "$(jq -c '.questions.q.criteria | keys_unsorted' "$LOG/body")" = '["low","medium","high","default"]' ] \
  || fail "the effort options offer a level a worker may not run at: $(jq -c '.questions.q.criteria | keys_unsorted' "$LOG/body")"
rm -f "$H/state/t2.meta" "$H/state/mate.meta"
pass "the concurrency and effort asks carry the kind and mode, concurrency the other work, and effort no level above high"

printf 'mismatch\n' > "$TMP_ROOT/pm-context"
write_response_all spawn-proj spawn-proj other-proj none several
run "$H" code out TYPESAFE_API_KEY="$KEY" -- fm-jev.sh ask --type project-match --summary "which project" \
  --question "Which registered project is this request about?" \
  --source "$TMP_ROOT/pm-context" --mine other-proj
expect_code 0 "$code" "project-match ask"
[ "$(jq -c '.questions.q.criteria | keys_unsorted' "$LOG/body")" = '["spawn-proj","other-proj","none","several"]' ] \
  || fail "project-match options are not the registry: $(jq -c '.questions.q.criteria' "$LOG/body")"
assert_contains "$(jq -r '.questions.q.criteria["spawn-proj"]' "$LOG/body")" "spawn-proj [direct-PR] - The login service and its flaky tests" \
  "each project's meaning is its whole registry entry"
PM_ID=$(sed -n 's/^  decision_id: //p' <<<"$out")
[ -n "$PM_ID" ] || fail "project-match ask printed no decision_id: $out"
run "$H" code out -- "${SPAWN[@]}" --decision "project-match=$PM_ID" --decision deliverable-class=off --concurrency parallel
expect_code 2 "$code" "spawn against a contradicting project-match decision"
assert_contains "$out" "decision $PM_ID resolves the project to 'other-proj', not spawn-proj" "firstmate's blind choice acts without authority and contradicts the spawn"
run "$H" code out -- "${SPAWN[@]}" --decision "project-match=nope" --decision deliverable-class=off --concurrency parallel
expect_code 2 "$code" "spawn against an unknown decision id"
pass "fm-spawn refuses a recorded decision whose acting answer contradicts it, and an unknown id"

# --- fm-send ----------------------------------------------------------------

H=$(new_home send ship)
run "$H" code out -- fm-send.sh t1 "Use the new fixture instead."
expect_code 2 "$code" "steer without a decision flag"
assert_contains "$out" "refused:" "steer refusal"
assert_contains "$out" "--mid-task-ask" "steer refusal names --mid-task-ask"
assert_contains "$out" "--not-a-decision" "steer refusal names --not-a-decision"
[ ! -s "$LOG/tmux" ] || fail "a refused steer touched tmux: $(cat "$LOG/tmux")"
[ -z "$(find "$H/state" -name '*.msg' 2>/dev/null)" ] || fail "a refused steer left an inbox message"
pass "fm-send refuses a steer that declares neither a mid-task ask nor not-a-decision, sending nothing"

run "$H" code out -- fm-send.sh t1 --mid-task-ask follow-up --not-a-decision "x"
expect_code 2 "$code" "both steer flags"
pass "fm-send refuses both declarations together"

run "$H" code out -- fm-send.sh t1 --not-a-decision "Use the new fixture instead."
assert_not_contains "$out" "refused:" "--not-a-decision passes the gate"
assert_not_contains "$out" "jev " "--not-a-decision asks nothing"
[ -n "$(find "$H/state" -name '*.msg' 2>/dev/null)" ] || fail "--not-a-decision steer was not delivered: $out"
pass "fm-send --not-a-decision delivers without an ask"

run "$H" code out -- fm-send.sh t1 --mid-task-ask follow-up "Also cover the logout path."
assert_contains "$out" "jev mid-task-ask not recorded (off or failed); follow-up acts" "jev off mid-task ask accepted"
assert_not_contains "$out" "refused:" "jev off never blocks the steer"
pass "fm-send --mid-task-ask with Jev off delivers on firstmate's own classification"

# --- fm-teardown (scout) ----------------------------------------------------

H=$(new_home teardown scout)
run "$H" code out -- fm-teardown.sh t1
expect_code 2 "$code" "scout teardown without flags"
assert_contains "$out" "fm-teardown.sh: refused: a scout teardown needs --report-has-captain-call <yes|no>" "teardown refusal"
assert_present "$H/state/t1.meta" "a refused teardown keeps the task record"
run "$H" code out -- fm-teardown.sh t1 --report-has-captain-call no
expect_code 2 "$code" "scout teardown without --scout-recommends-ship"
assert_contains "$out" "--scout-recommends-ship" "teardown refusal names the second flag"
pass "fm-teardown refuses a scout cleanup until both report calls are declared"

# --- fm-control -------------------------------------------------------------

STUCK_IDS='working idle-done waiting-on-answered-question looping confused unresponsive parked-at-decision blocked paused-declared-wait failed waiting-on-prompt unread-instructions held-for-captain endpoint-gone state-unknown'
STUCK_IDS_PIPED=${STUCK_IDS// /|}

H=$(new_home control ship)
for verb in interrupt relaunch; do
  run "$H" code out -- fm-control.sh t1 "$verb"
  expect_code 2 "$code" "$verb without --worker-state"
  assert_contains "$out" "fm-control.sh: refused: $verb needs --worker-state <$STUCK_IDS_PIPED>" "$verb refusal"
  [ ! -s "$LOG/tmux" ] || fail "a refused $verb touched tmux: $(cat "$LOG/tmux")"
done
run "$H" code out -- fm-control.sh t1 interrupt --worker-state stuck
expect_code 2 "$code" "invalid --worker-state"
pass "fm-control refuses interrupt and relaunch without a valid worker state, touching nothing"

# meanings_ok <body-file>: every option id carries a meaning that is not the id or a bare Yes/No.
meanings_ok() {
  jq -e '.questions.q.criteria | all(to_entries[]; .value != .key and (.value | length) > 12)' "$1" >/dev/null
}

H=$(new_home live ship)
fm_write_meta "$H/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=claude" "worktree=$H/wt" "project=$H/proj"
mkdir -p "$H/wt"
mkdir -p "$H/state/t1.inbox/handled"
printf 'a\n' > "$H/state/t1.inbox/001.msg"
printf 'b\n' > "$H/state/t1.inbox/002.msg"
printf 'c\n' > "$H/state/t1.inbox/handled/000.msg"
NOW=$(date +%s)
printf '%s\n' "done [at=$NOW]: ready in branch fm/t1" > "$H/state/t1.status"
# shellcheck disable=SC2086
write_response_all unread-instructions $STUCK_IDS
run "$H" code out TYPESAFE_API_KEY="$KEY" FAKE_TMUX_SCREEN='Allow this bash command? (y/n)' -- fm-control.sh t1 interrupt --worker-state unread-instructions
assert_not_contains "$out" "refused:" "a state firstmate distinguishes is a valid --worker-state"
assert_contains "$out" "jev stuck-worker decision " "the stuck-worker ask went out with the new state"
# shellcheck disable=SC2086
[ "$(jq -c '.questions.q.criteria | keys_unsorted' "$LOG/body")" = "$(printf '%s\n' $STUCK_IDS | jq -Rn -c '[inputs]')" ] \
  || fail "the stuck-worker choice list is not the full state set: $(jq -c '.questions.q.criteria | keys_unsorted' "$LOG/body")"
pass "fm-control accepts every state firstmate distinguishes and sends them all as options"

meanings_ok "$LOG/body" || fail "a stuck-worker option goes out without a meaning: $(jq -c '.questions.q.criteria' "$LOG/body")"
assert_contains "$(jq -r '.questions.q.criteria["waiting-on-prompt"]' "$LOG/body")" "permission" "the prompt option names a permission dialog"
pass "every stuck-worker option carries a one-line meaning"

LIVE_CTX=$(jq -r '.state.context' "$LOG/body")
assert_contains "$LIVE_CTX" $'Current state:\nRead just now; it outranks every status line' "the context labels the live state"
assert_contains "$LIVE_CTX" "state: unknown · source: pane" "the context carries the crew-state line"
assert_contains "$LIVE_CTX" "Unread steering-inbox messages for this worker, read just now: 2" "the context counts the unread inbox records, not handled ones"
assert_contains "$LIVE_CTX" "Allow this bash command? (y/n)" "the context carries the endpoint screen tail"
assert_contains "$LIVE_CTX" "done [at=$NOW]: ready in branch fm/t1" "the old status line is still sent, as an event log"
assert_contains "$LIVE_CTX" "Agent process in the recorded endpoint: " "the context carries the agent-process state"
assert_contains "$LIVE_CTX" "Pane foreground command: fakepane (other)" "the context carries the pane command and its class"
grep -Eq 'Machine booted at: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z' <<<"$LIVE_CTX" || fail "the context carries no boot time: $LIVE_CTX"
[ "$(sed -n 's/^Machine booted at: //p' <<<"$LIVE_CTX" | cut -c1-4)" -ge 2000 ] || fail "the boot time is not this machine's: $LIVE_CTX"
assert_contains "$LIVE_CTX" "Last status line written at: $(date -u -r "$NOW" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$NOW" +%Y-%m-%dT%H:%M:%SZ)" "the context carries the last status time"
case "$LIVE_CTX" in
  *"Current state:"*"Recent status lines, an event log"*) ;;
  *) fail "the live state must come before the status lines: $LIVE_CTX" ;;
esac
pass "the stuck-worker context carries crew-state, the unread inbox count, and the screen tail ahead of the status lines"

# shellcheck disable=SC2086
write_response_all endpoint-gone $STUCK_IDS
run "$H" code out TYPESAFE_API_KEY="$KEY" FAKE_TMUX_PANE_CMD=zsh -- fm-control.sh t1 interrupt --worker-state endpoint-gone
SHELL_CTX=$(jq -r '.state.context' "$LOG/body")
assert_contains "$SHELL_CTX" "Pane foreground command: zsh (shell)" "a bare shell pane is classified"
assert_contains "$SHELL_CTX" "the pane runs the bare shell zsh), so weigh those facts" "a bare shell pane names the contradiction"
assert_not_contains "$SHELL_CTX" "it outranks every status line" "a contradicted crew-state line is not framed as outranking"
printf '%s\n' 'done [at=1]: ready in branch fm/t1' > "$H/state/t1.status"
run "$H" code out TYPESAFE_API_KEY="$KEY" -- fm-control.sh t1 interrupt --worker-state endpoint-gone
OLD_CTX=$(jq -r '.state.context' "$LOG/body")
assert_contains "$OLD_CTX" "contradict a live worker (the last status line predates the machine's boot)" "a status line from before the boot names the contradiction"
assert_not_contains "$OLD_CTX" "it outranks every status line" "a pre-boot status line drops the outranks frame"
pass "the stuck-worker context drops the outranks frame when a process fact contradicts a live worker"

H=$(new_home meanings ship)
write_response_all follow-up invalidates follow-up downstream-correction
run "$H" code out TYPESAFE_API_KEY="$KEY" -- fm-send.sh t1 --mid-task-ask follow-up "Also cover the logout path."
assert_contains "$out" "jev mid-task-ask decision " "the mid-task ask went out"
meanings_ok "$LOG/body" || fail "a mid-task-ask option goes out without a meaning: $(jq -c '.questions.q.criteria' "$LOG/body")"
write_response_all no yes no
run "$H" code out TYPESAFE_API_KEY="$KEY" -- fm-merge-local.sh t1 --merge-risk no
assert_contains "$out" "jev merge-risk decision " "the merge-risk ask went out"
meanings_ok "$LOG/body" || fail "a merge-risk option goes out without a meaning: $(jq -c '.questions.q.criteria' "$LOG/body")"
printf -- '- spawn-proj [x]\n' > "$H/data/projects.md"
printf -- '- mate-one [scope: x]\n' > "$H/data/secondmates.md"
SELF_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
for qtype in project-match deliverable-class secondmate-scope surface-class concurrency effort-level mid-task-ask \
  report-has-captain-call scout-recommends-ship merge-risk stuck-worker; do
  lines=$(bash -c 'SCRIPT_DIR=$1/bin; FM_HOME=$2; . "$1/bin/fm-jev-gate-lib.sh"; fm_jev_gate_option_lines "$3"' _ "$SELF_ROOT" "$H" "$qtype") \
    || fail "$qtype has no option lines"
  [ -n "$lines" ] || fail "$qtype has no option lines"
  while IFS= read -r line; do
    meaning=${line#*=}
    [ "$meaning" != "$line" ] && [ "${#meaning}" -gt 12 ] || fail "$qtype option line has no meaning: '$line'"
  done <<<"$lines"
done
pass "every script-embedded ask sends a one-line meaning with each option"

DC_IDS=$(bash -c 'SCRIPT_DIR=$1/bin; FM_HOME=$2; . "$1/bin/fm-jev-gate-lib.sh"; fm_jev_gate_choices deliverable-class' _ "$SELF_ROOT" "$H")
for id in steer-existing acknowledge; do
  assert_contains " ${DC_IDS//|/ } " " $id " "deliverable-class offers $id"
done
pass "deliverable-class offers a steer of work under way and a bare acknowledgement"

# --- merges -----------------------------------------------------------------

H=$(new_home merge ship)
run "$H" code out -- fm-pr-merge.sh t1 https://github.com/o/r/pull/1
expect_code 2 "$code" "PR merge without --merge-risk"
assert_contains "$out" "fm-pr-merge.sh: refused: a merge needs --merge-risk <yes|no>" "PR merge refusal"
assert_contains "$out" "nothing was merged" "PR merge refusal says nothing merged"
run "$H" code out -- fm-merge-local.sh t1
expect_code 2 "$code" "local landing without --merge-risk"
assert_contains "$out" "fm-merge-local.sh: refused: a merge needs --merge-risk <yes|no>" "local landing refusal"
run "$H" code out -- fm-merge-local.sh t1 --merge-risk maybe
expect_code 2 "$code" "local landing with an invalid --merge-risk"
pass "fm-pr-merge and fm-merge-local refuse without a yes/no merge-risk call"

H=$(new_home features ship)
REPO="$TMP_ROOT/features-repo"
git init -q -b main "$REPO"
mkdir -p "$REPO/src/auth"
printf 'a\n' > "$REPO/src/auth/login.py"
printf 'c\n' > "$REPO/old-notes.txt"
git -C "$REPO" add -A
git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm init
git -C "$REPO" checkout -qb fm/t1
mkdir -p "$REPO/db/migrations"
printf '1\n2\n' > "$REPO/db/migrations/0042_drop_users.sql"
printf 'z\n' >> "$REPO/src/auth/login.py"
git -C "$REPO" rm -q old-notes.txt
git -C "$REPO" add -A
git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm change
fm_write_meta "$H/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=claude" "project=$REPO" "mode=local-only"
write_response_all no yes no
run "$H" code out TYPESAFE_API_KEY="$KEY" -- fm-merge-local.sh t1 --merge-risk no
MR_ID=$(sed -n 's/.*jev merge-risk decision \([^:]*\):.*/\1/p' <<<"$out" | head -n 1)
[ -n "$MR_ID" ] || fail "the merge-risk ask recorded no decision: $out"
MR_CTX=$(jq -r .context "$H/state/jev-audit/$MR_ID.json")
assert_contains "$MR_CTX" $'Files changed: 3\nFiles added: 1\nFiles deleted: 1\nFiles renamed: 0\nLines added: 3\nLines deleted: 1' "the merge-risk ask counts the change"
assert_contains "$MR_CTX" "A path names a migration: yes" "a migration path is flagged"
assert_contains "$MR_CTX" "A path names auth or security: yes" "an auth path is flagged"
assert_contains "$MR_CTX" "A path names infra or deploy: no" "no infra path is flagged"
assert_contains "$MR_CTX" "A path names CI configuration: no" "no CI path is flagged"
for name in 0042_drop_users login.py old-notes db/migrations; do
  assert_not_contains "$MR_CTX" "$name" "no path or file name reaches the merge-risk ask ($name)"
done
fm_write_meta "$H/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=claude" "project=$REPO" "branch=fm/gone"
run "$H" code out TYPESAFE_API_KEY="$KEY" -- fm-merge-local.sh t1 --merge-risk no
MR_ID=$(sed -n 's/.*jev merge-risk decision \([^:]*\):.*/\1/p' <<<"$out" | head -n 1)
assert_contains "$(jq -r .context "$H/state/jev-audit/$MR_ID.json")" "Change features: could not be computed (no readable branch fm/gone" \
  "an unreadable branch says the features could not be computed"
pass "the merge-risk ask carries locally computed counts and path facts, never a path"

# --- mid-task ask: the worker's recent status lines ride along -----------------

H=$(new_home events ship)
for n in $(seq 1 25); do printf 'working [at=%s]: status line %02d\n' "$n" "$n"; done > "$H/state/t1.status"
write_response_all follow-up invalidates follow-up downstream-correction
run "$H" code out TYPESAFE_API_KEY="$KEY" -- fm-send.sh t1 --mid-task-ask follow-up "Also cover the logout path."
assert_contains "$out" "jev mid-task-ask decision " "the mid-task ask went out"
EVENTS_CTX=$(jq -r '.state.context' "$LOG/body")
assert_contains "$EVENTS_CTX" "The worker's last status lines, its own event log, oldest first:" "the status lines are labelled as an event log"
assert_contains "$EVENTS_CTX" "status line 06"$'\n'"working [at=7]" "the twenty newest lines go, oldest first"
assert_contains "$EVENTS_CTX" "status line 25" "the newest line goes"
assert_not_contains "$EVENTS_CTX" "status line 05" "lines older than the newest twenty stay home"
assert_contains "$EVENTS_CTX" "Fix the flaky login test." "the brief still goes"
rm -f "$H/state/t1.status"
run "$H" code out TYPESAFE_API_KEY="$KEY" -- fm-send.sh t1 --mid-task-ask follow-up "Also cover the logout path."
assert_contains "$(jq -r '.state.context' "$LOG/body")" "oldest first:"$'\n'"none recorded" "a task with no status says none recorded"
pass "a mid-task ask carries the worker's last twenty status lines as an event log"

# --- scout report asks: the brief and the recorded captain calls ride along -----

H=$(new_home holds scout)
printf 'decisions_reviewed=1\ndecision_keys=t1-pick-db\n' >> "$H/state/t1.meta"
printf 'needs-decision [key=auth]: pick the auth provider\n' > "$H/state/t1.status"
write_response_all no yes no
run "$H" code out TYPESAFE_API_KEY="$KEY" -- fm-teardown.sh t1 --report-has-captain-call no --scout-recommends-ship no
assert_contains "$out" "jev scout-recommends-ship decision " "the report asks went out"
HOLDS_CTX=$(jq -r '.state.context' "$LOG/body")
assert_contains "$HOLDS_CTX" "The scout's instructions:"$'\n'"## Captain's intent" "the scout's brief sections go, labelled"
assert_contains "$HOLDS_CTX" "Fix the flaky login test." "the brief's intent goes"
assert_contains "$HOLDS_CTX" "Captain calls already recorded for this scout:" "the recorded captain calls are labelled"
assert_contains "$HOLDS_CTX" "- inventory task t1-pick-db: " "the completion inventory entry goes with its state"
assert_contains "$HOLDS_CTX" "- open decision auth in the status log: pick the auth provider" "an open keyed decision goes"
assert_contains "$HOLDS_CTX" "The flake is a race in the fixture." "the report still goes"
H=$(new_home noholds scout)
run "$H" code out TYPESAFE_API_KEY="$KEY" -- fm-teardown.sh t1 --report-has-captain-call no --scout-recommends-ship no
assert_contains "$(jq -r '.state.context' "$LOG/body")" "Captain calls already recorded for this scout:"$'\n'"none" "a scout with no recorded call says none"
pass "the scout report asks carry the scout's brief and its recorded captain calls"

# --- blind choice before the answer, through a gated script -------------------

H=$(new_home blind ship)
write_response no 0.99 yes
rm -f "$LOG/usage-at-post"
run "$H" code out TYPESAFE_API_KEY="$KEY" FAKE_CURL_USAGE="$H/state/jev-usage.jsonl" -- fm-merge-local.sh t1 --merge-risk yes
assert_contains "$out" "jev merge-risk decision " "the gate asked Jev"
assert_contains "$out" ": yes acts (decided by firstmate)" "with no authority entry, firstmate's call acts even against a confident Jev"
assert_present "$LOG/usage-at-post" "the fake Jev saw the usage log at request time"
[ "$(jq -sc '[.[] | select(.event == "mine") | {mine, blind}]' "$LOG/usage-at-post")" = '[{"mine":"yes","blind":true}]' ] \
  || fail "the blind choice was not recorded before the request: $(cat "$LOG/usage-at-post")"
[ "$(jq -sc '[.[] | select(.event == "call")] | length' "$LOG/usage-at-post")" = 0 ] \
  || fail "Jev's answer was recorded before the request left"
[ "$(jq -src 'map(select(.event == "call")) | last | .question_type' "$H/state/jev-usage.jsonl")" = merge-risk ] \
  || fail "the answered call was not recorded as merge-risk"
pass "a gated script records firstmate's blind choice before Jev is asked, and without authority its call stays firstmate's"

H=$(new_home words ship)
jq -cn '{hook_event_name: "UserPromptSubmit", session_id: "s1", prompt: "land t1 now, it is only docs"}' \
  | env -u FM_TASK_ID FM_HOME="$H" "$ROOT/bin/fm-jev-prompt-reminder.sh" > /dev/null
jq -cn '{hook_event_name: "UserPromptSubmit", session_id: "s1", prompt: "wait, it also touches the merge script"}' \
  | env -u FM_TASK_ID FM_HOME="$H" "$ROOT/bin/fm-jev-prompt-reminder.sh" > /dev/null
write_response yes 0.8 no
run "$H" code out TYPESAFE_API_KEY="$KEY" -- fm-merge-local.sh t1 --merge-risk no
GATE_ID=$(sed -n 's/.*jev merge-risk decision \([^:]*\):.*/\1/p' <<<"$out" | head -n 1)
[ -n "$GATE_ID" ] || fail "the gated merge recorded no decision: $out"
GATE_CTX=$(jq -r .context "$H/state/jev-audit/$GATE_ID.json")
assert_contains "$GATE_CTX" $'The operator\'s words this turn, verbatim, oldest first:\nMessage at' "a script-built ask opens with the operator's words"
assert_contains "$GATE_CTX" 'land t1 now, it is only docs' "the turn's opening prompt reaches the script-built ask"
assert_contains "$GATE_CTX" 'wait, it also touches the merge script' "the mid-turn message reaches the script-built ask"
assert_contains "$GATE_CTX" $'Merge:\n' "the script's own context follows as a source"
assert_contains "$GATE_CTX" 'Fix the flaky login test.' "the brief still reaches the script-built ask"
pass "a script-built ask carries the operator's verbatim words for the turn ahead of the script's context"

BIGBRIEF="$TMP_ROOT/big-brief.md"
{
  printf '# Task\n## Captain'"'"'s intent\n'
  head -c 9000 /dev/zero | tr '\0' 'x'
  printf '\nTAIL-MARKER-AFTER-6000\n## Firstmate spec\nspec body\n'
} > "$BIGBRIEF"
head -c 7000 /dev/zero | tr '\0' 'y' > "$TMP_ROOT/big-extra"
bash -c 'SCRIPT_DIR=$1/bin; FM_HOME=$2; . "$1/bin/fm-jev-gate-lib.sh"; fm_jev_gate_context "$3" "$4" extra "$5"' _ \
  "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" "$TMP_ROOT" "$TMP_ROOT/big-context" "$BIGBRIEF" "$TMP_ROOT/big-extra"
[ "$(wc -c < "$TMP_ROOT/big-context")" -gt 16000 ] || fail "context was cut: $(wc -c < "$TMP_ROOT/big-context") bytes"
grep -q 'TAIL-MARKER-AFTER-6000' "$TMP_ROOT/big-context" || fail "marker past byte 6000 missing from context"
pass "a context larger than 6000 bytes reaches the ask whole"
