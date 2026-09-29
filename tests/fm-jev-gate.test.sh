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
cat > /dev/null
[ -z "${FAKE_CURL_USAGE:-}" ] || cp "$FAKE_CURL_USAGE" "$FAKE_CURL_LOG/usage-at-post" 2>/dev/null || true
cp "${FAKE_CURL_RESPONSE:?}" "$out"
printf '200'
SH
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_CURL_LOG:?}/tmux"
case "${1:-}" in
  display-message) printf 'fakepane\n' ;;
  capture-pane) printf '\n' ;;
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

write_response spawn-proj 0.9 other-proj
printf 'mismatch\n' > "$TMP_ROOT/pm-context"
run "$H" code out TYPESAFE_API_KEY="$KEY" -- fm-jev.sh ask --type project-match --summary "which project" \
  --question "Which registered project is this request about?" --option spawn-proj --option other-proj \
  --context "$TMP_ROOT/pm-context" --mine other-proj
expect_code 0 "$code" "project-match ask"
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

H=$(new_home control ship)
for verb in interrupt relaunch; do
  run "$H" code out -- fm-control.sh t1 "$verb"
  expect_code 2 "$code" "$verb without --worker-state"
  assert_contains "$out" "fm-control.sh: refused: $verb needs --worker-state <working|waiting-on-answered-question|looping|confused|unresponsive>" "$verb refusal"
  [ ! -s "$LOG/tmux" ] || fail "a refused $verb touched tmux: $(cat "$LOG/tmux")"
done
run "$H" code out -- fm-control.sh t1 interrupt --worker-state stuck
expect_code 2 "$code" "invalid --worker-state"
pass "fm-control refuses interrupt and relaunch without a valid worker state, touching nothing"

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

# --- blind choice before the answer, through a gated script -------------------

H=$(new_home blind ship)
write_response no 0.99 yes
rm -f "$LOG/usage-at-post"
run "$H" code out TYPESAFE_API_KEY="$KEY" FAKE_CURL_USAGE="$H/state/jev-usage.jsonl" -- fm-merge-local.sh t1 --merge-risk yes
assert_contains "$out" "jev merge-risk decision " "the gate asked Jev"
assert_contains "$out" ": yes acts (decided by firstmate)" "a never-type acts on firstmate's call even against a confident Jev"
assert_present "$LOG/usage-at-post" "the fake Jev saw the usage log at request time"
[ "$(jq -sc '[.[] | select(.event == "mine") | {mine, blind}]' "$LOG/usage-at-post")" = '[{"mine":"yes","blind":true}]' ] \
  || fail "the blind choice was not recorded before the request: $(cat "$LOG/usage-at-post")"
[ "$(jq -sc '[.[] | select(.event == "call")] | length' "$LOG/usage-at-post")" = 0 ] \
  || fail "Jev's answer was recorded before the request left"
[ "$(jq -src 'map(select(.event == "call")) | last | .question_type' "$H/state/jev-usage.jsonl")" = merge-risk ] \
  || fail "the answered call was not recorded as merge-risk"
pass "a gated script records firstmate's blind choice before Jev is asked, and a never-type stays firstmate's"
