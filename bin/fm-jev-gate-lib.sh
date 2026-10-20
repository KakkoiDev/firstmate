# shellcheck shell=bash
# fm-jev-gate-lib.sh - the Jev decision asks embedded in the action scripts.
# Usage: . bin/fm-jev-gate-lib.sh   (after FM_HOME and SCRIPT_DIR are set)
#
# Sourced by bin/fm-spawn.sh, bin/fm-send.sh, bin/fm-teardown.sh,
# bin/fm-pr-merge.sh, bin/fm-merge-local.sh, and bin/fm-control.sh. This file
# owns the question wording, options, and context of every script-embedded
# ask and the refusal a missing decision argument prints; bin/fm-jev.sh owns
# the ask, the blind-choice record, the acting answer, and grading.
#
# Contract for each gated action:
#   - firstmate's choice arrives as an explicit argument: a value the script
#     asks with, or, for a choice made before the script runs, the decision id
#     `bin/fm-jev.sh ask ... --mine <choice>` printed ("off" when it printed
#     nothing because Jev was off or failed, accepted only when the ask ledger
#     holds an ask of that type from the last 30 minutes that found Jev off or
#     failing: `bin/fm-jev.sh asked`);
#   - a missing argument refuses with exit 2 and names the exact argument or
#     the exact bin/fm-jev.sh command to run;
#   - the script asks with its choice as --mine, so the choice is recorded
#     before Jev's answer is read, prints the decision id on stderr, and acts
#     on the acting answer (Jev's only for a type the operator listed in the
#     authority file, at or above its floor);
#   - Jev off or failing records nothing and never blocks: the explicit choice
#     acts.
#
# FM_JEV_GATE=off disables every gate, so no argument is required and nothing
#   is asked. The test suite exports it; internal callers that cross an action
#   boundary pass explicit values instead.
# Every option goes out as id=meaning, so Jev reads what each id stands for;
#   the meanings live in fm_jev_gate_option_lines next to the choice lists.
# The context a script builds is whole: the extra texts come first, then the
#   brief's task sections. It reaches bin/fm-jev.sh as a --source file, after
#   the operator's words for the turn that bin/fm-jev.sh adds itself.

# shellcheck source=bin/fm-brief-heading-lib.sh
declare -F fm_brief_task_heading_body >/dev/null || . "$SCRIPT_DIR/fm-brief-heading-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
declare -F secondmate_registry_parse_line >/dev/null || . "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
declare -F fm_task_inbox_unhandled_count >/dev/null || . "$SCRIPT_DIR/fm-task-inbox-lib.sh"

FM_JEV_GATE_ID='' FM_JEV_GATE_ACTING='' FM_JEV_GATE_DECIDER=''

fm_jev_gate_enabled() {
  [ "${FM_JEV_GATE:-on}" != off ]
}

# Question wording per type.
fm_jev_gate_question() {  # <type>
  case "$1" in
    project-match) printf 'Which registered project is this request about?' ;;
    deliverable-class) printf 'Should this message ship a change, scout for knowledge, be answered from a finished worker report or text the captain supplied, steer a worker already on it, or only be acknowledged?' ;;
    secondmate-scope) printf 'Which persistent secondmate scope fits this work?' ;;
    surface-class) printf "Is this task's surface internal-only, product-facing, mixed, or uncertain?" ;;
    concurrency) printf 'Can this task run in parallel with work under way, or what blocks it?' ;;
    effort-level) printf 'Which reasoning effort fits this task?' ;;
    mid-task-ask) printf 'Does this mid-task ask invalidate the work under way, or is it a follow-up or downstream correction?' ;;
    report-has-captain-call) printf 'Does this report contain a call only the human operator can make?' ;;
    scout-recommends-ship) printf 'Does this scout report recommend shippable work?' ;;
    merge-risk) printf 'Is this merge destructive, irreversible, or security-sensitive?' ;;
    stuck-worker) printf 'Which state best describes this worker?' ;;
    *) return 1 ;;
  esac
}

