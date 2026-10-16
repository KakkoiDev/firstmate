#!/usr/bin/env bash
# fm-jev-prompt-reminder.sh - Claude Code UserPromptSubmit hook that reminds
# firstmate to open a new request with the deliverable-class Jev ask, and
# records the operator's words for the turn.
# Usage: fm-jev-prompt-reminder.sh < <UserPromptSubmit hook JSON>
#        fm-jev-prompt-reminder.sh --shell-turns < <JSON with session_id and transcript_path>
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
#     current turn, one JSON object per entry, oldest first:
#       {"v":1,"ts":"<ISO-8601 UTC>","session_id":"<payload session_id>","prompt":"<prompt as submitted>"}
#     or, for a shell command the operator ran with the ! prefix:
#       {"v":1,"ts":"<ISO-8601 UTC>","session_id":"<session_id>","kind":"shell","command":"<command>","output":"<output>"}
#     An entry opens a new turn, emptying the file first, when the file's
#     newest record names another session, or when the previous turn ended.
#     A turn ends only when its turn end goes through every Stop hook, so a
#     block by any hook keeps the turn open whatever order the hooks run in.
#     The payload's transcript_path tells: Claude Code appends one
#     {"type":"system","subtype":"stop_hook_summary",...} line per Stop,
#     after the whole hook chain ran, and its hookErrors array is empty
#     exactly when no hook blocked. The previous turn ended when a summary
#     appended since the previous entry has an empty hookErrors; one with a
#     non-empty hookErrors is a block, and no summary means no Stop yet.
#     $FM_HOME/state/jev-turn-anchor holds "<session_id>\t<transcript path>\tb<byte size>"
#     as of the previous entry, and only the transcript bytes after that
#     size are read, so the cost follows what one turn appended rather than
#     the whole transcript. When the transcript is not readable, the anchor
#     names another session or transcript, is in another format, or holds a
#     size past the transcript's end, or a summary since it has no hookErrors
#     array, the turn ended when $FM_HOME/state/jev-turn-closed exists
#     (bin/fm-jev-stop-check.sh writes it when its own check allows the turn
#     end). Every entry removes the marker and rewrites the anchor.
#     Otherwise the entry arrived mid-turn and is added to the same turn.
#     A prompt sets the words aside before the transcript is read, and they
#     are put back only once an entry is known to be mid-turn, so a run cut
#     short, such as by the hook timeout, leaves no words rather than an
#     earlier turn's.
#     A prompt is the operator's words, and is appended, unless it is empty,
#     carries FIRSTMATE_OP:, opens with <task-notification> (Claude's own
#     rewake), or is an operational-input doorbell whose record exists
#     (bin/fm-operational-input.sh doorbell-kind).
#     bin/fm-jev.sh ask reads the file into every ask's context.
#   - A ! shell command fires no UserPromptSubmit hook. Claude Code records
#     it in the transcript as a user message <bash-input>...</bash-input>
#     followed by one whose parentUuid is that message's uuid and whose text
#     opens with <bash-stdout> or <bash-stderr>. --shell-turns, which every
#     prompt also runs first, imports each such pair the transcript holds
#     after $FM_HOME/state/jev-turn-shell-mark ("<transcript path>\t<bytes
#     already read>") as an entry
#     at the command's own time: the command without its tags, the output
#     verbatim with its tags, and the command's time, truncated to the
#     second, as the turn start. A command with no recorded output stops the
#     import before it, unless another command follows it, which imports it
#     with a null output. With no mark for that transcript, the import starts
#     at the commands written at or after the recorded turn start, and with no
#     turn start it only sets the mark. bin/fm-jev-stop-check.sh runs it
#     before it reads the turn start, and fm_jev_turn_words in
#     bin/fm-jev-lib.sh before it reads the words.
set -u

mode=prompt
[ "${1:-}" != --shell-turns ] || mode=shell-turns
payload=$(cat 2>/dev/null) || payload=''
[ -z "${FM_TASK_ID:-}" ] || exit 0
[ "${FM_JEV_GATE:-on}" != off ] || exit 0
script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)
state="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$script_dir/.." 2>/dev/null && pwd -P)}}/state"
words="$state/jev-turn-words.jsonl"
aside="$state/jev-turn-words.aside"

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

