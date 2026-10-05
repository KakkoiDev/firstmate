#!/usr/bin/env bash
# fm-jev.sh - ask typesafe.ai's System One model (Jev) one typed question, record
# firstmate's own answer beside it, and report how far Jev can be trusted.
#
# Usage:
#   fm-jev.sh ask --type <slug> --summary <line> --question <text>
#                 (--option <id>[=<meaning>] ... | --yes-no) [--source <file>]...
#                 [--context <file>] [--mine <answer>] [--target <kind>:<value>]
#   fm-jev.sh ask --template claim-check --claim <one sentence>
#                 --source <URL|file> --evidence <verbatim quote> [common]
#   fm-jev.sh ask --template ticket-status --ticket <id> --current <value>
#                 --proposed <value> --evidence <verbatim quote> [common]
#   fm-jev.sh ask --template ask-scope --words <the operator's words>
#                 --candidate <id>[=<meaning>] ... [common]
#     [common]: [--summary <line>] [--source <file>]... [--context <file>]
#               [--mine <answer>] [--target <kind>:<value>]
#               (claim-check's one --source is its template field)
#   fm-jev.sh asked --type <type>[,<type>...] [--status <status>[,...]]
#   fm-jev.sh target-status --target <kind>:<value> --require <claim-check|template>
#   fm-jev.sh turn --since <ISO-8601 UTC time>
#   fm-jev.sh acting <decision-id>
#   fm-jev.sh record-mine <decision-id> <answer>
#   fm-jev.sh record-outcome <decision-id> <text> [--final <choice>]
#   fm-jev.sh show <decision-id>
#   fm-jev.sh dd-failures [--quiet | --ack]
#   fm-jev.sh report [--since <YYYY-MM-DD[THH:MM:SSZ]>] [--floor <0..1>]
#                    [--audit-sample <n>] [--min-answered <n>]
#                    [--min-agreement <0..1>] [--max-overruled <n>]
#
# --mine: firstmate's blind choice, one of the options. With Jev on, it is
#   appended as a "mine" record with blind: true BEFORE the request is sent,
#   so Jev's answer cannot anchor it, and the ask then appends one "decided"
#   record: {v, event: "decided", ts, decision_id, decider, acting, listed,
#   floor}. The acting answer is Jev's when the question type is listed in
#   the authority file, Jev answered, and its confidence is at or above that
#   type's floor; otherwise it is firstmate's blind choice. decider names
#   whose answer acts (jev or firstmate). The output block gains
#   "  acting: <answer>   decider: <jev|firstmate>". With Jev off nothing is
#   recorded and stdout stays empty, exactly as without --mine; the caller's
#   own choice acts. A failed call records its blind choice and a firstmate
#   decision, and stdout stays empty.
#   The action scripts (fm-spawn, fm-send, fm-teardown, fm-pr-merge,
#   fm-merge-local, fm-control) ask this way through bin/fm-jev-gate-lib.sh.
# Authority file: ${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/jev-authority, written
#   only by the human operator; docs/configuration.md "Jev authority" owns its
#   schema. Absent or empty means Jev decides nothing (shadow only). The four
#   never-types (merge-risk, finding-authority, report-has-captain-call,
#   mid-task-ask) and malformed lines are refused with one stderr warning
#   each and never grant authority.
# --mine that differs from Jev's answer prints one stderr line
#   "jev: WARNING: firstmate disagrees with Jev on <type> <id>: jev <answer>
#   (<confidence>), firstmate <choice>"; record-mine prints the same line.
# --template: a question format whose fields are rendered, in English, into
#   the state ahead of every other section; it sets --type, --question, and
#   the options, so those flags are refused beside it, and a missing field is
#   refused with exit 2 naming it. The summary defaults to the type and the
#   claim, ticket, or words.
#   claim-check: options supported, contradicted, not-addressed. --claim is one
#     sentence on one line. When --source is not an http(s) URL it must be a
#     readable file that contains --evidence (whitespace runs read as one
#     space), so a quote not read from that file is refused.
#   ticket-status: options <the proposed value as a slug> and keep-current.
#   ask-scope: options each --candidate, then several and unclear.
# --target: binds the ask to what it guards, such as notion:<page id or URL>
#   or slack:<channel id>, normalized by fm_jev_target_key in
#   bin/fm-jev-lib.sh; it needs --mine. Every ask that passes its argument
#   checks appends one ask ledger line (bin/fm-jev-lib.sh), Jev off included.
# asked: prints the newest ask ledger line of one of the types (and, with
#   --status, one of the statuses) from the last ASK_WINDOW_SECS (30 minutes);
#   exit 1 when there is none. bin/fm-jev-gate-lib.sh reads it to accept a
#   decision passed as "off".
# target-status: prints one verdict for a target, which
#   bin/fm-jev-pretool-check.sh acts on:
#     blocked <id> <answer> <confidence>: a claim-check on the target answered
#       contradicted or not-addressed at or above the claim-check floor, with
#       no record-outcome on that decision and no later claim-check answered
#       supported on different evidence (evidence_sha256), however old;
#     missing: no ask on the target in the last ASK_WINDOW_SECS, of type
#       claim-check for --require claim-check, else of any template type;
#     warn <id> <answer> <confidence>: the newest recent claim-check answered
#       contradicted or not-addressed below the floor;
#     ok: otherwise, including an ask that found Jev off or failing.
#   The floor is ${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/jev-claim-check-floor,
#   one number from 0 through 1 (default CLAIM_FLOOR, 0.5); docs/configuration.md
#   "Jev authority" owns that file.
# turn: prints the section "Jev asks this turn (<n>)" for the decisions called
#   at or after --since (fractional seconds dropped), oldest first, one line
#   each:
#     <asker> <type>: <summary> - jev <answer> (<confidence>), mine <choice>
#   with "jev error (-)" for a failed call, "mine unrecorded" without a
#   firstmate choice, and " [DISAGREE]" appended when both answered and
#   differ; "none" follows the header when there are none. dispatch-rule calls
#   with one context_sha256 print once (the labelled one, else the newest).
#   bin/fm-jev-stop-check.sh reads it.
# acting: prints "<acting-answer> <decider>" for a recorded decision: the
#   decided record when there is one, else firstmate's recorded choice with
#   decider firstmate. Exit 2 when the decision carries no firstmate choice.
#
# ask: one POST through the shared transport in bin/fm-jev-lib.sh. The request
#   is {model, state: {context}, questions: {q: {type: choice, instructions,
#   criteria}}}: the question text is the instructions, each --option is one
#   criterion (its meaning defaults to the id; an id is letters, digits, dot,
#   dash, or underscore, so a registered project name fits), --yes-no is the choice
#   {yes, no}, and the state is the context ask builds itself, one section
#   after another with a blank line between them:
#     1. the template's rendered fields, when --template is given;
#     2. "The operator's words this turn, verbatim, oldest first:", then
#        "Message at <ts>:" and each prompt recorded in
#        $FM_HOME/state/jev-turn-words.jsonl (bin/fm-jev-prompt-reminder.sh
#        owns that record), mid-turn messages included; left out inside a task
#        worker (FM_TASK_ID set) and when none is recorded;
#     3. per --source, in order, "Source <path>, verbatim:" and the file's
#        bytes; each must be a readable, non-empty regular file;
#     4. "Firstmate's note, its own account rather than a source:" and the
#        --context file, when given;
#     5. the type's standing rules (fm_jev_constraints in bin/fm-jev-lib.sh);
#        the call record's constraints_sent says whether any went out.
#   --mine never enters the state. The duplicate queries and the audit
#   snapshot see the same state. The summary is one English line saying what
#   is asked; it is recorded, never sent.
#   Manual types (MANUAL_TYPES below: the types firstmate asks by hand, with
#   no action script building the context) are refused with exit 2, asking
#   and recording nothing, when the state would carry neither the operator's
#   words nor a --source file, so a --context note alone never reaches Jev;
#   the refusal prints the same command with a --source placeholder added.
#   Output (stdout, TOON-style block):
#     jev:
#       decision_id: <id>
#       answer: <option id>   confidence: <0..1>
#       probabilities: <id>=<p> ...
#       model: <version>   latency_ms: <n>   tokens: <in>/<out>
#   Off (TYPESAFE_API_KEY absent from the environment and $FM_HOME/.env): one
#   "jev: off" stderr line, nothing on stdout, no call, no record. The same
#   holds when any request string matches the never-send list
#   (fm_jev_never_send_line in bin/fm-jev-lib.sh) or the list cannot be
#   checked; the line names the list line number, never the value.
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
#   carries no id). The answer must be one of the call's options. A decision
#   whose blind choice was recorded by ask --mine refuses a second one.
# record-outcome: appends a later human correction or override as free text;
#   --final names the choice actually taken when it differs from the acting
#   answer. The final choice is the outcome's --final, else the acting answer,
#   else firstmate's; the decision is "followed" when the final choice equals
#   Jev's answer and "overridden" otherwise. The outcome is also graded against
#   the deciding party: "upheld" when the final choice equals the acting
#   answer, "overruled" otherwise.
#   Both send one Datadog label event after appending (bin/fm-jev-lib.sh).
# dd-failures: prints "jev datadog failures: <n> unacknowledged" from
#   $FM_HOME/state/jev-dd-failures.jsonl (bin/fm-jev-lib.sh owns the record),
#   naming the first and last unacknowledged failure when n > 0. --quiet prints
#   nothing when n is 0 (the session-start digest and fleet view use it).
#   --ack acknowledges every failure recorded so far by storing that count in
#   $FM_HOME/state/jev-dd-failures.acked.
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
#   Claude (API-equivalent). Per type it also shows the decider split, how
#   often each decider was overruled by a later outcome, the authority
#   listing, a flag when the Jev model changed across decisions taken while
#   the type was listed, the upper-bound cost line, and graduation readiness:
#   at least --min-answered (default 20) answered calls, at least
#   --min-agreement (default 0.95) of confident answers agreeing with
#   firstmate's blind choice (recorded by ask --mine; a later record-mine is
#   not blind and does not count), and at most --max-overruled (default 0) confident Jev
#   answers later overruled by an outcome. Confident means at or above the
#   type's listed floor, else --floor. The upper-bound line prices each matched
#   issuing request (fm_jev_request_cost) minus that decision's Jev cost, at
#   Opus rates, with the same tokens at Sonnet and Haiku rates labelled as an
#   assumption; the Haiku figure is invalid when any matched request's context
#   exceeded 200k tokens. The rates are the PRICE_* list prices below. --since
#   keeps calls whose timestamp is at or
#   after it. --audit-sample <n> then lists n random decisions where Jev and
#   Claude agreed and every decision where both answered and disagreed, each
#   with its three answers and audit snapshot path.
#
# The record format and its path are owned by bin/fm-jev-lib.sh.
# Home: FM_JEV_HOME, which bin/fm-spawn.sh exports into every ship and scout
#   pane, wins over FM_HOME, so a worker's asks land in the home that launched
#   it whatever directory it runs from; unset, FM_HOME and then this checkout.
# Exit 2 only for a usage error (a manual-type ask without the operator's words
# or a --source included), an unreadable context or source file, a missing jq,
# or an unknown decision id or answer; record subcommands never touch the
# network.
#
# Authority: an answer is evidence unless the operator lists its type in the
#   authority file; the caller acts on the acting answer ask --mine prints, or
#   on its own judgement when it asked without --mine.
set -u

