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
#      "tokens_in","tokens_out","jev_cost_usd","context_sha256",
#      "constraints_sent","status"}
#   jev_cost_usd is tokens_in at FM_JEV_USD_PER_BILLION_INPUT; output is free.
#   constraints_sent is true when the standing rules block below went out with
#   the context, false when the type had none; a record written before the
#   field existed lacks it.
#   status is ok (a validated answer) or error (anything else, answer null).
#   bin/fm-jev.sh appends "mine", "decided", "request", "duplicate", and
#   "outcome" lines that carry the same decision_id (its header owns their
#   fields); readers join on it, so the file stays append-only.
#   The record holds no question text, context, or request payload; its
#   context_sha256 and decision_id point at the audit snapshot.
#   A write failure is discarded: the record never changes what a caller does.
#   fm_jev_append adds "asker" to every line that lacks one: $FM_TASK_ID in a
#   task worker, else "firstmate".
#
# Ask ledger: fm_jev_ask_record appends one line per bin/fm-jev.sh ask that
#   passed its argument checks, whatever Jev then did, to
#   $FM_HOME/state/jev-asks.jsonl:
#     {"v":1,"ts","asker","question_type","target","decision_id","status",
#      "mine","answer","confidence","evidence_sha256"}
#   status is ok, error, or off (no key, the never-send list, or no curl), so
#   an ask made while Jev was down is told apart from an ask never made;
#   decision_id is null when off. target is the key fm_jev_target_key made
#   from ask --target, else null. evidence_sha256 is the sha256 of a
#   claim-check's whitespace-collapsed evidence, else null. It is the record
#   bin/fm-jev-pretool-check.sh and bin/fm-jev-gate-lib.sh read.
#
# Target key: fm_jev_target_key <kind>:<value> prints the lowercased kind, a
#   colon, and the value's first dashed UUID with its dashes removed, else its
#   first free-standing 32-hex id, else the whole lowercased value; so a
#   Notion URL, a dashed id, and a bare id name one page. Exit 1 when kind or
#   value is empty.
#
# Never-send list: fm_jev_never_send_line <text-file> checks text about to be
#   sent against the optional $FM_HOME/config/dispatch-never-send list, whose
#   matching rule docs/configuration.md "Typed dispatch resolution" owns: each
#   non-blank, non-# line is a literal matched case-insensitively with
#   surrounding whitespace trimmed and every whitespace run, on both sides,
#   read as one space. Exit 0 prints the first matching line number, 1 means no
#   match or no list, and 2 prints why the list could not be checked. Callers
#   send nothing on 0 or 2 and never print the matched value.
#
# Standing rules: fm_jev_constraints <question-type> prints the block a caller
#   appends to the context of an ask of that type, read from the optional
#   ${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/jev-constraints, whose format
#   docs/configuration.md "Jev constraints" owns. Exit 1 prints nothing: no
#   file, an unreadable file, or no line for the type. A malformed line is
#   skipped with one stderr warning and never fails the ask.
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
#   "jev: datadog log not sent (...)" stderr line and never a caller failure,
#   and one durable line in $FM_HOME/state/jev-dd-failures.jsonl:
#   {v, ts, decision_id, event, reason}. `fm-jev.sh dd-failures` counts the
#   lines not yet acknowledged, which the session-start digest and the fleet
#   view print.
#   Two event shapes, numeric fields kept numeric:
#     event=decision (fm_jev_decision_event), one per decision and Claude
#       model: decision_id,
#       question_type, summary, context_sha256, jev_answer, jev_confidence,
#       jev_model, jev_status, jev_latency_ms, jev_tokens_in, jev_tokens_out,
#       jev_cost_usd, claude_answer, claude_model, claude_status,
#       claude_latency_ms (API duration), claude_wall_ms, claude_tokens_in,
#       claude_tokens_out, claude_cost_usd (API-equivalent), claude_jev_agree
#       (null when either answer is missing), firstmate_answer.
#     event=label (fm_jev_label_event), after record-mine, record-outcome, or
#       an ask that carried firstmate's blind choice: decision_id,
#       firstmate_answer, followed_or_overridden, final_choice, decider (jev or
#       firstmate), acting_answer, graded (upheld, overruled, or null before
#       any outcome).
#     event=request-cost (fm_jev_request_cost), one per Jev call, tagged
#       cost_source:issuing-request so it never counts as a duplicate query:
#       decision_id, question_type, request_status, request_reason,
#       request_tool_use_id, request_model, request_input_tokens,
#       request_cache_creation_input_tokens, request_cache_read_input_tokens,
#       request_output_tokens, request_context_tokens, jev_cost_usd.
#   No question text, context, options, or probabilities are sent.
#
# Issuing request: fm_jev_request_cost <decision-id> <question-type>
#   <ask-start-ms> <issuer> finds the Claude Code request whose Bash tool call
#   ran the ask, so its real cost can bound what Jev saves. The transcript is
#   $FM_JEV_TRANSCRIPT when set, else the one file
#   ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/*/$CLAUDE_CODE_SESSION_ID.jsonl.
#   A candidate is an assistant Bash tool_use whose command contains <issuer>
#   (the script basename that asked, such as fm-spawn.sh), written at or before
#   the ask started, with no tool_result or one written at or after it; the
#   command text and the still-running call identify it, never a timestamp
#   alone. Exactly one candidate is a match; the line's message.usage and
#   message.model are recorded. The transcript is written asynchronously, so
#   the lookup polls for up to $FM_JEV_TRANSCRIPT_WAIT seconds (default 10);
#   it runs detached and never blocks the ask. It appends one record:
#     {"v":1,"event":"request","ts","decision_id","status","reason",
#      "tool_use_id","request_model","input_tokens",
#      "cache_creation_input_tokens","cache_creation_1h_input_tokens",
#      "cache_read_input_tokens","output_tokens"}
#   status is ok, unavailable (no session id, another harness, or no single
#   transcript file), unmatched (no candidate), or ambiguous (several), and
#   every token field is null unless ok. It makes no model call.

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
# claude_* fields absent from the joined record are null, except claude_model,
# which is <claude-model> unless that is empty (no duplicate query ran).
fm_jev_decision_event() {
  jq -c --arg cstatus "$2" --arg cmodel "$3" '
    (.claude_answer // null) as $ca |
    {ddsource: "firstmate", service: "firstmate-jev", ddtags: ("question_type:" + .question_type),
     message: ("\(.question_type): \(.summary) -> jev \(.answer // "none"), claude \($ca // "none")"),
     event: "decision", decision_id, question_type, summary, context_sha256: (.context_sha256 // null),
     jev_answer: .answer, jev_confidence: .confidence, jev_model: .model, jev_status: .status,
     jev_latency_ms: .latency_ms, jev_tokens_in: .tokens_in, jev_tokens_out: .tokens_out,
     jev_cost_usd: (.jev_cost_usd // null),
     claude_answer: $ca, claude_model: (.claude_model // (if $cmodel == "" then null else $cmodel end)), claude_status: (.claude_status // $cstatus),
     claude_latency_ms: (.claude_latency_ms // null), claude_wall_ms: (.claude_wall_ms // null),
     claude_tokens_in: (.claude_tokens_in // null), claude_tokens_out: (.claude_tokens_out // null),
     claude_cost_usd: (.claude_cost_usd // null),
     claude_jev_agree: (if .answer == null or $ca == null then null else .answer == $ca end),
     firstmate_answer: (.mine // null)}' <<<"$1" 2>/dev/null
}

# fm_jev_label_event <joined-json>: the follow-up after record-mine,
# record-outcome, or a blind-choice ask.
fm_jev_label_event() {
  jq -c '
    {ddsource: "firstmate", service: "firstmate-jev", ddtags: ("question_type:" + .question_type),
     message: ("\(.question_type) label: firstmate \(.mine // "none"), \(.decision // "undecided"), decided by \(.decider // "none")"),
     event: "label", decision_id, firstmate_answer: (.mine // null),
     followed_or_overridden: (.decision // null), final_choice: (.final // null),
     decider: (.decider // null), acting_answer: (.acting // null), graded: (.graded // null)}' <<<"$1" 2>/dev/null
}

# fm_jev_request_event <call-json> <request-json>: the issuing-request cost event.
fm_jev_request_event() {
  jq -c --argjson req "$2" '
    def n($v): if ($v | type) == "number" then $v else 0 end;
    {ddsource: "firstmate", service: "firstmate-jev",
     ddtags: ("question_type:" + .question_type + ",cost_source:issuing-request"),
     message: ("\(.question_type) issuing request: \($req.status) \($req.request_model // "")"),
     event: "request-cost", decision_id, question_type,
     request_status: $req.status, request_reason: ($req.reason // null),
     request_tool_use_id: ($req.tool_use_id // null), request_model: ($req.request_model // null),
     request_input_tokens: $req.input_tokens, request_cache_creation_input_tokens: $req.cache_creation_input_tokens,
     request_cache_read_input_tokens: $req.cache_read_input_tokens, request_output_tokens: $req.output_tokens,
     request_context_tokens: (if $req.status == "ok"
       then n($req.input_tokens) + n($req.cache_creation_input_tokens) + n($req.cache_read_input_tokens) else null end),
     jev_cost_usd: (.jev_cost_usd // null)}' <<<"$1" 2>/dev/null
}

# fm_jev_transcript_path: prints the one transcript file for this Claude Code
# session, or fails with the reason on stdout.
fm_jev_transcript_path() {
  local dir id matches=()
  if [ -n "${FM_JEV_TRANSCRIPT:-}" ]; then
    [ -r "$FM_JEV_TRANSCRIPT" ] || { printf 'FM_JEV_TRANSCRIPT is not readable'; return 1; }
    printf '%s' "$FM_JEV_TRANSCRIPT"
    return 0
  fi
  id=${CLAUDE_CODE_SESSION_ID:-}
  [ -n "$id" ] || { printf 'no Claude Code session id (another harness, or run outside a session)'; return 1; }
  [[ $id =~ ^[A-Za-z0-9-]+$ ]] || { printf 'session id is not a transcript name'; return 1; }
  dir=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects
  shopt -s nullglob
  matches=("$dir"/*/"$id".jsonl)
  shopt -u nullglob
  [ "${#matches[@]}" -eq 1 ] || { printf '%s transcript files for session %s' "${#matches[@]}" "$id"; return 1; }
  printf '%s' "${matches[0]}"
}

# shellcheck disable=SC2016 # $names below are jq variables, not shell ones.
FM_JEV_REQUEST_JQ='
  def ms($t): ($t | tostring) as $s |
    (($s | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) * 1000)
    + ((($s | capture("\\.(?<f>[0-9]+)Z$").f // "0") + "000")[0:3] | tonumber);
  reduce (inputs | try fromjson catch empty | select(type == "object")) as $l ({u: {}, r: {}};
    if $l.type == "assistant" and ($l.message.content | type) == "array" then
      reduce ($l.message.content[] | select(type == "object" and .type == "tool_use" and .name == "Bash"
          and ((.input.command // "") | type) == "string" and (.input.command | contains($issuer)))) as $t (.;
        .u[$t.id] = {ts: $l.timestamp, model: ($l.message.model // null), usage: ($l.message.usage // {})})
    elif $l.type == "user" and ($l.message.content | type) == "array" then
      reduce ($l.message.content[] | select(type == "object" and .type == "tool_result")) as $t (.;
        .r[$t.tool_use_id] = $l.timestamp)
    else . end)
  | .r as $r
  | [.u | to_entries[] | select((try ms(.value.ts) catch null) as $t | $t != null and $t <= $start)
      | select($r[.key] == null or ((try ms($r[.key]) catch 0) >= $start))]
  | if length == 1 then first | {status: "ok", tool_use_id: .key, request_model: .value.model,
        input_tokens: (.value.usage.input_tokens // null),
        cache_creation_input_tokens: (.value.usage.cache_creation_input_tokens // null),
        cache_creation_1h_input_tokens: (.value.usage.cache_creation.ephemeral_1h_input_tokens // null),
        cache_read_input_tokens: (.value.usage.cache_read_input_tokens // null),
        output_tokens: (.value.usage.output_tokens // null)}
    elif length == 0 then {status: "unmatched", reason: "no running Bash tool call that invokes \($issuer) in the transcript"}
    else {status: "ambiguous", reason: "\(length) running Bash tool calls invoke \($issuer)"} end
'

# fm_jev_request_cost <decision-id> <question-type> <ask-start-ms> <issuer>:
# records the issuing request (see the header) and sends its cost event.
fm_jev_request_cost() {
  local id=$1 qtype=$2 start=$3 issuer=$4 path reason found='' deadline line call
  if ! path=$(fm_jev_transcript_path); then
    reason=$path
    found=$(jq -cn --arg r "$reason" '{status: "unavailable", reason: $r}')
  else
    deadline=$(( $(fm_timing_now_ms) + ${FM_JEV_TRANSCRIPT_WAIT:-10} * 1000 ))
    while :; do
      found=$(jq -Rcn --arg issuer "$issuer" --argjson start "$start" "$FM_JEV_REQUEST_JQ" "$path" 2>/dev/null) \
        || found=$(jq -cn '{status: "unmatched", reason: "transcript unreadable"}')
      [ "$(jq -r .status <<<"$found")" = unmatched ] || break
      [ "$(fm_timing_now_ms)" -lt "$deadline" ] || break
      sleep 0.5
    done
  fi
  line=$(jq -c --arg id "$id" --arg ts "$(fm_jev_now_iso)" '
    {v: 1, event: "request", ts: $ts, decision_id: $id, status, reason: (.reason // null),
     tool_use_id: (.tool_use_id // null), request_model: (.request_model // null),
     input_tokens: (.input_tokens // null), cache_creation_input_tokens: (.cache_creation_input_tokens // null),
     cache_creation_1h_input_tokens: (.cache_creation_1h_input_tokens // null),
     cache_read_input_tokens: (.cache_read_input_tokens // null), output_tokens: (.output_tokens // null)}' <<<"$found" 2>/dev/null) || return 0
  fm_jev_append "$line"
  call=$(fm_jev_call_record "$id")
  [ -n "$call" ] || call=$(jq -cn --arg id "$id" --arg q "$qtype" '{decision_id: $id, question_type: $q}')
  fm_jev_dd_send "$(fm_jev_request_event "$call" "$line")" "$id"
}

fm_jev_dd_failures_path() {
  printf '%s/state/jev-dd-failures.jsonl' "$FM_HOME"
}

# fm_jev_dd_failure <reason> <event-json> [<decision-id>]: the stderr line and
# the durable failure record for one unsent event.
fm_jev_dd_failure() {
  local id=${3:-} kind='' path
  [ -n "$id" ] || id=$(jq -r '.decision_id // empty' <<<"$2" 2>/dev/null)
  kind=$(jq -r '.event // empty' <<<"$2" 2>/dev/null)
  echo "jev: datadog log not sent ($1)" >&2
  path=$(fm_jev_dd_failures_path)
  mkdir -p "${path%/*}" 2>/dev/null
  jq -cn --arg ts "$(fm_jev_now_iso)" --arg id "$id" --arg kind "$kind" --arg reason "$1" \
    '{v: 1, ts: $ts, decision_id: (if $id == "" then null else $id end),
      event: (if $kind == "" then null else $kind end), reason: $reason}' >> "$path" 2>/dev/null || true
}

# fm_jev_dd_send <event-json> [<decision-id>]: one Datadog log event with the
# key on fd 3. The decision id names a failure whose event did not render.
fm_jev_dd_send() {
  local event=$1 id=${2:-} key site http
  key=${DD_API_KEY_PRIVATE:-$(fmx_env_get DD_API_KEY "$FM_HOME/.env")}
  [ -n "$key" ] || return 0
  site=${DD_SITE_PRIVATE:-$(fmx_env_get DD_SITE "$FM_HOME/.env")}
  site=${site:-datadoghq.com}
  [ -n "$event" ] || { fm_jev_dd_failure "event rendering failed" '' "$id"; return 0; }
  command -v curl >/dev/null 2>&1 || { fm_jev_dd_failure "curl not installed" "$event" "$id"; return 0; }
  if [[ ! $site =~ ^[a-z0-9]+([.-][a-z0-9]+)*$ ]]; then
    fm_jev_dd_failure "DD_SITE is not a Datadog site name" "$event" "$id"
    return 0
  fi
  http=$(jq -c '[.]' <<<"$event" | curl -sS --max-time "$FM_JEV_DD_TIMEOUT" -o /dev/null -w '%{http_code}' \
    -X POST "https://http-intake.logs.$site/api/v2/logs" -H 'Content-Type: application/json' \
    -H @/dev/fd/3 3< <(printf 'DD-API-KEY: %s\n' "$key") \
    --data-binary @- 2>/dev/null) || http=000
  case "$http" in
    2??) ;;
    *) fm_jev_dd_failure "http $http" "$event" "$id" ;;
  esac
  return 0
}

fm_jev_never_send_line() {  # <text-file>
  local path="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/dispatch-never-send" norm list value n=0 rc
  [ -e "$path" ] || [ -L "$path" ] || return 1
  { [ -f "$path" ] && [ -r "$path" ]; } || { printf '%s is not a readable regular file' "$path"; return 2; }
  norm=$(mktemp) || { printf 'mktemp failed'; return 2; }
  # grep's own stderr is discarded because it can echo the pattern.
  if ! jq -Rr 'gsub("\\s+"; " ")' "$1" > "$norm" 2>/dev/null \
    || ! list=$(jq -Rr 'gsub("\\s+"; " ")' "$path" 2>/dev/null); then
    rm -f "$norm"
    printf 'could not read the text or %s' "$path"
    return 2
  fi
  while IFS= read -r value; do
    n=$((n + 1))
    value=${value# }
    value=${value% }
    case "$value" in
      ''|'#'*) continue ;;
    esac
    grep -qiF -e "$value" "$norm" 2>/dev/null; rc=$?
    case "$rc" in
      0) rm -f "$norm"; printf '%s' "$n"; return 0 ;;
      1) ;;
      *) rm -f "$norm"; printf 'could not check the text against %s line %s' "$path" "$n"; return 2 ;;
    esac
  done <<<"$list"
  rm -f "$norm"
  return 1
}

fm_jev_constraints() {  # <question-type>
  local path="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/jev-constraints" line type text rules='' n=0
  [ -f "$path" ] && [ -r "$path" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    [[ ! $line =~ ^[[:space:]]*(#|$) ]] || continue
    type='' text=''
    read -r type text <<<"$line"
    if [[ ! $type =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || [ -z "$text" ]; then
      echo "jev: constraints line $n refused (expected <type> <rule text>)" >&2
      continue
    fi
    [ "$type" != "$1" ] || rules="$rules- $text"$'\n'
  done < "$path"
  [ -n "$rules" ] || return 1
  printf 'Standing operator rules for this question:\n%s' "$rules"
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
  local log line
  log=$(fm_jev_log_path)
  line=$(jq -c --arg a "${FM_TASK_ID:-firstmate}" '. + {asker: (.asker // $a)}' <<<"$1" 2>/dev/null) || line=$1
  { mkdir -p "${log%/*}" && printf '%s\n' "$line" >> "$log"; } 2>/dev/null || true
}

fm_jev_ask_ledger_path() {
  printf '%s/state/jev-asks.jsonl' "$FM_HOME"
}

fm_jev_target_key() {  # <kind>:<value>
  local kind=${1%%:*} value=${1#*:}
  [ "$kind" != "$1" ] && [ -n "$kind" ] && [ -n "$value" ] || return 1
  kind=$(printf '%s' "$kind" | tr '[:upper:]' '[:lower:]')
  value=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')
  if [[ $value =~ [0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12} ]]; then
    value=${BASH_REMATCH[0]//-/}
  elif [[ $value =~ (^|[^0-9a-f])([0-9a-f]{32})([^0-9a-f]|$) ]]; then
    value=${BASH_REMATCH[2]}
  fi
  printf '%s:%s' "$kind" "$value"
}

# fm_jev_ask_record <type> <target> <decision-id> <status> <mine>
#   <response-file> <question-key> <evidence-sha256>: one ask ledger line;
#   empty strings become null.
fm_jev_ask_record() {
  local body='' line path
  [ "$4" != ok ] || body=$(cat "$6" 2>/dev/null) || body=''
  line=$(jq -cn --arg type "$1" --arg target "$2" --arg id "$3" --arg status "$4" --arg mine "$5" \
    --arg body "$body" --arg q "$7" --arg ev "$8" --arg ts "$(fm_jev_now_iso)" --arg asker "${FM_TASK_ID:-firstmate}" '
    def nul($s): if $s == "" then null else $s end;
    (try ($body | fromjson) catch null) as $r | ($r.answers[$q] // null) as $a |
    {v: 1, ts: $ts, asker: $asker, question_type: $type, target: nul($target), decision_id: nul($id),
     status: $status, mine: nul($mine), answer: ($a.choice // null), confidence: ($a.confidence // null),
     evidence_sha256: nul($ev)}' 2>/dev/null) || return 0
  path=$(fm_jev_ask_ledger_path)
  { mkdir -p "${path%/*}" && printf '%s\n' "$line" >> "$path"; } 2>/dev/null || true
}

# fm_jev_record_call <decision-id> <question-type> <summary> <options-json>
#   <question-key> <status> <latency-ms> <response-file> [<context-sha256>]
#   [<constraints-sent: true|false>]
# Appends the call record and prints nothing.
fm_jev_record_call() {
  local id=$1 qtype=$2 summary=$3 options=$4 qkey=$5 status=$6 lat=$7 resp=$8 sha=${9:-} sent=${10:-} body='' line
  if [ "$status" = ok ]; then
    body=$(cat "$resp" 2>/dev/null) || body=''
  fi
  line=$(jq -cn --arg id "$id" --arg qtype "$qtype" --arg summary "$summary" --argjson options "$options" \
    --arg qkey "$qkey" --arg status "$status" --arg lat "$lat" --arg ts "$(fm_jev_now_iso)" --arg sha "$sha" \
    --arg sent "$sent" --arg body "$body" --argjson max "$FM_JEV_SUMMARY_MAX" --argjson price "$FM_JEV_USD_PER_BILLION_INPUT" '
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
     constraints_sent: (if $sent == "" then null else $sent == "true" end),
     status: $status}' 2>/dev/null) || return 0
  fm_jev_append "$line"
}
