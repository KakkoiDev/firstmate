---
name: jev-shadow
description: >-
  Agent-only protocol for Jev as the decision step at every typed decision point.
  Load at session start and follow it at each decision point it lists.
  The action scripts ask Jev themselves; Jev's answer acts only for a type the operator listed in config/jev-authority.
  The one gating exception is claim-check: a confident contradicted or not-addressed answer holds the Notion write it guards.
user-invocable: false
metadata:
  internal: true
---

# Jev decision step

Every typed decision below is asked of Jev with firstmate's own choice recorded blind first.
The acting answer is firstmate's choice unless the operator listed the type in `config/jev-authority` and Jev answered at or above its floor; `docs/configuration.md` "Jev authority" owns that file.
No rule elsewhere in firstmate is relaxed by this skill, and Jev off or failing never blocks work.
The one exception to shadow-only answers is `claim-check`, below.

## Protocol at each decision point

1. Decide first, so Jev's answer cannot anchor your choice.
2. Where the action script asks for you, pass your choice as the argument it names; the script refuses without it and prints the exact argument or `bin/fm-jev.sh ask` command.
3. Where a decision is made before the script runs, give Jev the raw material, never your account of it: pass each file the decision rests on unedited as `--source` (status lines, the brief, the report excerpt, script output), and ask with your choice as `--mine`:
   `bin/fm-jev.sh ask --type <type> --summary "<one English line>" --question "<wording>" --option <id>... --source <file> [--source <file>]... [--context <note>] --mine <your choice>` (or `--yes-no`).
   The ask adds the operator's verbatim words for this turn, mid-turn messages included, ahead of the sources, and the type's standing rules from `config/jev-constraints` (`docs/configuration.md` "Jev constraints") after them, so copy neither into a file.
   `--context` is an optional note labelled as yours; keep your conclusion and your choice out of it, since the choice is already recorded blind as `--mine`.
   A manual-type ask with neither the operator's words nor a `--source` is refused and prints the command to run instead.
   Pass the printed decision id to the script, or `off` when `ask` printed nothing.
4. Act on the acting answer: the `acting:` line `ask` prints, the line a script prints on stderr, or your own choice when nothing was recorded.
5. When a human later corrects or overrides that decision, run `bin/fm-jev.sh record-outcome <decision-id> "<what the human said>"`, adding `--final <choice>` when the choice actually taken changed; the outcome is graded against whichever party decided.

Never wait on, retry, or argue with a Jev answer; a fresh `claim-check` on new evidence is the one re-ask, below.
When `record-mine` or `ask --mine` prints `jev: WARNING: firstmate disagrees with Jev`, say so to the operator in the final message.
`bin/fm-jev.sh --help` owns the command syntax and record semantics, and `bin/fm-jev-gate-lib.sh` owns the script-embedded question wording.

## Decision points

Options in angle brackets are filled from the live registry or fleet at the time of asking.