TYPESAFE_API_KEY_PRIVATE=${TYPESAFE_API_KEY:-}
export -n TYPESAFE_API_KEY_PRIVATE 2>/dev/null || true
unset TYPESAFE_API_KEY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_JEV_HOME:-${FM_HOME:-$FM_ROOT}}"

# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"
# shellcheck source=bin/fm-timing-lib.sh
. "$SCRIPT_DIR/fm-timing-lib.sh"
# shellcheck source=bin/fm-jev-lib.sh
. "$SCRIPT_DIR/fm-jev-lib.sh"
fm_jev_capture_dd

REPORT_FLOOR=0.6
# An ask counts as made for a guard (asked, target-status) for this long.
ASK_WINDOW_SECS=1800
# Default claim-check floor; config/jev-claim-check-floor overrides it.
CLAIM_FLOOR=0.5
QKEY=q
AUTHORITY_FILE="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/jev-authority"
NEVER_TYPES='report-has-captain-call'
# Types firstmate asks by hand, with no action script building the context.
MANUAL_TYPES='deliverable-class project-match secondmate-scope surface-class brief-answers-question finding-authority heartbeat-suspicious'
SOURCE_PLACEHOLDER='<file holding the raw evidence: status lines, brief, report, or script output>'
GRAD_MIN_ANSWERED=20
GRAD_MIN_AGREEMENT=0.95
GRAD_MAX_OVERRULED=0
# USD per million tokens, input and output, for the upper-bound line. These are
# list prices assumed for the Opus, Sonnet, and Haiku tiers, not read from a
# price page; correct them here when the published prices differ. Cache writes
# are priced at 1.25x input (5-minute) or 2x input (1-hour), cache reads at
# 0.1x input.
PRICE_OPUS='5 25'
PRICE_SONNET='3 15'
PRICE_HAIKU='1 5'
HAIKU_CONTEXT_MAX=200000
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
      (map(select(.event == "decided")) | last) as $dd |
      (map(select(.event == "request")) | last) as $rq |
      ($dd.acting // $m.mine // null) as $acting |
      ($o.final // $acting) as $final |
      $c + {claude_model: ($d.claude_model // null), claude_answer: ($d.claude_answer // null),
            claude_status: ($d.status // null), claude_wall_ms: ($d.claude_wall_ms // null),
            claude_latency_ms: ($d.claude_latency_ms // null), claude_cost_usd: ($d.claude_cost_usd // null),
            claude_tokens_in: ($d.claude_tokens_in // null), claude_tokens_out: ($d.claude_tokens_out // null)}
         + {mine: ($m.mine // null), blind: ($m.blind // false), outcome: ($o.outcome // null), final: $final,
            decision: (if $final == null then null
                       elif $c.answer != null and $final == $c.answer then "followed"
                       else "overridden" end),
            acting: $acting,
            decider: ($dd.decider // (if $m != null then "firstmate" else null end)),
            listed: ($dd.listed // false), authority_floor: ($dd.floor // null),
            graded: (if $o == null or $acting == null then null
                     elif $final == $acting then "upheld" else "overruled" end),
            request_status: ($rq.status // null), request_model: ($rq.request_model // null),
            request_input_tokens: ($rq.input_tokens // null),
            request_cache_creation_input_tokens: ($rq.cache_creation_input_tokens // null),
            request_cache_creation_1h_input_tokens: ($rq.cache_creation_1h_input_tokens // null),
            request_cache_read_input_tokens: ($rq.cache_read_input_tokens // null),
            request_output_tokens: ($rq.output_tokens // null)});
'

# authority_map: prints the authority file as a JSON object {type: floor},
# warning on stderr about every refused line; {} when the file is absent.
authority_map() {
  local line n=0 type floor rest map='{}'
  if [ -f "$AUTHORITY_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      n=$((n + 1))
      line=${line%%#*}
      type='' floor='' rest=''
      read -r type floor rest <<<"$line"
      [ -n "$type" ] || continue
      if ! slug_ok "$type" || [ -n "$rest" ] || ! [[ $floor =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]]; then
        echo "jev: authority line $n refused (expected <type> <floor from 0 through 1>)" >&2
        continue
      fi
      case " $NEVER_TYPES " in
        *" $type "*) echo "jev: authority line $n refused ($type is never handed to Jev)" >&2; continue ;;
      esac
      map=$(jq -c --arg t "$type" --argjson f "$floor" '. + {($t): $f}' <<<"$map")
    done < "$AUTHORITY_FILE"
  fi
  printf '%s' "$map"
}

# authority_floor <type>: the type's listed floor, or nothing.
authority_floor() {
  authority_map | jq -r --arg t "$1" '.[$t] // empty'
}

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

# add_option <id>[=<meaning>]: one criterion into cmd_ask's criteria.
add_option() {
  local slug=${1%%=*} meaning
  if [ "$slug" = "$1" ]; then meaning=$slug; else meaning=${1#*=}; fi
  option_ok "$slug" || die "option id must be letters, digits, dot, dash, or underscore: $slug"
  [ -n "$meaning" ] || die "option meaning is empty: $slug"
  [ "$(jq -r --arg s "$slug" 'has($s)' <<<"$criteria")" = false ] || die "duplicate option: $slug"
  criteria=$(jq -c --arg s "$slug" --arg m "$meaning" '. + {($s): $m}' <<<"$criteria")
}

squash() { tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//'; }

# turn_words: the operator's prompts recorded this turn
# (bin/fm-jev-prompt-reminder.sh owns the record), oldest first, under one
# heading; nothing inside a task worker or when none is recorded.
turn_words() {
  [ -z "${FM_TASK_ID:-}" ] || return 0
  [ -s "$FM_HOME/state/jev-turn-words.jsonl" ] || return 0
  jq -Rrn '[inputs | fromjson? | select(type == "object" and (.prompt | type) == "string" and .prompt != "")]
    | if length == 0 then empty else
        "The operator'\''s words this turn, verbatim, oldest first:",
        (.[] | "Message at \(.ts // "an unrecorded time"):", .prompt)
      end' "$FM_HOME/state/jev-turn-words.jsonl" 2>/dev/null || true
}

# ctx_gap: uses cmd_ask's ctx. Prints what ends the context so far with one
# blank line, or nothing while it is empty.
ctx_gap() {
  [ -s "$ctx" ] || return 0
  if [ -z "$(tail -c 1 "$ctx")" ]; then printf '\n'; else printf '\n\n'; fi
}

# template_fill: uses cmd_ask's locals. Checks the template's fields and sets
# qtype, question, criteria, the rendered English state, and a default summary.
template_fill() {
  local f cand quoted
  [ -z "$qtype$question" ] && [ "$yes_no" = 0 ] && [ "$criteria" = '{}' ] \
    || die "--template sets the type, question, and options; drop --type, --question, --option, and --yes-no"
  case "$template" in
    claim-check)
      for f in claim source evidence; do
        f="tf_$f"; [ -n "${!f}" ] || die "--template claim-check needs --${f#tf_} ($(template_field_help "${f#tf_}"))"
      done
      case "${tf_claim}" in *$'\n'*) die "--claim must be one sentence on one line" ;; esac
      [[ ! ${tf_claim} =~ [.!?][[:space:]]+[[:upper:]] ]] || die "--claim must be one sentence"
      if [[ ! ${tf_source} =~ ^https?:// ]]; then
        [ -f "${tf_source}" ] && [ -r "${tf_source}" ] \
          || die "--source must be a URL or a readable file: ${tf_source}"
        quoted=$(squash < "${tf_source}")
        [[ $quoted == *"$(squash <<<"${tf_evidence}")"* ]] \
          || die "--evidence is not a verbatim quote of ${tf_source}; quote the text as read"
      fi
      evidence_sha=$(fm_jev_sha256 <(squash <<<"${tf_evidence}" | tr -d '\n'))
      qtype=claim-check
      question='Does the quoted evidence, read from the named source, support the claim?'
      add_option 'supported=The evidence states what the claim says.'
      add_option 'contradicted=The evidence states something the claim contradicts.'
      add_option 'not-addressed=The evidence does not settle the claim either way.'
      template_text=$(printf 'Claim: %s\nSource: %s\nEvidence, quoted verbatim from the source:\n%s\n' \
        "${tf_claim}" "${tf_source}" "${tf_evidence}")
      default_summary=$tf_claim
      ;;
    ticket-status)
      for f in ticket current proposed evidence; do
        f="tf_$f"; [ -n "${!f}" ] || die "--template ticket-status needs --${f#tf_} ($(template_field_help "${f#tf_}"))"
      done
      cand=$(printf '%s' "${tf_proposed}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]\{1,\}/-/g; s/^-//; s/-$//')
      [ -n "$cand" ] || die "--proposed has no letters or digits: ${tf_proposed}"
      [ "$cand" != keep-current ] || die "--proposed cannot be named keep-current"
      qtype=ticket-status
      question="Should ticket ${tf_ticket} move from ${tf_current} to ${tf_proposed}, given the evidence?"
      add_option "$cand=Change the status to ${tf_proposed}."
      add_option "keep-current=Keep the status at ${tf_current}."
      template_text=$(printf 'Ticket: %s\nCurrent status: %s\nProposed status: %s\nEvidence, quoted verbatim:\n%s\n' \
        "${tf_ticket}" "${tf_current}" "${tf_proposed}" "${tf_evidence}")
      default_summary="${tf_ticket} ${tf_current} -> ${tf_proposed}"
      ;;
    ask-scope)
      [ -n "$tf_words" ] || die "--template ask-scope needs --words ($(template_field_help words))"
      [ "${#candidates[@]}" -ge 1 ] || die "--template ask-scope needs at least one --candidate ($(template_field_help candidate))"
      template_text="The operator's words, verbatim:"$'\n'"${tf_words}"$'\n'"Candidate targets:"
      for cand in "${candidates[@]}"; do
        case "${cand%%=*}" in several|unclear) die "--candidate cannot be named ${cand%%=*}" ;; esac
        add_option "$cand"
        template_text="$template_text"$'\n'"- ${cand%%=*}: $(jq -r --arg s "${cand%%=*}" '.[$s]' <<<"$criteria")"
      done
      add_option 'several=The words cover more than one candidate.'
      add_option 'unclear=The words do not say which candidate they cover.'
      qtype=ask-scope
      question="Which candidate target do the operator's words cover?"
      default_summary="$(squash <<<"${tf_words}" | cut -c1-120)"
      ;;
    *) die "unknown --template: $template (claim-check, ticket-status, ask-scope)" ;;
  esac
}

template_field_help() {
  case "$1" in
    claim) printf 'the claim, one sentence' ;;
    source) printf 'the URL or file path the evidence was read from' ;;
    evidence) printf 'a verbatim quote read from that source in this turn' ;;
    ticket) printf 'the ticket id or URL' ;;
    current) printf 'the status the ticket shows now' ;;
    proposed) printf 'the status about to be written' ;;
    words) printf "the operator's words, verbatim" ;;
    candidate) printf 'a target the words could cover, as <id>[=<meaning>]' ;;
  esac
}

cmd_ask() {
  local qtype='' summary='' question='' context='' yes_no=0 mine='' have_mine=0 template='' target=''
  local criteria='{}' request resp='' options id='' http lat answer_ok prompt ctx sha start never
  local template_text='' default_summary='' evidence_sha='' f rules constraints_sent=false
  local tf_claim='' tf_source='' tf_evidence='' tf_ticket='' tf_current='' tf_proposed='' tf_words=''
  local have_words=0 src
  local -a candidates=() sources=() argv=("$@")
  start=$(fm_timing_now_ms)
  while [ $# -gt 0 ]; do
    case "$1" in
      --mine) [ $# -ge 2 ] || die "--mine needs a value"; mine=$2; have_mine=1; shift 2 ;;
      --type) [ $# -ge 2 ] || die "--type needs a value"; qtype=$2; shift 2 ;;
      --summary) [ $# -ge 2 ] || die "--summary needs a value"; summary=$2; shift 2 ;;
      --question) [ $# -ge 2 ] || die "--question needs a value"; question=$2; shift 2 ;;
      --context) [ $# -ge 2 ] || die "--context needs a value"; context=$2; shift 2 ;;
      --source) [ $# -ge 2 ] || die "--source needs a value"; sources+=("$2"); shift 2 ;;
      --template) [ $# -ge 2 ] || die "--template needs a value"; template=$2; shift 2 ;;
      --target) [ $# -ge 2 ] || die "--target needs a value"; target=$2; shift 2 ;;
      --claim|--evidence|--ticket|--current|--proposed|--words)
        [ $# -ge 2 ] || die "$1 needs a value"; printf -v "tf_${1#--}" '%s' "$2"; shift 2 ;;
      --candidate) [ $# -ge 2 ] || die "--candidate needs a value"; candidates+=("$2"); shift 2 ;;
      --yes-no) yes_no=1; shift ;;
      --option) [ $# -ge 2 ] || die "--option needs a value"; add_option "$2"; shift 2 ;;
      *) die "unknown ask argument: $1" ;;
    esac
  done
  # claim-check's one --source is its template field; everywhere else each
  # --source is a file sent verbatim.
  if [ "$template" = claim-check ]; then
    [ "${#sources[@]}" -le 1 ] || die "--template claim-check takes one --source"
    tf_source=${sources[0]:-}
    sources=()
  fi
  for src in ${sources[@]+"${sources[@]}"}; do
    [ -f "$src" ] && [ -r "$src" ] || die "--source must be a readable file: $src"
    [ -s "$src" ] || die "--source file is empty: $src"
  done
  if [ -n "$template" ]; then
    template_fill
    [ -n "$summary" ] || summary=$default_summary
  else
    [ -z "$tf_claim$tf_evidence$tf_ticket$tf_current$tf_proposed$tf_words" ] \
      && [ "${#candidates[@]}" = 0 ] || die "template fields need --template"
  fi
  if [ -n "$target" ]; then
    target=$(fm_jev_target_key "$target") || die "--target must be <kind>:<value>, such as notion:<page id>"
    [ "$have_mine" = 1 ] || die "--target needs --mine, firstmate's own choice"
  fi
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
  if [ "$have_mine" = 1 ]; then
    [ "$(jq -r --arg m "$mine" 'has($m)' <<<"$criteria")" = true ] \
      || die "--mine $mine is not one of $(jq -r 'keys_unsorted | join(", ")' <<<"$criteria")"
  fi
  [ -z "$(turn_words | head -c 1)" ] || have_words=1
  case " $MANUAL_TYPES " in
    *" $qtype "*)
      if [ "$have_words" = 0 ] && [ "${#sources[@]}" = 0 ]; then
        printf 'error: %s is asked by hand, and this ask carries neither the operator'\''s words for this turn nor a --source file, so Jev would see only firstmate'\''s own account; nothing was asked\n' "$qtype" >&2
        printf '  run: bin/fm-jev.sh ask' >&2
        printf ' %q' "${argv[@]}" >&2
        printf ' --source %s\n' "$SOURCE_PLACEHOLDER" >&2
        exit 2
      fi
      ;;
  esac

  if [ -z "$TYPESAFE_API_KEY_PRIVATE" ]; then
    TYPESAFE_API_KEY_PRIVATE=$(fmx_env_get TYPESAFE_API_KEY "$FM_HOME/.env")
  fi
  if [ -z "$TYPESAFE_API_KEY_PRIVATE" ]; then
    echo "jev: off (TYPESAFE_API_KEY absent from the environment and $FM_HOME/.env)" >&2
    ledger off
  fi
  if ! command -v curl >/dev/null 2>&1; then
    echo "jev: error (curl not installed)" >&2
    ledger off
  fi

  # One private copy of the context, so the bytes sent, hashed, and snapshotted
  # are the same even if the caller rewrites or deletes its file.
  ctx=$(mktemp) || die "mktemp failed"
  resp=$(mktemp) || { rm -f "$ctx"; die "mktemp failed"; }
  trap 'rm -f "$resp" "$ctx"' EXIT
  { [ -z "$template_text" ] || printf '%s\n' "$template_text"; } > "$ctx"
  if [ "$have_words" = 1 ]; then
    { ctx_gap; turn_words; } >> "$ctx"
  fi
  for src in ${sources[@]+"${sources[@]}"}; do
    { ctx_gap; printf 'Source %s, verbatim:\n' "$src"; cat "$src"; } >> "$ctx" 2>/dev/null \
      || die "--source file not readable: $src"
  done
  if [ -n "$context" ]; then
    { ctx_gap; printf "Firstmate's note, its own account rather than a source:\n"; cat "$context"; } >> "$ctx" 2>/dev/null \
      || die "context file not readable: $context"
  fi
  if rules=$(fm_jev_constraints "$qtype"); then
    { ctx_gap; printf '%s\n' "$rules"; } >> "$ctx" && constraints_sent=true
  fi
  sha=$(fm_jev_sha256 "$ctx")
  request=$(jq -n --rawfile context "$ctx" --arg model "$FM_JEV_MODEL" \
    --arg question "$question" --arg qkey "$QKEY" --argjson criteria "$criteria" '
    {model: $model, state: {context: $context},
     questions: {($qkey): {type: "choice", instructions: $question, criteria: $criteria}}}') \
    || die "could not build the request"
  options=$(jq -c 'keys_unsorted' <<<"$criteria")
  # The never-send list covers every string about to leave this machine, for
  # Jev and the duplicate queries alike.
  jq -r '.. | strings | gsub("\\s+"; " ")' <<<"$request" > "$resp" 2>/dev/null \
    || { echo "jev: off (could not extract the request text to check; nothing sent)" >&2; ledger off; }
  if never=$(fm_jev_never_send_line "$resp"); then
    echo "jev: off (context matches the never-send list line $never; nothing sent)" >&2
    ledger off
  elif [ $? = 2 ]; then
    echo "jev: off ($never; nothing sent)" >&2
    ledger off
  fi
  : > "$resp"
  prompt=$(jq -rn --rawfile context "$ctx" --arg question "$question" --argjson criteria "$criteria" '
    "Question: \($question)\n\nOptions (reply with one id):\n"
    + ([$criteria | to_entries[] | "- \(.key): \(.value)"] | join("\n"))
    + "\n\nContext:\n\($context)\n\nReply with exactly one option id from the list and nothing else."') \
    || die "could not build the duplicate prompt"
  id=$(fm_jev_new_id)
  if [ "$have_mine" = 1 ]; then
    fm_jev_append "$(jq -cn --arg id "$id" --arg mine "$mine" --arg ts "$(fm_jev_now_iso)" \
      '{v: 1, event: "mine", ts: $ts, decision_id: $id, mine: $mine, blind: true}')"
  fi
  fm_jev_post "$request" "$resp"
  http=$FM_JEV_HTTP lat=$FM_JEV_LAT_MS
  if [ "$http" != 200 ]; then
    settle error
    echo "jev: error (http $http after ${lat} ms)" >&2
    ledger error
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
    ledger error
  fi
  settle ok
  jq -r --arg id "$id" --arg qkey "$QKEY" --arg lat "$lat" --arg acting "$ACTING" --arg decider "$DECIDER" '
    def show($v): ($v // "-") | tostring | gsub("[\t\r\n]"; " ");
    .answers[$qkey] as $a |
    "jev:",
    "  decision_id: \($id)",
    "  answer: \($a.choice | show(.))   confidence: \($a.confidence)",
    "  probabilities: \([$a.probabilities | to_entries[] | "\(.key)=\(.value)"] | join(" "))",
    "  model: \(show(.model))   latency_ms: \($lat)   tokens: \(show(.usage.input_tokens))/\(show(.usage.output_tokens))",
    (if $acting == "" then empty else "  acting: \($acting)   decider: \($decider)" end)' "$resp" \
    || echo "jev: error (output rendering failed)" >&2
  [ "$have_mine" = 0 ] || warn_disagreement "$qtype" "$id" "$mine" \
    "$(jq -r --arg q "$QKEY" '.answers[$q].choice' "$resp")" "$(jq -r --arg q "$QKEY" '.answers[$q].confidence' "$resp")"
  ledger ok
}

# ledger <ok|error|off>: uses cmd_ask's locals. Appends the ask ledger line
# (bin/fm-jev-lib.sh) and ends the ask with exit 0.
ledger() {
  fm_jev_ask_record "$qtype" "$target" "$id" "$1" "$mine" "$resp" "$QKEY" "$evidence_sha"
  exit 0
}

# warn_disagreement <type> <decision-id> <mine> <jev-answer> <confidence>
warn_disagreement() {
  [ -n "$4" ] && [ "$4" != null ] && [ "$3" != "$4" ] || return 0
  echo "jev: WARNING: firstmate disagrees with Jev on $1 $2: jev $4 ($5), firstmate $3" >&2
}

# settle <ok|error>: uses cmd_ask's locals. Records the call, writes the audit
# snapshot, records the decision when a blind choice was given, then detaches
# the issuing-request lookup, the label event, and the duplicate queries, each
# followed by its model's Datadog decision event (claude_status error when no
# duplicate was recorded).
ACTING='' DECIDER=''
settle() {
  local floor='' listed=false conf answer
  fm_jev_record_call "$id" "$qtype" "$summary" "$options" "$QKEY" "$1" "$lat" "$resp" "$sha" "$constraints_sent"
  fm_jev_write_audit "$id" "$qtype" "$question" "$criteria" "$ctx" "$sha" "$request" "$resp"
  audit_add "$id" claude_system_prompt <(printf '%s' "$CLAUDE_SYSTEM_PROMPT")
  audit_add "$id" claude_prompt <(printf '%s' "$prompt")
  if [ "$have_mine" = 1 ]; then
    ACTING=$mine DECIDER=firstmate
    floor=$(authority_floor "$qtype")
    if [ -n "$floor" ]; then
      listed=true
      if [ "$1" = ok ]; then
        answer=$(jq -r --arg q "$QKEY" '.answers[$q].choice' "$resp")
        conf=$(jq -r --arg q "$QKEY" '.answers[$q].confidence' "$resp")
        if jq -en --argjson c "$conf" --argjson f "$floor" '$c >= $f' >/dev/null; then
          ACTING=$answer DECIDER=jev
        fi
      fi
    fi
    fm_jev_append "$(jq -cn --arg id "$id" --arg ts "$(fm_jev_now_iso)" --arg d "$DECIDER" --arg a "$ACTING" \
      --argjson listed "$listed" --arg floor "$floor" '
      {v: 1, event: "decided", ts: $ts, decision_id: $id, decider: $d, acting: $a, listed: $listed,
       floor: (if $floor == "" then null else ($floor | tonumber) end)}')"
  fi
  fm_jev_detach duplicate_then_event "$id" "$prompt" "$options" "$have_mine"
}

duplicate_then_event() {  # <decision-id> <prompt> <options-json> <label: 0|1>
  local model
  fm_jev_request_cost "$1" "$qtype" "$start" "${FM_JEV_ISSUER:-fm-jev.sh}"
  [ "$4" != 1 ] || fm_jev_dd_send "$(fm_jev_label_event "$(show_one "$1")")" "$1"
  for model in $FM_JEV_CLAUDE_MODELS; do
    duplicate_claude "$1" "$model" "$2" "$3"
    fm_jev_dd_send "$(fm_jev_decision_event "$(show_one "$1" "$model")" error "$model")" "$1"
  done
}

cmd_record_mine() {
  [ $# -eq 2 ] || die "record-mine needs <decision-id> <answer>"
  local id answer=$2 call
  id=$(resolve_id "$1")
  call=$(show_one "$id")
  [ "$(jq -r --arg a "$answer" '.options | index($a) != null' <<<"$call")" = true ] \
    || die "answer $answer is not one of $(jq -r '.options | join(", ")' <<<"$call")"
  [ "$(jq -r '.blind' <<<"$call")" != true ] \
    || die "decision $id already carries firstmate's blind choice $(jq -r .mine <<<"$call"); record a later correction with record-outcome"
  fm_jev_append "$(jq -cn --arg id "$id" --arg mine "$answer" --arg ts "$(fm_jev_now_iso)" \
    '{v: 1, event: "mine", ts: $ts, decision_id: $id, mine: $mine}')"
  call=$(show_one "$id")
  fm_jev_dd_send "$(fm_jev_label_event "$call")" "$id"
  jq -r '"jev: recorded \(.decision_id) mine=\(.mine) jev=\(.answer // "none") \(.decision)"' <<<"$call"
  warn_disagreement "$(jq -r .question_type <<<"$call")" "$id" "$answer" \
    "$(jq -r '.answer // empty' <<<"$call")" "$(jq -r '.confidence // "-"' <<<"$call")"
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
  fm_jev_dd_send "$(fm_jev_label_event "$joined")" "$id"
  jq -r '"jev: recorded outcome for \(.decision_id) final=\(.final // "none") jev=\(.answer // "none") \(.decision // "undecided") decider=\(.decider // "none") \(.graded // "ungraded")"' <<<"$joined"
}

cmd_acting() {
  [ $# -eq 1 ] || die "acting needs <decision-id>"
  local id joined
  id=$(resolve_id "$1")
  joined=$(show_one "$id")
  [ "$(jq -r '.acting // empty' <<<"$joined")" != '' ] || die "decision $id carries no firstmate choice"
  jq -r '"\(.acting) \(.decider)"' <<<"$joined"
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
  local since='' floor=$REPORT_FLOOR sample='' min_answered=$GRAD_MIN_ANSWERED
  local min_agreement=$GRAD_MIN_AGREEMENT max_overruled=$GRAD_MAX_OVERRULED
  while [ $# -gt 0 ]; do
    case "$1" in
      --since) [ $# -ge 2 ] || die "--since needs a value"; since=$2; shift 2 ;;
      --floor) [ $# -ge 2 ] || die "--floor needs a value"; floor=$2; shift 2 ;;
      --audit-sample) [ $# -ge 2 ] || die "--audit-sample needs a value"; sample=$2; shift 2 ;;
      --min-answered) [ $# -ge 2 ] || die "--min-answered needs a value"; min_answered=$2; shift 2 ;;
      --min-agreement) [ $# -ge 2 ] || die "--min-agreement needs a value"; min_agreement=$2; shift 2 ;;
      --max-overruled) [ $# -ge 2 ] || die "--max-overruled needs a value"; max_overruled=$2; shift 2 ;;
      *) die "unknown report argument: $1" ;;
    esac
  done
  if [ -n "$since" ]; then
    [[ $since =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)?$ ]] \
      || die "--since must be YYYY-MM-DD or YYYY-MM-DDTHH:MM:SSZ"
  fi
  [[ $floor =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]] || die "--floor must be a number from 0 through 1"
  [[ $min_agreement =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]] || die "--min-agreement must be a number from 0 through 1"
  [[ $min_answered =~ ^[0-9]+$ ]] || die "--min-answered must be a whole number"
  [[ $max_overruled =~ ^[0-9]+$ ]] || die "--max-overruled must be a whole number"
  [ -z "$sample" ] || [[ $sample =~ ^[0-9]+$ ]] || die "--audit-sample must be a whole number"
  report_text "$since" "$floor" "$min_answered" "$min_agreement" "$max_overruled"
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

report_text() {  # <since> <floor> <min-answered> <min-agreement> <max-overruled>
  local since=$1 floor=$2 auth
  auth=$(authority_map)
  records | jq -rs --arg since "$since" --argjson floor "$floor" --argjson auth "$auth" \
    --argjson min_answered "$3" --argjson min_agreement "$4" --argjson max_overruled "$5" \
    --arg opus "$PRICE_OPUS" --arg sonnet "$PRICE_SONNET" --arg haiku "$PRICE_HAIKU" \
    --argjson haiku_max "$HAIKU_CONTEXT_MAX" "$JOIN_JQ"'
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
    def n($v): if ($v | type) == "number" then $v else 0 end;
    def rates($s): $s | split(" ") | map(tonumber);
    def price($r; $rate): (n($r.request_input_tokens) * $rate[0]
      + (n($r.request_cache_creation_input_tokens) - n($r.request_cache_creation_1h_input_tokens)) * $rate[0] * 1.25
      + n($r.request_cache_creation_1h_input_tokens) * $rate[0] * 2
      + n($r.request_cache_read_input_tokens) * $rate[0] * 0.1
      + n($r.request_output_tokens) * $rate[1]) / 1000000;
    def upper($rows):
      [$rows[] | select(.request_status == "ok")] as $m |
      ([$m[] | .jev_cost_usd | numbers] | add // 0) as $jev |
      def susd($x): if $x < 0 then "-" + usd(- $x) else usd($x) end;
      def net($rate): susd(([$m[] | price(.; rates($rate))] | add // 0) - $jev);
      "  upper bound: issuing requests matched \($m | length)/\($rows | length)"
      + (if ($m | length) == 0 then ""
         else "   opus \(net($opus)) after jev \(usd($jev))   assumption: sonnet \(net($sonnet)), haiku "
           + (if any($m[]; n(.request_input_tokens) + n(.request_cache_creation_input_tokens)
                          + n(.request_cache_read_input_tokens) > $haiku_max)
              then "invalid (context over \($haiku_max))" else net($haiku) end) end);
    def decisions($rows; $type):
      ($auth[$type] // null) as $listed |
      ($listed // $floor) as $gf |
      [$rows[] | select(.status == "ok")] as $ok |
      [$ok[] | select(.blind and .confidence >= $gf)] as $conf |
      [$ok[] | select(.confidence >= $gf and .outcome != null and .final != .answer)] as $conf_over |
      ($conf | length) as $cn | ([$conf[] | select(.answer == .mine)] | length) as $ca |
      [$rows[] | select(.decider == "jev")] as $dj |
      [$rows[] | select(.decider == "firstmate")] as $df |
      [$rows[] | select(.listed) | {ts, model} | select(.model != null)] as $lm |
      ([$lm | sort_by(.ts)[] | .model] | reduce .[] as $x ([]; if length > 0 and last == $x then . else . + [$x] end)) as $models |
      "  decider: jev \($dj | length)   firstmate \($df | length)   overruled: jev \([$dj[] | select(.graded == "overruled")] | length)   firstmate \([$df[] | select(.graded == "overruled")] | length)",
      "  authority: \(if $listed == null then "not listed" else "listed at floor \($listed)" end)",
      (if ($models | length) > 1 then "  flag: jev model changed while listed (\($models | join(" -> ")))" else empty end),
      upper($rows),
      "  graduation: \(if ($ok | length) >= $min_answered and $cn > 0 and ($ca / $cn) >= $min_agreement and ($conf_over | length) <= $max_overruled then "ready" else "not ready" end)   answered \($ok | length) (>= \($min_answered))   confident (>= \($gf)) blind agreement \(ratio($ca; $cn)) (>= \(($min_agreement * 1000 | round) / 10)%)   confident jev overruled \($conf_over | length) (<= \($max_overruled))";
    [joined[] | select($since == "" or .ts >= $since)] as $all |
    "jev report (since \(if $since == "" then "all records" else $since end), floor \($floor))",
    if ($all | length) == 0 then "no recorded calls"
    else
      (($all | group_by(.question_type))[] | (first.question_type), stats(.), decisions(.; first.question_type)),
      "all types", stats($all), upper($all)
    end'
}

# ledger_rows: every ask ledger line as one JSON array.
ledger_rows() {
  local path
  path=$(fm_jev_ask_ledger_path)
  if [ -f "$path" ]; then
    jq -cR 'try fromjson catch empty | select(type == "object")' "$path" | jq -cs .
  else
    printf '[]'
  fi
}

cmd_asked() {
  local types='' statuses=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --type) [ $# -ge 2 ] || die "--type needs a value"; types=$2; shift 2 ;;
      --status) [ $# -ge 2 ] || die "--status needs a value"; statuses=$2; shift 2 ;;
      *) die "unknown asked argument: $1" ;;
    esac
  done
  [ -n "$types" ] || die "asked needs --type"
  ledger_rows | jq -ce --arg types "$types" --arg st "$statuses" --argjson w "$ASK_WINDOW_SECS" '
    ((now - $w) | todate) as $since | ($types | split(",")) as $t |
    [.[] | select(.ts >= $since and (.question_type as $q | $t | index($q)) != null
      and ($st == "" or (.status as $s | $st | split(",") | index($s)) != null))] | last // empty' \
    || exit 1
}

# claim_floor: the operator's claim-check floor, else CLAIM_FLOOR.
claim_floor() {
  local path="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/jev-claim-check-floor" v=''
  [ ! -f "$path" ] || v=$(tr -d '[:space:]' < "$path")
  if [ -z "$v" ]; then printf '%s' "$CLAIM_FLOOR"
  elif [[ $v =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]]; then printf '%s' "$v"
  else echo "jev: $path is not a number from 0 through 1; using $CLAIM_FLOOR" >&2; printf '%s' "$CLAIM_FLOOR"
  fi
}

cmd_target_status() {
  local target='' require='' key outcomes
  while [ $# -gt 0 ]; do
    case "$1" in
      --target) [ $# -ge 2 ] || die "--target needs a value"; target=$2; shift 2 ;;
      --require) [ $# -ge 2 ] || die "--require needs a value"; require=$2; shift 2 ;;
      *) die "unknown target-status argument: $1" ;;
    esac
  done
  case "$require" in claim-check|template) ;; *) die "--require must be claim-check or template" ;; esac
  key=$(fm_jev_target_key "$target") || die "--target must be <kind>:<value>"
  outcomes=$(records | jq -cs '[.[] | select(.event == "outcome") | .decision_id] | unique')
  ledger_rows | jq -r --arg t "$key" --arg req "$require" --argjson floor "$(claim_floor)" \
    --argjson w "$ASK_WINDOW_SECS" --argjson outcomes "$outcomes" '
    ((now - $w) | todate) as $since |
    [.[] | select(.target == $t)] as $rows |
    [$rows[] | select(.question_type == "claim-check")] as $cc |
    def against: .answer == "contradicted" or .answer == "not-addressed";
    def verdict($word): "\($word) \(.decision_id) \(.answer) \(.confidence)";
    [range(0; $cc | length) as $i | $cc[$i] |
      select(.status == "ok" and against and .confidence >= $floor
        and ((.decision_id as $d | $outcomes | index($d)) == null)) |
      . as $b |
      select([$cc[($i + 1):][] | select(.answer == "supported" and .evidence_sha256 != $b.evidence_sha256)]
        | length == 0)] as $open |
    [$rows[] | select(.ts >= $since and
      (if $req == "claim-check" then .question_type == "claim-check"
       else (.question_type | IN("claim-check", "ticket-status", "ask-scope")) end))] as $recent |
    ([$recent[] | select(.question_type == "claim-check")] | last) as $last |
    if ($open | length) > 0 then $open | last | verdict("blocked")
    elif ($recent | length) == 0 then "missing"
    elif $last != null and $last.status == "ok" and ($last | against)
      and ((($last.decision_id) as $d | $outcomes | index($d)) == null) then $last | verdict("warn")
    else "ok" end'
}

cmd_turn() {
  local since=''
  [ $# -eq 2 ] && [ "$1" = --since ] || die "turn needs --since <ISO-8601 UTC time>"
  since=$2
  [[ $since =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\.[0-9]+)?Z$ ]] \
    || die "--since must be an ISO-8601 UTC time such as 2026-09-29T03:11:06Z"
  since="${BASH_REMATCH[1]}Z"
  records | jq -rs --arg since "$since" "$JOIN_JQ"'
    def show($v): ($v // "-") | tostring | gsub("[\t\r\n]"; " ");
    [joined[] | select(.ts >= $since)] as $all |
    ([$all[] | select(.question_type == "dispatch-rule" and .context_sha256 != null)]
      | group_by(.context_sha256) | map(([.[] | select(.mine != null)] | last) // (sort_by(.ts) | last))) as $dr |
    ([$all[] | select(.question_type != "dispatch-rule" or .context_sha256 == null)] + $dr | sort_by(.ts)) as $rows |
    "Jev asks this turn (\($rows | length))",
    if ($rows | length) == 0 then "none" else
      ($rows[] |
        "\(.asker // "firstmate") \(.question_type): \(show(.summary)) - jev "
        + (if .status == "ok" then "\(.answer) (\(.confidence))" else "error (-)" end)
        + ", mine \(.mine // "unrecorded")"
        + (if .answer != null and .mine != null and .answer != .mine then " [DISAGREE]" else "" end))
    end'
}

cmd_dd_failures() {
  local mode=${1:-} path acked_path total acked n
  [ $# -le 1 ] || die "dd-failures takes at most one of --quiet or --ack"
  case "$mode" in ''|--quiet|--ack) ;; *) die "dd-failures takes --quiet or --ack" ;; esac
  path=$(fm_jev_dd_failures_path)
  acked_path="${path%.jsonl}.acked"
  total=0
  [ ! -f "$path" ] || total=$(grep -c . "$path")
  acked=$(cat "$acked_path" 2>/dev/null) || acked=0
  [[ $acked =~ ^[0-9]+$ ]] && [ "$acked" -le "$total" ] || acked=0
  n=$((total - acked))
  if [ "$mode" = --ack ]; then
    printf '%s\n' "$total" > "$acked_path" || die "could not write $acked_path"
    echo "jev: acknowledged $n datadog failure(s)"
    return 0
  fi
  if [ "$n" -eq 0 ]; then
    [ "$mode" = --quiet ] || echo "jev datadog failures: 0 unacknowledged"
    return 0
  fi
  tail -n "$n" "$path" | jq -rs --argjson n "$n" '
    def line($r): "\($r.reason) for \($r.decision_id // "an unknown decision") at \($r.ts)";
    "jev datadog failures: \($n) unacknowledged (first: \(line(first)); last: \(line(last))); acknowledge with bin/fm-jev.sh dd-failures --ack"'
}

command -v jq >/dev/null 2>&1 || die "jq required"
[ $# -gt 0 ] || { usage; exit 2; }
sub=$1; shift
case "$sub" in
  ask) cmd_ask "$@" ;;
  acting) cmd_acting "$@" ;;
  record-mine) cmd_record_mine "$@" ;;
  record-outcome) cmd_record_outcome "$@" ;;
  show) cmd_show "$@" ;;
  report) cmd_report "$@" ;;
  dd-failures) cmd_dd_failures "$@" ;;
  asked) cmd_asked "$@" ;;
  turn) cmd_turn "$@" ;;
  target-status) cmd_target_status "$@" ;;
  -h|--help) usage ;;
  *) die "unknown subcommand: $sub (see --help)" ;;
esac
