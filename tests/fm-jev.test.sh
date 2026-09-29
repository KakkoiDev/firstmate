#!/usr/bin/env bash
# Behavior tests for bin/fm-jev.sh and the usage record in bin/fm-jev-lib.sh.
#
# Drives the public argv and environment interface with a fake curl on PATH
# that records argv, the request body it read from stdin, the header it read
# from file descriptor 3, and whether a key reached its environment, then
# answers with a canned typesafe.ai response; a Datadog intake URL is recorded
# separately and answered 202. A fake claude stands in for the detached
# duplicate query. No case touches the network, and the absent-key case
# proves the tool makes no call and writes no record.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-jev.sh"
TMP_ROOT=$(fm_test_tmproot fm-jev)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
NO_CURL_BIN="$TMP_ROOT/no-curl-bin"
LOG="$TMP_ROOT/log"
RESPONSE="$TMP_ROOT/response.json"
CONTEXT="$TMP_ROOT/context.md"
USAGE="$HOME_DIR/state/jev-usage.jsonl"
SIDELOG="$HOME_DIR/state/jev-duplicate.log"
AUDIT_DIR="$HOME_DIR/state/jev-audit"
BASE_PATH=$PATH
KEY='test-key-4c7e21aa-never-on-argv'
DD_KEY='dd-key-91b3f0c2-never-on-argv'
mkdir -p "$HOME_DIR" "$LOG" "$NO_CURL_BIN"
for command_name in awk bash cat date dirname jq mkdir mktemp rm; do
  ln -s "$(command -v "$command_name")" "$NO_CURL_BIN/$command_name"
done
unset TYPESAFE_API_KEY DD_API_KEY DD_SITE

printf '%s\n' 'Worker pane shows the same test failing for the third time.' 'CONTEXT-ONLY-MARKER' > "$CONTEXT"

write_response() {  # <path> <choice> <confidence>
  cat > "$1" <<JSON
{ "model": "jev-1.13.0",
  "answers": { "q": { "type": "choice", "choice": "$2", "confidence": $3,
    "probabilities": { "working": 0.05, "looping": 0.9, "confused": 0.05 } } },
  "usage": { "input_tokens": 420, "output_tokens": 55 } }
JSON
}

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
set -u
case " $* " in
  *' https://http-intake.logs.'*)
    mkdir -p "${FAKE_CURL_LOG:?}"
    if [ -n "${TYPESAFE_API_KEY+x}${TYPESAFE_API_KEY_PRIVATE+x}${DD_API_KEY+x}${DD_API_KEY_PRIVATE+x}" ]; then
      printf 'dd:secret-present\n' >> "$FAKE_CURL_LOG/dd-env"
    else
      printf 'dd:clean\n' >> "$FAKE_CURL_LOG/dd-env"
    fi
    printf '%s\n' "$@" >> "$FAKE_CURL_LOG/dd-argv"
    { cat; printf '\n'; } >> "$FAKE_CURL_LOG/dd-body"
    cat /dev/fd/3 >> "$FAKE_CURL_LOG/dd-header" 2>/dev/null || printf 'fd3 unreadable\n' >> "$FAKE_CURL_LOG/dd-header"
    printf '%s' "${FAKE_DD_HTTP:-202}"
    exit 0
    ;;
esac
if [ -n "${TYPESAFE_API_KEY+x}" ] || [ -n "${TYPESAFE_API_KEY_PRIVATE+x}" ]; then
  printf 'curl:secret-present\n' >> "${FAKE_CURL_LOG:?}/child-env"
else
  printf 'curl:clean\n' >> "${FAKE_CURL_LOG:?}/child-env"
fi
out=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    *) printf '%s\n' "$1" >> "$FAKE_CURL_LOG/argv"; shift ;;
  esac
done
cat > "$FAKE_CURL_LOG/body"
cat /dev/fd/3 > "$FAKE_CURL_LOG/header" 2>/dev/null || printf 'fd3 unreadable\n' > "$FAKE_CURL_LOG/header"
if [ "${FAKE_CURL_FAIL:-0}" = 1 ]; then
  exit 7
fi
cp "${FAKE_CURL_RESPONSE:?}" "$out"
printf '%s' "${FAKE_CURL_HTTP:-200}"
SH
chmod +x "$FAKEBIN/curl"

# Fake claude: records argv, stdin, working directory, and whether a key
# reached its environment, then answers like `claude -p --output-format json`.
cat > "$FAKEBIN/claude" <<'SH'
#!/usr/bin/env bash
set -u
L=${FAKE_CURL_LOG:?}
mkdir -p "$L"
printf '%s\n' "$@" > "$L/claude-argv"
model=''
prev=''
for a in "$@"; do
  [ "$prev" = --model ] && model=$a
  prev=$a
done
printf '%s\n' "$model" >> "$L/claude-models"
pwd -P > "$L/claude-pwd"
find . -mindepth 1 | wc -l | tr -d ' ' > "$L/claude-dir-count"
if [ -n "${TYPESAFE_API_KEY+x}${TYPESAFE_API_KEY_PRIVATE+x}${DD_API_KEY+x}${DD_API_KEY_PRIVATE+x}" ]; then
  echo secret-present > "$L/claude-env"
else
  echo clean > "$L/claude-env"
fi
cat > "$L/claude-stdin"
[ "$model" = "${FAKE_CLAUDE_FAIL_MODEL:-}" ] && { echo 'claude failed' >&2; exit 1; }
case "${FAKE_CLAUDE_MODE:-ok}" in
  fail) echo 'claude failed' >&2; exit 1 ;;
  sleep) sleep 4 ;;
