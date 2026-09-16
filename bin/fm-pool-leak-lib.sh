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
# against the claim each slot carries (bin/fm-treehouse-slot-lib.sh) and against
# the pool's own treehouse-state.json. Only a claim the pool still agrees with
# gets a cleanup command: a slot the pool no longer records, a slot it leases to
# someone other than the claimant, and a pool state that cannot be read are each
# reported with no command, because a claim left behind by a return that died
# half-done names a slot that is already back in the pool. A claim
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
  local state=$1 meta worktree project slot pool key seen
  seen=$'\n'
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    worktree=$(fm_meta_get "$meta" worktree)
    project=$(fm_meta_get "$meta" project)
    [ -n "$worktree" ] && [ -n "$project" ] || continue
    slot=$(CDPATH='' cd -- "$worktree" 2>/dev/null && pwd -P) || continue
    pool=$(dirname "$(dirname "$slot")")
    key="$project -> $pool"
    case "$seen" in
      *$'\n'"$key"$'\n'*) continue ;;
    esac
    seen="$seen$key"$'\n'
    fm_treehouse_pool_slot "$project" "$worktree" || continue
    printf '%s\n' "$pool"
  done | LC_ALL=C sort -u
}

# What the pool itself records for each of its slots, one
# "<slot-directory><tab><lease holder>" line, sorted by nothing in particular.
# Returns 2 when the pool's state cannot be read as the pool's state at all -
# missing, not JSON, or no jq to parse it - because an unreadable pool record is
# not evidence that a claim is still current.
fm_pool_leak_pool_slots() {  # <pool>
  local pool=$1 state raw line path holder dir
  state="$pool/treehouse-state.json"
  [ -f "$state" ] && [ ! -L "$state" ] || return 2
  command -v jq >/dev/null 2>&1 || return 2
  jq -e '(.worktrees | type) == "array"' "$state" >/dev/null 2>&1 || return 2
  raw=$(jq -r '.worktrees[] | [(.path // ""), (.lease_holder // "")] | @tsv' \
    "$state" 2>/dev/null) || return 2
  while IFS=$'\t' read -r path holder; do
    [ -n "$path" ] || continue
    dir=$(CDPATH='' cd -- "$(dirname "$path")" 2>/dev/null && pwd -P) || continue
    printf '%s\t%s\n' "$dir" "$holder"
  done <<EOF
$raw
EOF
}

# 0 = the pool records this slot, and prints the task it leases it to, empty
# when the pool records no holder; 1 = the pool no longer records this slot.
fm_pool_leak_slot_pool_holder() {  # <slot-lines> <slot>
  local lines=$1 slot=$2 line
  while IFS= read -r line; do
    case "$line" in
      "$slot"$'\t'*) printf '%s\n' "${line#*$'\t'}"; return 0 ;;
    esac
  done <<EOF
$lines
EOF
  return 1
}

# Whether the task a claim names still has a worker running.
# 0 = a live endpoint, 1 = no live endpoint, 2 = no record to tear down,
# 3 = a tool the record's backend needs is not resolvable here, so liveness is
#     unknown.
fm_pool_leak_task_state() {  # <home> <task-id>
  local home=$1 id=$2 meta window target backend tool tools
  meta="$home/state/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 2
  window=$(fm_meta_get "$meta" window)
  [ -n "$window" ] || return 1
  backend=$(fm_backend_of_meta "$meta")
  tools=$(fm_backend_required_tools "$backend") || return 3
  for tool in $tools; do
    fm_backend_required_tool_available "$backend" "$tool" || return 3
  done
  target=$(fm_backend_target_of_meta "$meta")
  fm_backend_target_exists "$backend" "${target:-$window}" "fm-$id" || return 1
  return 0
}

# One POOL_LEAK line per held slot, or nothing at all.
fm_pool_leak_report() {  # <state-dir>
  local state=$1 pool slot claim_home claim_id rc name
  local pool_slots pool_rc holder holder_rc
  while IFS= read -r pool; do
    [ -n "$pool" ] || continue
    pool_rc=0
    pool_slots=$(fm_pool_leak_pool_slots "$pool") || pool_rc=$?
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
      if [ "$pool_rc" -ne 0 ]; then
        echo "POOL_LEAK: $pool slot $name claims task $claim_id, but this pool's own $pool/treehouse-state.json could not be read, so nothing here can confirm the slot is still that task's; read that file and $slot by hand before returning anything"
        continue
      fi
      holder_rc=0
      holder=$(fm_pool_leak_slot_pool_holder "$pool_slots" "$slot") || holder_rc=$?
      if [ "$holder_rc" -ne 0 ]; then
        echo "POOL_LEAK: $pool slot $name claims task $claim_id, but this pool no longer records that slot, so returning it is not the fix; inspect $slot for unlanded work, then clear $slot/.fm-slot-owner by hand"
        continue
      fi
      if [ -n "$holder" ] && [ "$holder" != "$claim_id" ]; then
        echo "POOL_LEAK: $pool slot $name claims task $claim_id, but the pool records that slot as leased to $holder; the claim and the pool name different holders, so no command here is safe - reconcile them by hand"
        continue
      fi
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
          echo "POOL_LEAK: $pool slot $name is held by task $claim_id, whose record names a backend whose tools this session cannot all resolve, so whether its worker is still running is unknown; resolve that backend's tools and re-check before tearing the task down"
          ;;
      esac
    done
  done < <(fm_pool_leak_pools "$state")
}
