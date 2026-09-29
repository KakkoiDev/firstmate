---
name: jev-shadow
description: >-
  Agent-only protocol for Jev as the decision step at every typed decision point.
  Load at session start and follow it at each decision point it lists.
  The action scripts ask Jev themselves; Jev's answer acts only for a type the operator listed in config/jev-authority.
user-invocable: false
metadata:
  internal: true
---

# Jev decision step

Every typed decision below is asked of Jev with firstmate's own choice recorded blind first.
The acting answer is firstmate's choice unless the operator listed the type in `config/jev-authority` and Jev answered at or above its floor; `docs/configuration.md` "Jev authority" owns that file.
No rule elsewhere in firstmate is relaxed by this skill, and Jev off or failing never blocks work.

## Protocol at each decision point

1. Decide first, so Jev's answer cannot anchor your choice.
2. Where the action script asks for you, pass your choice as the argument it names; the script refuses without it and prints the exact argument or `bin/fm-jev.sh ask` command.
3. Where a decision is made before the script runs, write a short English context file with only the evidence the question needs, then ask with your choice as `--mine`:
   `bin/fm-jev.sh ask --type <type> --summary "<one English line>" --question "<wording>" --option <id>... --context <file> --mine <your choice>` (or `--yes-no`).
   Pass the printed decision id to the script, or `off` when `ask` printed nothing.
4. Act on the acting answer: the `acting:` line `ask` prints, the line a script prints on stderr, or your own choice when nothing was recorded.
5. When a human later corrects or overrides that decision, run `bin/fm-jev.sh record-outcome <decision-id> "<what the human said>"`, adding `--final <choice>` when the choice actually taken changed; the outcome is graded against whichever party decided.

Never wait on, retry, or argue with a Jev answer.
`bin/fm-jev.sh --help` owns the command syntax and record semantics, and `bin/fm-jev-gate-lib.sh` owns the script-embedded question wording.

## Decision points

Options in angle brackets are filled from the live registry or fleet at the time of asking.

| Type | Asked by | Question | Options |
| --- | --- | --- | --- |
| `project-match` | you, before `fm-spawn.sh --decision project-match=<id\|off>` | Which registered project is this request about? | `<each registered project>`, `none`, `several` |
| `deliverable-class` | you, before `fm-spawn.sh --decision deliverable-class=<id\|off>` | Should this request ship a change, scout for knowledge, or be answered from existing evidence? | `ship`, `scout`, `answer-from-evidence` |
| `secondmate-scope` | you, before `fm-spawn.sh --decision secondmate-scope=<id\|off>` when secondmates are registered | Which persistent secondmate scope fits this work? | `<each registered secondmate id>`, `main` |
| `surface-class` | you, before `fm-spawn.sh --decision surface-class=<id\|off>` for a ship on a `no-mistakes-prod-only` project | Is this task's surface internal-only, product-facing, mixed, or uncertain? | `internal-only`, `product-facing`, `mixed`, `uncertain` |
| `concurrency` | `fm-spawn.sh --concurrency <choice>` | Can this task run in parallel with work under way, or what blocks it? | `parallel`, `semantic-dependency`, `shared-external-state`, `migration-conflict` |
| `effort-level` | `fm-spawn.sh`, from `--effort` or `default` | Which reasoning effort fits this task? | `low`, `medium`, `high`, `xhigh`, `max`, `ultra`, `default` |
| `dispatch-rule` | `bin/fm-dispatch-resolve.sh` itself | the rule match | record with `record-mine latest:dispatch-rule <rule_N or default>` |
| `mid-task-ask` | `fm-send.sh --mid-task-ask <choice>`, or `--not-a-decision` for a steer that answers nothing | Does this mid-task ask invalidate the work under way, or is it a follow-up or downstream correction? | `invalidates`, `follow-up`, `downstream-correction` |
| `stuck-worker` | `fm-control.sh <id> interrupt\|relaunch --worker-state <choice>` | Which state best describes this worker? | `working`, `waiting-on-answered-question`, `looping`, `confused`, `unresponsive` |
| `merge-risk` | `fm-pr-merge.sh` and `fm-merge-local.sh --merge-risk <yes\|no>` | Is this merge destructive, irreversible, or security-sensitive? | yes/no |
| `report-has-captain-call` | `fm-teardown.sh` for a scout, `--report-has-captain-call <yes\|no>` | Does this report contain a call only the human operator can make? | yes/no |
| `scout-recommends-ship` | `fm-teardown.sh` for a scout, `--scout-recommends-ship <yes\|no>` | Does this scout report recommend shippable work? | yes/no |
| `brief-answers-question` | you, manually, in `stuck-crewmate-recovery` | Do the worker's instructions already answer its question? | yes/no |
| `finding-authority` | you, manually, in `ask-user-authority` | How should this review finding be handled? | `decide-in-scope`, `escalate-expansion`, `escalate-product-call`, `escalate-same-theme`, `escalate-destructive` |
| `heartbeat-suspicious` | you, manually, per task on a heartbeat | Does this task look suspicious enough to inspect now? | yes/no |

The three manual types have no script boundary to enforce them; ask them with `--mine` as in step 3.
`merge-risk`, `finding-authority`, `report-has-captain-call`, and `mid-task-ask` are never handed to Jev, so firstmate's own choice always acts on them.
For `report-has-captain-call`, a Jev answer can only add candidates to your inventory; it never closes or skips the inventory `captain-hold-lifecycle` requires.
A chat-only request with no script boundary still starts at `deliverable-class`; the prompt reminder in `.claude/settings.json` points there and never blocks.
