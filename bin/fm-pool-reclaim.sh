#!/usr/bin/env bash
# fm-pool-reclaim.sh - make lossless Treehouse pool slots reusable again, and
# name every slot that stays out of the pool with the reason it stays.
#
# Treehouse reuses an unleased slot only when it is idle, its tree is clean
# (untracked files included), and its HEAD is an ancestor of the reset ref it
# derives from origin/HEAD: the remote branch, or the local one only when the
# local branch is strictly ahead. Two Firstmate habits break that rule:
#   - A slot released with a task branch still checked out, or whose HEAD was
#     landed only on a local default branch that has diverged from origin
#     (local-only landings), is "available" yet never handed out again.
#   - A finished task's slot stays leased until its cleanup runs, and cleanup
#     waits on captain calls the slot itself plays no part in.
#
# Rules, applied only with --apply (the default is a dry run):
#   detach   An unleased, idle, clean slot whose HEAD is not on the reset ref
#            but is contained in a branch or remote-tracking ref is detached
#            onto the merge base of the local and origin default branches,
#            which is an ancestor of whichever one Treehouse resets to. No ref
#            is deleted, so every commit stays reachable from its ref. A slot
#            a task may still resume in is kept: its owner claim's task record
#            still names it or cannot be read, or a record in this home names it.
#   release  A slot leased by this home's task under its own id is returned
#            when that task's last status event is done:, its recorded
#            endpoint is dead or missing (bin/fm-backend.sh's recovery-grade
#            fm_backend_agent_state), the slot is idle and clean, and its HEAD
#            is saved: for a scout, contained in any ref or on the reset ref;
#            for a ship, landed on the local or origin default branch, so the
#            unlanded-work refusal in bin/fm-teardown.sh still sees an
#            unlanded ship's copy. The slot is detached as above, the task's
#            slot-owner claim is dropped, `treehouse return --if-lease-holder`
#            returns it, and the task record's worktree= line is renamed
#            worktree_released= so no record names the slot any more; the
#            task's later cleanup then has no slot to touch.
# Every other non-free slot is reported as kept, with its cause; nothing that
# could hold unique or uncommitted work is ever changed.
#
# The project's Treehouse lock (bin/fm-wake-lib.sh fm_treehouse_project_lock_path)
# is taken for --apply unless --lock-held says the caller already holds it, as
# bin/fm-spawn.sh does right before it asks Treehouse for a slot.
#
# Output: one line per non-free slot, `<action> <slot> <cause>[ <detail>]`, with
# action one of detached, released, would-detach, would-release, kept.
# Exit: 0 after a report, 1 on an unreadable pool or lock, 2 on bad usage.
# Usage: fm-pool-reclaim.sh [--apply [--lock-held]] <project-dir>
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

usage() { echo "usage: fm-pool-reclaim.sh [--apply [--lock-held]] <project-dir>" >&2; exit 2; }

APPLY=0
LOCK_HELD=0
PROJECT=
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --lock-held) LOCK_HELD=1 ;;
    -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
    -*) usage ;;
    *) [ -z "$PROJECT" ] || usage; PROJECT=$1 ;;
  esac
  shift
done
[ -n "$PROJECT" ] && [ -d "$PROJECT" ] || usage

POOL_JSON=$( (cd "$PROJECT" && treehouse status --json) 2>/dev/null) || {
  echo "error: cannot read the Treehouse pool for $PROJECT" >&2
  exit 1
}

