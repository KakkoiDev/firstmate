#!/usr/bin/env bash
# fm-jev-pretool-check.sh - Claude Code PreToolUse guard that refuses a
# consequential tool call in a firstmate primary until a matching Jev ask,
# with firstmate's own choice recorded, is bound to the same target.
#
# Usage: <PreToolUse JSON on stdin> | bin/fm-jev-pretool-check.sh --claude
#
# Scope: a genuine primary home (fm_primary_scope_matches in
#   bin/fm-primary-scope-lib.sh), outside a task worker (FM_TASK_ID unset),
#   with FM_JEV_GATE not off. Anywhere else it is inert: exit 0, no output.
#
# Classification, owned here, by the tool name's suffix so every Notion or
# Slack MCP server name matches:
#   Notion writes: notion-update-page, notion-create-pages,
#     notion-create-comment, notion-move-pages, notion-duplicate-page,
#     notion-update-data-source, notion-create-view, notion-update-view. The
#     target is notion:<id> from page_id, view_id, data_source_id,
#     database_id, parent_page_id, parent.* or new_parent.* (the first
#     present, in that order), else notion:workspace. A write asserts a state
#     when any string in its input holds merged, done, released, decided, or
#     closed as a word (any case), or when it sets a property whose name holds
#     "status"; it then needs a claim-check on the target. Any other Notion
#     write needs a template ask (claim-check, ticket-status, or ask-scope).
#   Slack sends: slack_send_message and slack_schedule_message; the target is
#     slack:<channel_id>, and a template ask is needed.
#   Bash: a command naming an action script with a Jev gate (fm-spawn.sh,
#     fm-send.sh, fm-teardown.sh, fm-pr-merge.sh, fm-merge-local.sh,
#     fm-control.sh) is refused when its text sets FM_JEV_GATE, because that
#     would switch off the script's own gate; bin/fm-jev-gate-lib.sh owns every
#     other refusal for those scripts.
#
# Verdict: bin/fm-jev.sh target-status, whose header owns the rules. missing
#   and blocked deny with the exact bin/fm-jev.sh command to run; warn allows
#   and prints the warning; ok allows. An ask that found Jev off or failing is
#   ok, so Jev being down never blocks work.
#
# Output (the shape of bin/fm-cd-pretool-check.sh):
#   ALLOW - exit 0, no output.
#   WARN - exit 0, {"systemMessage", "hookSpecificOutput": {hookEventName,
#          additionalContext}} on stdout.
#   DENY - exit 2, {"hookSpecificOutput": {hookEventName, permissionDecision:
#          "deny"}, "systemMessage"} on stderr, stdout empty.
#   FAIL OPEN - empty or malformed stdin, missing jq, or a verdict that could
#               not be read.
set -u

[ "${1:-}" = --claude ] || [ $# -eq 0 ] || { echo "usage: fm-jev-pretool-check.sh --claude < <PreToolUse JSON>" >&2; exit 2; }
[ -z "${FM_TASK_ID:-}" ] || exit 0
[ "${FM_JEV_GATE:-on}" != off ] || exit 0
PAYLOAD=$(cat 2>/dev/null) || exit 0
[ -n "$PAYLOAD" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)} || exit 0
FM_HOME=${FM_HOME:-$FM_ROOT}
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_primary_scope_matches "$FM_ROOT" "$FM_HOME/state" || exit 0

TOOL=$(jq -r '.tool_name // empty' <<<"$PAYLOAD" 2>/dev/null) || exit 0
JEV="bin/fm-jev.sh"

deny() {  # <message>
  jq -cn --arg m "$1" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny"}, systemMessage: $m}' >&2
  exit 2
}

warn() {  # <message>
  jq -cn --arg m "$1" '{systemMessage: $m, hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $m}}'
  exit 0
}

