#!/usr/bin/env bash
# fm-jev.sh - ask typesafe.ai's System One model (Jev) one typed question, record
# firstmate's own answer beside it, and report how far Jev can be trusted.
#
# Usage:
#   fm-jev.sh ask --type <slug> --summary <line> --question <text>
#                 (--option <id>[=<meaning>] ... | --yes-no) [--context <file>]
#   fm-jev.sh record-mine <decision-id> <answer>
#   fm-jev.sh record-outcome <decision-id> <text> [--final <choice>]
#   fm-jev.sh show <decision-id>
#   fm-jev.sh report [--since <YYYY-MM-DD[THH:MM:SSZ]>] [--floor <0..1>]
#                    [--audit-sample <n>]
#
# ask: one POST through the shared transport in bin/fm-jev-lib.sh. The request
#   is {model, state: {context}, questions: {q: {type: choice, instructions,
#   criteria}}}: the question text is the instructions, each --option is one
#   criterion (its meaning defaults to the id; an id is letters, digits, dot,
#   dash, or underscore, so a registered project name fits), --yes-no is the choice
#   {yes, no}, and the --context file (English) is the state. The summary is
#   one English line saying what is asked; it is recorded, never sent.
#   Output (stdout, TOON-style block):
#     jev:
#       decision_id: <id>
#       answer: <option id>   confidence: <0..1>
#       probabilities: <id>=<p> ...
#       model: <version>   latency_ms: <n>   tokens: <in>/<out>
#   Off (TYPESAFE_API_KEY absent from the environment and $FM_HOME/.env): one
#   "jev: off" stderr line, nothing on stdout, no call, no record.
#   Any call failure (curl missing, transport, HTTP, response shape): one
#   "jev: error (...)" stderr line, nothing on stdout, a status=error record.
#   Every ask outcome exits 0, so a caller is never blocked; decide as if the
#   tool were absent whenever stdout is empty.
#   Duplicate Claude queries: after every Jev call (answered or failed), ask
#   detaches one process that asks the same question, options, and context of
#   each model in $FM_JEV_CLAUDE_MODELS (space-separated, default
#   "claude-opus-5-5 claude-sonnet-5 claude-haiku-4-5-20251001"), one
#   `claude -p` after another, so the time and cost of answering it with each
#   Claude model are measured beside Jev without slowing the decision path.
#   Each query runs from an
#   empty temporary directory with --safe-mode, no setting sources, no MCP
#   servers, no tools, no session persistence, no dynamic system prompt
#   sections, and a strict one-option system prompt, so the measured input is
#   the question rather than CLAUDE.md, hooks, or tool definitions. It adds
#   firstmate.role=jev-duplicate to OTEL_RESOURCE_ATTRIBUTES, so Claude Code
#   telemetry can exclude these queries from the cost of real work. Each
#   success appends one "duplicate" record: claude_model, claude_answer (null and
#   status off-option when the reply is not exactly one option id),
#   claude_wall_ms (measured around the process), claude_latency_ms
#   (duration_api_ms), claude_cost_usd (total_cost_usd, the API-equivalent
#   price even under a subscription), claude_tokens_in (input plus cache
#   creation plus cache read), claude_tokens_out, status. Any failure writes
#   no record and one line to $FM_HOME/state/jev-duplicate.log, because a
#   detached process writing to the caller's stderr would hold the caller's
#   output pipe open.
#   Audit: before detaching, ask writes the local audit snapshot owned by
#   bin/fm-jev-lib.sh (question, option meanings, context bytes and sha256, the
#   Jev request and raw response) plus claude_system_prompt and claude_prompt;
#   the duplicate queries add claude_response, the raw output of the last one.
#   Datadog: as each model's query finishes or fails, the same detached
#   process sends one decision event for that model (bin/fm-jev-lib.sh), so a
#   decision yields one event per model; a send failure line goes to the same
#   side log.
#   The joined record behind show, report, and the label events carries the
#   first model's duplicate only.
#
# record-mine: appends firstmate's own answer for a decision. <decision-id> is
#   an id printed by ask, or latest:<question-type> for the newest call of that
#   type (how firstmate labels a bin/fm-dispatch-resolve.sh call, whose output
#   carries no id). The answer must be one of the call's options.
# record-outcome: appends a later captain correction or override as free text;
#   --final names the choice actually taken when it differs from firstmate's.
#   The final choice is the outcome's --final, else firstmate's answer; the
#   decision is "followed" when the final choice equals Jev's answer and
#   "overridden" otherwise.
#   Both send one Datadog label event after appending (bin/fm-jev-lib.sh).
# show: prints {record, audit} as JSON: the joined record for one decision and
#   its audit snapshot (null when none was written).
# report: per question type, plain text: calls, answered, step-aside count,
#   agreement with firstmate, agreement on confident answers (confidence >=
#   floor, default 0.6, the resolver's global floor) and below the floor,
#   escalation rate (answered below the floor), false-confident count
#   (confident and disagreeing), disagreements and how many carry an outcome,
#   followed/overridden on the final choice, three-way agreement over the
#   decisions where Jev, the duplicate Claude query, and firstmate all
#   answered, latency p50/p95 (nearest rank) for Jev and for Claude (wall and
#   API), Jev token totals, and total and per-decision cost for Jev and for
#   Claude (API-equivalent). --since keeps calls whose timestamp is at or
#   after it. --audit-sample <n> then lists n random decisions where Jev and
#   Claude agreed and every decision where both answered and disagreed, each
#   with its three answers and audit snapshot path.
#
# The record format and its path are owned by bin/fm-jev-lib.sh.
# Exit 2 only for a usage error, an unreadable context file, a missing jq, or
# an unknown decision id or answer; record subcommands never touch the network.
#
# Authority: an answer is evidence, never a decision; the caller acts on its
#   own judgement and records it with record-mine.
set -u

