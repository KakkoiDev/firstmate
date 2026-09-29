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
#     nothing because Jev was off or failed);
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
# FM_JEV_GATE_CONTEXT_BYTES caps the context sent with an ask (default 6000):
#   the extra texts come first, then the brief's task sections.

# shellcheck source=bin/fm-brief-heading-lib.sh
declare -F fm_brief_task_heading_body >/dev/null || . "$SCRIPT_DIR/fm-brief-heading-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
declare -F secondmate_registry_parse_line >/dev/null || . "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

FM_JEV_GATE_CONTEXT_BYTES=${FM_JEV_GATE_CONTEXT_BYTES:-6000}
FM_JEV_GATE_ID='' FM_JEV_GATE_ACTING='' FM_JEV_GATE_DECIDER=''

fm_jev_gate_enabled() {
  [ "${FM_JEV_GATE:-on}" != off ]
}

# Question wording per type; yes/no types print "yes-no" as their options.
fm_jev_gate_question() {  # <type>
  case "$1" in
    project-match) printf 'Which registered project is this request about?' ;;
    deliverable-class) printf 'Should this request ship a change, scout for knowledge, or be answered from existing evidence?' ;;
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

# Options per type, one id per line; project-match and secondmate-scope read
# the live registries.
fm_jev_gate_options() {  # <type>
  case "$1" in
    project-match) fm_jev_gate_projects; printf 'none\nseveral\n' ;;
    deliverable-class) printf 'ship\nscout\nanswer-from-evidence\n' ;;
    secondmate-scope) fm_jev_gate_secondmates; printf 'main\n' ;;
    surface-class) printf 'internal-only\nproduct-facing\nmixed\nuncertain\n' ;;
    concurrency) printf 'parallel\nsemantic-dependency\nshared-external-state\nmigration-conflict\n' ;;
    effort-level) printf 'low\nmedium\nhigh\nxhigh\nmax\nultra\ndefault\n' ;;
    mid-task-ask) printf 'invalidates\nfollow-up\ndownstream-correction\n' ;;
    report-has-captain-call|scout-recommends-ship|merge-risk) printf 'yes-no\n' ;;
    stuck-worker) printf 'working\nidle-done\nwaiting-on-answered-question\nlooping\nconfused\nunresponsive\n' ;;
    *) return 1 ;;
  esac
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
  local opt
  while IFS= read -r opt; do
    [ -n "$opt" ] || continue
    if [ "$opt" = yes-no ]; then printf -- '--yes-no\n'; else printf -- '--option\n%s\n' "$opt"; fi
  done < <(fm_jev_gate_options "$1")
}

fm_jev_gate_is_option() {  # <type> <value>
  local opt
  while IFS= read -r opt; do
    if [ "$opt" = yes-no ]; then case "$2" in yes|no) return 0 ;; esac; fi
    [ "$opt" != "$2" ] || return 0
  done < <(fm_jev_gate_options "$1")
  return 1
}

fm_jev_gate_choices() {  # <type>: the option ids as one "a|b|c" string
  fm_jev_gate_options "$1" | sed 's/^yes-no$/yes|no/' | paste -sd'|' -
}

# fm_jev_gate_context <out-file> <brief-or-report> [<label> <file>]...
# Writes each labelled extra text, then the brief's `# Task` sections (the
# whole file when it has none), truncated to FM_JEV_GATE_CONTEXT_BYTES.
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
  } | head -c "$FM_JEV_GATE_CONTEXT_BYTES" > "$out"
}

# The exact command firstmate runs for a choice asked before the script.
fm_jev_gate_ask_command() {  # <type>
  local cmd opt
  cmd="bin/fm-jev.sh ask --type $1 --summary \"<one line naming the request>\" --question \"$(fm_jev_gate_question "$1")\""
  while IFS= read -r opt; do
    [ -n "$opt" ] || continue
    if [ "$opt" = yes-no ]; then cmd="$cmd --yes-no"; else cmd="$cmd --option $opt"; fi
  done < <(fm_jev_gate_options "$1")
  printf '%s --context <file with the request text> --mine <your choice>' "$cmd"
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
  out=$(FM_HOME=$FM_HOME FM_JEV_ISSUER=$issuer "$SCRIPT_DIR/fm-jev.sh" ask --type "$qtype" --summary "$summary" \
    --question "$(fm_jev_gate_question "$qtype")" "${opts[@]}" --context "$ctx" --mine "$mine") || out=''
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
# the caller's own evidence acts.
fm_jev_gate_recorded() {
  local issuer=$1 qtype=$2 id=$3 row rtype
  FM_JEV_GATE_ID='' FM_JEV_GATE_ACTING='' FM_JEV_GATE_DECIDER=''
  [ "$id" != off ] || { printf '%s: jev %s not recorded (off or failed)\n' "$issuer" "$qtype" >&2; return 0; }
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
