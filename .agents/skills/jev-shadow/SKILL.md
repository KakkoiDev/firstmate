---
name: jev-shadow
description: >-
  Agent-only shadow protocol for asking Jev at every typed decision point.
  Load at session start and follow it at each decision point it lists.
  Jev's answer is logged beside firstmate's own and never decides anything.
user-invocable: false
metadata:
  internal: true
---

# Jev shadow

Firstmate asks Jev at every decision point below, records its own choice beside Jev's, and acts on its own choice.
No decision is ever taken on Jev's answer alone, and no rule elsewhere in firstmate is relaxed by this skill.
The purpose is agreement data per question type, so a type can graduate to Jev authority only after the captain reviews `bin/fm-jev.sh report`.

## Protocol at each decision point

1. Decide first. State your own choice in your reasoning before you ask, so Jev's answer cannot anchor it.
2. Write a short English context file with only the evidence the question needs, then ask:
   `bin/fm-jev.sh ask --type <type> --summary "<one English line>" --question "<wording>" --option <id>... --context <file>` (or `--yes-no`).
3. Act on your own choice from step 1, exactly as you would without Jev.
4. When `ask` printed a decision id, record your step 1 choice even when Jev disagrees: `bin/fm-jev.sh record-mine <decision-id> <your choice>`.
   Empty stdout means Jev was off or failed; there is nothing to record and nothing else changes.
5. When the captain later corrects or overrides that decision, run `bin/fm-jev.sh record-outcome <decision-id> "<what the captain said>"`, adding `--final <choice>` when the choice actually taken changed.

Never wait on, retry, or argue with a Jev answer, and never mention it to the captain unless asked for the report.
`bin/fm-jev.sh --help` owns the command syntax and record semantics.

## Decision points

Options in angle brackets are filled from the live registry or fleet at the time of asking.

| Type | Where | Question | Options |
| --- | --- | --- | --- |
| `project-match` | `AGENTS.md` section 7, resolving the project | Which registered project is this request about? | `<each registered project>`, `none`, `several` |
| `secondmate-scope` | section 7, routing by scope | Which persistent secondmate scope fits this work? | `<each registered secondmate id>`, `main` |
| `deliverable-class` | section 7, classifying the deliverable | Should this request ship a change, scout for knowledge, or be answered from existing evidence? | `ship`, `scout`, `answer-from-evidence` |
| `surface-class` | section 7, `no-mistakes-prod-only` surface rule | Is this task's surface internal-only, product-facing, mixed, or uncertain? | `internal-only`, `product-facing`, `mixed`, `uncertain` |
| `concurrency` | section 7, overlap and serialization | Can this task run in parallel with work under way, or what blocks it? | `parallel`, `semantic-dependency`, `shared-external-state`, `migration-conflict` |
| `dispatch-rule` | section 4, `bin/fm-dispatch-resolve.sh` | asked by the resolver itself | record with `record-mine latest:dispatch-rule <rule_N or default>` |
| `effort-level` | `harness-adapters` effort fallback | Which reasoning effort fits this task? | `low`, `medium`, `high`, `xhigh` |
| `stuck-worker` | section 8 wake step 2, `stuck-crewmate-recovery` | Which state best describes this worker? | `working`, `waiting-on-answered-question`, `looping`, `confused`, `unresponsive` |
| `brief-answers-question` | `stuck-crewmate-recovery` | Do the worker's instructions already answer its question? | yes/no |
| `finding-authority` | `ask-user-authority` | How should this review finding be handled? | `decide-in-scope`, `escalate-expansion`, `escalate-product-call`, `escalate-same-theme`, `escalate-destructive` |
| `mid-task-ask` | `validation-supervision` | Does this mid-task ask invalidate the work under way, or is it a follow-up or downstream correction? | `invalidates`, `follow-up`, `downstream-correction` |
| `merge-risk` | section 7, merges that still escalate | Is this merge destructive, irreversible, or security-sensitive? | yes/no |
| `heartbeat-suspicious` | section 8 wake step 4, per task | Does this task look suspicious enough to inspect now? | yes/no |
| `report-has-captain-call` | `captain-hold-lifecycle` | Does this report contain a call only the captain can make? | yes/no |
| `scout-recommends-ship` | `scout-completion` | Does this scout report recommend shippable work? | yes/no |

For `report-has-captain-call`, a Jev answer can only add candidates to your inventory; it never closes or skips the inventory `captain-hold-lifecycle` requires.
