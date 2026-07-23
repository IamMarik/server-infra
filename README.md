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
├── monitoring/
└── backup/
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

Current scripts validate repository conventions and deploy Compose or native
host modules through an explicit driver contract. Individual infrastructure
capabilities are implemented incrementally.

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

Run the complete deployment preflight, including driver-specific module
validation and Docker Compose resolution when applicable, without changing
runtime state:

```bash
./scripts/deploy.sh --config-root /etc/server-infra --check
```

External deployment remains opt-in during migration. The positional
environment command is retained as the explicit rollback path. Applying
external configuration requires an additional explicit operation:

```bash
./scripts/deploy.sh --config-root /etc/server-infra --apply
```

For migration, apply requires every expected Compose project to exist so a
typo in `SERVER_INFRA_INSTANCE` cannot silently create new empty named
volumes. `--allow-new-project` applies only to an intentional first deployment
of a Compose module.

Preview host layout preparation for the proxy:

```bash
./scripts/install.sh --module proxy --check
```

On the Linux host, apply creates only directories and optional `*.example`
files. It never creates active runtime files or secrets:

```bash
sudo ./scripts/install.sh --module proxy --apply --install-examples
```

Preview or install the host tools required by the backup module:

```bash
./scripts/install-restic.sh --check
sudo ./scripts/install-restic.sh --apply
```

Create the initial server and backup configuration with hidden secret prompts:

```bash
sudo ./scripts/backup-setup.sh
```

The wizard creates root-owned active configuration, preserves existing base
path lists, keeps retention disabled, and validates the result. Secrets are
never accepted as command-line arguments.

Initialize a PostgreSQL Compose backup source from an application repository:

```bash
server-infra-backup project init
```

For files without a database producer:

```bash
server-infra-backup project init --files-only
```

The wizard creates a non-secret `.server-infra/backup` manifest in the
application repository, including a project README and manual restore-check
script. See `backup/README.md` for validation, server installation, listing,
removal, dump testing, and restore instructions. The public command is
installed by applying the `backup` host module. From the application root,
`project validate` and `project install` find this directory automatically.
For PostgreSQL sources, the Compose env file selected by the wizard is
automatically included in the backup paths.

## Documentation

- `ARCHITECTURE.md` explains the system model.
- `STYLE.md` defines repository style rules.
- `AGENTS.md` gives AI-agent instructions.
- Each module has its own `README.md`.
- `rfc/0001-backup-stack.md` defines the host-level backup module and rollout.
- `rfc/0002-external-runtime-configuration.md` defines the safe runtime
  configuration migration.
