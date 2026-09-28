# shellcheck shell=bash
# fm-jev-lib.sh - the single owner of the typesafe.ai System One (Jev) transport
# and of the local Jev usage record, shared by bin/fm-jev.sh and
# bin/fm-dispatch-resolve.sh.
#
# Sourced, never executed. Callers source bin/fm-timing-lib.sh first.
#
# Key: each caller moves TYPESAFE_API_KEY out of its exported environment into
#   the unexported shell variable TYPESAFE_API_KEY_PRIVATE before it sources
#   anything, and fills an empty value from $FM_HOME/.env through fmx_env_get
#   (bin/fm-env-lib.sh), so the environment wins. The key reaches curl only as
#   a header read from file descriptor 3, never on argv, and no record written
#   here ever contains it.
#
# Transport: fm_jev_post <request-json> <response-file> sends one POST to
#   $FM_JEV_BASE/v1/systemone with a $FM_JEV_TIMEOUT second limit and sets
#   FM_JEV_HTTP (000 on a transport failure) and FM_JEV_LAT_MS.
#
# Usage record: fm_jev_record_call appends one JSONL line per Jev call to
#   $FM_HOME/state/jev-usage.jsonl:
#     {"v":1,"event":"call","ts","decision_id","question_type","summary",
#      "options","answer","confidence","probabilities","model","latency_ms",
#      "tokens_in","tokens_out","status"}
#   status is ok (a validated answer) or error (anything else, answer null).
#   bin/fm-jev.sh appends later "mine" and "outcome" lines that carry the same
#   decision_id; readers join on it, so the file stays append-only.
#   No question text, context, or request payload is recorded.
#   A write failure is discarded: the record never changes what a caller does.

# shellcheck disable=SC2034 # Read by the sourcing caller.
FM_JEV_MODEL=jev-latest
FM_JEV_BASE=https://api.typesafe.ai
FM_JEV_TIMEOUT=5
FM_JEV_SUMMARY_MAX=200

fm_jev_log_path() {
  printf '%s/state/jev-usage.jsonl' "$FM_HOME"
}

fm_jev_new_id() {
  printf 'jev-%s-%s-%s' "$(fm_timing_now_ms)" "$$" "$RANDOM$RANDOM"
}

fm_jev_now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '1970-01-01T00:00:00Z'
}

# fm_jev_post <request-json> <response-file>
# shellcheck disable=SC2034 # FM_JEV_HTTP and FM_JEV_LAT_MS are read by the caller.
fm_jev_post() {
  local request=$1 resp=$2 t0 t1
  t0=$(fm_timing_now_ms)
  FM_JEV_HTTP=$(printf '%s' "$request" | curl -sS --max-time "$FM_JEV_TIMEOUT" -o "$resp" -w '%{http_code}' \
    -X POST "$FM_JEV_BASE/v1/systemone" -H 'Content-Type: application/json' \
    -H @/dev/fd/3 3< <(printf 'Authorization: Bearer %s\n' "$TYPESAFE_API_KEY_PRIVATE") \
    --data-binary @- 2>/dev/null) || FM_JEV_HTTP=000
  t1=$(fm_timing_now_ms)
  FM_JEV_LAT_MS=$(( t1 - t0 ))
}

fm_jev_append() {  # <json-line>
  local log
  log=$(fm_jev_log_path)
  { mkdir -p "${log%/*}" && printf '%s\n' "$1" >> "$log"; } 2>/dev/null || true
}

# fm_jev_record_call <decision-id> <question-type> <summary> <options-json>
#   <question-key> <status> <latency-ms> <response-file>
# Appends the call record and prints nothing.
fm_jev_record_call() {
  local id=$1 qtype=$2 summary=$3 options=$4 qkey=$5 status=$6 lat=$7 resp=$8 body='' line
  if [ "$status" = ok ]; then
    body=$(cat "$resp" 2>/dev/null) || body=''
  fi
  line=$(jq -cn --arg id "$id" --arg qtype "$qtype" --arg summary "$summary" --argjson options "$options" \
    --arg qkey "$qkey" --arg status "$status" --arg lat "$lat" --arg ts "$(fm_jev_now_iso)" \
    --arg body "$body" --argjson max "$FM_JEV_SUMMARY_MAX" '
    (try ($body | fromjson) catch null) as $r |
    ($r.answers[$qkey] // null) as $a |
    {v: 1, event: "call", ts: $ts, decision_id: $id, question_type: $qtype,
     summary: ($summary | gsub("[\t\r\n]+"; " ") | .[0:$max]), options: $options,
     answer: ($a.choice // null), confidence: ($a.confidence // null),
     probabilities: ($a.probabilities // null), model: ($r.model // null),
     latency_ms: (try ($lat | tonumber) catch null),
     tokens_in: ($r.usage.input_tokens // null), tokens_out: ($r.usage.output_tokens // null),
     status: $status}' 2>/dev/null) || return 0
  fm_jev_append "$line"
}
