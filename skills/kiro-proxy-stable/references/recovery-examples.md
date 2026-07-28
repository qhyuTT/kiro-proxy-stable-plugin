# Recovery examples (Kiro proxy)

## Example A — mid Edit disconnect

User: 中断了，继续

Response pattern:

1. Goal: finish refactor of `auth.ts`
2. Last success: imports updated; `login()` signature changed
3. In flight: body of `login()` not yet patched
4. Next action: Read `auth.ts` around `login`, then one focused Edit

Do not re-run the whole refactor plan.

## Example B — Write truncated / empty tool result

- Do not immediately retry a huge Write.
- Switch to smaller Edit chunks or write a temp section then merge.
- One tool call, verify, then next.

## Example C — user only sends “继续”

Treat as:

- Resume last incomplete step
- Keep the same goal
- No new architecture discussion unless the last step was blocked by a real code error

## Example D — repeated disconnects in one session

1. Shrink batch size to 1–2 tools/turn
2. After a few stable turns, optionally increase again
3. If still unstable, provide a Handoff block and suggest `/clear` + paste handoff