# Options per type as "id=meaning" lines, one per option; project-match and
# secondmate-scope read the live registries. Each meaning is one line.
# effort-level is asked only for a ship or scout spawn, so it offers no xhigh,
# max, or ultra: bin/fm-spawn.sh refuses those levels for a worker.
# stuck-worker names every state firstmate itself distinguishes, from:
#   working, parked, blocked, paused, done, failed, unknown - the states
#     bin/fm-crew-state.sh reports; parked is its needs-decision or
#     awaiting-approval gate, paused the declared-wait verb of
#     bin/fm-classify-lib.sh;
#   held-for-captain - bin/fm-classify-lib.sh's captain-held verb;
#   waiting-on-prompt - the interactive launch prompt fm_busy_launch_prompt_parked
#     in bin/fm-busy-lib.sh recognizes; that detector covers trust, sign-in, and
#     import dialogs only, and no code detects a mid-run tool permission prompt,
#     so the choice is read from the screen tail the ask carries;
#   unread-instructions - an unhandled record in the task's steering inbox
#     (bin/fm-task-inbox-lib.sh);
#   endpoint-gone - the recorded endpoint or its agent is gone, the positive
#     death evidence bin/fm-crew-state.sh reports.
# The first six ids predate the rest and stay valid for recorded decisions.
fm_jev_gate_option_lines() {  # <type>
  local id
  case "$1" in
    project-match)
      while IFS= read -r id; do
        [ -z "$id" ] || printf '%s=The request is about the registered project %s.\n' "$id" "$id"
      done < <(fm_jev_gate_projects)
      printf 'none=No registered project fits the request.\nseveral=More than one registered project fits the request.\n'
      ;;
    deliverable-class)
      printf '%s\n' \
        'ship=A project change delivered through the selected delivery mode.' \
        'scout=Knowledge delivered as a report, with no project change.' \
        'answer-from-evidence=Answerable from a finished worker report or text the captain supplied, with no fresh read.' \
        'steer-existing=A steer, answer, or correction for a worker already on this work, so no new worker is dispatched.' \
        'acknowledge=An acknowledgement, or a question about work under way answered from firstmate'"'"'s own records, so no work is dispatched.'
      ;;
    secondmate-scope)
      while IFS= read -r id; do
        [ -z "$id" ] || printf '%s=Route the work to the persistent secondmate %s.\n' "$id" "$id"
      done < <(fm_jev_gate_secondmates)
      printf 'main=No secondmate scope fits, so the main home takes the work.\n'
      ;;
    surface-class)
      printf '%s\n' \
        'internal-only=Internal tooling, automation, contributor or operator process, or release work.' \
        'product-facing=A change the product shows its users.' \
        'mixed=Touches both internal and product-facing surface.' \
        'uncertain=The evidence does not settle the surface.'
      ;;
    concurrency)
      printf '%s\n' \
        'parallel=Independent of work under way, so it can run now beside it.' \
        'semantic-dependency=Needs the result of work under way before it can start.' \
        'shared-external-state=Mutates external state that work under way also uses.' \
        'migration-conflict=Conflicts with a migration running concurrently.'
      ;;
    effort-level)
      printf '%s\n' \
        'low=Well-understood explicit work with nothing left to decide.' \
        'medium=Ship work: implementing a change whose scope its instructions already set.' \
        'high=Ambiguous investigation or design, where the work must find out what to build.' \
        'default=No explicit effort; the harness default applies.'
      ;;
    mid-task-ask)
      printf '%s\n' \
        'invalidates=The ask makes the work under way wrong or moot, so it must restart or be rescoped.' \
        'follow-up=The ask adds new work and leaves the work under way valid.' \
        'downstream-correction=The ask corrects text or evidence to match behavior already accepted; the work under way stands.'
      ;;
    report-has-captain-call)
      printf 'yes=The report holds a call only the human operator can make.\nno=The report holds no call reserved for the human operator.\n'
      ;;
    scout-recommends-ship)
      printf 'yes=The scout report recommends shippable work.\nno=The scout report recommends no shippable work.\n'
      ;;
    merge-risk)
      printf 'yes=The merge is destructive, irreversible, or security-sensitive.\nno=The merge is none of destructive, irreversible, or security-sensitive.\n'
      ;;
    stuck-worker)
      printf '%s\n' \
        'working=The worker is making progress: its harness is busy or a validation step is running.' \
        'idle-done=The worker finished its task and sits idle.' \
        'waiting-on-answered-question=The worker is idle on a question its instructions or a steer already answered.' \
        'looping=The worker repeats one failed step.' \
        'confused=The worker misreads its task or works on the wrong thing.' \
        'unresponsive=The worker is alive but does not react to steers.' \
        'parked-at-decision=The worker is stopped at an open needs-decision or a validation gate awaiting approval.' \
        'blocked=The worker declared it is blocked and needs help.' \
        'paused-declared-wait=The worker declared a wait expected to clear on its own.' \
        'failed=The worker or its validation run ended in failure.' \
        'waiting-on-prompt=The worker is stopped at an interactive prompt, such as a trust, sign-in, or permission dialog, that needs a human key press.' \
        'unread-instructions=The worker has instructions waiting unread in its steering inbox.' \
        'held-for-captain=The task is held for the captain, so an idle worker is expected.' \
        'endpoint-gone=The worker endpoint or its agent process is gone.' \
        'state-unknown=No current-state source answers, so the state cannot be told.'
      ;;
    *) return 1 ;;
  esac
}

