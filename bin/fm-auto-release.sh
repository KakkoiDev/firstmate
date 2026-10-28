#!/usr/bin/env bash
# fm-auto-release.sh - clean up finished workers without asking, so dead copies
# never hold the pool slots or project places a new spawn needs.
#
# Usage: fm-auto-release.sh
#
# For every task record in this home, it runs the ordinary bin/fm-teardown.sh
# <id>, never --force, when the task is finished:
#   - a ship whose recorded pr= this home already saw merged: a merge-poll
#     notification marker or retirement receipt matching that PR
#     (bin/fm-pr-lib.sh owns both), so the sweep itself makes no forge call;
#   - a scout whose data/<id>/report.md exists and whose last status state is
#     done. Teardown still runs the scout's captain-call completion gate.
# Secondmates and every other record are left alone.
# Teardown keeps every landed-work refusal, so unlanded work is never discarded.
# Output is one line per task it acted on, nothing otherwise:
#   released <id> (<why>)
#   released <id> (<why>); its pool slot was lost: <teardown's last line>
#   refused <id> (<why>): <teardown's last line>
# It exits 0 even when a cleanup refuses; those lines are the report.
# bin/fm-wake-drain.sh runs it on every heartbeat, and bin/fm-spawn.sh runs it
# when a spawn is deferred for project capacity.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, FM_DATA_OVERRIDE select the home.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

case "${1:-}" in
  '') ;;
  -h|--help) sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) printf 'fm-auto-release: unknown argument: %s\n' "$1" >&2; exit 2 ;;
esac

meta_value() {  # <meta> <key>
  sed -n "s/^$2=//p" "$1" | head -1
}

last_state() {  # <status-file>
  [ -f "$1" ] || return 0
  sed -n -E 's/^(working|needs-decision|blocked|paused|done|failed)( \[[^]]*\])?:.*/\1/p' "$1" | tail -1
}

pr_merged() {  # <id> <meta>
  fm_pr_metadata_identity_parse "$2" && [ -n "$FM_PR_META_URL" ] || return 1
  fm_pr_poll_merge_already_notified "$STATE" "$1" "$FM_PR_META_PROVIDER" \
    "$FM_PR_META_HOST" "$FM_PR_META_PATH" "$FM_PR_META_NUMBER" && return 0
  fm_pr_poll_retirement_receipt_valid "$STATE" "$1"
}

for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  id=$(basename "$meta" .meta)
  fm_pr_task_id_valid "$id" || continue
  why=
  case "$(meta_value "$meta" kind)" in
    ship) ! pr_merged "$id" "$meta" || why="PR merged" ;;
    scout)
      [ -f "$DATA/$id/report.md" ] && [ "$(last_state "$STATE/$id.status")" = "done" ] \
        && why="report done" ;;
  esac
  [ -n "$why" ] || continue
  rc=0
  out=$("$SCRIPT_DIR/fm-teardown.sh" "$id" 2>&1) || rc=$?
  last=$(printf '%s\n' "$out" | sed '/^[[:space:]]*$/d' | tail -1)
  case "$rc" in
    0) printf 'released %s (%s)\n' "$id" "$why" ;;
    4) printf 'released %s (%s); its pool slot was lost: %s\n' "$id" "$why" "$last" ;;
    *) printf 'refused %s (%s): %s\n' "$id" "$why" "$last" ;;
  esac
done
exit 0
