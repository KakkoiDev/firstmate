#!/usr/bin/env bash
# fm-prompt-wait.sh - the ONLY writer of the "this worker is waiting on a human
# decision" record, and the owner of its re-surface ladder policy.
#
# WHY THIS EXISTS. A worker blocked mid-turn on a permission or confirmation
# dialog emits no turn-end and appends no status line, so before this record the
# only thing that noticed was bin/fm-watch.sh's pane-staleness timer - tens of
# minutes. The harness knows the moment it asks; this record is how it says so.
# docs/verification/worker-prompt-wait.md owns which harness events feed it and what each
# supported adapter can and cannot report.
#
# Record file: state/<id>.prompt-wait - exactly one line, created only while no
# episode is open, so one blocked prompt produces one wake no matter how many
# harness events describe it:
#
#   gen=<token>\tat=<epoch>\tsource=<s>\tevent=<e>\tsummary=<one-line text>
#
# gen is the incarnation token minted by bin/fm-busy-event.sh arm and embedded
# into the adapter's hook wiring, so a hook that outlives its incarnation cannot
# open or close an episode for its replacement. bin/fm-busy-lib.sh stays the one
# owner of that token; this script only reads it.
#
# Ladder file: state/<id>.prompt-wait.ring - "<count>\t<epoch>", the re-surface
# schedule, in the shape bin/fm-task-inbox-lib.sh uses for the steering inbox.
# It has no escalation ceiling on purpose: an unanswered prompt is exactly the
# failure this record exists to report, so it keeps re-surfacing on a bounded
# cadence rather than going quiet after N tries.
#
# Status-log lines. The record wakes firstmate through the watcher; each harness
# permission event also appends one line to state/<id>.status, the same channel
# a worker's own `blocked:` line uses, so firstmate reads what was refused and
# why the moment it happens (verified live, Claude Code 2.1.304):
#
#   blocked [at=E] [key=prompt-wait]: refused-pending: <tool> <command> (prompt waiting)
#       when an episode opens. The dialog stays up: these hooks report and
#       never return a permission decision.
#   resolved [at=E] [key=prompt-wait]: <how>
#       when an open episode closes (answered, turn over, agent replaced).
#   blocked [at=E] [key=refused]: refused: <tool> <command> (classifier <reason>)
#       when the auto-mode classifier denies a call (PermissionDenied).
#
# <command> is one line cut to FM_PROMPT_WAIT_COMMAND_MAX characters. A
# permissions.deny rule or a PreToolUse hook deny fires no hook at all, so
# neither is reported here.
#
# The record is a SIGNAL, not current-state truth. bin/fm-watch.sh surfaces its
# appearance and each ladder-due re-touch through the ordinary signal wake, and
# bin/fm-crew-state.sh remains the current-state owner.
#
# Subcommands:
#
#   record <state-dir> <id> --gen G --source S --event E
#       Open an episode. Reads the harness hook payload (JSON) on stdin and
#       derives the one-line summary from it. A stale gen, an already-open
#       episode, or an unreadable payload all leave the record alone.
#
#   clear <state-dir> <id> --gen G
#       Close the episode the harness just proved is over. A stale gen leaves
#       the live incarnation's record alone.
#
#   retire <state-dir> <id>
#       Remove the record and ladder with no gen check, for spawn arm, where
#       no gen is being honored; an open record's blocker is resolved.
#
#   denied <state-dir> <id> --gen G
#       Report an auto-mode classifier denial. Reads the PermissionDenied
#       payload on stdin. A stale gen writes nothing.
#
#   due <state-dir> <id>
#       Ladder policy. Prints `quiet`, or `resurface <count>` once the open
#       record has gone FM_PROMPT_WAIT_RERING_SECS without a re-surface.
#
#   resurfaced <state-dir> <id>
#       Advance the ladder after the watcher re-surfaces the record.
#
#   summary <state-dir> <id>
#       Print the open episode's summary text, or nothing when none is open.
#
# Every hook-facing subcommand (record, clear, denied) exits 0 whatever happens, and the generated hook
# command lines still append `|| true`: a refused or broken record must never
# break the harness's own lifecycle. `due`, `resurfaced`, and `summary` are
# watcher-facing and report failure normally.
#
# Tunables (env):
#   FM_PROMPT_WAIT_RERING_SECS   default 300; re-surface cadence while open
#   FM_PROMPT_WAIT_SUMMARY_MAX   default 200; summary characters kept
set -u

