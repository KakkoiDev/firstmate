#!/usr/bin/env bash
# Behavior tests for bin/fm-jev.sh and the usage record in bin/fm-jev-lib.sh.
#
# Drives the public argv and environment interface with a fake curl on PATH
# that records argv, the request body it read from stdin, the header it read
# from file descriptor 3, and whether a key reached its environment, then
# answers with a canned typesafe.ai response. No case touches the network, and
# the absent-key case proves the tool makes no call and writes no record.
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
BASE_PATH=$PATH
KEY='test-key-4c7e21aa-never-on-argv'
mkdir -p "$HOME_DIR" "$LOG" "$NO_CURL_BIN"
for command_name in awk bash cat date dirname jq mkdir mktemp rm; do
  ln -s "$(command -v "$command_name")" "$NO_CURL_BIN/$command_name"
done
unset TYPESAFE_API_KEY

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

export FAKE_CURL_LOG="$LOG" FAKE_CURL_RESPONSE="$RESPONSE"

reset() {
  rm -rf "$LOG" "$HOME_DIR/state"
  mkdir -p "$LOG"
}

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
assert_equals 1 "$(wc -l < "$USAGE" | tr -d ' ')" "one record per call"
record=$(cat "$USAGE")
assert_equals '["answer","confidence","decision_id","event","latency_ms","model","options","probabilities","question_type","status","summary","tokens_in","tokens_out","ts","v"]' \
  "$(jq -c 'keys' <<<"$record")" "record carries exactly the documented fields"
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

reset
TYPESAFE_API_KEY=$KEY run code out err ask --type deploy-check --summary 'Is the deploy safe' --question 'Is it safe?' --yes-no
assert_equals '{"yes":"Yes.","no":"No."}' "$(jq -c .questions.q.criteria "$LOG/body")" "--yes-no is the yes/no Choice"
assert_equals '' "$(jq -r .state.context "$LOG/body")" "no context file sends an empty context"
assert_equals '' "$out" "a response over other options is not an answer"
assert_contains "$err" 'jev: error (response is not a Choice answer over the options)' "the mismatch is named"
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
  assert_equals 'error||' "$(jq -r '[.status, (.answer // ""), (.model // "")] | join("|")' "$USAGE")" "$env_assign records an error with no answer"
done
reset
printf '%s\n' '{"model":"jev-1.13.0","answers":{"q":{"choice":"looping","confidence":1.4}}}' > "$RESPONSE"
TYPESAFE_API_KEY=$KEY run code out err "${ASK[@]}"
expect_code 0 "$code" "malformed answer exits 0"
assert_equals '' "$out" "malformed answer prints nothing on stdout"
assert_equals 'error' "$(jq -r .status "$USAGE")" "malformed answer records an error"
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
  "$(jq -r '[.answer, .mine, .outcome, .final, .decision] | join("|")' <<<"$out")" "show joins call, mine, and outcome"
run code out err show "$id2"
assert_equals 'looping|confused||confused|overridden' \
  "$(jq -r '[.answer, .mine, (.outcome // ""), .final, .decision] | join("|")' <<<"$out")" "without an outcome the final choice is firstmate's"
assert_equals 'call call mine mine outcome' "$(jq -r .event "$USAGE" | tr '\n' ' ' | sed 's/ $//')" "the log stays append-only"
assert_absent "$LOG/argv" "record subcommands never call curl"
pass "record-mine and record-outcome append beside the call and join on its decision id"

# --- report math on a fixture log -----------------------------------------------
reset
mkdir -p "$HOME_DIR/state"
fixture_call() {  # <id> <type> <ts> <status> <answer> <confidence> <latency> <tokens_in> <tokens_out>
  jq -cn --arg id "$1" --arg t "$2" --arg ts "$3" --arg s "$4" --arg a "$5" --argjson c "$6" --argjson l "$7" --argjson ti "$8" --argjson to "$9" '
    {v: 1, event: "call", ts: $ts, decision_id: $id, question_type: $t, summary: "s",
     options: ["a", "b", "working", "looping", "confused"],
     answer: (if $a == "" then null else $a end), confidence: $c, probabilities: null, model: "jev-1.13.0",
     latency_ms: $l, tokens_in: $ti, tokens_out: $to, status: $s}'
}
fixture_mine() { jq -cn --arg id "$1" --arg m "$2" '{v: 1, event: "mine", ts: "2026-09-26T00:00:00Z", decision_id: $id, mine: $m}'; }
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
  latency_ms p50: 300   p95: 5000
  tokens: in 100   out 14
stuck-worker
  calls: 1   answered: 1   step-aside: 0
  agreement with firstmate: 0/1 (0%)
  confident (>= 0.6): 0/1 (0%) agree   below floor: 0/0 (-) agree
  escalation rate: 0/1 (0%)
  false-confident: 1
  disagreements: 1   outcome-labelled: 0
  final choice: followed 0   overridden 1
  latency_ms p50: 60   p95: 60
  tokens: in 2   out 2
all types
  calls: 6   answered: 5   step-aside: 1
  agreement with firstmate: 2/4 (50%)
  confident (>= 0.6): 1/3 (33.3%) agree   below floor: 1/1 (100%) agree
  escalation rate: 1/5 (20%)
  false-confident: 2
  disagreements: 2   outcome-labelled: 1
  final choice: followed 2   overridden 2
  latency_ms p50: 200   p95: 5000
  tokens: in 102   out 16
TXT
)
assert_equals "$expected" "$out" "report math over the fixture since the date"
run code out err report --floor 0.85
assert_contains "$out" 'jev report (since all records, floor 0.85)' "no --since reads every record"
assert_contains "$out" $'stuck-worker\n  calls: 2   answered: 2   step-aside: 0\n  agreement with firstmate: 1/2 (50%)\n  confident (>= 0.85): 1/1 (100%) agree   below floor: 0/1 (0%) agree' "--floor moves the confident split"
run code out err report --since yesterday
expect_code 2 "$code" "a malformed --since is a usage error"
rm -f "$USAGE"
run code out err report
assert_contains "$out" 'no recorded calls' "an empty log reports no calls"
pass "report: per-type agreement, confident split, escalation, false-confident, outcomes, latency, tokens"