# begin_entry: the turn bookkeeping before one entry, given the transcript's
# byte size before it (empty when the transcript is not readable).
begin_entry() {  # <session> <transcript> <byte size>
  local closed="$state/jev-turn-closed" anchor="$state/jev-turn-anchor" last ended=''
  [ ! -e "$words" ] || mv -f "$words" "$aside" || return 1
  if [ -s "$aside" ] && [ -n "$1" ]; then
    last=$(tail -n 1 "$aside" | jq -r '.session_id // ""' 2>/dev/null) || last=''
    [ -z "$last" ] || [ "$last" = "$1" ] || rm -f "$aside"
  fi
  [ -z "$3" ] || ended=$(turn_ended "$1" "$2" "$3" 2>/dev/null)
  if [ "$ended" = yes ] || { [ -z "$ended" ] && [ -e "$closed" ]; }; then
    rm -f "$aside"
  fi
  [ ! -e "$aside" ] || mv -f "$aside" "$words"
  rm -f "$closed"
  if [ -n "$3" ]; then
    printf '%s\t%s\tb%s\n' "$1" "$2" "$3" > "$anchor"
  else
    rm -f "$anchor"
  fi
}

# SHELL_TURNS_JQ reads the "<line>:<text>" rows grep prints for the unread
# slice and prints one object per ! shell command, oldest first: its slice
# line, time, command, output (null while none is recorded), and whether
# another command follows it.
# shellcheck disable=SC2016 # $names below are jq variables, not shell ones.
SHELL_TURNS_JQ='
  def text: .message.content
    | if type == "string" then . elif type == "array"
      then map(select(type == "object" and .type == "text") | .text | strings) | join("") else "" end;
  def secs: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
  [inputs | capture("^(?<n>[0-9]+):(?<j>.*)$") | {line: (.n | tonumber), j}] as $rows
  | [$rows[] | (.j | fromjson?) as $l | select($l | type == "object" and .type == "user") | {line, l: $l}] as $u
  | [$u[] | select((.l | text | startswith("<bash-input>")) and (.l.timestamp | type) == "string")] as $cmds
  | $cmds | to_entries[] | (.key + 1 < ($cmds | length)) as $later | .value
  | select($since == "" or ((try (.l.timestamp | secs) catch -1) >= ($since | secs)))
  | .line as $n | .l.uuid as $id
  | (first($u[] | select($id != null and .l.parentUuid == $id)
      | .l | text | select(startswith("<bash-stdout>") or startswith("<bash-stderr>"))) // null) as $out
  | {line: $n,
     ts: (.l.timestamp | sub("\\.[0-9]+Z$"; "Z")), session_id: (.l.sessionId // ""),
     command: (.l | text | ltrimstr("<bash-input>") | rtrimstr("</bash-input>")), output: $out, later: $later}
'

# slice: prints the transcript's bytes from offset <from> up to <size>; dd
# seeks to the block, where tail -c +N would read every byte before it.
slice() {  # <transcript> <from> <size>
  local skip=$(($2 % 65536))
  dd if="$1" bs=65536 skip=$(($2 / 65536)) 2>/dev/null \
    | if [ "$skip" -gt 0 ]; then tail -c "+$((skip + 1))"; else cat; fi \
    | head -c "$(($3 - $2))"
}

# shell_turns: imports the ! shell commands the transcript holds past the mark
# as entries (see the header). Only the bytes past the mark are read.
shell_turns() {  # <session> <transcript>
  local session=$1 transcript=$2 mark="$state/jev-turn-shell-mark" m_path m_off
  local size from=0 since='' rows entry line ts session_id
  command -v jq >/dev/null 2>&1 || return 0
  [ -n "$transcript" ] && [ -f "$transcript" ] && [ -r "$transcript" ] || return 0
  size=$(wc -c < "$transcript" | tr -d '[:space:]')
  case "$size" in ''|*[!0-9]*) return 0 ;; esac
  if IFS=$'\t' read -r m_path m_off < "$mark" 2>/dev/null && [ "$m_path" = "$transcript" ] \
    && [[ $m_off =~ ^[0-9]+$ ]] && [ "$m_off" -le "$size" ]; then
    from=$m_off
  else
    since=$(tr -d '[:space:]' < "$state/jev-turn-start" 2>/dev/null) || since=''
    if [ -z "$since" ] || ! jq -en --arg s "$since" '$s | fromdateiso8601' >/dev/null 2>&1; then
      printf '%s\t%s\n' "$transcript" "$size" > "$mark"
      return 0
    fi
  fi
  if [ "$size" -le "$from" ]; then
    [ -z "$since" ] || printf '%s\t%s\n' "$transcript" "$size" > "$mark"
    return 0
  fi
  rows=$(slice "$transcript" "$from" "$size" \
    | LC_ALL=C grep -nF -e '<bash-input>' -e '<bash-stdout>' -e '<bash-stderr>')
  while IFS= read -r entry; do
    [ "$(jq -r '.output != null or .later' <<<"$entry")" = true ] || return 0
    line=$(jq -r .line <<<"$entry")
    ts=$(jq -r .ts <<<"$entry")
    session_id=$session
    [ -n "$session_id" ] || session_id=$(jq -r .session_id <<<"$entry")
    begin_entry "$session_id" "$transcript" \
      "$((from + $(slice "$transcript" "$from" "$size" | head -n "$((line - 1))" | wc -c)))" || return 0
    printf '%s\n' "$ts" > "$state/jev-turn-start"
    jq -c --arg s "$session_id" \
      '{v: 1, ts, session_id: $s, kind: "shell", command, output}' <<<"$entry" >> "$words"
    printf '%s\t%s\n' "$transcript" \
      "$((from + $(slice "$transcript" "$from" "$size" | head -n "$line" | wc -c)))" > "$mark"
  done < <(printf '%s\n' "$rows" | jq -Rcn --arg since "$since" "$SHELL_TURNS_JQ" 2>/dev/null)
  # A last line still being written is read again next time.
  [ -z "$(slice "$transcript" "$((size - 1))" "$size" | tr -d '\n')" ] || return 0
  printf '%s\t%s\n' "$transcript" "$size" > "$mark"
}

record_words() {  # <session> <transcript>
  local prompt size=''
  command -v jq >/dev/null 2>&1 || return 0
  prompt=$(jq -j 'if type == "object" and (.prompt | type) == "string" then .prompt else empty end' <<<"$payload" 2>/dev/null) || return 0
  if [ -n "$2" ] && [ -f "$2" ] && [ -r "$2" ]; then
    size=$(wc -c < "$2" 2>/dev/null | tr -d '[:space:]')
    case "$size" in ''|*[!0-9]*) size='' ;; esac
  fi
  begin_entry "$1" "$2" "$size" || return 0
  operator_words "$prompt" || return 0
  jq -c --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg s "$1" \
    '{v: 1, ts: $ts, session_id: $s, prompt: .prompt}' <<<"$payload" >> "$words"
}