# The default branch name, then the commit every reusable slot is detached to.
DEFAULT=$(git -C "$PROJECT" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)
DEFAULT=${DEFAULT#origin/}
[ -n "$DEFAULT" ] || DEFAULT=$(git -C "$PROJECT" symbolic-ref -q --short HEAD 2>/dev/null)
LOCAL_REF=refs/heads/$DEFAULT
REMOTE_REF=refs/remotes/origin/$DEFAULT
git -C "$PROJECT" rev-parse -q --verify "$LOCAL_REF^{commit}" >/dev/null || LOCAL_REF=
git -C "$PROJECT" rev-parse -q --verify "$REMOTE_REF^{commit}" >/dev/null || REMOTE_REF=
if [ -n "$LOCAL_REF" ] && [ -n "$REMOTE_REF" ]; then
  BASE=$(git -C "$PROJECT" merge-base "$LOCAL_REF" "$REMOTE_REF")
elif [ -n "${LOCAL_REF}${REMOTE_REF}" ]; then
  BASE=$(git -C "$PROJECT" rev-parse "${LOCAL_REF}${REMOTE_REF}^{commit}")
else
  BASE=
fi
[ -n "$BASE" ] || { echo "error: cannot resolve the default branch of $PROJECT" >&2; exit 1; }

if [ "$APPLY" = 1 ] && [ "$LOCK_HELD" = 0 ]; then
  LOCK=$(fm_treehouse_project_lock_path "$PROJECT") || { echo "error: cannot resolve the Treehouse project lock for $PROJECT" >&2; exit 1; }
  fm_lock_try_acquire "$LOCK" || { echo "error: another Treehouse slot allocation or return holds $LOCK" >&2; exit 1; }
  trap 'fm_lock_release "$LOCK"' EXIT
fi

on_ref() {  # <slot> <ref>: HEAD is an ancestor of ref
  [ -n "$2" ] && git -C "$1" merge-base --is-ancestor HEAD "$2" 2>/dev/null
}

# Why a tree is not clean, counting untracked files as Treehouse does; prints
# nothing for a clean tree. One status call, the costly step on a large slot.
slot_dirty_cause() {  # <slot>
  local out line nested=0 other=0
  if ! out=$(git -C "$1" status --porcelain --untracked-files=all 2>/dev/null); then
    echo "git-unreadable"
    return
  fi
  [ -n "$out" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      '?? '*) if [ -e "$1/${line#?? }/.git" ]; then nested=$((nested + 1)); else other=$((other + 1)); fi ;;
      *) other=$((other + 1)) ;;
    esac
  done <<< "$out"
  if [ "$other" = 0 ]; then echo "nested-git-repo $nested"; else echo "dirty $((nested + other))"; fi
}

slot_in_refs() {  # <slot>: HEAD is contained in a branch or remote-tracking ref
  [ -n "$(git -C "$1" for-each-ref --count=1 --contains HEAD --format=x refs/heads refs/remotes 2>/dev/null)" ]
}

detach_to_base() {  # <slot>
  git -C "$1" checkout -q --detach "$BASE" 2>/dev/null
}

say() { printf '%s %s %s\n' "$1" "$2" "$3"; }

record_names_slot() {  # <meta> <slot>
  local recorded
  recorded=$(fm_meta_get "$1" worktree)
  [ -n "$recorded" ] && [ "$(cd "$recorded" 2>/dev/null && pwd -P)" = "$(cd "$2" && pwd -P)" ]
}

# The task an unleased slot still belongs to, which may resume in it: the slot's
# owner claim while the claimant's record still names the slot or cannot be
# read, else any record in this home that names it. Prints the keep cause or nothing.
slot_task_cause() {  # <slot>
  local slot=$1 home meta
  fm_treehouse_slot_owner_state "$slot" ""
  case "$FM_TREEHOUSE_SLOT_OWNER" in
    unsafe) echo "claim-unreadable"; return ;;
    other)
      home=$FM_TREEHOUSE_SLOT_OWNER_HOME
      if [ "$home" = "$FM_HOME" ]; then meta="$STATE/$FM_TREEHOUSE_SLOT_OWNER_ID.meta"; else meta="$home/state/$FM_TREEHOUSE_SLOT_OWNER_ID.meta"; fi
      if [ ! -f "$meta" ] || [ -L "$meta" ]; then
        echo "claimed-by-$FM_TREEHOUSE_SLOT_OWNER_ID:record-unreadable"
        return
      fi
      record_names_slot "$meta" "$slot" && { echo "claimed-by-$FM_TREEHOUSE_SLOT_OWNER_ID"; return; }
      ;;
  esac
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    record_names_slot "$meta" "$slot" && { echo "named-by-$(basename "$meta" .meta)"; return; }
  done
}