# Options per type, one id per line.
fm_jev_gate_options() {  # <type>
  fm_jev_gate_option_lines "$1" | sed 's/=.*//'
}

# Registered project names from data/projects.md: the text after "- " up to
# the first " [" or " - ".
fm_jev_gate_projects() {
  local reg="${FM_DATA_OVERRIDE:-$FM_HOME/data}/projects.md"
  [ -f "$reg" ] || return 0
  awk 'substr($0, 1, 2) == "- " {
    n = substr($0, 3); i = index(n, " ["); j = index(n, " - ")
    if (i && (!j || i < j)) n = substr(n, 1, i - 1); else if (j) n = substr(n, 1, j - 1)
    if (n != "") print n }' "$reg"
}

# Registered secondmate ids from data/secondmates.md.
fm_jev_gate_secondmates() {
  local reg="${FM_DATA_OVERRIDE:-$FM_HOME/data}/secondmates.md" line
  [ -f "$reg" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    secondmate_registry_parse_line "$line" && printf '%s\n' "$SECONDMATE_REGISTRY_ID"
  done < "$reg"
  return 0
}

fm_jev_gate_option_args() {  # <type>: prints the fm-jev.sh option arguments, one per line
  local line
  while IFS= read -r line; do
    [ -z "$line" ] || printf -- '--option\n%s\n' "$line"
  done < <(fm_jev_gate_option_lines "$1")
}

fm_jev_gate_is_option() {  # <type> <value>
  local opt
  while IFS= read -r opt; do
    [ "$opt" != "$2" ] || return 0
  done < <(fm_jev_gate_options "$1")
  return 1
}

fm_jev_gate_choices() {  # <type>: the option ids as one "a|b|c" string
  fm_jev_gate_options "$1" | paste -sd'|' -
}

# fm_jev_gate_context <out-file> <brief-or-report> [<label> <file>]...
# Writes each labelled extra text, then the brief's `# Task` sections (the
# whole file when it has none).
fm_jev_gate_context() {
  local out=$1 brief=$2 heading sections=''
  shift 2
  {
    while [ $# -ge 2 ]; do
      printf '%s:\n' "$1"
      cat "$2" 2>/dev/null || true
      printf '\n\n'
      shift 2
    done
    if [ -f "$brief" ]; then
      for heading in "## Captain's intent" "## Firstmate spec"; do
        fm_brief_task_heading_present "$brief" "$heading" || continue
        sections="$sections$heading"$'\n'"$(fm_brief_task_heading_body "$brief" "$heading")"$'\n\n'
      done
      if [ -n "$sections" ]; then printf '%s' "$sections"; else cat "$brief"; fi
    fi
  } > "$out"
}

# fm_jev_gate_live_state <out-file> <task-id> <state-dir>
# Writes the worker's state as read now: bin/fm-crew-state.sh's line, the
# unread steering-inbox count, and the tail of the endpoint screen, each
# labelled, so a stale status line cannot outweigh them. A part that cannot be
# read says so instead of being left out.
fm_jev_gate_live_state() {
  local out=$1 id=$2 state=$3 line unread tail_lines=${FM_JEV_GATE_SCREEN_TAIL_LINES:-25} screen=''
  line=$(FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$state "$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>&1 | head -n 3) || line=''
  [ -n "$line" ] || line='state: unknown · source: none · fm-crew-state.sh printed nothing'
  unread=$(fm_task_inbox_unhandled_count "$state" "$id")
  if fm_backend_validate_task_endpoint "$state/$id.meta" "$id" >/dev/null 2>&1; then
    screen=$(fm_backend_capture "$FM_BACKEND_VALIDATED_BACKEND" "$FM_BACKEND_VALIDATED_TARGET" "$tail_lines" "fm-$id" 2>/dev/null) || screen=''
  fi
  {
    printf 'Read just now; it outranks every status line below, which is an event log and can be stale:\n%s\n\n' "$line"
    printf 'Unread steering-inbox messages for this worker, read just now: %s\n\n' "$unread"
    printf 'Endpoint screen tail, last %s lines, read just now:\n' "$tail_lines"
    if [ -n "$screen" ]; then printf '%s\n' "$screen"; else printf '(the endpoint screen could not be read)\n'; fi
  } > "$out"
}

# The exact command firstmate runs for a choice asked before the script.
fm_jev_gate_ask_command() {  # <type>
  local cmd opt
  cmd="bin/fm-jev.sh ask --type $1 --summary \"<one line naming the request>\" --question \"$(fm_jev_gate_question "$1")\""
  while IFS= read -r opt; do
    [ -n "$opt" ] || continue
    cmd="$cmd --option $(printf '%q' "$opt")"
  done < <(fm_jev_gate_option_lines "$1")
  printf '%s --source <file holding the raw evidence: status lines, brief, report, or script output> --mine <your choice>' "$cmd"
}

fm_jev_gate_refuse() {  # <issuer> <message> [<command>]
  printf '%s: refused: %s\n' "$1" "$2" >&2
  [ $# -lt 3 ] || printf '  run: %s\n' "$3" >&2
  exit 2
}

# fm_jev_gate_ask <issuer> <type> <mine> <summary> <context-file>
# Asks with firstmate's choice as --mine and sets FM_JEV_GATE_ID (empty when
# Jev was off or failed), FM_JEV_GATE_ACTING, and FM_JEV_GATE_DECIDER.
fm_jev_gate_ask() {
  local issuer=$1 qtype=$2 mine=$3 summary=$4 ctx=$5 out opt opts=()
  FM_JEV_GATE_ID='' FM_JEV_GATE_ACTING=$mine FM_JEV_GATE_DECIDER=firstmate
  while IFS= read -r opt; do opts+=("$opt"); done < <(fm_jev_gate_option_args "$qtype")
  [ ! -s "$ctx" ] || opts+=(--source "$ctx")
  out=$(FM_HOME=$FM_HOME FM_JEV_ISSUER=$issuer "$SCRIPT_DIR/fm-jev.sh" ask --type "$qtype" --summary "$summary" \
    --question "$(fm_jev_gate_question "$qtype")" "${opts[@]}" --mine "$mine") || out=''
  FM_JEV_GATE_ID=$(sed -n 's/^  decision_id: //p' <<<"$out")
  if [ -n "$FM_JEV_GATE_ID" ]; then
    FM_JEV_GATE_ACTING=$(sed -n 's/^  acting: \([^ ]*\) .*/\1/p' <<<"$out")
    FM_JEV_GATE_DECIDER=$(sed -n 's/.*   decider: //p' <<<"$out")
    [ -n "$FM_JEV_GATE_ACTING" ] || FM_JEV_GATE_ACTING=$mine FM_JEV_GATE_DECIDER=firstmate
    printf '%s: jev %s decision %s: %s acts (decided by %s)\n' "$issuer" "$qtype" "$FM_JEV_GATE_ID" \
      "$FM_JEV_GATE_ACTING" "$FM_JEV_GATE_DECIDER" >&2
  else
    printf '%s: jev %s not recorded (off or failed); %s acts\n' "$issuer" "$qtype" "$mine" >&2
  fi
}

# fm_jev_gate_recorded <issuer> <type> <decision-id|off>
# Validates a decision asked before the script and sets the same variables;
# "off" means the ask printed nothing, so FM_JEV_GATE_ACTING stays empty and
# the caller's own evidence acts, and it is refused unless that ask is in the
# ask ledger.
fm_jev_gate_recorded() {
  local issuer=$1 qtype=$2 id=$3 row rtype
  FM_JEV_GATE_ID='' FM_JEV_GATE_ACTING='' FM_JEV_GATE_DECIDER=''
  if [ "$id" = off ]; then
    FM_HOME=$FM_HOME "$SCRIPT_DIR/fm-jev.sh" asked --type "$qtype" --status off,error >/dev/null 2>&1 \
      || fm_jev_gate_refuse "$issuer" \
        "$qtype=off needs a $qtype ask from the last 30 minutes that found Jev off or failing, and none is recorded; ask first" \
        "$(fm_jev_gate_ask_command "$qtype")"
    printf '%s: jev %s not recorded (off or failed)\n' "$issuer" "$qtype" >&2
    return 0
  fi
  row=$(FM_HOME=$FM_HOME "$SCRIPT_DIR/fm-jev.sh" show "$id" 2>/dev/null \
    | jq -r '.record | [.question_type // "", .acting // "", .decider // ""] | @tsv' 2>/dev/null) || row=''
  IFS=$'\t' read -r rtype FM_JEV_GATE_ACTING FM_JEV_GATE_DECIDER <<<"$row"
  [ "$rtype" = "$qtype" ] || fm_jev_gate_refuse "$issuer" \
    "decision $id is not a recorded $qtype decision" "$(fm_jev_gate_ask_command "$qtype")"
  [ -n "$FM_JEV_GATE_ACTING" ] || fm_jev_gate_refuse "$issuer" \
    "decision $id carries no firstmate choice; ask with --mine" "$(fm_jev_gate_ask_command "$qtype")"
  FM_JEV_GATE_ID=$id
  printf '%s: jev %s decision %s: %s acts (decided by %s)\n' "$issuer" "$qtype" "$id" \
    "$FM_JEV_GATE_ACTING" "$FM_JEV_GATE_DECIDER" >&2
}

# fm_jev_gate_merge_risk <issuer> <task-id> <yes|no|''> <what is merged>
# Requires firstmate's merge-risk answer, asks it with the merge line and the
# task's brief as context, and prints a notice when the acting answer is yes.
# merge-risk is never handed to Jev and never changes merge authority.
fm_jev_gate_merge_risk() {
  local issuer=$1 id=$2 mine=$3 what=$4 ctx line
  fm_jev_gate_enabled || return 0
  case "$mine" in
    yes|no) ;;
    '') fm_jev_gate_refuse "$issuer" "a merge needs --merge-risk <yes|no>, firstmate's own answer to whether it is destructive, irreversible, or security-sensitive; nothing was merged" ;;
    *) fm_jev_gate_refuse "$issuer" "--merge-risk must be yes or no (got '$mine'); nothing was merged" ;;
  esac
  ctx=$(mktemp) || fm_jev_gate_refuse "$issuer" "mktemp failed; nothing was merged"
  line=$(mktemp) || { rm -f "$ctx"; fm_jev_gate_refuse "$issuer" "mktemp failed; nothing was merged"; }
  printf '%s\n' "$what" > "$line"
  fm_jev_gate_context "$ctx" "${FM_DATA_OVERRIDE:-$FM_HOME/data}/$id/brief.md" "Merge" "$line"
  fm_jev_gate_ask "$issuer" merge-risk "$mine" \
    "Is the merge of task $id destructive, irreversible, or security-sensitive" "$ctx"
  rm -f "$ctx" "$line"
  [ "$FM_JEV_GATE_ACTING" != yes ] \
    || echo "$issuer: merge-risk is yes for $id; this merge needs the human's explicit word for this concrete merge" >&2
}
