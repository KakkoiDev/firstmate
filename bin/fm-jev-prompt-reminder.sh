#!/usr/bin/env bash
# fm-jev-prompt-reminder.sh - Claude Code UserPromptSubmit hook that reminds
# firstmate to open a new request with the deliverable-class Jev ask, and
# records the operator's words for the turn.
# Usage: fm-jev-prompt-reminder.sh < <UserPromptSubmit hook JSON>
#
# A request answered in chat has no action script to refuse it, so this is the
# only prompt toward the ask there; it is a reminder and never a block. It
# prints one context line on stdout for a prompt typed by a human, and nothing
# for a Firstmate operational input (a prompt carrying FIRSTMATE_OP:), inside a
# task worker (FM_TASK_ID set), or with FM_JEV_GATE=off. It always exits 0.
# .agents/skills/jev-shadow/SKILL.md owns the ask itself.
#
# Outside a task worker and with the gate on, when $FM_HOME/state exists:
#   - every prompt, operational input included, writes the current UTC time as
#     ISO-8601 to $FM_HOME/state/jev-turn-start; that is the turn start
#     bin/fm-jev-stop-check.sh reads.
#   - $FM_HOME/state/jev-turn-words.jsonl holds the operator's words for the
#     current turn, one JSON object per prompt, oldest first:
#       {"v":1,"ts":"<ISO-8601 UTC>","session_id":"<payload session_id>","prompt":"<prompt as submitted>"}
#     A prompt opens a new turn, emptying the file first, when the file's
#     newest record names another session, or when the previous turn ended.
#     A turn ends only when its turn end goes through every Stop hook, so a
#     block by any hook keeps the turn open whatever order the hooks run in.
#     The payload's transcript_path tells: Claude Code appends one
#     {"type":"system","subtype":"stop_hook_summary",...} line per Stop,
#     after the whole hook chain ran, and its hookErrors array is empty
#     exactly when no hook blocked. The previous turn ended when a summary
#     appended since the previous prompt has an empty hookErrors; one with a
#     non-empty hookErrors is a block, and no summary means no Stop yet.
#     $FM_HOME/state/jev-turn-anchor holds "<session_id>\t<transcript path>\tb<byte size>"
#     as of the previous prompt, and only the transcript bytes after that
#     size are read, so the cost follows what one turn appended rather than
#     the whole transcript. When the transcript is not readable, the anchor
#     names another session or transcript, is in another format, or holds a
#     size past the transcript's end, or a summary since it has no hookErrors
#     array, the turn ended when $FM_HOME/state/jev-turn-closed exists
#     (bin/fm-jev-stop-check.sh writes it when its own check allows the turn
#     end). Every prompt removes the marker and rewrites the anchor.
#     Otherwise the prompt arrived mid-turn and is added to the same turn.
#     The words are set aside before the transcript is read and put back only
#     once the prompt is known to be mid-turn, so a run cut short, such as by
#     the hook timeout, leaves no words rather than an earlier turn's.
#     A prompt is the operator's words, and is appended, unless it is empty,
#     carries FIRSTMATE_OP:, opens with <task-notification> (Claude's own
#     rewake), or is an operational-input doorbell whose record exists
#     (bin/fm-operational-input.sh doorbell-kind).
#     bin/fm-jev.sh ask reads the file into every ask's context.
set -u

payload=$(cat 2>/dev/null) || payload=''
[ -z "${FM_TASK_ID:-}" ] || exit 0
[ "${FM_JEV_GATE:-on}" != off ] || exit 0
script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)
state="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$script_dir/.." 2>/dev/null && pwd -P)}}/state"

# operator_words: true when the prompt is the operator's own text.
operator_words() {  # <prompt>
  local p=$1
  [ -n "${p//[[:space:]]/}" ] || return 1
  case "$p" in *FIRSTMATE_OP:*) return 1 ;; esac
  case "${p#"${p%%[![:space:]]*}"}" in '<task-notification>'*) return 1 ;; esac
  case "$p" in
    ": Firstmate operational input waiting: read '"*)
      ! printf '%s' "$p" | "$script_dir/fm-operational-input.sh" doorbell-kind >/dev/null 2>&1 || return 1
      ;;
  esac
  return 0
}