if [ -d "$state" ]; then
  session=$(jq -r 'if type == "object" then (.session_id // "") | tostring else "" end' <<<"$payload" 2>/dev/null) || session=''
  transcript=$(jq -r 'if type == "object" then (.transcript_path // "") | tostring else "" end' <<<"$payload" 2>/dev/null) || transcript=''
  rm -f "$aside"
  [ "$mode" != prompt ] || [ ! -e "$words" ] || mv -f "$words" "$aside" 2>/dev/null || true
  shell_turns "$session" "$transcript" 2>/dev/null || true
  if [ "$mode" = prompt ]; then
    date -u +%Y-%m-%dT%H:%M:%SZ > "$state/jev-turn-start" 2>/dev/null || true
    record_words "$session" "$transcript" 2>/dev/null || true
    # Words set aside by a run that returned before any entry are put back.
    [ ! -e "$aside" ] || [ -e "$words" ] || mv -f "$aside" "$words" 2>/dev/null || true
  fi
fi
[ "$mode" = prompt ] || exit 0
case "$payload" in
  *FIRSTMATE_OP:*) exit 0 ;;
esac
printf '%s\n' 'Jev decision step: a new request starts with the deliverable-class ask with your choice as --mine (jev-shadow skill); a chat-only answer is still a decision.'
exit 0
