#!/usr/bin/env bash
# Single owner of the opt-in PR review gate: the worker steps a ship brief adds
# and the one evidence check that holds a GitHub ship PR back until they ran.
# A home opts in with the presence flag config/pr-review-gate
# (docs/configuration.md "PR review gate"). Without it nothing here applies.
# With it, a GitHub pull request of a ship task in no-mistakes or direct-PR
# mode is not registered ready by bin/fm-pr-check.sh, and so not merged by
# bin/fm-pr-merge.sh, which records through it, until the task's evidence
# record data/<id>/review-gate is valid. local-only has no PR and is exempt;
# Gerrit, GitLab, Forgejo, and external review tools are out of scope.
#
# Evidence record format, one field per line:
#   review=<file>             the pr-review-enhanced review artifact, a path
#                             relative to data/<id>/ that must stay inside it
#                             and name a non-empty regular file
#   round=<n> <result>        one line per @claude review-bot round, n counting
#                             1, 2, 3 in order; result is clean (nothing
#                             actionable), fixed (in-scope findings fixed and
#                             pushed), or no-answer (no bot reply within 10
#                             minutes of the request)
# The loop runs 1 to 3 rounds. A round other than the last ends fixed, because
# fixed work gets another round; a loop that stops before round 3 ends clean or
# no-answer.
# fm_review_gate_dod prints the brief section; fm_review_gate_check validates.

fm_review_gate_enabled() {  # <config-dir>
  [ -e "$1/pr-review-gate" ]
}

# 0 when the gate governs this task's PR.
fm_review_gate_applies() {  # <config-dir> <kind> <mode> <provider>
  fm_review_gate_enabled "$1" || return 1
  [ "$2" = ship ] || [ -z "$2" ] || return 1
  case "$3" in no-mistakes|direct-PR|'') ;; *) return 1 ;; esac
  [ "$4" = github ]
}

# 0 when <data>/<id>/review-gate is valid evidence. 1 otherwise, with a
# one-line reason on stdout.
fm_review_gate_check() {  # <data-dir> <task-id>
  local dir="$1/$2" record review='' line n result rounds=0 last='' prev='' bad=''
  record="$dir/review-gate"
  if [ ! -f "$record" ]; then
    printf '%s\n' "no review evidence at $record"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      review=*) review=${line#review=} ;;
      round=*)
        n=${line#round=}; result=${n#* }; n=${n%% *}
        rounds=$((rounds + 1))
        if [ "$n" != "$rounds" ]; then
          bad="round $n is out of order"
        else
          case "$result" in
            clean|fixed|no-answer) last=$result ;;
            *) bad="round $n has result '$result', not clean, fixed, or no-answer" ;;
          esac
          if [ "$rounds" -gt 1 ] && [ "$prev" != fixed ]; then
            bad="round $n follows a $prev round, which ends the loop"
          fi
        fi
        prev=$result
        ;;
      '') ;;
      *) bad="unrecognised line '$line'" ;;
    esac
  done < "$record"
  case "$review" in
    ''|/*|../*|*/../*|*/..|..)
      printf '%s\n' "review artifact '${review}' in $record is not a path inside $dir"
      return 1 ;;
  esac
  if [ ! -f "$dir/$review" ] || [ ! -s "$dir/$review" ]; then
    printf '%s\n' "review artifact $dir/$review is missing or empty"
    return 1
  fi
  if [ -n "$bad" ]; then
    printf '%s\n' "bot loop record in $record is invalid: $bad"
    return 1
  fi
  if [ "$rounds" -eq 0 ] || [ "$rounds" -gt 3 ]; then
    printf '%s\n' "bot loop record in $record has $rounds rounds, not 1 to 3"
    return 1
  fi
  if [ "$last" = fixed ] && [ "$rounds" -lt 3 ]; then
    printf '%s\n' "bot loop record in $record ends with fixed round $rounds, so the next round is still owed"
    return 1
  fi
  return 0
}

# The Definition of done addition for a gated ship brief, or nothing.
fm_review_gate_dod() {  # <config-dir> <data-dir> <task-id> <mode> <forge>
  local config=$1 data=$2 id=$3 mode=$4 forge=$5
  fm_review_gate_enabled "$config" || return 0
  case "$mode" in no-mistakes|direct-PR) ;; *) return 0 ;; esac
  [ "$forge" = none ] || return 0
  cat <<EOF

## PR review gate (home configuration)
Before your PR \`done:\` report, run this review chain on the open PR, in order, and record it; firstmate refuses to register or merge a GitHub PR whose record is missing or invalid.
1. Run the pr-review-enhanced skill on the PR, single-pass, save its findings to a file under \`$data/$id/\`, and fix every in-scope finding.
2. Run the @claude review-bot loop for at most 3 rounds: post a PR comment that starts with \`@claude review\`, then wait for the bot's reply.
   A round ends clean when the reply has nothing actionable, fixed when you fixed its in-scope findings and pushed them, or no-answer when no reply came within 10 minutes of the request; a no-answer round ends the loop and you move on.
   Request the next round only after a fixed round, and stop after round 3 whatever its result.
3. Push every fix the way your Definition of done pushes (under no-mistakes, run /no-mistakes again rather than pushing from this copy) and get CI green again.
4. Write \`$data/$id/review-gate\` with one \`review=<file>\` line naming the findings file relative to \`$data/$id/\`, then one \`round=<n> <clean|fixed|no-answer>\` line per round, numbered from 1.
EOF
}
