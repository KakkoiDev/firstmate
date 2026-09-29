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
#      "tokens_in","tokens_out","jev_cost_usd","context_sha256","status"}
#   jev_cost_usd is tokens_in at FM_JEV_USD_PER_BILLION_INPUT; output is free.
#   status is ok (a validated answer) or error (anything else, answer null).
#   bin/fm-jev.sh appends later "mine" and "outcome" lines that carry the same
#   decision_id; readers join on it, so the file stays append-only.
#   The record holds no question text, context, or request payload; its
#   context_sha256 and decision_id point at the audit snapshot.
#   A write failure is discarded: the record never changes what a caller does.
#
# Audit snapshot: fm_jev_write_audit writes $FM_HOME/state/jev-audit/<id>.json,
#   local only, so a later audit can re-judge the decision from what the models
#   saw: {v, decision_id, ts, question_type, question, options, context,
#   context_sha256, jev_request, jev_response}. context holds the exact context
#   text sent and context_sha256 is the sha256 of those bytes; jev_request is
#   the exact request body and jev_response the raw response text. bin/fm-jev.sh
#   adds claude_system_prompt, claude_prompt, and claude_response once its
#   duplicate query returns. No key or auth header is ever written.
#
# Datadog: callers run fm_jev_capture_dd after sourcing this file, moving
#   DD_API_KEY and DD_SITE (default datadoghq.com) out of the exported
#   environment; an empty value falls back to $FM_HOME/.env. Absent DD_API_KEY,
#   nothing is sent. fm_jev_dd_send posts one event to
#   https://http-intake.logs.$DD_SITE/api/v2/logs with the key on the fd 3
#   DD-API-KEY header and service firstmate-jev; any failure is one
#   "jev: datadog log not sent (...)" stderr line and never a caller failure.
#   Two event shapes, numeric fields kept numeric:
#     event=decision (fm_jev_decision_event), one per decision and Claude
#       model: decision_id,
#       question_type, summary, context_sha256, jev_answer, jev_confidence,
#       jev_model, jev_status, jev_latency_ms, jev_tokens_in, jev_tokens_out,
#       jev_cost_usd, claude_answer, claude_model, claude_status,
#       claude_latency_ms (API duration), claude_wall_ms, claude_tokens_in,
#       claude_tokens_out, claude_cost_usd (API-equivalent), claude_jev_agree
#       (null when either answer is missing), firstmate_answer.
#     event=label (fm_jev_label_event), after record-mine or record-outcome:
#       decision_id, firstmate_answer, followed_or_overridden, final_choice.
#   No question text, context, options, or probabilities are sent.

# shellcheck disable=SC2034 # Read by the sourcing caller.
FM_JEV_MODEL=jev-latest
FM_JEV_BASE=https://api.typesafe.ai
FM_JEV_TIMEOUT=5
FM_JEV_SUMMARY_MAX=200
# Jev billing, captain 2026-09-28: $42 per billion input tokens, output tokens free.
FM_JEV_USD_PER_BILLION_INPUT=42
FM_JEV_DD_TIMEOUT=5

# Moves DD_API_KEY and DD_SITE out of the exported environment; see the header.
fm_jev_capture_dd() {
  DD_API_KEY_PRIVATE=${DD_API_KEY:-}
  DD_SITE_PRIVATE=${DD_SITE:-}
  export -n DD_API_KEY_PRIVATE DD_SITE_PRIVATE 2>/dev/null || true
  unset DD_API_KEY DD_SITE
}