TYPESAFE_API_KEY_PRIVATE=${TYPESAFE_API_KEY:-}
export -n TYPESAFE_API_KEY_PRIVATE 2>/dev/null || true
unset TYPESAFE_API_KEY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"
# shellcheck source=bin/fm-timing-lib.sh
. "$SCRIPT_DIR/fm-timing-lib.sh"
# shellcheck source=bin/fm-jev-lib.sh
. "$SCRIPT_DIR/fm-jev-lib.sh"
fm_jev_capture_dd

REPORT_FLOOR=0.6
QKEY=q
FM_JEV_CLAUDE_MODELS=${FM_JEV_CLAUDE_MODELS:-claude-opus-5-5 claude-sonnet-5 claude-haiku-4-5-20251001}
CLAUDE_SYSTEM_PROMPT='You answer one multiple-choice question. Reply with exactly one of the listed option ids and nothing else: no explanation, no punctuation, no quotes.'

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}
slug_ok() { [[ $1 =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; }
option_ok() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }

# records [model]: every record in the log, one JSON object per line, keeping
# only the duplicates of <model> (default the first of $FM_JEV_CLAUDE_MODELS);
# unparsable lines are skipped.
records() {
  local log model=${1:-${FM_JEV_CLAUDE_MODELS%% *}}
  log=$(fm_jev_log_path)
  [ -f "$log" ] || return 0
  jq -cR --arg m "$model" 'try fromjson catch empty | select(type == "object") |
    select(.event != "duplicate" or .claude_model == $m)' "$log"
}

# shellcheck disable=SC2016 # $names below are jq variables, not shell ones.
JOIN_JQ='
  def joined:
    group_by(.decision_id) | map(
      (map(select(.event == "call")) | first) as $c |
      select($c != null) |
      (map(select(.event == "mine")) | last) as $m |
      (map(select(.event == "outcome")) | last) as $o |
      (map(select(.event == "duplicate")) | last) as $d |
      ($o.final // $m.mine // null) as $final |
      $c + {claude_model: ($d.claude_model // null), claude_answer: ($d.claude_answer // null),
            claude_status: ($d.status // null), claude_wall_ms: ($d.claude_wall_ms // null),
            claude_latency_ms: ($d.claude_latency_ms // null), claude_cost_usd: ($d.claude_cost_usd // null),
            claude_tokens_in: ($d.claude_tokens_in // null), claude_tokens_out: ($d.claude_tokens_out // null)}
         + {mine: ($m.mine // null), outcome: ($o.outcome // null), final: $final,
            decision: (if $final == null then null
                       elif $c.answer != null and $final == $c.answer then "followed"
                       else "overridden" end)});
'

# resolve_id <decision-id or latest:type>: prints the call's decision id.
resolve_id() {
  local want=$1 id
  case "$want" in
    latest:*)
      id=$(records | jq -rs --arg t "${want#latest:}" '
        [.[] | select(.event == "call" and .question_type == $t)] | last | .decision_id // empty')
      ;;
    *)
      id=$(records | jq -rs --arg id "$want" '
        [.[] | select(.event == "call" and .decision_id == $id)] | last | .decision_id // empty')
      ;;
  esac
  [ -n "$id" ] || die "no recorded Jev call for $want"
  printf '%s' "$id"
}

duplicate_log() {  # <decision-id> <reason>
  local log
  log=$(fm_jev_side_log_path)
  { mkdir -p "${log%/*}" && printf '%s %s: %s\n' "$(fm_jev_now_iso)" "$1" "$2" >> "$log"; } 2>/dev/null || true
}

# audit_add <decision-id> <field> <value-file>: sets one raw-text field on an
# existing audit snapshot.
audit_add() {
  local path tmp
  path=$(fm_jev_audit_path "$1")
  [ -f "$path" ] || return 0
  tmp=$(mktemp "${path%/*}/.audit.XXXXXX" 2>/dev/null) || return 0
  if jq --arg k "$2" --rawfile v "$3" '. + {($k): $v}' "$path" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$path" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
}

# duplicate_claude <decision-id> <model> <prompt> <options-json>: runs detached.
duplicate_claude() {
  local id=$1 model=$2 prompt=$3 options=$4 dir out t0 t1 line
  command -v claude >/dev/null 2>&1 || { duplicate_log "$id" "$model: claude not installed"; return 0; }
  dir=$(mktemp -d) || { duplicate_log "$id" "mktemp failed"; return 0; }
  out=$(mktemp) || { rmdir "$dir"; duplicate_log "$id" "mktemp failed"; return 0; }
  t0=$(fm_timing_now_ms)
  if ! (cd "$dir" && printf '%s' "$prompt" \
      | OTEL_RESOURCE_ATTRIBUTES="${OTEL_RESOURCE_ATTRIBUTES:+$OTEL_RESOURCE_ATTRIBUTES,}firstmate.role=jev-duplicate" claude -p --safe-mode --setting-sources '' --strict-mcp-config \
      --tools '' --no-session-persistence --exclude-dynamic-system-prompt-sections \
      --model "$model" --output-format json --system-prompt "$CLAUDE_SYSTEM_PROMPT" \
      > "$out" 2>/dev/null); then
    audit_add "$id" claude_response "$out"
    rm -rf "$dir" "$out"
    duplicate_log "$id" "$model: claude exited non-zero"
    return 0
  fi
  t1=$(fm_timing_now_ms)
  rmdir "$dir" 2>/dev/null
  audit_add "$id" claude_response "$out"
  line=$(jq -c --arg id "$id" --arg ts "$(fm_jev_now_iso)" --arg model "$model" \
    --argjson wall "$(( t1 - t0 ))" --argjson options "$options" '
    select(.type == "result" and .is_error == false and (.result | type) == "string") |
    (.result | gsub("^\\s+|\\s+$"; "")) as $reply |
    (($options | index($reply)) != null) as $valid |
    def n($v): if ($v | type) == "number" then $v else 0 end;
    {v: 1, event: "duplicate", ts: $ts, decision_id: $id, claude_model: $model,
     claude_answer: (if $valid then $reply else null end),
     claude_wall_ms: $wall, claude_latency_ms: (.duration_api_ms // null),
     claude_cost_usd: (.total_cost_usd // null),
     claude_tokens_in: (n(.usage.input_tokens) + n(.usage.cache_creation_input_tokens) + n(.usage.cache_read_input_tokens)),
     claude_tokens_out: (.usage.output_tokens // null),
     status: (if $valid then "ok" else "off-option" end)}' "$out" 2>/dev/null) || line=''
  rm -f "$out"
  if [ -z "$line" ]; then
    duplicate_log "$id" "$model: claude output is not a successful result"
    return 0
  fi
  fm_jev_append "$line"
}

show_one() {  # <decision-id> [model]
  records "${2:-}" | jq -s --arg id "$1" "$JOIN_JQ"'
    [.[] | select(.decision_id == $id)] | joined | first // empty'
}

cmd_ask() {
  local qtype='' summary='' question='' context='' yes_no=0 opt slug meaning
  local criteria='{}' request resp options id http lat answer_ok prompt ctx sha
  while [ $# -gt 0 ]; do
    case "$1" in
      --type) [ $# -ge 2 ] || die "--type needs a value"; qtype=$2; shift 2 ;;
      --summary) [ $# -ge 2 ] || die "--summary needs a value"; summary=$2; shift 2 ;;
      --question) [ $# -ge 2 ] || die "--question needs a value"; question=$2; shift 2 ;;
      --context) [ $# -ge 2 ] || die "--context needs a value"; context=$2; shift 2 ;;
      --yes-no) yes_no=1; shift ;;
      --option)
        [ $# -ge 2 ] || die "--option needs a value"
        opt=$2; shift 2
        slug=${opt%%=*}
        if [ "$slug" = "$opt" ]; then meaning=$slug; else meaning=${opt#*=}; fi
        option_ok "$slug" || die "option id must be letters, digits, dot, dash, or underscore: $slug"
        [ -n "$meaning" ] || die "option meaning is empty: $slug"
        [ "$(jq -r --arg s "$slug" 'has($s)' <<<"$criteria")" = false ] || die "duplicate option: $slug"
        criteria=$(jq -c --arg s "$slug" --arg m "$meaning" '. + {($s): $m}' <<<"$criteria")
        ;;
      *) die "unknown ask argument: $1" ;;
    esac
  done
  [ -n "$qtype" ] || die "--type required"
  slug_ok "$qtype" || die "--type must be a kebab slug: $qtype"
  [ -n "$summary" ] || die "--summary required"
  [ -n "$question" ] || die "--question required"
  if [ "$yes_no" = 1 ]; then
    [ "$criteria" = '{}' ] || die "--yes-no and --option are exclusive"
    criteria='{"yes":"Yes.","no":"No."}'
  fi
  [ "$(jq 'length' <<<"$criteria")" -ge 2 ] || die "at least two --option values, or --yes-no, required"
  [ -z "$context" ] || [ -r "$context" ] || die "context file not readable: $context"

  if [ -z "$TYPESAFE_API_KEY_PRIVATE" ]; then
    TYPESAFE_API_KEY_PRIVATE=$(fmx_env_get TYPESAFE_API_KEY "$FM_HOME/.env")
  fi
  if [ -z "$TYPESAFE_API_KEY_PRIVATE" ]; then
    echo "jev: off (TYPESAFE_API_KEY absent from the environment and $FM_HOME/.env)" >&2
    exit 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    echo "jev: error (curl not installed)" >&2
    exit 0
  fi

  # One private copy of the context, so the bytes sent, hashed, and snapshotted
  # are the same even if the caller rewrites or deletes its file.
  ctx=$(mktemp) || die "mktemp failed"
  resp=$(mktemp) || { rm -f "$ctx"; die "mktemp failed"; }
  trap 'rm -f "$resp" "$ctx"' EXIT
  cat "${context:-/dev/null}" > "$ctx" 2>/dev/null || die "context file not readable: $context"
  sha=$(fm_jev_sha256 "$ctx")
  request=$(jq -n --rawfile context "$ctx" --arg model "$FM_JEV_MODEL" \
    --arg question "$question" --arg qkey "$QKEY" --argjson criteria "$criteria" '
    {model: $model, state: {context: $context},
     questions: {($qkey): {type: "choice", instructions: $question, criteria: $criteria}}}') \
    || die "could not build the request"
  options=$(jq -c 'keys_unsorted' <<<"$criteria")
  prompt=$(jq -rn --rawfile context "$ctx" --arg question "$question" --argjson criteria "$criteria" '
    "Question: \($question)\n\nOptions (reply with one id):\n"
    + ([$criteria | to_entries[] | "- \(.key): \(.value)"] | join("\n"))
    + "\n\nContext:\n\($context)\n\nReply with exactly one option id from the list and nothing else."') \
    || die "could not build the duplicate prompt"
  id=$(fm_jev_new_id)
  fm_jev_post "$request" "$resp"
  http=$FM_JEV_HTTP lat=$FM_JEV_LAT_MS
  if [ "$http" != 200 ]; then
    settle error
    echo "jev: error (http $http after ${lat} ms)" >&2
    exit 0
  fi
  answer_ok=$(jq -e --arg qkey "$QKEY" --argjson options "$options" '
    .answers[$qkey] as $a |
    ($a.choice | type) == "string" and ($options | index($a.choice)) != null and
    ($a.confidence | type) == "number" and $a.confidence >= 0 and $a.confidence <= 1 and
    ($a.probabilities | type) == "object" and
    (($a.probabilities | keys | sort) == ($options | sort)) and
    all($a.probabilities[]; type == "number" and . >= 0 and . <= 1) and
    (($a.probabilities | [.[]] | add) as $total | $total >= 0.99 and $total <= 1.01) and
    ((has("usage") | not) or
      ((.usage | type) == "object" and
       (.usage.input_tokens | type) == "number" and
       (.usage.output_tokens | type) == "number"))' "$resp" 2>/dev/null) || answer_ok=false
  if [ "$answer_ok" != true ]; then
    settle error
    echo "jev: error (response is not a Choice answer over the options)" >&2
    exit 0
  fi
  settle ok
  jq -r --arg id "$id" --arg qkey "$QKEY" --arg lat "$lat" '
    def show($v): ($v // "-") | tostring | gsub("[\t\r\n]"; " ");
    .answers[$qkey] as $a |
    "jev:",
    "  decision_id: \($id)",
    "  answer: \($a.choice | show(.))   confidence: \($a.confidence)",
    "  probabilities: \([$a.probabilities | to_entries[] | "\(.key)=\(.value)"] | join(" "))",
    "  model: \(show(.model))   latency_ms: \($lat)   tokens: \(show(.usage.input_tokens))/\(show(.usage.output_tokens))"' "$resp" \
    || echo "jev: error (output rendering failed)" >&2
  exit 0
}

# settle <ok|error>: uses cmd_ask's locals. Records the call, writes the audit
# snapshot, then detaches the duplicate queries, each followed by its model's
# Datadog decision event (claude_status error when no duplicate was recorded).
settle() {
  fm_jev_record_call "$id" "$qtype" "$summary" "$options" "$QKEY" "$1" "$lat" "$resp" "$sha"
  fm_jev_write_audit "$id" "$qtype" "$question" "$criteria" "$ctx" "$sha" "$request" "$resp"
  audit_add "$id" claude_system_prompt <(printf '%s' "$CLAUDE_SYSTEM_PROMPT")
  audit_add "$id" claude_prompt <(printf '%s' "$prompt")
  fm_jev_detach duplicate_then_event "$id" "$prompt" "$options"
}

duplicate_then_event() {  # <decision-id> <prompt> <options-json>
  local model
  for model in $FM_JEV_CLAUDE_MODELS; do
    duplicate_claude "$1" "$model" "$2" "$3"
    fm_jev_dd_send "$(fm_jev_decision_event "$(show_one "$1" "$model")" error "$model")"
  done
}

cmd_record_mine() {
  [ $# -eq 2 ] || die "record-mine needs <decision-id> <answer>"
  local id answer=$2 call
  id=$(resolve_id "$1")
  call=$(show_one "$id")
  [ "$(jq -r --arg a "$answer" '.options | index($a) != null' <<<"$call")" = true ] \
    || die "answer $answer is not one of $(jq -r '.options | join(", ")' <<<"$call")"
  fm_jev_append "$(jq -cn --arg id "$id" --arg mine "$answer" --arg ts "$(fm_jev_now_iso)" \
    '{v: 1, event: "mine", ts: $ts, decision_id: $id, mine: $mine}')"
  call=$(show_one "$id")
  fm_jev_dd_send "$(fm_jev_label_event "$call")"
  jq -r '"jev: recorded \(.decision_id) mine=\(.mine) jev=\(.answer // "none") \(.decision)"' <<<"$call"
}

cmd_record_outcome() {
  local raw_id='' text='' final='' have_final=0 id joined
  while [ $# -gt 0 ]; do
    case "$1" in
      --final) [ $# -ge 2 ] || die "--final needs a value"; final=$2; have_final=1; shift 2 ;;
      *)
        if [ -z "$raw_id" ]; then raw_id=$1
        elif [ -z "$text" ]; then text=$1
        else die "record-outcome takes <decision-id> <text> [--final <choice>]"; fi
        shift ;;
    esac
  done
  [ -n "$raw_id" ] && [ -n "$text" ] || die "record-outcome needs <decision-id> <text>"
  [ "$have_final" = 0 ] || [ -n "$final" ] || die "--final needs a value"
  id=$(resolve_id "$raw_id")
  fm_jev_append "$(jq -cn --arg id "$id" --arg outcome "$text" --arg final "$final" --arg ts "$(fm_jev_now_iso)" \
    '{v: 1, event: "outcome", ts: $ts, decision_id: $id, outcome: $outcome,
      final: (if $final == "" then null else $final end)}')"
  joined=$(show_one "$id")
  fm_jev_dd_send "$(fm_jev_label_event "$joined")"
  jq -r '"jev: recorded outcome for \(.decision_id) final=\(.final // "none") jev=\(.answer // "none") \(.decision // "undecided")"' <<<"$joined"
}

cmd_show() {
  [ $# -eq 1 ] || die "show needs <decision-id>"
  local id path
  id=$(resolve_id "$1")
  path=$(fm_jev_audit_path "$id")
  [ -f "$path" ] || path=/dev/null
  show_one "$id" | jq --slurpfile audit "$path" '{record: ., audit: ($audit | first // null)}'
}

cmd_report() {
  local since='' floor=$REPORT_FLOOR sample=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --since) [ $# -ge 2 ] || die "--since needs a value"; since=$2; shift 2 ;;
      --floor) [ $# -ge 2 ] || die "--floor needs a value"; floor=$2; shift 2 ;;
      --audit-sample) [ $# -ge 2 ] || die "--audit-sample needs a value"; sample=$2; shift 2 ;;
      *) die "unknown report argument: $1" ;;
    esac
  done
  if [ -n "$since" ]; then
    [[ $since =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)?$ ]] \
      || die "--since must be YYYY-MM-DD or YYYY-MM-DDTHH:MM:SSZ"
  fi
  [[ $floor =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]] || die "--floor must be a number from 0 through 1"
  [ -z "$sample" ] || [[ $sample =~ ^[0-9]+$ ]] || die "--audit-sample must be a whole number"
  report_text "$since" "$floor"
  [ -z "$sample" ] || audit_sample "$since" "$sample"
}

# audit_sample <since> <n>: n random decisions where Jev and Claude agreed,
# then every decision where both answered and disagreed, each with its snapshot.
audit_sample() {
  local lines agreed shown
  lines=$(records | jq -rs --arg since "$1" --arg dir "$(dirname "$(fm_jev_audit_path x)")" "$JOIN_JQ"'
    [joined[] | select(($since == "" or .ts >= $since) and .answer != null and .claude_answer != null)][] |
    [(if .answer == .claude_answer then "agree" else "disagree" end),
     "  \(.decision_id) \(.question_type) jev=\(.answer) claude=\(.claude_answer) firstmate=\(.mine // "none") audit=\($dir)/\(.decision_id).json"]
    | @tsv')
  agreed=$(awk -F '\t' '$1 == "agree"' <<<"$lines" | grep -c . || true)
  shown=$(( agreed < $2 ? agreed : $2 ))
  printf 'audit sample: %s of %s jev = claude agreements, random\n' "$shown" "$agreed"
  awk -F '\t' 'BEGIN { srand() } $1 == "agree" { print rand() "\t" $2 }' <<<"$lines" \
    | sort -n | cut -f2- | head -n "$2"
  printf 'jev / claude disagreements: %s\n' "$(awk -F '\t' '$1 == "disagree"' <<<"$lines" | grep -c . || true)"
  awk -F '\t' '$1 == "disagree" { print $2 }' <<<"$lines"
}

report_text() {  # <since> <floor>
  local since=$1 floor=$2
  records | jq -rs --arg since "$since" --argjson floor "$floor" "$JOIN_JQ"'
    def pct($n; $d): if $d == 0 then "-" else "\((($n * 1000 / $d) | round) / 10)%" end;
    def ratio($n; $d): "\($n)/\($d) (\(pct($n; $d)))";
    def rank($xs; $p): ($xs | sort) as $s | ($s | length) as $n |
      if $n == 0 then "-" else $s[([(($p * $n) | ceil) - 1, 0] | max)] | tostring end;
    def usd($x): ($x * 100000000 | round) as $u |
      "$\(($u / 100000000) | floor).\(("00000000" + (($u % 100000000) | tostring))[-8:])";
    def cost($xs): if ($xs | length) == 0 then "-"
      else "total \(usd($xs | add)) per decision \(usd(($xs | add) / ($xs | length)))" end;
    def stats($rows):
      [$rows[] | select(.status == "ok")] as $ok |
      [$ok[] | select(.mine != null)] as $cmp |
      [$cmp[] | select(.answer == .mine)] as $agree |
      [$cmp[] | select(.confidence >= $floor)] as $conf |
      [$cmp[] | select(.confidence < $floor)] as $low |
      [$cmp[] | select(.answer != .mine)] as $dis |
      [$rows[] | select(.decision != null)] as $fin |
      [$rows[] | .latency_ms | numbers] as $lat |
      [$rows[] | select(.answer != null and .claude_answer != null)] as $jc |
      [$rows[] | select(.claude_answer != null and .mine != null)] as $cm |
      [$jc[] | select(.mine != null)] as $tri |
      [$rows[] | .claude_wall_ms | numbers] as $cwall |
      [$rows[] | .claude_latency_ms | numbers] as $capi |
      "  calls: \($rows | length)   answered: \($ok | length)   step-aside: \(($rows | length) - ($ok | length))",
      "  agreement with firstmate: \(ratio($agree | length; $cmp | length))",
      "  confident (>= \($floor)): \(ratio([$conf[] | select(.answer == .mine)] | length; $conf | length)) agree   below floor: \(ratio([$low[] | select(.answer == .mine)] | length; $low | length)) agree",
      "  escalation rate: \(ratio([$ok[] | select(.confidence < $floor)] | length; $ok | length))",
      "  false-confident: \([$conf[] | select(.answer != .mine)] | length)",
      "  disagreements: \($dis | length)   outcome-labelled: \([$dis[] | select(.outcome != null)] | length)",
      "  final choice: followed \([$fin[] | select(.decision == "followed")] | length)   overridden \([$fin[] | select(.decision == "overridden")] | length)",
      "  jev latency_ms p50: \(rank($lat; 0.5))   p95: \(rank($lat; 0.95))",
      "  claude: duplicates \([$rows[] | select(.claude_status != null)] | length)   answered \([$rows[] | select(.claude_answer != null)] | length)",
      "  claude wall_ms p50: \(rank($cwall; 0.5))   p95: \(rank($cwall; 0.95))   api_ms p50: \(rank($capi; 0.5))   p95: \(rank($capi; 0.95))",
      "  jev = claude: \(ratio([$jc[] | select(.answer == .claude_answer)] | length; $jc | length))   claude = firstmate: \(ratio([$cm[] | select(.claude_answer == .mine)] | length; $cm | length))",
      "  three-way all agree: \(ratio([$tri[] | select(.answer == .claude_answer and .answer == .mine)] | length; $tri | length))",
      "  tokens: in \([$rows[] | .tokens_in | numbers] | add // 0)   out \([$rows[] | .tokens_out | numbers] | add // 0)",
      "  cost: jev \(cost([$rows[] | .jev_cost_usd | numbers]))   claude (API-equivalent) \(cost([$rows[] | .claude_cost_usd | numbers]))";
    [joined[] | select($since == "" or .ts >= $since)] as $all |
    "jev report (since \(if $since == "" then "all records" else $since end), floor \($floor))",
    if ($all | length) == 0 then "no recorded calls"
    else
      (($all | group_by(.question_type))[] | (first.question_type), stats(.)),
      "all types", stats($all)
    end'
}

command -v jq >/dev/null 2>&1 || die "jq required"
[ $# -gt 0 ] || { usage; exit 2; }
sub=$1; shift
case "$sub" in
  ask) cmd_ask "$@" ;;
  record-mine) cmd_record_mine "$@" ;;
  record-outcome) cmd_record_outcome "$@" ;;
  show) cmd_show "$@" ;;
  report) cmd_report "$@" ;;
  -h|--help) usage ;;
  *) die "unknown subcommand: $sub (see --help)" ;;
esac
