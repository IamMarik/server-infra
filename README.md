# server-infra

Reusable infrastructure repository for one or more VPS servers.

The repository does not know about application projects. It only contains infrastructure modules, environment declarations, and operational scripts.

## Core idea

```text
module + environment + script = configured server
```

Examples:

```bash
./scripts/deploy.sh prod-app
./scripts/health.sh prod-app
./scripts/logs.sh prod-app monitoring
```

## Repository layout

```text
AGENTS.md            AI agent instructions
ARCHITECTURE.md      repository architecture
bootstrap/           first-time server setup docs/scripts
proxy/               reverse proxy module
monitoring/          uptime/log monitoring module
database/            database module/security backup docs
security/            security module/docs
environments/        server declarations and config examples
scripts/             operational commands
```

## Workflow

1. Change files locally.
2. Commit and push.
3. On the server:

```bash
cd ~/projects/server-infra
git pull
./scripts/deploy.sh prod-app
```

Git is the source of truth. The server is not.
