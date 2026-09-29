#!/usr/bin/env bash
# fm-jev-prompt-reminder.sh - Claude Code UserPromptSubmit hook that reminds
# firstmate to open a new request with the deliverable-class Jev ask.
# Usage: fm-jev-prompt-reminder.sh < <UserPromptSubmit hook JSON>
#
# A request answered in chat has no action script to refuse it, so this is the
# only prompt toward the ask there; it is a reminder and never a block. It
# prints one context line on stdout for a prompt typed by a human, and nothing
# for a Firstmate operational input (a prompt carrying FIRSTMATE_OP:), inside a
# task worker (FM_TASK_ID set), or with FM_JEV_GATE=off. It always exits 0.
# .agents/skills/jev-shadow/SKILL.md owns the ask itself.
#
# Outside a task worker and with the gate on, every prompt, operational input
# included, also writes the current UTC time as ISO-8601 to
# $FM_HOME/state/jev-turn-start when that state directory exists; that is the
# turn start bin/fm-jev-stop-check.sh reads.
set -u

payload=$(cat 2>/dev/null) || payload=''
[ -z "${FM_TASK_ID:-}" ] || exit 0
[ "${FM_JEV_GATE:-on}" != off ] || exit 0
state="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P)}}/state"
[ ! -d "$state" ] || date -u +%Y-%m-%dT%H:%M:%SZ > "$state/jev-turn-start" 2>/dev/null || true
case "$payload" in
  *FIRSTMATE_OP:*) exit 0 ;;
esac
printf '%s\n' 'Jev decision step: a new request starts with the deliverable-class ask with your choice as --mine (jev-shadow skill); a chat-only answer is still a decision.'
exit 0