SUMMARY='"type":"system","subtype":"stop_hook_summary"'

# turn_ended: prints yes or no when the transcript's Stop summaries between
# the anchor's size and <size now> tell whether the previous turn ended, and
# nothing when they cannot. No byte before the anchor's size is read.
turn_ended() {  # <session> <transcript> <size now>
  local a_session a_path a_size
  IFS=$'\t' read -r a_session a_path a_size < "$state/jev-turn-anchor" 2>/dev/null || return 0
  [ "$a_session" = "$1" ] && [ "$a_path" = "$2" ] || return 0
  case "$a_size" in b[0-9]*) a_size=${a_size#b} ;; *) return 0 ;; esac
  case "$a_size" in *[!0-9]*) return 0 ;; esac
  [ "$a_size" -le "$3" ] || return 0
  tail -c "+$((a_size + 1))" "$2" | head -c "$(($3 - a_size))" | grep -F -- "$SUMMARY" | jq -rs '
    [.[] | .hookErrors | if type != "array" then "unknown" elif length == 0 then "end" else "block" end]
    | if index("end") != null then "yes" elif index("unknown") != null then empty else "no" end'
}

record_words() {
  local words="$state/jev-turn-words.jsonl" closed="$state/jev-turn-closed" anchor="$state/jev-turn-anchor"
  local aside="$state/jev-turn-words.aside" prompt session last transcript size='' ended=''
  command -v jq >/dev/null 2>&1 || return 0
  prompt=$(jq -j 'if type == "object" and (.prompt | type) == "string" then .prompt else empty end' <<<"$payload" 2>/dev/null) || return 0
  session=$(jq -r 'if type == "object" then (.session_id // "") | tostring else "" end' <<<"$payload" 2>/dev/null) || session=''
  transcript=$(jq -r 'if type == "object" then (.transcript_path // "") | tostring else "" end' <<<"$payload" 2>/dev/null) || transcript=''
  rm -f "$aside"
  [ ! -e "$words" ] || mv -f "$words" "$aside" || return 0
  if [ -s "$aside" ] && [ -n "$session" ]; then
    last=$(tail -n 1 "$aside" | jq -r '.session_id // ""' 2>/dev/null) || last=''
    [ -z "$last" ] || [ "$last" = "$session" ] || rm -f "$aside"
  fi
  if [ -n "$transcript" ] && [ -f "$transcript" ] && [ -r "$transcript" ]; then
    size=$(wc -c < "$transcript" 2>/dev/null | tr -d '[:space:]')
    case "$size" in ''|*[!0-9]*) size='' ;; esac
  fi
  [ -z "$size" ] || ended=$(turn_ended "$session" "$transcript" "$size" 2>/dev/null)
  if [ "$ended" = yes ] || { [ -z "$ended" ] && [ -e "$closed" ]; }; then
    rm -f "$aside"
  fi
  [ ! -e "$aside" ] || mv -f "$aside" "$words"
  rm -f "$closed"
  if [ -n "$size" ]; then
    printf '%s\t%s\tb%s\n' "$session" "$transcript" "$size" > "$anchor"
  else
    rm -f "$anchor"
  fi
  operator_words "$prompt" || return 0
  jq -c --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg s "$session" \
    '{v: 1, ts: $ts, session_id: $s, prompt: .prompt}' <<<"$payload" >> "$words"
}

if [ -d "$state" ]; then
  date -u +%Y-%m-%dT%H:%M:%SZ > "$state/jev-turn-start" 2>/dev/null || true
  record_words 2>/dev/null || true
fi
case "$payload" in
  *FIRSTMATE_OP:*) exit 0 ;;
esac
printf '%s\n' 'Jev decision step: a new request starts with the deliverable-class ask with your choice as --mine (jev-shadow skill); a chat-only answer is still a decision.'
exit 0