esac
jq -cn --arg r "${FAKE_CLAUDE_ANSWER:-looping}" '
  {type: "result", subtype: "success", is_error: false, result: $r,
   duration_ms: 3882, duration_api_ms: 3832, total_cost_usd: 0.004504,
   usage: {input_tokens: 2, cache_creation_input_tokens: 552, cache_read_input_tokens: 0, output_tokens: 5},
   modelUsage: {}}'
SH
chmod +x "$FAKEBIN/claude"

export FAKE_CURL_LOG="$LOG" FAKE_CURL_RESPONSE="$RESPONSE"
# One Claude model unless a case opts into the default list.
export FM_JEV_CLAUDE_MODELS=claude-opus-5-5

reset() {
  rm -rf "$LOG" "$HOME_DIR/state"
  mkdir -p "$LOG"
}

# settled <n>: n detached duplicate queries have finished, each leaving either
# a duplicate record or a side-log line.
settled() {
  local d=0 s=0
  [ -f "$USAGE" ] && d=$(grep -c '"event":"duplicate"' "$USAGE")
  [ -f "$SIDELOG" ] && s=$(grep -c . "$SIDELOG")
  [ $((d + s)) -ge "$1" ]
}
# lines_at_least <file> <n>
lines_at_least() { [ -f "$1" ] && [ "$(grep -c . "$1")" -ge "$2" ]; }
# wait_for <description> <command...>: polls for up to ten seconds.
wait_for() {
  local desc=$1 _
  shift
  for _ in $(seq 1 100); do
    "$@" && return 0
    sleep 0.1
  done
  fail "$desc (timed out)"
}
calls() { jq -c 'select(.event == "call")' "$USAGE"; }

# run <exit-var> <out-var> <err-var> [args...]
run() {
  local __exit=$1 __out=$2 __err=$3 _out _code
  shift 3
  _out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" "$TOOL" "$@" 2> "$TMP_ROOT/stderr")
  _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
  printf -v "$__err" '%s' "$(cat "$TMP_ROOT/stderr")"
}

ASK=(ask --type stuck-worker --summary 'What is the stuck worker doing'
  --question 'Which state best describes the worker in the context?'
  --option 'working=Making progress.' --option 'looping=Repeating the same failed step.' --option confused
  --context "$CONTEXT")
code='' out='' err=''

# --- absent key: off, no call, no record --------------------------------------
reset
write_response "$RESPONSE" looping 0.9
run code out err "${ASK[@]}"
expect_code 0 "$code" "absent key exits 0"
assert_equals '' "$out" "absent key prints nothing on stdout"
assert_contains "$err" 'jev: off (TYPESAFE_API_KEY absent from the environment and' "absent key explains itself on stderr"
assert_absent "$LOG/argv" "absent key never calls curl"
assert_absent "$USAGE" "absent key writes no usage record"
pass "absent key is off: one stderr line, exit 0, no call, no record"

# --- answered: output, request shape, record shape, key handling ----------------
reset
printf '%s\n' "TYPESAFE_API_KEY=$KEY" > "$HOME_DIR/.env"
run code out err "${ASK[@]}"
rm -f "$HOME_DIR/.env"
expect_code 0 "$code" "answered ask exits 0"
assert_contains "$out" 'jev:' "TOON block header"
assert_contains "$out" '  answer: looping   confidence: 0.9' "answer and confidence line"
assert_contains "$out" '  probabilities: working=0.05 looping=0.9 confused=0.05' "probabilities line"
assert_contains "$out" '  model: jev-1.13.0   latency_ms: ' "model and latency line"
assert_contains "$out" 'tokens: 420/55' "token line"
id=$(sed -n 's/^  decision_id: //p' <<<"$out")
[[ $id =~ ^jev-[0-9]+-[0-9]+-[0-9]+$ ]] || fail "decision id has the documented shape (got '$id')"
body=$(cat "$LOG/body")
assert_equals 'jev-latest' "$(jq -r .model <<<"$body")" "request uses the shared model"
assert_equals '["q"]' "$(jq -c '.questions | keys' <<<"$body")" "one question is asked"
assert_equals 'choice' "$(jq -r .questions.q.type <<<"$body")" "the question is a Choice"
assert_equals '{"working":"Making progress.","looping":"Repeating the same failed step.","confused":"confused"}' \
  "$(jq -c .questions.q.criteria <<<"$body")" "options become criteria, meaning defaulting to the slug"
assert_contains "$(jq -r .state.context <<<"$body")" 'CONTEXT-ONLY-MARKER' "the context file is the state"
assert_not_contains "$body" 'What is the stuck worker doing' "the summary is never sent"
argv=$(cat "$LOG/argv")
assert_not_contains "$argv" "$KEY" "the key never appears on curl argv"
assert_contains "$argv" 'https://api.typesafe.ai/v1/systemone' "the fixed endpoint"
assert_contains "$argv" $'--max-time\n5' "the fixed five-second timeout"
assert_contains "$argv" '@/dev/fd/3' "the header is read from a file descriptor"
assert_equals "Authorization: Bearer $KEY" "$(cat "$LOG/header")" ".env key reaches curl on the fd header"
assert_equals 'curl:clean' "$(cat "$LOG/child-env")" "the key is absent from the curl environment"
wait_for "the duplicate query settles" settled 1
assert_equals 1 "$(calls | wc -l | tr -d ' ')" "one call record per call"
record=$(calls)
assert_equals '["answer","confidence","context_sha256","decision_id","event","jev_cost_usd","latency_ms","model","options","probabilities","question_type","status","summary","tokens_in","tokens_out","ts","v"]' \
  "$(jq -c 'keys' <<<"$record")" "record carries exactly the documented fields"
