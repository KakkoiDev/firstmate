#!/usr/bin/env bash
# Startup detection of Treehouse pool slots a finished task never returned.
# Usage: . bin/fm-pool-leak-lib.sh   (needs bin/fm-backend.sh and
#                                     bin/fm-treehouse-slot-lib.sh sourced first)
#
# A pool slot stays out of the pool until cleanup returns it, and Treehouse
# refuses to hand out a slot whose copy is dirty, so a finished task whose
# cleanup never ran costs the whole fleet that slot until someone notices. On
# 2026-09-15 every launch for one project failed for an hour with 11 of 16 slots
# held by tasks that had already finished. Nothing here returns, resets, or
# claims a slot: it reports which slots are held and the exact command that
# returns each one, because two of those slots held staged work no branch
# carried and an automatic sweep would have destroyed it.
#
# Scope: the slots of every pool this home's own task records reach, judged
# against the claim each slot carries (bin/fm-treehouse-slot-lib.sh). A claim
# names the task AND the home that took the slot, so the record it points at is
# read in that home rather than by searching every home on the machine. A claim
# whose home is a directory that does not exist here belongs to another machine
# and is left alone; a claim carrying no home at all names no record anywhere and
# is reported. A slot carrying NO claim is reported by nothing: claims arrived on
# 2026-09-07, so an unclaimed slot was taken before them, and nothing in the
# slot says which of the records naming it is its current holder - the same
# reason cleanup refuses one. Those are a closed, shrinking set.
#
# Pure detection: no locks, no writes, and no network. Every line is prefixed
# POOL_LEAK: and is safe to print in a read-only session.

_FM_POOL_LEAK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Pools reachable from one home's task records, one absolute path per line.
# Discovery reads only this home's state/*.meta records carrying both worktree=
# and project=, so a pool no surviving record names is not discovered and none
# of its slots are examined.
fm_pool_leak_pools() {  # <state-dir>
  local state=$1 meta worktree project slot pool
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    worktree=$(fm_meta_get "$meta" worktree)
    project=$(fm_meta_get "$meta" project)
    [ -n "$worktree" ] && [ -n "$project" ] || continue
    fm_treehouse_pool_slot "$project" "$worktree" || continue
    slot=$(CDPATH='' cd -- "$worktree" 2>/dev/null && pwd -P) || continue
    pool=$(dirname "$(dirname "$slot")")
    printf '%s\n' "$pool"
  done | LC_ALL=C sort -u
}

# Whether the task a claim names still has a worker running.
# 0 = a live endpoint, 1 = no live endpoint, 2 = no record to tear down,
# 3 = the record's backend CLI is not resolvable here, so liveness is unknown.
fm_pool_leak_task_state() {  # <home> <task-id>
  local home=$1 id=$2 meta window target backend
  meta="$home/state/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 2
  window=$(fm_meta_get "$meta" window)
  [ -n "$window" ] || return 1
  backend=$(fm_backend_of_meta "$meta")
  fm_backend_required_tool_available "$backend" "$backend" || return 3
  target=$(fm_backend_target_of_meta "$meta")
  fm_backend_target_exists "$backend" "${target:-$window}" "fm-$id" || return 1
  return 0
}

# One POOL_LEAK line per held slot, or nothing at all.
fm_pool_leak_report() {  # <state-dir>
  local state=$1 pool slot claim_home claim_id rc name
  while IFS= read -r pool; do
    [ -n "$pool" ] || continue
    for slot in "$pool"/*; do
      [ -d "$slot" ] && [ ! -L "$slot" ] || continue
      rc=0
      fm_treehouse_slot_claim_read "$slot" || rc=$?
      name=$(basename "$slot")
      case "$rc" in
        1) continue ;;
        2)
          echo "POOL_LEAK: $pool slot $name carries a slot-owner claim that cannot be read, so nothing can prove whose slot it is; inspect $slot/.fm-slot-owner before any task reuses that slot"
          continue
          ;;
      esac
      claim_id=$FM_TREEHOUSE_SLOT_CLAIM_ID
      claim_home=$FM_TREEHOUSE_SLOT_CLAIM_HOME
      if [ -z "$claim_home" ]; then
        echo "POOL_LEAK: $pool slot $name claims task $claim_id, but its claim records no home, so nothing can find the record whose cleanup returns that slot; inspect $slot for unlanded work, then repair or clear $slot/.fm-slot-owner by hand"
        continue
      fi
      [ -d "$claim_home" ] || continue
      rc=0
      fm_pool_leak_task_state "$claim_home" "$claim_id" || rc=$?
      case "$rc" in
        0) continue ;;
        1)
          echo "POOL_LEAK: $pool slot $name is still held by task $claim_id, whose worker is gone; return it with: FM_HOME=$claim_home $_FM_POOL_LEAK_LIB_DIR/fm-teardown.sh $claim_id"
          ;;
        2)
          echo "POOL_LEAK: $pool slot $name claims task $claim_id, but home $claim_home holds no record for it, so no cleanup command can return that slot; inspect $slot for unlanded work, then clear the claim by hand"
          ;;
        3)
          echo "POOL_LEAK: $pool slot $name is held by task $claim_id, whose record names a backend this session cannot resolve, so whether its worker is still running is unknown; resolve that backend's CLI and re-check before tearing the task down"
          ;;
      esac
    done
  done < <(fm_pool_leak_pools "$state")
}