usage() {
  cat >&2 <<'EOF'
usage:
  fm-prompt-wait.sh record <state-dir> <id> --gen G --source S --event E   (payload on stdin)
  fm-prompt-wait.sh clear <state-dir> <id> --gen G
  fm-prompt-wait.sh retire <state-dir> <id>
  fm-prompt-wait.sh denied <state-dir> <id> --gen G   (payload on stdin)
  fm-prompt-wait.sh due <state-dir> <id>
  fm-prompt-wait.sh resurfaced <state-dir> <id>
  fm-prompt-wait.sh summary <state-dir> <id>
See the header comment for the full contract.
EOF
  exit 2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"

FM_PROMPT_WAIT_RERING_SECS=${FM_PROMPT_WAIT_RERING_SECS:-300}
FM_PROMPT_WAIT_SUMMARY_MAX=${FM_PROMPT_WAIT_SUMMARY_MAX:-200}
FM_PROMPT_WAIT_COMMAND_MAX=200
FM_PROMPT_WAIT_STATUS_KEY=prompt-wait
FM_PROMPT_WAIT_DENIED_KEY=refused

fm_prompt_wait_record_path() {  # <state-dir> <id>
  printf '%s/%s.prompt-wait' "$1" "$2"
}

fm_prompt_wait_ring_path() {  # <state-dir> <id>
  printf '%s/%s.prompt-wait.ring' "$1" "$2"
}

# One field of the open record, or failure when no readable record exists.
fm_prompt_wait_field() {  # <state-dir> <id> <key>
  local rec line field
  rec=$(fm_prompt_wait_record_path "$1" "$2")
  [ -f "$rec" ] && [ ! -L "$rec" ] || return 1
  IFS= read -r line < "$rec" || return 1
  while [ -n "$line" ]; do
    field=${line%%$'\t'*}
    case "$field" in
      "$3="*) printf '%s' "${field#"$3"=}"; return 0 ;;
    esac
    [ "$field" != "$line" ] || break
    line=${line#*$'\t'}
  done
  return 1
}

# A single tab-free, newline-free, length-capped line for a wake payload.
fm_prompt_wait_clean() {
  fm_prompt_wait_one_line | cut -c "1-$FM_PROMPT_WAIT_SUMMARY_MAX"
}

# stdin as one printable line: tabs and line breaks become spaces, and every
# other control byte (a terminal escape among them) is dropped.
fm_prompt_wait_one_line() {
  LC_ALL=C tr '\t\r\n' '   ' | LC_ALL=C tr -d '\000-\037\177'
}

# Derive the human-readable "what it asked" from the harness payload on stdin.
# jq is optional in this repo (bin/fm-bootstrap.sh requires it only for Relay
# and dispatch-profile validation), so a home without it still gets the wake and
# loses only the detail line; firstmate reads the pane for the exact dialog
# either way.
fm_prompt_wait_summary_from_payload() {  # <event> <payload>
  local event=$1 payload=$2 summary=''
  if [ -n "$payload" ] && command -v jq >/dev/null 2>&1; then
    summary=$(printf '%s' "$payload" | jq -r '
      if .hook_event_name == "PermissionRequest" then
        ((.tool_name // "tool") + ": "
          + ((.tool_input.command // .tool_input.file_path // .tool_input.path
              // (.tool_input | tojson)) | tostring))
      elif .hook_event_name == "Notification" then
        (.message // .notification_type // "waiting on a prompt")
      else
        (.message // "waiting on a prompt")
      end' 2>/dev/null) || summary=''
  fi
  [ -n "$summary" ] && [ "$summary" != null ] || summary="$event"
  printf '%s' "$summary" | fm_prompt_wait_clean
}

# "<tool> <command>" for a status line, the command cut to
# FM_PROMPT_WAIT_COMMAND_MAX characters. Without jq, or for a payload that names
# no tool (a Notification dialog), it falls back to <fallback>.
fm_prompt_wait_tool_command() {  # <payload> <fallback>
  local payload=$1 tool='' command=''
  if [ -n "$payload" ] && command -v jq >/dev/null 2>&1; then
    tool=$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null) || tool=''
    command=$(printf '%s' "$payload" | jq -r '
      if .tool_input == null then (.message // empty)
      else ((.tool_input.command // .tool_input.file_path // .tool_input.path
              // .tool_input.url // (.tool_input | tojson)) | tostring)
      end' 2>/dev/null) || command=''
  fi
  [ -n "$command" ] || command=$2
  command=$(printf '%s' "$command" | fm_prompt_wait_one_line | cut -c "1-$FM_PROMPT_WAIT_COMMAND_MAX")
  tool=$(printf '%s' "$tool" | LC_ALL=C tr -c 'A-Za-z0-9_.:-' '_' | cut -c 1-64)
  if [ -n "$tool" ]; then
    printf '%s %s' "$tool" "$command"
  else
    printf '%s' "$command"
  fi
}

# Append one worker status line to the task's status log. The append is what
# wakes firstmate, exactly as a worker's own `blocked:` line does.
fm_prompt_wait_status_append() {  # <state-dir> <id> <line>
  printf '%s\n' "$3" >> "$1/$2.status" 2>/dev/null || return 0
}

# 0 when <gen> is the task's currently armed incarnation. An unarmed task has no
# incarnation to bind to, so its events are refused rather than guessed at.
fm_prompt_wait_gen_current() {  # <state-dir> <id> <gen>
  local current
  fm_busy_token_valid "$3" || return 1
  current=$(fm_busy_current_gen "$1" "$2") || return 1
  [ "$current" = "$3" ]
}

fm_prompt_wait_valid_id() {  # <id>
  case "$1" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#1}" -le 64 ]
}

cmd_record() {  # <state-dir> <id> --gen G --source S --event E
  local state=$1 id=$2 gen='' source='' event='' rec summary line open_gen payload
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --gen) gen=${2-}; shift 2 || return 0 ;;
      --source) source=${2-}; shift 2 || return 0 ;;
      --event) event=${2-}; shift 2 || return 0 ;;
      *) return 0 ;;
    esac
  done
  [ -n "$source" ] && [ -n "$event" ] || return 0
  fm_prompt_wait_valid_id "$id" || return 0
  [ -d "$state" ] || return 0
  fm_prompt_wait_gen_current "$state" "$id" "$gen" || return 0

  rec=$(fm_prompt_wait_record_path "$state" "$id")
  # A record left by a superseded incarnation would otherwise block the live one
  # from ever opening an episode, so it is cleared before the create below.
  if open_gen=$(fm_prompt_wait_field "$state" "$id" gen); then
    [ "$open_gen" = "$gen" ] && return 0
    rm -f -- "$rec" "$(fm_prompt_wait_ring_path "$state" "$id")" 2>/dev/null || return 0
  elif [ -e "$rec" ] || [ -L "$rec" ]; then
    # Present but unreadable as a record: replace it rather than wedging on it.
    rm -f -- "$rec" 2>/dev/null || return 0
  fi

  payload=$(cat 2>/dev/null) || payload=''
  summary=$(fm_prompt_wait_summary_from_payload "$event" "$payload")
  source=$(printf '%s' "$source" | fm_prompt_wait_clean)
  event=$(printf '%s' "$event" | fm_prompt_wait_clean)
  line=$(printf 'gen=%s\tat=%s\tsource=%s\tevent=%s\tsummary=%s' \
    "$gen" "$(date +%s)" "$source" "$event" "$summary")
  # noclobber makes the create itself the episode lock: two harness events
  # describing the same blocked prompt race here and exactly one wins.
  ( set -C; printf '%s\n' "$line" > "$rec" ) 2>/dev/null || return 0
  fm_prompt_wait_status_append "$state" "$id" \
    "blocked [at=$(date +%s)] [key=$FM_PROMPT_WAIT_STATUS_KEY]: refused-pending: $(fm_prompt_wait_tool_command "$payload" "$event") (prompt waiting)"
  return 0
}

cmd_clear() {  # <state-dir> <id> --gen G
  local state=$1 id=$2 gen=''
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --gen) gen=${2-}; shift 2 || return 0 ;;
      *) return 0 ;;
    esac
  done
  fm_prompt_wait_valid_id "$id" || return 0
  fm_prompt_wait_gen_current "$state" "$id" "$gen" || return 0
  fm_prompt_wait_close "$state" "$id" "prompt no longer waiting" || return 0
  return 0
}

# Remove the open record and ladder, closing the record's status-log blocker
# when a record was actually open, so firstmate's open decisions do not keep
# a prompt that is already over.
fm_prompt_wait_close() {  # <state-dir> <id> <how>
  local state=$1 id=$2 rec
  rec=$(fm_prompt_wait_record_path "$state" "$id")
  if [ -e "$rec" ] || [ -L "$rec" ]; then
    rm -f -- "$rec" "$(fm_prompt_wait_ring_path "$state" "$id")" || return 1
    fm_prompt_wait_status_append "$state" "$id" \
      "resolved [at=$(date +%s)] [key=$FM_PROMPT_WAIT_STATUS_KEY]: $3"
    return 0
  fi
  rm -f -- "$(fm_prompt_wait_ring_path "$state" "$id")"
}

cmd_retire() {  # <state-dir> <id>
  local state=$1 id=$2
  fm_prompt_wait_valid_id "$id" || return 1
  fm_prompt_wait_close "$state" "$id" "prompt closed: the agent that asked was replaced"
}

cmd_denied() {  # <state-dir> <id> --gen G   (PermissionDenied payload on stdin)
  local state=$1 id=$2 gen='' payload reason=''
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --gen) gen=${2-}; shift 2 || return 0 ;;
      *) return 0 ;;
    esac
  done
  fm_prompt_wait_valid_id "$id" || return 0
  [ -d "$state" ] || return 0
  fm_prompt_wait_gen_current "$state" "$id" "$gen" || return 0
  payload=$(cat 2>/dev/null) || payload=''
  if [ -n "$payload" ] && command -v jq >/dev/null 2>&1; then
    reason=$(printf '%s' "$payload" | jq -r '.reason // empty' 2>/dev/null) || reason=''
  fi
  reason=$(printf '%s' "${reason:-no reason given}" | fm_prompt_wait_clean)
  fm_prompt_wait_status_append "$state" "$id" \
    "blocked [at=$(date +%s)] [key=$FM_PROMPT_WAIT_DENIED_KEY]: refused: $(fm_prompt_wait_tool_command "$payload" "a tool call") (classifier $reason)"
  return 0
}

cmd_due() {  # <state-dir> <id>
  local state=$1 id=$2 at count last ring now
  fm_prompt_wait_valid_id "$id" || return 1
  at=$(fm_prompt_wait_field "$state" "$id" at) || { printf 'quiet\n'; return 0; }
  case "$at" in ''|*[!0-9]*) printf 'quiet\n'; return 0 ;; esac
  count=0
  last=$at
  ring=$(cat "$(fm_prompt_wait_ring_path "$state" "$id")" 2>/dev/null || true)
  if [ -n "$ring" ]; then
    IFS=$(printf '\t') read -r count last <<EOF
$ring
EOF
    case "${count:-}" in ''|*[!0-9]*) count=0 ;; esac
    case "${last:-}" in ''|*[!0-9]*) last=$at ;; esac
  fi
  now=$(date +%s)
  if [ "$((now - last))" -ge "$FM_PROMPT_WAIT_RERING_SECS" ]; then
    printf 'resurface %s\n' "$count"
  else
    printf 'quiet\n'
  fi
}

