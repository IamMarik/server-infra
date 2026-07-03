# Architecture

## Purpose

`server-infra` is a reusable infrastructure repository for VPS servers.

It owns:

- reverse proxy
- monitoring
- database infrastructure
- security configuration
- backup/restore scripts
- operational scripts

It does not own application code.

## Main model

```text
Infrastructure modules + environment declaration + operational scripts
```

A module describes what can run.

An environment describes what should run on a specific server.

A script applies the environment to the server.

## Repository boundaries

This repository should not know about concrete applications by default.

Examples of forbidden hardcoding in scripts:

```text
ai-tutor-monorepo
en-mentor
aevo-ios
```

Application-specific details may exist only in environment values if they are needed for deployment or routing.

## Modules

Each top-level subsystem is a module:

```text
proxy/
monitoring/
database/
security/
```

A module may contain:

```text
README.md
docker-compose.yml
config/
scripts/
```

The module must be usable independently through Docker Compose.

## Environments

An environment is a declaration of one server role.

Examples:

```text
environments/prod-app
environments/prod-db
```

Each environment has:

```text
environment.yaml
<module>/config.env.example
<module>/config.env       # local/server only
```

`environment.yaml` enables modules:

```yaml
name: prod-app
enabledModules:
  - proxy
  - monitoring
  - security
```

## Deployment flow

```text
server
  ↓
cd ~/projects/server-infra
  ↓
git pull
  ↓
./scripts/deploy.sh <environment>
  ↓
read environment.yaml
  ↓
deploy enabled modules
```

## Configuration rules

- `config.env.example` is committed.
- `config.env` is not committed.
- Use native config files where appropriate.
- Do not put all values into one global env file.
- Keep module configuration close to the module, and environment values in `environments/`.

## Script rules

Scripts must be:

- idempotent
- non-interactive
- readable
- safe by default
- explicit about what they are doing

A script should be safe to run repeatedly.

## Current direction

The first production setup is expected to use:

- Caddy as reverse proxy
- Uptime Kuma for availability monitoring
- Dozzle for Docker logs
- PostgreSQL/Redis infrastructure if needed
- simple shell scripts for deploy, health, logs, backup, restore