assert_equals true "$(jq '(.jev_cost_usd - 0.00001764 | fabs) < 1e-15' <<<"$record")" "Jev cost is 420 input tokens at \$42 per billion"
assert_equals "$(shasum -a 256 "$CONTEXT" | awk '{print $1}')" "$(jq -r .context_sha256 <<<"$record")" "record points at the context by its sha256"
assert_equals "call|$id|stuck-worker|What is the stuck worker doing|looping|0.9|jev-1.13.0|420|55|ok" \
  "$(jq -r '[.event, .decision_id, .question_type, .summary, .answer, .confidence, .model, .tokens_in, .tokens_out, .status] | join("|")' <<<"$record")" \
  "record values"
assert_equals '["working","looping","confused"]' "$(jq -c .options <<<"$record")" "record lists the options"
[ "$(jq -r '.latency_ms | type' <<<"$record")" = number ] || fail "record latency is a number"
[[ $(jq -r .ts <<<"$record") =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || fail "record timestamp is ISO UTC"
assert_not_contains "$record" "$KEY" "the key is never recorded"
assert_not_contains "$record" 'CONTEXT-ONLY-MARKER' "the context is never recorded"
assert_not_contains "$record" 'Which state best describes' "the question text is never recorded"
pass "answered: typed output, one Choice request, key on the fd header only, one summary record"

# --- duplicate Claude query: isolated, joined by decision id ------------------------
duplicate=$(jq -c 'select(.event == "duplicate")' "$USAGE")
assert_equals '["claude_answer","claude_cost_usd","claude_latency_ms","claude_model","claude_tokens_in","claude_tokens_out","claude_wall_ms","decision_id","event","status","ts","v"]' \
  "$(jq -c 'keys' <<<"$duplicate")" "duplicate record carries exactly the documented fields"
assert_equals "$id|claude-opus-5-5|looping|3832|0.004504|554|5|ok" \
  "$(jq -r '[.decision_id, .claude_model, .claude_answer, .claude_latency_ms, .claude_cost_usd, .claude_tokens_in, .claude_tokens_out, .status] | join("|")' <<<"$duplicate")" \
  "duplicate record values: API latency, API-equivalent cost, input plus cache tokens"
[ "$(jq -r '.claude_wall_ms | type' <<<"$duplicate")" = number ] || fail "wall latency is a number"
claude_argv=$(cat "$LOG/claude-argv")
for flag in -p --safe-mode --strict-mcp-config --no-session-persistence --exclude-dynamic-system-prompt-sections; do
  assert_contains "$claude_argv" "$flag" "claude runs with $flag"
done
assert_contains "$claude_argv" $'--setting-sources\n\n' "claude loads no setting sources"
assert_contains "$claude_argv" $'--tools\n\n' "claude has no tools"
assert_contains "$claude_argv" $'--model\nclaude-opus-5-5' "claude uses the pinned model"
assert_contains "$claude_argv" $'--output-format\njson' "claude answers in JSON"
assert_not_contains "$claude_argv" 'CONTEXT-ONLY-MARKER' "the context never reaches claude argv"
assert_equals 0 "$(cat "$LOG/claude-dir-count")" "claude runs in an empty directory"
assert_not_equals "$(cd "$ROOT" && pwd -P)" "$(cat "$LOG/claude-pwd")" "claude never runs in the repository"
assert_equals clean "$(cat "$LOG/claude-env")" "no key reaches the claude environment"
claude_stdin=$(cat "$LOG/claude-stdin")
assert_contains "$claude_stdin" 'Which state best describes the worker in the context?' "claude gets the same question"
assert_contains "$claude_stdin" '- looping: Repeating the same failed step.' "claude gets the same options"
assert_contains "$claude_stdin" 'CONTEXT-ONLY-MARKER' "claude gets the same context"
assert_not_contains "$claude_stdin" "$KEY" "the key never reaches claude"
pass "duplicate query: isolated claude run, one joined duplicate record"

# --- audit snapshot: exact question, context, prompts, and raw answers --------------
audit="$AUDIT_DIR/$id.json"
assert_present "$audit" "the audit snapshot is written"
has_claude_response() { jq -e 'has("claude_response")' "$audit" >/dev/null 2>&1; }
wait_for "claude's raw answer lands in the snapshot" has_claude_response
assert_equals '["claude_prompt","claude_response","claude_system_prompt","context","context_sha256","decision_id","jev_request","jev_response","options","question","question_type","ts","v"]' \
  "$(jq -c 'keys' "$audit")" "the snapshot carries exactly the documented fields"
assert_equals "$(cat "$CONTEXT")" "$(jq -r .context "$audit")" "the snapshot holds the exact context"
assert_equals "$(jq -j .context "$audit" | shasum -a 256 | awk '{print $1}')" "$(jq -r .context_sha256 "$audit")" "the snapshot sha256 matches its context bytes"
assert_equals "$(jq -r .context_sha256 <<<"$record")" "$(jq -r .context_sha256 "$audit")" "record and snapshot share the sha256"
assert_equals "$(jq -cS . "$LOG/body")" "$(jq -cS .jev_request "$audit")" "the snapshot holds the exact Jev request"
assert_equals "$(cat "$RESPONSE")" "$(jq -r .jev_response "$audit")" "the snapshot holds the raw Jev response"
assert_equals "$claude_stdin" "$(jq -r .claude_prompt "$audit")" "the snapshot holds the exact claude prompt"
assert_equals looping "$(jq -r '.claude_response | fromjson | .result' "$audit")" "the snapshot holds the raw claude answer"
assert_equals 'Which state best describes the worker in the context?' "$(jq -r .question "$audit")" "the snapshot holds the question"
assert_equals '{"working":"Making progress.","looping":"Repeating the same failed step.","confused":"confused"}' \
  "$(jq -c .options "$audit")" "the snapshot holds the option meanings"
grep -rqF -- "$KEY" "$AUDIT_DIR" && fail "the key is never in the audit snapshot"
assert_not_contains "$(cat "$audit")" 'Authorization' "no auth header is in the audit snapshot"
run code out err show "$id"
expect_code 0 "$code" "show exits 0"
assert_equals "$(jq -cS . "$audit")" "$(jq -cS .audit <<<"$out")" "show prints the audit snapshot"
assert_equals "looping|looping|ok" "$(jq -r '.record | [.answer, .claude_answer, .claude_status] | join("|")' <<<"$out")" "show joins the duplicate beside the call"
pass "audit snapshot: exact context and prompts, matching sha256, no key, printed by show"

reset
TYPESAFE_API_KEY=$KEY run code out err ask --type deploy-check --summary 'Is the deploy safe' --question 'Is it safe?' --yes-no
assert_equals '{"yes":"Yes.","no":"No."}' "$(jq -c .questions.q.criteria "$LOG/body")" "--yes-no is the yes/no Choice"
assert_equals '' "$(jq -r .state.context "$LOG/body")" "no context file sends an empty context"
assert_equals '' "$out" "a response over other options is not an answer"
assert_contains "$err" 'jev: error (response is not a Choice answer over the options)' "the mismatch is named"
wait_for "the yes/no duplicate settles" settled 1
assert_equals 'off-option|' "$(jq -r 'select(.event == "duplicate") | [.status, (.claude_answer // "")] | join("|")' "$USAGE")" \
  "a claude reply that is not an option id is recorded as off-option with no answer"
pass "--yes-no asks the yes/no Choice and validates the answer against it"

# --- failures step aside: exit 0, nothing on stdout, error record ----------------
for failure in 'FAKE_CURL_FAIL=1|http 000' 'FAKE_CURL_HTTP=503|http 503'; do
  reset
  write_response "$RESPONSE" looping 0.9
  env_assign=${failure%%|*}
  env "$env_assign" TYPESAFE_API_KEY="$KEY" PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" "$TOOL" "${ASK[@]}" > "$TMP_ROOT/out" 2> "$TMP_ROOT/stderr"
  expect_code 0 "$?" "$env_assign exits 0"
  assert_equals '' "$(cat "$TMP_ROOT/out")" "$env_assign prints nothing on stdout"
  assert_contains "$(cat "$TMP_ROOT/stderr")" "jev: error (${failure#*|} after" "$env_assign is one stderr line"
  assert_equals 'error||' "$(calls | jq -r '[.status, (.answer // ""), (.model // "")] | join("|")')" "$env_assign records an error with no answer"
  wait_for "$env_assign duplicate settles" settled 1
done
reset
printf '%s\n' '{"model":"jev-1.13.0","answers":{"q":{"choice":"looping","confidence":1.4}}}' > "$RESPONSE"
TYPESAFE_API_KEY=$KEY run code out err "${ASK[@]}"
expect_code 0 "$code" "malformed answer exits 0"
assert_equals '' "$out" "malformed answer prints nothing on stdout"
assert_equals 'error' "$(calls | jq -r .status)" "malformed answer records an error"
wait_for "malformed-answer duplicate settles" settled 1
reset
out=$(PATH="$NO_CURL_BIN" FM_HOME="$HOME_DIR" TYPESAFE_API_KEY="$KEY" "$TOOL" "${ASK[@]}" 2> "$TMP_ROOT/stderr")
expect_code 0 "$?" "missing curl exits 0"
assert_equals '' "$out" "missing curl prints nothing on stdout"
assert_contains "$(cat "$TMP_ROOT/stderr")" 'jev: error (curl not installed)' "missing curl is named"
assert_absent "$USAGE" "missing curl makes no call and writes no record"
pass "every Jev failure steps aside: exit 0, empty stdout, one stderr line, an error record"

# --- usage errors exit 2 before any call ----------------------------------------
reset
TYPESAFE_API_KEY=$KEY run code out err ask --type 'Bad Type' --summary s --question q --yes-no
expect_code 2 "$code" "non-slug type is a usage error"
TYPESAFE_API_KEY=$KEY run code out err ask --type t --summary s --question q --option only
expect_code 2 "$code" "one option is a usage error"
TYPESAFE_API_KEY=$KEY run code out err ask --type t --summary s --question q --option 'a b' --option c
expect_code 2 "$code" "an option id with a space is a usage error"
TYPESAFE_API_KEY=$KEY run code out err ask --type t --summary s --question q --yes-no --context "$TMP_ROOT/missing"
expect_code 2 "$code" "unreadable context is a usage error"
assert_absent "$LOG/argv" "usage errors never call curl"
pass "usage errors exit 2 before any network call"

# --- record-mine and record-outcome join on the decision id ---------------------
reset
write_response "$RESPONSE" looping 0.9
TYPESAFE_API_KEY=$KEY run code out err "${ASK[@]}"
id1=$(sed -n 's/^  decision_id: //p' <<<"$out")
TYPESAFE_API_KEY=$KEY run code out err "${ASK[@]}"
id2=$(sed -n 's/^  decision_id: //p' <<<"$out")
assert_not_equals "$id1" "$id2" "each call gets its own decision id"
wait_for "both duplicates settle" settled 2
rm -f "$LOG/argv"
run code out err record-mine "$id1" looping
expect_code 0 "$code" "record-mine exits 0"
assert_equals "jev: recorded $id1 mine=looping jev=looping followed" "$out" "record-mine confirms a followed decision"
run code out err record-mine latest:stuck-worker confused
assert_equals "jev: recorded $id2 mine=confused jev=looping overridden" "$out" "latest:<type> labels the newest call of that type"
run code out err record-mine "$id1" sleeping
expect_code 2 "$code" "an answer outside the options is refused"
run code out err record-mine jev-0-0-0 looping
expect_code 2 "$code" "an unknown decision id is refused"
run code out err record-outcome "$id1" 'captain says it was confused' --final confused
expect_code 0 "$code" "record-outcome exits 0"
assert_equals "jev: recorded outcome for $id1 final=confused jev=looping overridden" "$out" "an outcome's final choice overrides"
run code out err show "$id1"
assert_equals 'looping|looping|captain says it was confused|confused|overridden' \
  "$(jq -r '.record | [.answer, .mine, .outcome, .final, .decision] | join("|")' <<<"$out")" "show joins call, mine, and outcome"
run code out err show "$id2"
assert_equals 'looping|confused||confused|overridden' \
  "$(jq -r '.record | [.answer, .mine, (.outcome // ""), .final, .decision] | join("|")' <<<"$out")" "without an outcome the final choice is firstmate's"
assert_equals 'call call mine mine outcome' "$(jq -r 'select(.event != "duplicate") | .event' "$USAGE" | tr '\n' ' ' | sed 's/ $//')" "the log stays append-only"
assert_equals 2 "$(jq -r 'select(.event == "duplicate") | .event' "$USAGE" | wc -l | tr -d ' ')" "one duplicate record per call"
assert_absent "$LOG/dd-body" "no Datadog key sends nothing"
assert_absent "$LOG/argv" "record subcommands never call curl"
pass "record-mine and record-outcome append beside the call and join on its decision id"

# --- Datadog: one combined decision event, label events, key on fd 3 only --------
reset
write_response "$RESPONSE" looping 0.9
TYPESAFE_API_KEY=$KEY DD_API_KEY=$DD_KEY DD_SITE=datadoghq.eu run code out err "${ASK[@]}"
expect_code 0 "$code" "ask with Datadog exits 0"
id=$(sed -n 's/^  decision_id: //p' <<<"$out")
wait_for "the combined decision event is sent" lines_at_least "$LOG/dd-body" 1
event=$(jq -c '.[0]' "$LOG/dd-body")
assert_equals 1 "$(jq -s 'length' "$LOG/dd-body")" "one Datadog request per decision"
assert_equals 1 "$(head -n1 "$LOG/dd-body" | jq 'length')" "the request holds one event"
assert_equals '["claude_answer","claude_cost_usd","claude_jev_agree","claude_latency_ms","claude_model","claude_status","claude_tokens_in","claude_tokens_out","claude_wall_ms","context_sha256","ddsource","ddtags","decision_id","event","firstmate_answer","jev_answer","jev_confidence","jev_cost_usd","jev_latency_ms","jev_model","jev_status","jev_tokens_in","jev_tokens_out","message","question_type","service","summary"]' \
  "$(jq -c 'keys' <<<"$event")" "the decision event carries exactly the documented fields"
assert_equals "decision|$id|firstmate-jev|stuck-worker|What is the stuck worker doing|looping|jev-1.13.0|ok|looping|claude-opus-5-5|ok|true" \
  "$(jq -r '[.event, .decision_id, .service, .question_type, .summary, .jev_answer, .jev_model, .jev_status, .claude_answer, .claude_model, .claude_status, .claude_jev_agree] | map(tostring) | join("|")' <<<"$event")" \
  "the decision event joins Jev and the duplicate query"
assert_equals 'number number number number number number number number number boolean null' \
  "$(jq -r '[.jev_confidence, .jev_latency_ms, .jev_tokens_in, .jev_cost_usd, .claude_latency_ms, .claude_wall_ms, .claude_tokens_in, .claude_tokens_out, .claude_cost_usd, .claude_jev_agree, .firstmate_answer] | map(type) | join(" ")' <<<"$event")" \
  "numeric fields stay numeric"
assert_equals '0.9|420|3832|554|5|0.004504' \
  "$(jq -r '[.jev_confidence, .jev_tokens_in, .claude_latency_ms, .claude_tokens_in, .claude_tokens_out, .claude_cost_usd] | map(tostring) | join("|")' <<<"$event")" \
  "the decision event values"
assert_equals "$(jq -r .context_sha256 "$AUDIT_DIR/$id.json")" "$(jq -r .context_sha256 <<<"$event")" "the event points at the audit snapshot by sha256"
dd_body=$(cat "$LOG/dd-body")
for secret_text in 'CONTEXT-ONLY-MARKER' 'Which state best describes' 'Repeating the same failed step' 'probabilities' "$KEY" "$DD_KEY"; do
  assert_not_contains "$dd_body" "$secret_text" "Datadog never gets: $secret_text"
done
assert_contains "$(cat "$LOG/dd-argv")" 'https://http-intake.logs.datadoghq.eu/api/v2/logs' "DD_SITE picks the intake host"
assert_not_contains "$(cat "$LOG/dd-argv")" "$DD_KEY" "the Datadog key never appears on curl argv"
assert_equals "DD-API-KEY: $DD_KEY" "$(cat "$LOG/dd-header")" "the Datadog key reaches curl on the fd header"
assert_equals 'dd:clean' "$(cat "$LOG/dd-env")" "no key is in the Datadog curl environment"
assert_equals clean "$(cat "$LOG/claude-env")" "the Datadog key never reaches claude"
pass "Datadog decision event: one combined event after the duplicate, numeric fields, no text, key on fd 3"

rm -f "$LOG/dd-body" "$LOG/dd-header"
printf '%s\n' "DD_API_KEY=$DD_KEY" > "$HOME_DIR/.env"
run code out err record-mine "$id" confused
rm -f "$HOME_DIR/.env"
expect_code 0 "$code" "record-mine with Datadog exits 0"
assert_equals '' "$err" "a sent label event is silent"
label=$(jq -c '.[0]' "$LOG/dd-body")
assert_equals '["ddsource","ddtags","decision_id","event","final_choice","firstmate_answer","followed_or_overridden","message","service"]' \
  "$(jq -c 'keys' <<<"$label")" "the label event carries exactly the documented fields"
assert_equals "label|$id|confused|overridden|confused" \
  "$(jq -r '[.event, .decision_id, .firstmate_answer, .followed_or_overridden, .final_choice] | join("|")' <<<"$label")" \
  "record-mine sends the label with the final choice"
assert_contains "$(cat "$LOG/dd-argv")" 'https://http-intake.logs.datadoghq.com/api/v2/logs' "DD_SITE defaults to datadoghq.com"
assert_equals "DD-API-KEY: $DD_KEY" "$(cat "$LOG/dd-header")" "an .env Datadog key reaches curl on the fd header"
rm -f "$LOG/dd-body"
DD_API_KEY=$DD_KEY run code out err record-outcome "$id" 'captain agreed with Jev' --final looping
assert_equals "label|$id|confused|followed|looping" \
  "$(jq -r '.[0] | [.event, .decision_id, .firstmate_answer, .followed_or_overridden, .final_choice] | join("|")' "$LOG/dd-body")" \
  "record-outcome sends the label with the overriding final choice"
DD_API_KEY=$DD_KEY FAKE_DD_HTTP=500 run code out err record-mine "$id" looping
expect_code 0 "$code" "a Datadog failure never fails the record"
assert_equals 'jev: datadog log not sent (http 500)' "$err" "a Datadog failure is one stderr line"
assert_equals looping "$(jq -r 'select(.event == "mine") | .mine' "$USAGE" | tail -n1)" "the record lands despite the Datadog failure"
rm -f "$LOG/dd-body"
DD_API_KEY=$DD_KEY DD_SITE='evil.example/x?' run code out err record-mine "$id" looping
assert_equals 'jev: datadog log not sent (DD_SITE is not a Datadog site name)' "$err" "a malformed DD_SITE is refused"
assert_absent "$LOG/dd-body" "a malformed DD_SITE sends nothing"
pass "Datadog label events: record-mine and record-outcome, .env key, failures step aside"

# --- Claude failure: no duplicate record, null Claude fields ------------------------
reset
TYPESAFE_API_KEY=$KEY DD_API_KEY=$DD_KEY FAKE_CLAUDE_MODE=fail run code out err "${ASK[@]}"
expect_code 0 "$code" "a claude failure never fails ask"
assert_contains "$out" '  answer: looping' "a claude failure leaves the Jev answer intact"
assert_equals '' "$err" "a claude failure writes nothing to the caller's stderr"
id=$(sed -n 's/^  decision_id: //p' <<<"$out")
wait_for "the decision event is sent after the claude failure" lines_at_least "$LOG/dd-body" 1
assert_equals 0 "$(jq -r 'select(.event == "duplicate") | .event' "$USAGE" | wc -l | tr -d ' ')" "a claude failure writes no duplicate record"
assert_contains "$(cat "$SIDELOG")" "$id: claude-opus-5-5: claude exited non-zero" "a claude failure is one side-log line"
event=$(jq -c '.[0]' "$LOG/dd-body")
assert_equals 'looping|error|null|claude-opus-5-5|null|null|null|null|null|null' \
  "$(jq -r '[.jev_answer, .claude_status, .claude_answer, .claude_model, .claude_latency_ms, .claude_wall_ms, .claude_tokens_in, .claude_tokens_out, .claude_cost_usd, .claude_jev_agree] | map(tostring) | join("|")' <<<"$event")" \
  "a claude failure names its model and sends null Claude fields and a null agreement"
reset
TYPESAFE_API_KEY=$KEY DD_API_KEY=$DD_KEY FAKE_CURL_HTTP=503 run code out err "${ASK[@]}"
wait_for "the decision event is sent after a Jev failure" lines_at_least "$LOG/dd-body" 1
assert_equals 'error|null|looping|null' \
  "$(jq -r '.[0] | [.jev_status, .jev_answer, .claude_answer, .claude_jev_agree] | map(tostring) | join("|")' "$LOG/dd-body")" \
  "a Jev failure still sends one event with a null agreement"
pass "claude failure: exit 0, no duplicate record, side-log line, null Claude fields in the event"

# --- default model list: one duplicate and one Datadog event per model -------------
reset
TYPESAFE_API_KEY=$KEY DD_API_KEY=$DD_KEY FM_JEV_CLAUDE_MODELS='' FAKE_CLAUDE_FAIL_MODEL=claude-sonnet-5 run code out err "${ASK[@]}"
expect_code 0 "$code" "a three-model ask exits 0"
id=$(sed -n 's/^  decision_id: //p' <<<"$out")
wait_for "three decision events are sent" lines_at_least "$LOG/dd-body" 3
assert_equals $'claude-opus-5-5\nclaude-sonnet-5\nclaude-haiku-4-5-20251001' "$(cat "$LOG/claude-models")" \
  "the default list asks Opus, Sonnet, then Haiku, one after another"
assert_equals 3 "$(jq -s 'length' "$LOG/dd-body")" "one Datadog request per model"
assert_equals "decision|$id|claude-opus-5-5|ok|looping|decision|$id|claude-sonnet-5|error|null|decision|$id|claude-haiku-4-5-20251001|ok|looping" \
  "$(jq -rs '[.[][0] | .event, .decision_id, .claude_model, .claude_status, .claude_answer] | map(tostring) | join("|")' "$LOG/dd-body")" \
  "each event carries its own model, and a failed model still names itself"
assert_equals 'claude-opus-5-5 claude-haiku-4-5-20251001' \
  "$(jq -r 'select(.event == "duplicate") | .claude_model' "$USAGE" | paste -sd ' ' -)" "one duplicate record per answering model"
assert_contains "$(cat "$SIDELOG")" "$id: claude-sonnet-5: claude exited non-zero" "the failed model is one side-log line"
assert_equals claude-opus-5-5 "$(FM_JEV_CLAUDE_MODELS='' run code out err show "$id"; jq -r .record.claude_model <<<"$out")" \
  "show joins the first model's duplicate"
pass "default model list: Opus, Sonnet, Haiku in sequence, one event per model, first model in the joined record"

# --- the duplicate never blocks the caller ------------------------------------------
reset
start=$SECONDS
TYPESAFE_API_KEY=$KEY FAKE_CLAUDE_MODE=sleep run code out err "${ASK[@]}"
elapsed=$((SECONDS - start))
expect_code 0 "$code" "ask with a slow claude exits 0"
assert_contains "$out" '  answer: looping' "ask prints its answer before claude returns"
[ "$elapsed" -le 2 ] || fail "ask returned before the four-second claude finished (took ${elapsed}s)"
assert_equals 0 "$(jq -r 'select(.event == "duplicate") | .event' "$USAGE" | wc -l | tr -d ' ')" "the duplicate has not landed when ask returns"
wait_for "the slow duplicate settles" settled 1
pass "the duplicate query runs detached: a captured ask returns before claude does"

# --- report math on a fixture log -----------------------------------------------
reset
mkdir -p "$HOME_DIR/state"
fixture_call() {  # <id> <type> <ts> <status> <answer> <confidence> <latency> <tokens_in> <tokens_out>
  jq -cn --arg id "$1" --arg t "$2" --arg ts "$3" --arg s "$4" --arg a "$5" --argjson c "$6" --argjson l "$7" --argjson ti "$8" --argjson to "$9" '
    {v: 1, event: "call", ts: $ts, decision_id: $id, question_type: $t, summary: "s",
     options: ["a", "b", "working", "looping", "confused"],
     answer: (if $a == "" then null else $a end), confidence: $c, probabilities: null, model: "jev-1.13.0",
     latency_ms: $l, tokens_in: $ti, tokens_out: $to,
     jev_cost_usd: (if $ti == null then null else $ti * 42 / 1e9 end), status: $s}'
}
fixture_mine() { jq -cn --arg id "$1" --arg m "$2" '{v: 1, event: "mine", ts: "2026-09-26T00:00:00Z", decision_id: $id, mine: $m}'; }
fixture_dup() {  # <id> <answer or empty> <wall> <api> <cost>
  jq -cn --arg id "$1" --arg a "$2" --argjson w "$3" --argjson l "$4" --argjson c "$5" '
    {v: 1, event: "duplicate", ts: "2026-09-26T00:00:00Z", decision_id: $id, claude_model: "claude-opus-5-5",
     claude_answer: (if $a == "" then null else $a end), claude_wall_ms: $w, claude_latency_ms: $l,
     claude_cost_usd: $c, claude_tokens_in: 554, claude_tokens_out: 5,
     status: (if $a == "" then "off-option" else "ok" end)}'
}
{
  fixture_call d1 project-match 2026-09-21T00:00:00Z ok a 0.9 100 10 2
  fixture_call d2 project-match 2026-09-22T00:00:00Z ok a 0.8 200 20 3
  fixture_call d3 project-match 2026-09-23T00:00:00Z ok b 0.4 400 30 4
  fixture_call d4 project-match 2026-09-24T00:00:00Z error '' null 5000 null null
  fixture_call d5 project-match 2026-09-25T00:00:00Z ok a 0.7 300 40 5
  fixture_call e1 stuck-worker 2026-09-01T00:00:00Z ok working 0.95 50 1 1
  fixture_call e2 stuck-worker 2026-09-25T00:00:00Z ok looping 0.65 60 2 2
  printf '%s\n' 'not json at all'
  fixture_mine d1 a
  fixture_mine d2 b
  fixture_mine d3 b
  fixture_mine e1 working
  fixture_mine e2 confused
  fixture_dup d1 a 3000 2800 0.004
  fixture_dup d2 b 4000 3900 0.002
  fixture_dup d3 '' 5000 4500 0.001
  fixture_dup e2 looping 3500 3400 0.003
  printf '%s\n' '{"v":1,"event":"outcome","ts":"2026-09-27T00:00:00Z","decision_id":"d2","outcome":"captain picked b","final":"b"}'
} > "$USAGE"
run code out err report --since 2026-09-20
expect_code 0 "$code" "report exits 0"
expected=$(cat <<'TXT'
jev report (since 2026-09-20, floor 0.6)
project-match
  calls: 5   answered: 4   step-aside: 1
  agreement with firstmate: 2/3 (66.7%)
  confident (>= 0.6): 1/2 (50%) agree   below floor: 1/1 (100%) agree
  escalation rate: 1/4 (25%)
  false-confident: 1
  disagreements: 1   outcome-labelled: 1
  final choice: followed 2   overridden 1
  jev latency_ms p50: 300   p95: 5000
  claude: duplicates 3   answered 2
  claude wall_ms p50: 4000   p95: 5000   api_ms p50: 3900   p95: 4500
  jev = claude: 1/2 (50%)   claude = firstmate: 2/2 (100%)
  three-way all agree: 1/2 (50%)
  tokens: in 100   out 14
  cost: jev total $0.00000420 per decision $0.00000105   claude (API-equivalent) total $0.00700000 per decision $0.00233333
stuck-worker
  calls: 1   answered: 1   step-aside: 0
  agreement with firstmate: 0/1 (0%)
  confident (>= 0.6): 0/1 (0%) agree   below floor: 0/0 (-) agree
  escalation rate: 0/1 (0%)
  false-confident: 1
  disagreements: 1   outcome-labelled: 0
  final choice: followed 0   overridden 1
  jev latency_ms p50: 60   p95: 60
  claude: duplicates 1   answered 1
  claude wall_ms p50: 3500   p95: 3500   api_ms p50: 3400   p95: 3400
  jev = claude: 1/1 (100%)   claude = firstmate: 0/1 (0%)
  three-way all agree: 0/1 (0%)
  tokens: in 2   out 2
  cost: jev total $0.00000008 per decision $0.00000008   claude (API-equivalent) total $0.00300000 per decision $0.00300000
all types
  calls: 6   answered: 5   step-aside: 1
  agreement with firstmate: 2/4 (50%)
  confident (>= 0.6): 1/3 (33.3%) agree   below floor: 1/1 (100%) agree
  escalation rate: 1/5 (20%)
  false-confident: 2
  disagreements: 2   outcome-labelled: 1
  final choice: followed 2   overridden 2
  jev latency_ms p50: 200   p95: 5000
  claude: duplicates 4   answered 3
  claude wall_ms p50: 3500   p95: 5000   api_ms p50: 3400   p95: 4500
  jev = claude: 2/3 (66.7%)   claude = firstmate: 2/3 (66.7%)
  three-way all agree: 1/3 (33.3%)
  tokens: in 102   out 16
  cost: jev total $0.00000428 per decision $0.00000086   claude (API-equivalent) total $0.01000000 per decision $0.00250000
TXT
)
assert_equals "$expected" "$out" "report math over the fixture since the date"
run code out err report --floor 0.85
assert_contains "$out" 'jev report (since all records, floor 0.85)' "no --since reads every record"
assert_contains "$out" $'stuck-worker\n  calls: 2   answered: 2   step-aside: 0\n  agreement with firstmate: 1/2 (50%)\n  confident (>= 0.85): 1/1 (100%) agree   below floor: 0/1 (0%) agree' "--floor moves the confident split"
run code out err report --since yesterday
expect_code 2 "$code" "a malformed --since is a usage error"
pass "report: per-type agreement, three-way agreement, latency and cost for Jev and Claude, outcomes, tokens"

run code out err report --since 2026-09-20 --audit-sample 5
expect_code 0 "$code" "report --audit-sample exits 0"
sample=$(sed -n '/^audit sample:/,$p' <<<"$out")
assert_equals 'audit sample: 2 of 2 jev = claude agreements, random' "$(sed -n 1p <<<"$sample")" "the sample names its size"
assert_equals "  d1 project-match jev=a claude=a firstmate=a audit=$AUDIT_DIR/d1.json"$'\n'"  e2 stuck-worker jev=looping claude=looping firstmate=confused audit=$AUDIT_DIR/e2.json" \
  "$(sed -n 2,3p <<<"$sample" | sort)" "the sample lists every agreement when n covers them"
assert_equals "jev / claude disagreements: 1"$'\n'"  d2 project-match jev=a claude=b firstmate=b audit=$AUDIT_DIR/d2.json" \
  "$(sed -n '4,$p' <<<"$sample")" "every disagreement follows the sample"
run code out err report --since 2026-09-20 --audit-sample 1
sample=$(sed -n '/^audit sample:/,$p' <<<"$out")
assert_equals 'audit sample: 1 of 2 jev = claude agreements, random' "$(sed -n 1p <<<"$sample")" "n caps the sample"
assert_contains "$(sed -n 2p <<<"$sample")" 'claude=' "one sampled agreement"
assert_equals 'jev / claude disagreements: 1' "$(sed -n 3p <<<"$sample")" "all disagreements are still listed under a small sample"
run code out err report --audit-sample many
expect_code 2 "$code" "a non-numeric --audit-sample is a usage error"
rm -f "$USAGE"
run code out err report
assert_contains "$out" 'no recorded calls' "an empty log reports no calls"
pass "report --audit-sample: n random agreements beside every disagreement, each with its snapshot path"
