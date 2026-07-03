# AI Agent Instructions

This repository contains server-level infrastructure only.

## Before changing files

1. Read `README.md`.
2. Read `ARCHITECTURE.md`.
3. Read `STYLE.md`.
4. If changing a module, read that module's `README.md`.

## Scope

Do not add application code here.
Do not add application-specific deployment logic here.
Do not hardcode project names into infrastructure modules.

Applications belong to their own repositories.

## Rules

- Keep infrastructure reusable.
- Keep scripts idempotent.
- Keep modules independent from applications.
- Do not create new top-level directories without approval.
- Do not introduce new deployment workflows without approval.
- Do not duplicate configuration across modules.
- Prefer extending the existing module contract.

## Change process

For non-trivial changes, state the plan first:

```text
Plan
- What changes.
- What does not change.
- Which architecture rules are affected.
```

If unsure where a change belongs, stop and ask.