# The release decision for a leased slot; prints the keep cause or nothing.
release_blocker() {  # <slot> <holder>
  local slot=$1 holder=$2 meta last kind backend target agent dirty
  meta="$STATE/$holder.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || { echo "leased-by-$holder:no-record-in-this-home"; return; }
  record_names_slot "$meta" "$slot" || { echo "leased-by-$holder:record-names-another-worktree"; return; }
  last=$(grep -v '^[[:space:]]*$' "$STATE/$holder.status" 2>/dev/null | tail -1)
  case "$last" in
    done*) ;;
    *) echo "leased-by-$holder:last-status-${last%%[ :]*}"; return ;;
  esac
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  agent=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null)
  case "$agent" in
    dead|missing) ;;
    *) echo "leased-by-$holder:done-endpoint-${agent:-unknown}"; return ;;
  esac
  git -C "$slot" rev-parse -q --verify HEAD >/dev/null 2>&1 || { echo "leased-by-$holder:done-git-unreadable"; return; }
  kind=$(fm_meta_get "$meta" kind)
  case "$kind" in
    scout)
      on_ref "$slot" "$BASE" || slot_in_refs "$slot" || { echo "leased-by-$holder:done-commits-only-in-slot"; return; } ;;
    ship)
      on_ref "$slot" "$LOCAL_REF" || on_ref "$slot" "$REMOTE_REF" || { echo "leased-by-$holder:done-ship-awaiting-landing"; return; } ;;
    *) echo "leased-by-$holder:kind-${kind:-unknown}"; return ;;
  esac
  dirty=$(slot_dirty_cause "$slot")
  [ -z "$dirty" ] || echo "leased-by-$holder:done-${dirty// /-}"
}

release_slot() {  # <slot> <holder>
  local slot=$1 holder=$2 meta lock rc=0
  meta="$STATE/$holder.meta"
  lock=$(fm_meta_lock_path "$meta") || return 1
  fm_lock_try_acquire "$lock" || return 1
  detach_to_base "$slot" \
    && (cd "$PROJECT" && treehouse return --if-lease-holder "$holder" "$slot") >/dev/null 2>&1 \
    && fm_treehouse_slot_owner_release "$slot" "$holder" \
    && sed -i.reclaim 's/^worktree=/worktree_released=/' "$meta" \
    && rm -f "$meta.reclaim" || rc=1
  fm_lock_release "$lock"
  return "$rc"
}

while IFS=$'\t' read -r name status holder procs slot; do
  [ -d "$slot" ] || { say kept "$name" "missing-path"; continue; }
  case "$status" in
    available)
      on_ref "$slot" "$REMOTE_REF" && continue
      [ -z "$REMOTE_REF" ] && on_ref "$slot" "$LOCAL_REF" && continue
      if [ "$procs" != 0 ] || [ -n "$(slot_dirty_cause "$slot")" ] || ! slot_in_refs "$slot"; then
        say kept "$name" "head-not-on-base-and-not-saved"
      elif cause=$(slot_task_cause "$slot") && [ -n "$cause" ]; then
        say kept "$name" "$cause"
      elif [ "$APPLY" = 0 ]; then
        say would-detach "$name" "head-not-on-base"
      elif detach_to_base "$slot"; then
        say detached "$name" "head-not-on-base"
      else
        say kept "$name" "detach-failed"
      fi
      ;;
    leased)
      cause=$(release_blocker "$slot" "$holder")
      if [ -z "$cause" ] && [ "$procs" != 0 ]; then cause="leased-by-$holder:done-processes-running"; fi
      if [ -n "$cause" ]; then
        say kept "$name" "$cause"
      elif [ "$APPLY" = 0 ]; then
        say would-release "$name" "leased-by-$holder:done-and-saved"
      elif release_slot "$slot" "$holder"; then
        say released "$name" "leased-by-$holder:done-and-saved"
      else
        say kept "$name" "leased-by-$holder:release-failed"
      fi
      ;;
    dirty) cause=$(slot_dirty_cause "$slot"); say kept "$name" "unleased-$(printf '%s' "${cause:-clean}" | tr ' ' '-')" ;;
    *) say kept "$name" "$status" ;;
  esac
done < <(printf '%s' "$POOL_JSON" | jq -r '.[] | [.name, .status,
  (if (.lease_holder // "") == "" then "-" else .lease_holder end),
  ((.processes // []) | length | tostring), .path] | @tsv')
