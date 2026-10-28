---
name: intent-to-production
description: Load when the captain requests dark factory / intent-to-production work, or an outcome-level feature needs agreement on observable behavior before shipping.
user-invocable: true
---

# Intent to production

Use Firstmate's existing scout, ship, no-mistakes, and merge-authority paths.
This skill owns the boundary between exploration, agreed behavior, and autonomous execution, not a new task runner, reviewer, approval system, or notes plugin.
Firstmate is the only interlocutor with the captain.
Do not turn routine, already specified mechanical work (for example, a dependency version bump) into a mandatory discovery exercise.

## Explore the intention

1. Start from the captain's requested outcome and the present product behavior, not a proposed implementation.
   Find contradictions, missing behavior choices, and acceptance examples that could change what users experience.
   Ask the captain only about genuine ambiguity in desired behavior, scope, or consequences, not about functions, files, frameworks, or routine engineering choices.
2. When investigation, a disposable prototype, or comparison is useful, dispatch a **scout** under the normal Firstmate contract.
   A scout may experiment in scratch space, inspect alternatives, and return evidence, but must not change a shipping project or treat its report as permission to implement.
   Request a report with: observed facts, prototypes or reproduction steps, contradictions, unresolved behavior questions, options and trade-offs, and a recommended product behavior.
   If the meaning is already settled, skip the scout rather than creating a decorative research step.
3. Discuss the scout's findings with the captain.
   Capture the captain's own clarifications and corrections, including when an original request was contradictory.
   Suggestions made by scouts or reviewers are proposals, not accepted requirements.

## Lock the observable behavior

Before dispatching a ship under this workflow, present the captain with one concise specification covering:

- **Outcome:** who can do what in the actual product, including existing behavior that must remain intact.
- **Observable examples:** representative user/AI interactions and what success or failure looks like.
- **Boundaries:** explicit non-goals, prohibited side effects, and integration constraints that affect the outcome.
- **Verification:** how the delivered behavior can be exercised and observed end-to-end, plus any testable acceptance criteria.
- **Open questions:** none that could materially change the intended behavior.

Ask the captain for explicit confirmation of the intended behavior.
A scout's recommendation, silence, previous approval of the overall factory concept, or passing tests is not confirmation of a particular feature specification.
If important questions remain, stay in exploration rather than starting implementation.

Once approved, preserve the captain's original request and actual clarifications under the existing brief's `## Captain's intent` contract.
Put a clear, self-contained, agreed build and acceptance specification under `## Firstmate spec`, with the fact that the captain confirmed it and any applicable non-goals.
Do not let an agent's paraphrase silently become new captain intent.
The agreed brief is the implementation contract; do not introduce a second competing specification store.

## Run the dark factory

Only after agreement, dispatch a **ship** through the existing Firstmate lifecycle, promoting the scout through `scout-completion` when applicable.
Resolve the project's normal delivery mode and run its existing testing and review pipeline, using no-mistakes wherever the project's required posture calls for it.
For this workflow, keep `yolo` **off** until the captain expressly authorizes autonomous merging for the particular task or changes that standing policy.
A worker may choose architecture, files, algorithms, test implementation, and ordinary engineering fixes without asking the captain.
A worker must not expand the agreed product behavior, silently weaken acceptance criteria, redesign unrelated features, or implement an attractive optimization outside the approved scope.
Tests can be added and run to verify the agreed behavior, including actual product interaction; tests are not permission to invent product requirements.
Unexpected technical problems that preserve the approved outcome are solved autonomously and documented.
When an impossible requirement, a material contradiction, a security-sensitive decision, or an unavoidable behavior change arises, stop the affected work and return the concrete choice to Firstmate and the captain.
Do not disguise an unresolved conflict as a successful delivery.
Firstmate does not ask for routine micro-approvals during implementation.

## Deliver evidence and discoveries

The PR and its closing report must distinguish **observed behavior and evidence** from an agent's claim of completion.
Report what was implemented, the commit and test/CI evidence actually observed, the end-to-end interactions demonstrated, and any remaining gaps.
Record unexpected technical changes that preserved the agreed behavior and why they were necessary.
List unrelated optimization opportunities, alternative designs, additional features, and unresolved findings as **deferred recommendations**, without implementing them.
Use the existing no-mistakes PR and validation ownership; do not create a parallel review gate or have an agent certify its own claims by prose alone.
Stop at a ready PR, present the result to the captain, and **do not merge or deploy without separate authorization**.
After the captain reviews discoveries, any desired change to observable behavior starts another exploration/specification cycle, rather than being smuggled into the current ship.

## Scope of this skill

This skill changes Firstmate's delegation behavior, not notes-keeping's task classifier or memory responsibilities.
The notes plugin remains a view of what is being worked on, not an implementation or verification authority.
Do not add a Laya/Jev classifier, policy daemon, new status taxonomy, or other layer merely to restate the agreed brief.
Add a deterministic guard only after an observed failure shows the existing dispatch, no-mistakes, and merge protections cannot enforce a needed boundary.
