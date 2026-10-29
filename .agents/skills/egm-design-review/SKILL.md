---
name: egm-design-review
description: Load at ship intake before scaffolding a ship brief with bin/fm-brief.sh, to decide whether the task needs an elephant-goldfish (EGM) design review, and before dispatching or completing that review scout.
user-invocable: false
metadata:
  internal: true
---

# EGM design review

[Elephant-Goldfish Model](https://github.com/google/elephant-goldfish-model) (EGM) is an agent plugin that stress-tests a design document with fresh-context reviewer subagents before implementation.
Firstmate runs it as a design gate before a ship, never inside one: every ship brief forbids subagents, and EGM stops rather than review in a single context.
`bin/fm-brief.sh` refuses a ship scaffold until it carries exactly one decision, and its header owns the flags.

## When a task needs the review

Decide at intake, before the ship brief exists.
The review is needed when any of these holds:

- new behavior the captain must agree on before it is built;
- a new subsystem, data model, schema, or API contract;
- a cross-module or cross-project change;
- the captain asks for a design, a spec, or an elephant-goldfish process.

It is skipped for a bug fix with a repro, a refactor, docs, config, or a one-file change.
A skip passes `--no-egm "<reason>"` naming which skip case applies, so the brief records why.
When the captain forces the review on, pass `--egm` with `--egm-review <report>`; when the captain waives it, the `--no-egm` reason quotes that waiver.
Unless `--egm` is passed, the scaffold asks Jev the `egm-review` question with this decision as `--mine`; a disagreement prints like any other Jev ask and never blocks (`jev-shadow`).

## Running the review

1. Scaffold the review as a scout with `bin/fm-brief.sh <id> <repo> --scout` and dispatch it on a harness that has the EGM plugin and a subagent tool: `claude`, `codex`, `omp`, or `agy`.
2. The scout scaffold's Rule 8 forbids subagents, so replace that rule in this one brief with: "You may spawn only the reviewer subagents `/egm:egm-review` itself spawns; spawn nothing else."
   This is the only brief that relaxes Rule 8.
3. In the Firstmate spec, tell the scout to write the design document itself from the captain's intent, then run `/egm:egm-review <design doc> uninterrupted`, stating the files that form the reviewers' reading list or that there is no additional context.
   The `uninterrupted` preset runs every stage without stopping; the brainstorm and draft skills stop for a human at each step, so the scout does not use them.
4. EGM writes its reports into the scout's scratch worktree, so the scout copies the design document and review report into `data/<id>/` and its `report.md` lists the findings and both paths.
5. Complete the scout under `scout-completion`, then scaffold the ship with `--egm-review data/<id>/report.md`, carrying any findings the captain accepts into the ship's Firstmate spec.

## One-time plugin install

The captain installs the plugin once per harness; firstmate and its workers never install it:

- Claude Code: `claude plugin marketplace add google/elephant-goldfish-model && claude plugin install egm@egm`
- Codex: `codex plugin marketplace add google/elephant-goldfish-model && codex plugin add egm@egm`
- omp: `omp plugin marketplace add google/elephant-goldfish-model && omp plugin install egm@egm`
- Antigravity: `agy plugin install https://github.com/google/elephant-goldfish-model`

Tell the review scout that a missing `/egm:egm-review` command means the plugin is absent, and that it then reports blocked instead of reviewing by hand.
