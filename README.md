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
├── server.env.example
├── modules.env.example
├── rfc/
├── scripts/
├── environments/
├── proxy/
└── monitoring/
```

## Core model

- **Host configuration** describes a server identity, role, and enabled
  modules.
- **Module** provides one infrastructure capability.
- **Scripts** apply host configuration and operate modules.
- **Applications are outside this repository.**

## Quick start

The current commands use the legacy repository-local environment contract
during migration:

```bash
./scripts/health.sh prod-app
./scripts/deploy.sh prod-app
```

Current scripts are foundation stubs. They validate repository conventions and prepare the deployment flow; service deployment is implemented incrementally.

The `environments/` flow is retained temporarily for rollback while runtime
configuration migrates to `/etc/server-infra`. Do not add new runtime values
or secrets to the repository.

## Repository check

Validate that known runtime and secret filenames are not tracked:

```bash
./scripts/check-repository.sh
```

This check is safe to run locally and in CI. It does not read or print runtime
secret contents.

Validate an external host configuration without executing it or changing the
host:

```bash
./scripts/validate-config.sh --config-root /etc/server-infra
```

Run the complete deployment preflight, including Docker Compose resolution,
without changing runtime state:

```bash
./scripts/deploy.sh --config-root /etc/server-infra --check
```

External deployment remains opt-in during migration. The positional
environment command is retained as the explicit rollback path. Applying
external configuration requires an additional explicit operation:

```bash
./scripts/deploy.sh --config-root /etc/server-infra --apply
```

For migration, apply requires the expected Compose project to exist so a typo
in `SERVER_INFRA_INSTANCE` cannot silently create new empty named volumes.
`--allow-new-project` is reserved for intentional first deployment of a new
module.

Preview host layout preparation for the proxy:

```bash
./scripts/install.sh --module proxy --check
```

On the Linux host, apply creates only directories and optional `*.example`
files. It never creates active runtime files or secrets:

```bash
sudo ./scripts/install.sh --module proxy --apply --install-examples
```

## Documentation

- `ARCHITECTURE.md` explains the system model.
- `STYLE.md` defines repository style rules.
- `AGENTS.md` gives AI-agent instructions.
- Each module has its own `README.md`.
- `rfc/0002-external-runtime-configuration.md` defines the safe runtime
  configuration migration.