| Type | Asked by | Question | Options |
| --- | --- | --- | --- |
| `project-match` | you, before `fm-spawn.sh --decision project-match=<id\|off>` | Which registered project is this request about? | `<each registered project>`, `none`, `several` |
| `deliverable-class` | you, before `fm-spawn.sh --decision deliverable-class=<id\|off>` | Should this message ship a change, scout for knowledge, be answered from a finished worker report or text the captain supplied, steer a worker already on it, or only be acknowledged? | `ship`, `scout`, `answer-from-evidence` (only when the answer already sits in a finished worker report under `data/` or in text the captain supplied; a fresh read of a project, PR, ticket, or outside source is `scout` or `ship`), `steer-existing`, `acknowledge` |
| `secondmate-scope` | you, before `fm-spawn.sh --decision secondmate-scope=<id\|off>` when secondmates are registered | Which persistent secondmate scope fits this work? | `<each registered secondmate id>`, `main` |
| `surface-class` | you, before `fm-spawn.sh --decision surface-class=<id\|off>` for a ship on a `no-mistakes-prod-only` project | Is this task's surface internal-only, product-facing, mixed, or uncertain? | `internal-only`, `product-facing`, `mixed`, `uncertain` |
| `concurrency` | `fm-spawn.sh --concurrency <choice>` | Can this task run in parallel with work under way, or what blocks it? | `parallel`, `semantic-dependency`, `shared-external-state`, `migration-conflict` |
| `effort-level` | `fm-spawn.sh`, from `--effort` or `default` | Which reasoning effort fits this task? | `low`, `medium`, `high`, `default` (with the gate on, `fm-spawn.sh` refuses `xhigh`, `max`, and `ultra` for a ship or scout) |
| `dispatch-rule` | `bin/fm-dispatch-resolve.sh` itself | the rule match | record with `record-mine latest:dispatch-rule <rule_N or default>` |
| `mid-task-ask` | `fm-send.sh --mid-task-ask <choice>`, or `--not-a-decision` for a steer that answers nothing | Does this mid-task ask invalidate the work under way, or is it a follow-up or downstream correction? | `invalidates`, `follow-up`, `downstream-correction` |
| `stuck-worker` | `fm-control.sh <id> interrupt\|relaunch --worker-state <choice>` | Which state best describes this worker? | `working`, `idle-done`, `waiting-on-answered-question`, `looping`, `confused`, `unresponsive`, `parked-at-decision`, `blocked`, `paused-declared-wait`, `failed`, `waiting-on-prompt`, `unread-instructions`, `held-for-captain`, `endpoint-gone`, `state-unknown` (`bin/fm-jev-gate-lib.sh` owns each id's meaning and source; the ask carries the live crew-state line, unread inbox count, and screen tail) |
| `merge-risk` | `fm-pr-merge.sh` and `fm-merge-local.sh --merge-risk <yes\|no>` | Is this merge destructive, irreversible, or security-sensitive? | yes/no |
| `report-has-captain-call` | `fm-teardown.sh` for a scout, `--report-has-captain-call <yes\|no>` | Does this report contain a call only the human operator can make? | yes/no |
| `scout-recommends-ship` | `fm-teardown.sh` for a scout, `--scout-recommends-ship <yes\|no>` | Does this scout report recommend shippable work? | yes/no |
| `brief-answers-question` | you, manually, in `stuck-crewmate-recovery` | Do the worker's instructions already answer its question? | yes/no |
| `finding-authority` | you, manually, in `ask-user-authority` | How should this review finding be handled? | `decide-in-scope`, `escalate-expansion`, `escalate-product-call`, `escalate-same-theme`, `escalate-destructive` |
| `heartbeat-suspicious` | you, manually, per task on a heartbeat | Does this task look suspicious enough to inspect now? | yes/no |

Every script-embedded ask sends a one-line meaning with each option; pass `--option <id>=<meaning>` on a manual ask the same way.
The three manual types have no script boundary to enforce them; ask them with `--mine` as in step 3.
`merge-risk`, `finding-authority`, `report-has-captain-call`, and `mid-task-ask` are never handed to Jev, so firstmate's own choice always acts on them.
For `report-has-captain-call`, a Jev answer can only add candidates to your inventory; it never closes or skips the inventory `captain-hold-lifecycle` requires.
A chat-only request with no script boundary still starts at `deliverable-class`; the prompt reminder in `.claude/settings.json` points there and never blocks.

## Structured asks

`bin/fm-jev.sh ask --template <type> --target <kind>:<id> --mine <choice>` renders required fields into the English state and refuses an ask with a missing field; `bin/fm-jev.sh --help` owns the fields.

| Type | Ask before | Options |
| --- | --- | --- |
| `claim-check` | any Notion write that asserts a state (merged, done, released, decided, closed) and any ticket status write; the evidence is a verbatim quote read from the source this turn | `supported`, `contradicted`, `not-addressed` |
| `ticket-status` | moving a ticket from its current value to a proposed one | `<the proposed value>`, `keep-current` |
| `ask-scope` | any other Notion write or Slack send, naming the operator's words and each target they could cover | `<each candidate>`, `several`, `unclear` |

On a Claude Code primary, the PreToolUse hook refuses a Notion write or Slack send without a template ask bound to its target from the last 30 minutes, and its refusal prints the exact ask to run; an ask that found Jev off or failing counts as asked.
`claim-check` is the one type that gates: an answer of `contradicted` or `not-addressed` at or above the claim-check floor keeps writes to that target refused until a fresh `claim-check` with new evidence is answered `supported`, or until `bin/fm-jev.sh record-outcome <decision-id> "<the operator's words>"` records the operator's explicit confirmation.
Below the floor the write proceeds with a warning; `docs/configuration.md` "Jev authority" owns the floor file.
Every other type, templated or not, stays shadow-only.

## Turn-end section

When a turn made Jev asks, the final message carries the output of `bin/fm-jev.sh turn --since <turn start>` verbatim: the `Jev asks this turn (<n>)` header and one line per ask.
Each line marked `[DISAGREE]` also needs a line outside the section that names the disagreement with the word "disagree" and the question type.
On a Claude Code primary, the Stop hook refuses a turn end that lacks either and prints the command with the turn start filled in.