cmd_resurfaced() {  # <state-dir> <id>
  local state=$1 id=$2 ring count last tmp
  fm_prompt_wait_valid_id "$id" || return 1
  fm_prompt_wait_field "$state" "$id" at >/dev/null || return 0
  count=0
  ring=$(cat "$(fm_prompt_wait_ring_path "$state" "$id")" 2>/dev/null || true)
  if [ -n "$ring" ]; then
    IFS=$(printf '\t') read -r count last <<EOF
$ring
EOF
    case "${count:-}" in ''|*[!0-9]*) count=0 ;; esac
  fi
  tmp="$(fm_prompt_wait_ring_path "$state" "$id").tmp.$$"
  printf '%s\t%s\n' "$((count + 1))" "$(date +%s)" > "$tmp" || return 1
  mv -f -- "$tmp" "$(fm_prompt_wait_ring_path "$state" "$id")" || { rm -f -- "$tmp"; return 1; }
  # The watcher's signal scan keys on the record's size:mtime, so the re-touch
  # IS the re-surface: it reuses the ordinary signal path instead of a second
  # queueing route that could drift from it.
  touch "$(fm_prompt_wait_record_path "$state" "$id")" 2>/dev/null || return 1
}

cmd_summary() {  # <state-dir> <id>
  local state=$1 id=$2 summary
  fm_prompt_wait_valid_id "$id" || return 1
  summary=$(fm_prompt_wait_field "$state" "$id" summary) || return 1
  printf '%s\n' "$summary"
}

CMD=${1:-}
case "$CMD" in
  record|clear|retire|denied|due|resurfaced|summary) ;;
  *) usage ;;
esac
shift
[ "$#" -ge 2 ] || usage
"cmd_$CMD" "$@"