case "$TOOL" in
  Bash)
    CMD=$(jq -r '.tool_input.command // empty' <<<"$PAYLOAD" 2>/dev/null) || exit 0
    case "$CMD" in *FM_JEV_GATE*) ;; *) exit 0 ;; esac
    case "$CMD" in
      *fm-spawn.sh*|*fm-send.sh*|*fm-teardown.sh*|*fm-pr-merge.sh*|*fm-merge-local.sh*|*fm-control.sh*)
        deny "[jev-gate] this command sets FM_JEV_GATE beside an action script, which would switch off the script's Jev gate; run it without FM_JEV_GATE and pass the decision arguments the script asks for" ;;
    esac
    exit 0
    ;;
  *notion-update-page|*notion-create-pages|*notion-create-comment|*notion-move-pages|*notion-duplicate-page|*notion-update-data-source|*notion-create-view|*notion-update-view)
    KIND=notion
    RAW=$(jq -r '.tool_input | (.page_id // .view_id // .data_source_id // .database_id // .parent_page_id
      // (.parent // .new_parent // {} | .page_id // .database_id // .data_source_id) // "workspace") | tostring' <<<"$PAYLOAD" 2>/dev/null) || exit 0
    ASSERTS=$(jq -r '.tool_input |
      ([.. | strings] | any(test("\\b(merged|done|released|decided|closed)\\b"; "i")))
      or ([.. | objects | .properties? | objects | keys[]] | any(test("status"; "i")))' <<<"$PAYLOAD" 2>/dev/null) || exit 0
    ;;
  *slack_send_message|*slack_schedule_message)
    KIND=slack
    RAW=$(jq -r '.tool_input.channel_id // empty' <<<"$PAYLOAD" 2>/dev/null) || exit 0
    [ -n "$RAW" ] || exit 0
    ASSERTS=false
    ;;
  *) exit 0 ;;
esac

TARGET="$KIND:$RAW"
if [ "$ASSERTS" = true ]; then REQUIRE=claim-check; else REQUIRE=template; fi
VERDICT=$(FM_HOME=$FM_HOME "$SCRIPT_DIR/fm-jev.sh" target-status --target "$TARGET" --require "$REQUIRE" 2>/dev/null) || exit 0
KEY=$(FM_HOME=$FM_HOME bash -c '. "$1/fm-jev-lib.sh" && fm_jev_target_key "$2"' _ "$SCRIPT_DIR" "$TARGET" 2>/dev/null) || KEY=$TARGET

CLAIM_CMD="$JEV ask --template claim-check --target $KEY --claim \"<the state this write asserts, one sentence>\" --source <the URL or file you read it from> --evidence \"<a verbatim quote from that source, read this turn>\" --mine <supported|contradicted|not-addressed>"
SCOPE_CMD="$JEV ask --template ask-scope --target $KEY --words \"<the operator's words that asked for this>\" --candidate <this target>=<what it is> [--candidate <another target the words could mean>] --mine <your candidate>"
read -r V_WORD V_ID V_ANSWER V_CONF <<<"$VERDICT"
case "$V_WORD" in
  ok) exit 0 ;;
  warn) warn "[jev-claim-check] warning: Jev answered $V_ANSWER at confidence $V_CONF, below the claim-check floor, to $V_ID on $KEY; the write proceeds" ;;
  blocked)
    deny "[jev-claim-check] Jev answered $V_ANSWER at confidence $V_CONF to claim-check $V_ID on $KEY, so writes to it stay refused until a fresh claim-check on new evidence is answered supported: $CLAIM_CMD; or until the operator's explicit confirmation is recorded: $JEV record-outcome $V_ID \"<the operator's words>\"" ;;
  missing)
    if [ "$REQUIRE" = claim-check ]; then
      deny "[jev-ask] this $TOOL call asserts a state (merged, done, released, decided, or closed, or a status property), so it needs a claim-check on $KEY from the last 30 minutes; read the source now, then run: $CLAIM_CMD (Jev off or failing still counts as asked)"
    fi
    deny "[jev-ask] this $TOOL call needs a Jev ask bound to $KEY from the last 30 minutes; run: $SCOPE_CMD (a claim-check or ticket-status ask on $KEY also counts; Jev off or failing still counts as asked)"
    ;;
esac
exit 0