# fm_jev_decision_event <joined-json> <claude-status when no duplicate ran>
# <claude-model>: the combined event for one decision and one Claude model;
# claude_* fields absent from the joined record are null, except claude_model.
fm_jev_decision_event() {
  jq -c --arg cstatus "$2" --arg cmodel "$3" '
    (.claude_answer // null) as $ca |
    {ddsource: "firstmate", service: "firstmate-jev", ddtags: ("question_type:" + .question_type),
     message: ("\(.question_type): \(.summary) -> jev \(.answer // "none"), claude \($ca // "none")"),
     event: "decision", decision_id, question_type, summary, context_sha256: (.context_sha256 // null),
     jev_answer: .answer, jev_confidence: .confidence, jev_model: .model, jev_status: .status,
     jev_latency_ms: .latency_ms, jev_tokens_in: .tokens_in, jev_tokens_out: .tokens_out,
     jev_cost_usd: (.jev_cost_usd // null),
     claude_answer: $ca, claude_model: (.claude_model // $cmodel), claude_status: (.claude_status // $cstatus),
     claude_latency_ms: (.claude_latency_ms // null), claude_wall_ms: (.claude_wall_ms // null),
     claude_tokens_in: (.claude_tokens_in // null), claude_tokens_out: (.claude_tokens_out // null),
     claude_cost_usd: (.claude_cost_usd // null),
     claude_jev_agree: (if .answer == null or $ca == null then null else .answer == $ca end),
     firstmate_answer: (.mine // null)}' <<<"$1" 2>/dev/null
}

# fm_jev_label_event <joined-json>: the follow-up after record-mine or record-outcome.
fm_jev_label_event() {
  jq -c '
    {ddsource: "firstmate", service: "firstmate-jev", ddtags: ("question_type:" + .question_type),
     message: ("\(.question_type) label: firstmate \(.mine // "none"), \(.decision // "undecided")"),
     event: "label", decision_id, firstmate_answer: (.mine // null),
     followed_or_overridden: (.decision // null), final_choice: (.final // null)}' <<<"$1" 2>/dev/null
}

# fm_jev_dd_send <event-json>: one Datadog log event with the key on fd 3.
fm_jev_dd_send() {
  local event=$1 key site http
  key=${DD_API_KEY_PRIVATE:-$(fmx_env_get DD_API_KEY "$FM_HOME/.env")}
  [ -n "$key" ] || return 0
  site=${DD_SITE_PRIVATE:-$(fmx_env_get DD_SITE "$FM_HOME/.env")}
  site=${site:-datadoghq.com}
  [ -n "$event" ] || { echo "jev: datadog log not sent (event rendering failed)" >&2; return 0; }
  command -v curl >/dev/null 2>&1 || { echo "jev: datadog log not sent (curl not installed)" >&2; return 0; }
  if [[ ! $site =~ ^[a-z0-9]+([.-][a-z0-9]+)*$ ]]; then
    echo "jev: datadog log not sent (DD_SITE is not a Datadog site name)" >&2
    return 0
  fi
  http=$(jq -c '[.]' <<<"$event" | curl -sS --max-time "$FM_JEV_DD_TIMEOUT" -o /dev/null -w '%{http_code}' \
    -X POST "https://http-intake.logs.$site/api/v2/logs" -H 'Content-Type: application/json' \
    -H @/dev/fd/3 3< <(printf 'DD-API-KEY: %s\n' "$key") \
    --data-binary @- 2>/dev/null) || http=000
  case "$http" in
    2??) ;;
    *) echo "jev: datadog log not sent (http $http)" >&2 ;;
  esac
  return 0
}

fm_jev_audit_path() {  # <decision-id>
  printf '%s/state/jev-audit/%s.json' "$FM_HOME" "$1"
}

fm_jev_sha256() {  # <file>
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  fi
}

# fm_jev_write_audit <decision-id> <question-type> <question> <options-json>
#   <context-file> <context-sha256> <request-json> <response-file or empty>
fm_jev_write_audit() {
  local path tmp
  path=$(fm_jev_audit_path "$1")
  { mkdir -p "${path%/*}" && tmp=$(mktemp "${path%/*}/.audit.XXXXXX"); } 2>/dev/null || return 0
  if jq -n --arg id "$1" --arg qtype "$2" --arg question "$3" --argjson options "$4" \
      --rawfile context "$5" --arg sha "$6" --arg request "$7" --rawfile response "${8:-/dev/null}" \
      --arg ts "$(fm_jev_now_iso)" '
      {v: 1, decision_id: $id, ts: $ts, question_type: $qtype, question: $question, options: $options,
       context: $context, context_sha256: (if $sha == "" then null else $sha end),
       jev_request: (try ($request | fromjson) catch $request), jev_response: $response}' > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$path" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
}

fm_jev_log_path() {
  printf '%s/state/jev-usage.jsonl' "$FM_HOME"
}

fm_jev_side_log_path() {
  printf '%s/state/jev-duplicate.log' "$FM_HOME"
}

# fm_jev_detach <command> [args...]: runs the command in the background with
# stdin, stdout, and stderr away from the caller (stderr to the side log), so a
# caller capturing this process's output never waits on it.
fm_jev_detach() {
  local log
  log=$(fm_jev_side_log_path)
  mkdir -p "${log%/*}" 2>/dev/null
  [ -w "${log%/*}" ] || log=/dev/null
  ( "$@" ) </dev/null >/dev/null 2>>"$log" &
}

# fm_jev_call_record <decision-id>: prints that decision's call record, if any.
fm_jev_call_record() {
  local log
  log=$(fm_jev_log_path)
  [ -f "$log" ] || return 0
  jq -cR --arg id "$1" 'try fromjson catch empty |
    select(type == "object" and .event == "call" and .decision_id == $id)' "$log" 2>/dev/null | tail -n 1
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
#   <question-key> <status> <latency-ms> <response-file> [<context-sha256>]
# Appends the call record and prints nothing.
fm_jev_record_call() {
  local id=$1 qtype=$2 summary=$3 options=$4 qkey=$5 status=$6 lat=$7 resp=$8 sha=${9:-} body='' line
  if [ "$status" = ok ]; then
    body=$(cat "$resp" 2>/dev/null) || body=''
  fi
  line=$(jq -cn --arg id "$id" --arg qtype "$qtype" --arg summary "$summary" --argjson options "$options" \
    --arg qkey "$qkey" --arg status "$status" --arg lat "$lat" --arg ts "$(fm_jev_now_iso)" --arg sha "$sha" \
    --arg body "$body" --argjson max "$FM_JEV_SUMMARY_MAX" --argjson price "$FM_JEV_USD_PER_BILLION_INPUT" '
    (try ($body | fromjson) catch null) as $r |
    ($r.answers[$qkey] // null) as $a |
    {v: 1, event: "call", ts: $ts, decision_id: $id, question_type: $qtype,
     summary: ($summary | gsub("[\t\r\n]+"; " ") | .[0:$max]), options: $options,
     answer: ($a.choice // null), confidence: ($a.confidence // null),
     probabilities: ($a.probabilities // null), model: ($r.model // null),
     latency_ms: (try ($lat | tonumber) catch null),
     tokens_in: ($r.usage.input_tokens // null), tokens_out: ($r.usage.output_tokens // null),
     jev_cost_usd: (if ($r.usage.input_tokens | type) == "number" then $r.usage.input_tokens * $price / 1e9 else null end),
     context_sha256: (if $sha == "" then null else $sha end),
     status: $status}' 2>/dev/null) || return 0
  fm_jev_append "$line"
}
