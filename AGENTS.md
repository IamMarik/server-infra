# AI Agent Instructions

This repository contains infrastructure only.

## Scope

- Do not add application code.
- Do not add project-specific business logic.
- Do not hardcode application repositories or application names in scripts.
- Application-specific values belong in environment config files, not in infrastructure code.

## Read first

Before changing anything:

1. Read `README.md`.
2. Read `ARCHITECTURE.md`.
3. Read the local `README.md` of the subsystem you are changing.

## Rules

- Git is the source of truth.
- Keep scripts idempotent.
- One subsystem owns one `docker-compose.yml`.
- Do not create new top-level directories without confirmation.
- Do not introduce a new deployment workflow without confirmation.
- Prefer extending an existing module over creating a new one.
- If unsure where a change belongs, stop and ask.

## Configuration

- Environment declarations live in `environments/<env>/environment.yaml`.
- Module values live in `environments/<env>/<module>/config.env`.
- Only `config.env.example` files are committed.
- Real `config.env` files are not committed.

## Deployment

Scripts must read the selected environment and enabled modules. Scripts must not contain a hardcoded list of servers, apps, or enabled modules.
