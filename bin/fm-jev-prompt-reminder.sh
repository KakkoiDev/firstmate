#!/usr/bin/env bash
# fm-jev-prompt-reminder.sh - Claude Code UserPromptSubmit hook that reminds
# firstmate to open a new request with the deliverable-class Jev ask.
# Usage: fm-jev-prompt-reminder.sh < <UserPromptSubmit hook JSON>
#
# A request answered in chat has no action script to refuse it, so this is the
# only prompt toward the ask there; it is a reminder and never a block. It
# prints one context line on stdout for a prompt typed by a human, and nothing
# for a Firstmate operational input (a prompt carrying FIRSTMATE_OP:), inside a
# task worker (FM_TASK_ID set), or with FM_JEV_GATE=off. It always exits 0 and
# reads no files. .agents/skills/jev-shadow/SKILL.md owns the ask itself.
set -u

payload=$(cat 2>/dev/null) || payload=''
[ -z "${FM_TASK_ID:-}" ] || exit 0
[ "${FM_JEV_GATE:-on}" != off ] || exit 0
case "$payload" in
  *FIRSTMATE_OP:*) exit 0 ;;
esac
printf '%s\n' 'Jev decision step: a new request starts with the deliverable-class ask with your choice as --mine (jev-shadow skill); a chat-only answer is still a decision.'
exit 0
