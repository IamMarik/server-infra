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
├── bootstrap/
├── proxy/
├── monitoring/
├── backup/
└── recovery/
```

## Core model

- **Host configuration** describes a server identity, role, and enabled
  modules.
- **Module** provides one infrastructure capability.
- **Scripts** apply host configuration and operate modules.
- **Recovery workflow** coordinates rebuild and restore after complete server
  loss without becoming an application deployment system.
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

## Clean host bootstrap

After creating a Debian or Ubuntu VM, establishing SSH access, and cloning
this repository, prepare the common host foundation:

```bash
./scripts/bootstrap.sh --check
sudo ./scripts/bootstrap.sh --apply
```

Bootstrap installs Git, the OpenSSH client, CA certificates, curl, jq,
dialog, restic, Docker Engine, and Docker Compose and prepares the shared
runtime roots. It never creates `/etc/server-infra`, creates operator
accounts, changes SSH or firewall policy, or starts public infrastructure.
See `bootstrap/README.md`.

## Repository check

Validate that known runtime and secret filenames are not tracked:

```bash
./scripts/check-repository.sh
```

This check is safe to run locally and in CI. It does not read or print runtime
secret contents.

## Terminal output

Operator commands retain stable `[server-infra]`, `[ok]`, `[warn]`, and
`[error]` prefixes. In an interactive terminal they also use color and compact
status symbols. Redirected output, systemd, cron, and CI remain plain by
default, without ANSI escape sequences or Unicode symbols.

Control the presentation explicitly when needed:

```bash
SERVER_INFRA_OUTPUT=plain server-infra-backup check
SERVER_INFRA_OUTPUT=pretty server-infra-backup check
NO_COLOR=1 server-infra-backup check
```

`SERVER_INFRA_OUTPUT` accepts `auto` (the default), `pretty`, or `plain`.
`NO_COLOR` disables ANSI color while retaining a terminal-appropriate symbol.
Non-UTF-8 terminals use ASCII fallbacks.

Validate an external host configuration without executing it or changing the
host:

```bash
./scripts/validate-config.sh
```

Run the complete deployment preflight, including driver-specific module
validation and Docker Compose resolution when applicable, without changing
runtime state:

```bash
./scripts/deploy.sh --check
```

External deployment remains opt-in during migration. The positional
environment command is retained as the explicit rollback path. Applying
external configuration requires an additional explicit operation:

```bash
./scripts/deploy.sh --apply
```

These commands default to `/etc/server-infra`. Pass `--config-root` only for
tests or a non-standard host layout.

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
path lists, keeps retention disabled, optionally configures Uptime Kuma, and
validates the result. Secrets are never accepted as command-line arguments.

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

Manually run or inspect an installed PostgreSQL dump producer from its
application checkout:

```bash
sudo server-infra-backup project dump
sudo server-infra-backup project status
sudo server-infra-backup project logs
sudo server-infra-backup project restore-db \
  --target-db my_app_restore
```

For complete VM loss, keep the secret break-glass record outside the server
and follow [backup/RECOVERY.md](backup/RECOVERY.md). On the replacement host,
clone the exact server-infra ref, apply the common bootstrap, then initialize
a non-secret resumable session. The recommended interactive entry point wraps
the same recovery state machine:

```bash
sudo ./scripts/bootstrap.sh --apply
sudo ./recovery/bin/server-infra-recovery-wizard
```

The wizard validates remote backup access, presents configuration and data
snapshots newest-first, displays infrastructure as deferred work, and lets the
operator select projects through a terminal checklist. PostgreSQL is restored
into a new isolated database after starting only its Compose database service.
It does not start applications, deploy Caddy, change DNS, or enable traffic.
The default secret input is `server-infra-break-glass.txt` in the repository
root; that filename is ignored by Git and must have mode `0600`. New
project checkouts are owned by the SSH operator inferred from `SUDO_USER`,
while root remains responsible for host configuration and recovery state.
The Git user has an explicit CLI override for automation.

Interactive terminals use the dialog-based TUI automatically. Arrow keys,
Space, Enter, and compatible terminal mouse events control snapshot and
project selection. Use `--ui plain` for a serial console or minimal terminal;
`--ui tui` requires an interactive terminal. Re-running the wizard keeps the
pinned snapshots, excludes completed projects, and preselects pending or
interrupted projects.

The non-interactive commands remain available for automation and diagnosis:

```bash
sudo ./recovery/bin/server-infra-recovery init
sudo ./recovery/bin/server-infra-recovery config-snapshots
sudo ./recovery/bin/server-infra-recovery restore-config \
  --snapshot <config-snapshot-id>
```

After configuration recovery, pin one data point for every project:

```bash
sudo ./recovery/bin/server-infra-recovery data-snapshots
sudo ./recovery/bin/server-infra-recovery select-data \
  --snapshot <data-snapshot-id>
```

Then validate the recovered project inventory and recreate each exact Git
checkout as an ordinary user:

```bash
sudo ./recovery/bin/server-infra-recovery projects-plan
sudo ./recovery/bin/server-infra-recovery clone-project \
  --name <project-name>
sudo ./recovery/bin/server-infra-recovery restore-project-files \
  --name <project-name>
sudo ./recovery/bin/server-infra-recovery restore-project-db \
  --name <project-name> \
  --target-db <project>_recovered \
  --start-service
```

The database command always uses the session's pinned data snapshot and
restores into a new isolated database. Application validation and traffic
cutover remain operator-guided. See `recovery/README.md`.

## Documentation

- `ARCHITECTURE.md` explains the system model.
- `STYLE.md` defines repository style rules.
- `AGENTS.md` gives AI-agent instructions.
- Each module has its own `README.md`.
- `rfc/0001-backup-stack.md` defines the host-level backup module and rollout.
- `rfc/0002-external-runtime-configuration.md` defines the safe runtime
  configuration migration.
- `rfc/0003-disaster-recovery-orchestrator.md` defines the approved recovery
  workflow and resumable state.
- `rfc/0004-clean-host-bootstrap.md` defines reproducible preparation of a
  clean Debian or Ubuntu host.
- `bootstrap/README.md` documents clean-host preparation and its security
  boundary.
- `backup/RECOVERY.md` defines the complete-server recovery runbook and
  break-glass record.
