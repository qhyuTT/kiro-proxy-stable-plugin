---
name: kiro-proxy-stable
description: Stabilize Claude Code sessions that route through Kiro reverse proxy. Use when Kiro proxy, kiro反代, connection interrupted, tool call failed, mid-stream disconnect, 任务中断, 继续任务, subagent under proxy, or proxy-related instability appears. Covers prevention, subagents, and interruption recovery.
---

# Kiro Proxy Stable Workflow (Claude Code)

> Short version already injected at session start: `scripts/kiro-proxy-rules.txt`. This file is the full playbook — prevention, recovery, subagent handoff.

You are running behind a **Kiro reverse proxy**. Upstream is not native Anthropic. Long single turns, dense tool batches, and oversized Write payloads raise mid-stream disconnect and incomplete `tool_use` risk.

## Why `/goal` is more stable (apply the same shape)

`/goal` keeps working across **many short turns**. Each turn ends before the stream gets huge; a small evaluator then starts the next turn. That pattern is naturally friendlier to Kiro than one giant agent loop.

When the task is long and has a **verifiable done condition**, prefer:

```text
/goal <measurable condition>
```

Examples: tests pass, lint clean, file X contains Y, all call sites migrated.

You still must follow tool rules below inside every turn (including turns started by `/goal`).

## 1. Prevention

### Tool rules (mandatory)

- Use **only Claude Code native tools**: `Read`, `Write`, `Edit`, `Bash`, `Glob`, `Grep`, `LS`, etc.
- **Do not** emit Kiro-native tool names or parameter shapes (`path` / `oldStr` / `newStr` as primary schema). Use Claude Code fields (`file_path`, `old_string`, `new_string`, …).
- Prefer **Edit** over large **Write**.
- Cap payload: ~8–12k characters of new text per Write/Edit; split larger changes into sequential Edits.
- Prefer **≤ 4–6 tool calls per turn**. Finish the batch, report progress, continue next turn.

### Turn design

- Prefer short, verifiable steps (the `/goal` shape) over one mega-turn.
- Read large files with offset/limit; only load what you need.
- Mechanical edits: brief plan, then tools—avoid huge preambles before the first tool call.

### Subagents

Subagents start with **fresh context**. They do not inherit the parent chat history.

- Parent: when spawning a subagent under Kiro proxy, put the goal + last successful step + constraints in the **delegation prompt** (do not assume the child saw prior turns).
- Child: obey the same native-tool and small-batch rules. Prefer returning a short summary upward rather than dumping huge intermediate logs into the parent.
- If a dedicated proxy-safe worker agent is available (`kiro-proxy-worker`), prefer it for implementation chunks.

## 2. Recovery

Signals: connection reset, stalled stream, incomplete tool call, user says 中断了 / 继续 / continue, missing tool result.

1. Do **not** restart the whole task from zero.
2. Restate in three lines: goal → last success → what was in flight.
3. Resume from the **first incomplete step only**.
4. Prefer the smallest action that restores a known-good state.
5. After 2–3 micro-steps succeed, widen batch size again under the limits above.

Corrupted/empty tool results: retry the **same** native tool; after two failures, **1 tool per turn** until stable.

Context too long / repeated proxy failures: offer a Handoff block for `/clear`:

```text
## Handoff
Goal: ...
Done:
- ...
Next:
- ...
Key files: ...
```

Optional: after handoff, restart progress with `/goal <condition>` so auto-continue carries the work.

## 3. Communication

- After each meaningful batch: what changed, what is next.
- User only says「继续」: resume last success, no new long plan.
- Treat disconnects as expected proxy friction; stay procedural.

## 4. Checklist

- [ ] Claude Code native tools only
- [ ] No oversized single Write
- [ ] Modest tools this turn
- [ ] Interrupt loses at most one small step
- [ ] Subagent got goal + constraints in its prompt
- [ ] Long verifiable work considered for `/goal`

## 5. Out of scope

Does not fix proxy protocol bugs, accounts, or network. If still unstable after these rules, bottleneck is upstream—keep small turns + resume (or `/goal`).

## Reference

See `references/recovery-examples.md`.
