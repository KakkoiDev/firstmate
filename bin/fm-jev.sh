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
# show: prints the joined record for one decision as JSON.
# report: per question type, plain text: calls, answered, step-aside count,
#   agreement with firstmate, agreement on confident answers (confidence >=
#   floor, default 0.6, the resolver's global floor) and below the floor,
#   escalation rate (answered below the floor), false-confident count
#   (confident and disagreeing), disagreements and how many carry an outcome,
#   followed/overridden on the final choice, latency p50/p95 (nearest rank),
#   and token totals. --since keeps calls whose timestamp is at or after it.
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

REPORT_FLOOR=0.6
QKEY=q

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

# Every record in the log, one JSON object per line; unparsable lines are skipped.
records() {
  local log
  log=$(fm_jev_log_path)
  [ -f "$log" ] || return 0
  jq -cR 'try fromjson catch empty | select(type == "object")' "$log"
}

# shellcheck disable=SC2016 # $names below are jq variables, not shell ones.
JOIN_JQ='
  def joined:
    group_by(.decision_id) | map(
      (map(select(.event == "call")) | first) as $c |
      select($c != null) |
      (map(select(.event == "mine")) | last) as $m |
      (map(select(.event == "outcome")) | last) as $o |
      ($o.final // $m.mine // null) as $final |
      $c + {mine: ($m.mine // null), outcome: ($o.outcome // null), final: $final,
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

show_one() {  # <decision-id>
  records | jq -s --arg id "$1" "$JOIN_JQ"'
    [.[] | select(.decision_id == $id)] | joined | first // empty'
}

cmd_ask() {
  local qtype='' summary='' question='' context='' yes_no=0 opt slug meaning
  local criteria='{}' request resp options id http lat answer_ok
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

  request=$(jq -n --rawfile context "${context:-/dev/null}" --arg model "$FM_JEV_MODEL" \
    --arg question "$question" --arg qkey "$QKEY" --argjson criteria "$criteria" '
    {model: $model, state: {context: $context},
     questions: {($qkey): {type: "choice", instructions: $question, criteria: $criteria}}}') \
    || die "could not build the request"
  options=$(jq -c 'keys_unsorted' <<<"$criteria")
  resp=$(mktemp) || die "mktemp failed"
  trap 'rm -f "$resp"' EXIT
  id=$(fm_jev_new_id)
  fm_jev_post "$request" "$resp"
  http=$FM_JEV_HTTP lat=$FM_JEV_LAT_MS
  if [ "$http" != 200 ]; then
    fm_jev_record_call "$id" "$qtype" "$summary" "$options" "$QKEY" error "$lat" "$resp"
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
    fm_jev_record_call "$id" "$qtype" "$summary" "$options" "$QKEY" error "$lat" "$resp"
    echo "jev: error (response is not a Choice answer over the options)" >&2
    exit 0
  fi
  fm_jev_record_call "$id" "$qtype" "$summary" "$options" "$QKEY" ok "$lat" "$resp"
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

cmd_record_mine() {
  [ $# -eq 2 ] || die "record-mine needs <decision-id> <answer>"
  local id answer=$2 call
  id=$(resolve_id "$1")
  call=$(show_one "$id")
  [ "$(jq -r --arg a "$answer" '.options | index($a) != null' <<<"$call")" = true ] \
    || die "answer $answer is not one of $(jq -r '.options | join(", ")' <<<"$call")"
  fm_jev_append "$(jq -cn --arg id "$id" --arg mine "$answer" --arg ts "$(fm_jev_now_iso)" \
    '{v: 1, event: "mine", ts: $ts, decision_id: $id, mine: $mine}')"
  show_one "$id" | jq -r '"jev: recorded \(.decision_id) mine=\(.mine) jev=\(.answer // "none") \(.decision)"'
}

cmd_record_outcome() {
  local raw_id='' text='' final='' have_final=0 id
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
  show_one "$id" | jq -r '"jev: recorded outcome for \(.decision_id) final=\(.final // "none") jev=\(.answer // "none") \(.decision // "undecided")"'
}

cmd_show() {
  [ $# -eq 1 ] || die "show needs <decision-id>"
  local id
  id=$(resolve_id "$1")
  show_one "$id"
}

cmd_report() {
  local since='' floor=$REPORT_FLOOR
  while [ $# -gt 0 ]; do
    case "$1" in
      --since) [ $# -ge 2 ] || die "--since needs a value"; since=$2; shift 2 ;;
      --floor) [ $# -ge 2 ] || die "--floor needs a value"; floor=$2; shift 2 ;;
      *) die "unknown report argument: $1" ;;
    esac
  done
  if [ -n "$since" ]; then
    [[ $since =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)?$ ]] \
      || die "--since must be YYYY-MM-DD or YYYY-MM-DDTHH:MM:SSZ"
  fi
  [[ $floor =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]] || die "--floor must be a number from 0 through 1"
  records | jq -rs --arg since "$since" --argjson floor "$floor" "$JOIN_JQ"'
    def pct($n; $d): if $d == 0 then "-" else "\((($n * 1000 / $d) | round) / 10)%" end;
    def ratio($n; $d): "\($n)/\($d) (\(pct($n; $d)))";
    def rank($xs; $p): ($xs | sort) as $s | ($s | length) as $n |
      if $n == 0 then "-" else $s[([(($p * $n) | ceil) - 1, 0] | max)] | tostring end;
    def stats($rows):
      [$rows[] | select(.status == "ok")] as $ok |
      [$ok[] | select(.mine != null)] as $cmp |
      [$cmp[] | select(.answer == .mine)] as $agree |
      [$cmp[] | select(.confidence >= $floor)] as $conf |
      [$cmp[] | select(.confidence < $floor)] as $low |
      [$cmp[] | select(.answer != .mine)] as $dis |
      [$rows[] | select(.decision != null)] as $fin |
      [$rows[] | .latency_ms | numbers] as $lat |
      "  calls: \($rows | length)   answered: \($ok | length)   step-aside: \(($rows | length) - ($ok | length))",
      "  agreement with firstmate: \(ratio($agree | length; $cmp | length))",
      "  confident (>= \($floor)): \(ratio([$conf[] | select(.answer == .mine)] | length; $conf | length)) agree   below floor: \(ratio([$low[] | select(.answer == .mine)] | length; $low | length)) agree",
      "  escalation rate: \(ratio([$ok[] | select(.confidence < $floor)] | length; $ok | length))",
      "  false-confident: \([$conf[] | select(.answer != .mine)] | length)",
      "  disagreements: \($dis | length)   outcome-labelled: \([$dis[] | select(.outcome != null)] | length)",
      "  final choice: followed \([$fin[] | select(.decision == "followed")] | length)   overridden \([$fin[] | select(.decision == "overridden")] | length)",
      "  latency_ms p50: \(rank($lat; 0.5))   p95: \(rank($lat; 0.95))",
      "  tokens: in \([$rows[] | .tokens_in | numbers] | add // 0)   out \([$rows[] | .tokens_out | numbers] | add // 0)";
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
