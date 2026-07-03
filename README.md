# server-infra

Reusable server infrastructure managed as code.

This repository owns server-level infrastructure only. It does not own application code, application databases, or project-specific deployment logic.

## Goals

- Keep server configuration reproducible.
- Keep infrastructure independent from applications.
- Deploy infrastructure modules from explicit environment configuration.
- Prefer simple shell and Docker Compose over hidden automation.
- Make every operation safe to repeat.

## Repository layout

```text
server-infra/
├── AGENTS.md
├── ARCHITECTURE.md
├── STYLE.md
├── README.md
├── rfc/
├── scripts/
├── environments/
├── proxy/
└── monitoring/
```

## Core model

- **Environment** describes a server role.
- **Module** provides one infrastructure capability.
- **Scripts** apply environments and operate modules.
- **Applications are outside this repository.**

## Quick start

```bash
./scripts/health.sh prod-app
./scripts/deploy.sh prod-app
```

Current scripts are foundation stubs. They validate repository conventions and prepare the deployment flow; service deployment is implemented incrementally.

## Documentation

- `ARCHITECTURE.md` explains the system model.
- `STYLE.md` defines repository style rules.
- `AGENTS.md` gives AI-agent instructions.
- Each module has its own `README.md`.
