#!/usr/bin/env bash
# fm-jev-stop-check.sh - Claude Code Stop hook that refuses a firstmate
# primary's turn end while its final message leaves out the Jev asks made this
# turn, or leaves a disagreement with Jev unmentioned.
#
# Usage: <Stop hook JSON on stdin> | bin/fm-jev-stop-check.sh --claude
#
# Scope: a genuine primary home (fm_primary_scope_matches in
#   bin/fm-primary-scope-lib.sh), outside a task worker (FM_TASK_ID unset),
#   with FM_JEV_GATE not off. Anywhere else it is inert: exit 0, no output.
#
# The turn starts at the ISO-8601 time in $FM_HOME/state/jev-turn-start, which
# bin/fm-jev-prompt-reminder.sh writes at every prompt. The section is the
# output of bin/fm-jev.sh turn --since <that time>, whose header owns its
# lines. When it lists at least one ask, the payload's last_assistant_message
# must hold:
#   - every section line, the "Jev asks this turn (<n>)" header included, as a
#     line of its own (leading space, a "- " or "* " bullet, and trailing space
#     are ignored);
#   - for every line marked [DISAGREE], another line outside the section that
#     contains "disagree" (any case) and that line's question type.
#
# Output:
#   ALLOW - exit 0, no output.
#   BLOCK - exit 2 with the reason on stderr, naming the command that prints
#           the section; Claude Code feeds it back and the turn continues.
#   FAIL OPEN - empty or malformed stdin, missing jq, no turn start recorded, a
#               payload without last_assistant_message, or a section that could
#               not be printed.
#
# Turn close: outside a task worker and with the gate on, every exit 0 (ALLOW
# and FAIL OPEN, in or out of scope) writes $FM_HOME/state/jev-turn-closed
# when that state directory exists; a BLOCK writes nothing, since the turn
# continues. Another Stop hook can still block the same turn end, so the
# marker only says this check let it through; bin/fm-jev-prompt-reminder.sh
# owns the words record and when it trusts the marker.
set -u

[ "${1:-}" = --claude ] || [ $# -eq 0 ] || { echo "usage: fm-jev-stop-check.sh --claude < <Stop hook JSON>" >&2; exit 2; }
[ -z "${FM_TASK_ID:-}" ] || exit 0
[ "${FM_JEV_GATE:-on}" != off ] || exit 0
TURN_STATE="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P)}}/state"
WORK=''
# shellcheck disable=SC2329 # Registered by the EXIT trap below.
on_exit() {
  local code=$?
  [ -z "$WORK" ] || rm -rf "$WORK"
  [ "$code" != 0 ] || [ ! -d "$TURN_STATE" ] || : > "$TURN_STATE/jev-turn-closed" 2>/dev/null || true
}
trap on_exit EXIT
PAYLOAD=$(cat 2>/dev/null) || exit 0
[ -n "$PAYLOAD" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)} || exit 0
FM_HOME=${FM_HOME:-$FM_ROOT}
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_primary_scope_matches "$FM_ROOT" "$FM_HOME/state" || exit 0

SINCE=$(tr -d '[:space:]' 2>/dev/null < "$FM_HOME/state/jev-turn-start") || exit 0
[ -n "$SINCE" ] || exit 0
jq -e 'type == "object" and (.last_assistant_message | type) == "string"' <<<"$PAYLOAD" >/dev/null 2>&1 || exit 0
SECTION=$(FM_HOME=$FM_HOME "$SCRIPT_DIR/fm-jev.sh" turn --since "$SINCE" 2>/dev/null) || exit 0
[ "$(printf '%s\n' "$SECTION" | sed -n 2p)" != none ] || exit 0

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-jev-stop.XXXXXX") || exit 0
printf '%s\n' "$SECTION" > "$WORK/section"
jq -r .last_assistant_message <<<"$PAYLOAD" \
  | sed -E 's/^[[:space:]]*([-*][[:space:]]+)?//; s/[[:space:]]+$//' > "$WORK/message"
CMD="bin/fm-jev.sh turn --since $SINCE"

missing=0
while IFS= read -r line; do
  grep -Fxq -- "$line" "$WORK/message" || missing=$((missing + 1))
done < "$WORK/section"
if [ "$missing" -gt 0 ]; then
  {
    printf '[jev-turn] this turn made Jev asks, and the final message lacks %s line(s) of their section; run %s and put its output, every line verbatim, in the final message:\n' "$missing" "$CMD"
    cat "$WORK/section"
  } >&2
  exit 2
fi

grep -Fxv -f "$WORK/section" "$WORK/message" > "$WORK/outside" || true
unmentioned=''
while IFS= read -r line; do
  case "$line" in *' [DISAGREE]') ;; *) continue ;; esac
  type=${line#* }
  type=${type%%:*}
  grep -i disagree "$WORK/outside" | grep -Fq -- "$type" || unmentioned="$unmentioned $type"
done < "$WORK/section"
if [ -n "$unmentioned" ]; then
  printf '[jev-turn] firstmate disagreed with Jev this turn (%s), and the final message does not say so outside the Jev asks section; add a line naming each disagreement, with the word "disagree" and the question type (%s prints the section)\n' "${unmentioned# }" "$CMD" >&2
  exit 2
fi
exit 0
