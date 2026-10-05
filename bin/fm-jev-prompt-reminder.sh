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
#     A prompt opens a new turn, emptying the file first, when
#     $FM_HOME/state/jev-turn-closed exists (bin/fm-jev-stop-check.sh writes
#     it when a turn end is allowed; this hook removes it) or when the file's
#     newest record names another session. Otherwise the prompt arrived
#     mid-turn and is added to the same turn.
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

record_words() {
  local words="$state/jev-turn-words.jsonl" closed="$state/jev-turn-closed" prompt session last
  command -v jq >/dev/null 2>&1 || return 0
  prompt=$(jq -j 'if type == "object" and (.prompt | type) == "string" then .prompt else empty end' <<<"$payload" 2>/dev/null) || return 0
  session=$(jq -r 'if type == "object" then (.session_id // "") | tostring else "" end' <<<"$payload" 2>/dev/null) || session=''
  if [ -s "$words" ] && [ -n "$session" ]; then
    last=$(tail -n 1 "$words" | jq -r '.session_id // ""' 2>/dev/null) || last=''
    [ -z "$last" ] || [ "$last" = "$session" ] || : > "$words"
  fi
  if [ -e "$closed" ]; then
    : > "$words"
    rm -f "$closed"
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
