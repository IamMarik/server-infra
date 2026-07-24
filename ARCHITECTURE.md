# Architecture

## Mission

`server-infra` manages reusable server-level infrastructure.

It is intentionally independent from applications. The same repository should
be able to configure an application server, a database-only server, a
monitoring server, or a future staging server by changing only host-owned
runtime configuration.

## Boundaries

This repository owns:

- reverse proxy infrastructure;
- server monitoring and operational tools;
- reusable server backup and restore tooling;
- complete-server recovery coordination;
- server bootstrap and health scripts;
- reusable infrastructure module definitions;
- environment-level infrastructure configuration.

This repository does not own:

- application source code;
- application business logic;
- application-specific Docker Compose files;
- application database schemas or migrations;
- application-specific deployment scripts.

## Core concepts

### Host configuration

Host configuration describes a server identity, role, and enabled modules.

Target:

```text
/etc/server-infra/
├── server.env
├── modules.env
├── proxy/
│   └── runtime.env
├── monitoring/
│   └── runtime.env
└── backup/
    ├── runtime.env
    ├── paths
    ├── excludes
    ├── freshness
    ├── sources.d/
    │   └── <project>/
    │       ├── source.conf
    │       ├── recovery.conf
    │       ├── paths
    │       ├── excludes
    │       └── freshness
    ├── removed-sources/
    └── restic-password
```

The host decides which modules are enabled and provides concrete runtime
values. The repository provides only the contract and safe examples.

The repository-local `environments/<environment>` model remains temporarily as
an explicit migration and rollback mechanism.

### Module

A module is a reusable server capability.

Examples:

- `proxy` - public HTTP/HTTPS routing;
- `monitoring` - uptime checks and container log viewing.
- `backup` - encrypted off-site snapshots and restore operations.

A module must not know which application is running on the server.

The backup module may consume externally declared project sources without
hardcoding application names. A project source is installed under
`/etc/server-infra/backup/sources.d/<project>` and contributes data paths,
exclude rules, and freshness markers to the server's data snapshot.

The optional PostgreSQL Compose producer is a constrained generic adapter. It
does not accept arbitrary shell commands, source env files, or store database
passwords. Concrete project paths and service names remain host/application
configuration.

An installed project source may contain non-secret `recovery.conf` metadata
captured from its Git checkout. It records the origin URL and exact commit
seen by `project install`; it does not contain Git credentials or application
deployment logic.

A project source may instead use `SOURCE_TYPE=files-only`. That source adds
reviewed paths and exclusions without a database producer, staging directory,
or project-specific systemd timer.

Modules declare a driver:

- `compose` for Docker Compose services;
- `host` for native host capabilities such as systemd jobs.

The deployment engine dispatches by driver, not by module name. A new module
must not require a module-specific deployment branch.

Host module manifests declare:

```text
HOST_EXECUTABLES="bin/<name> ..."
HOST_PUBLIC_EXECUTABLES="bin/<name> ..."
HOST_REQUIRED_COMMANDS="<command> ..."
HOST_PREFLIGHT_EXECUTABLE="bin/<name>"
HOST_STATE_DIRS="<name> ..."
HOST_CACHE_DIRS="<name> ..."
SYSTEMD_UNITS="systemd/<name>.<type> ..."
SYSTEMD_ENABLE_UNITS="<name>.<type> ..."
```

`HOST_EXECUTABLES` may be empty. Declared executables are installed under
`/usr/local/libexec/server-infra/<module>/`.

`HOST_PUBLIC_EXECUTABLES` may be empty and must be a subset of
`HOST_EXECUTABLES`. Declared public commands are also installed under
`/usr/local/bin/`; internal helpers remain available only through `libexec`.

`HOST_REQUIRED_COMMANDS` lists host dependencies checked before apply.
`HOST_PREFLIGHT_EXECUTABLE` may be empty or name one declared executable. A
preflight receives the active configuration root and must validate without
changing host or external state.

`HOST_STATE_DIRS` and `HOST_CACHE_DIRS` declare non-nested directories below
`/var/lib/server-infra/<module>/` and `/var/cache/server-infra/<module>/`.

`SYSTEMD_UNITS` must contain at least one unit. Units are installed under
`/etc/systemd/system/`. `SYSTEMD_ENABLE_UNITS` may be empty, but every enabled
unit must also be present in `SYSTEMD_UNITS`.

Host artifact declarations are repository-relative, contain no nested paths
beneath `bin/` or `systemd/`, and must not reference symlinks. Template units
are not supported by the initial host driver.

### Script

A script performs one operational action, such as deploy, health, logs, or bootstrap.

Scripts must be idempotent and deterministic. Running the same script multiple times should converge to the same server state.

### Clean host bootstrap

Bootstrap prepares the operating-system foundation before active host
configuration exists. It installs common tooling and creates shared runtime,
state, and cache roots, but it never creates `/etc/server-infra`, application
state, or public routes.

The same bootstrap contract precedes both a new-host setup and disaster
recovery:

```text
trusted repository checkout
  -> clean host bootstrap
  -> create OR restore /etc/server-infra
  -> deploy OR recover projects
```

The approved package, Docker, and security boundaries are defined in
`rfc/0004-clean-host-bootstrap.md`.

### Recovery workflow

`recovery/` is an operator workflow, not a module. It does not have a module
manifest, deployment driver, runtime service, or independent server profile.
It coordinates the existing infrastructure, backup, and project recovery
contracts after complete server loss.

The external break-glass record provides only the credentials and repository
metadata needed before `/etc/server-infra` can be restored. Recovery session
state belongs outside Git under:

```text
/var/lib/server-infra/recovery/
├── session.env
└── projects/
    └── <project>.env
```

The session and project state contain no provider credentials, restic
password, Git private key, restored application value, or application secret.
Project state may record the non-secret name of an isolated PostgreSQL restore
target so an interrupted restore cannot silently continue into another
database.
The restored host configuration and project `recovery.conf` files remain the
sources of truth; the orchestrator must not duplicate their values in a
tracked server description.

The interactive recovery wizard is only a facade over the same non-interactive
operations and state. It may select projects and start a project's PostgreSQL
service, but infrastructure modules remain a distinct deferred plan. It does
not deploy Caddy, start applications, promote databases, change DNS, or enable
traffic.

The approved boundary, bootstrap procedure, and phased state model are defined
in `rfc/0003-disaster-recovery-orchestrator.md`.

## Deployment flow

```text
Host configuration
  ↓
Enabled modules
  ↓
Module manifest + host runtime config
  ↓
Module driver
  ├── compose → Docker Compose services
  └── host    → Native host services and timers
```

The deployment engine should deploy modules generically. Driver-specific
behavior is allowed; module-specific behavior requires a repository-level
architectural decision.

Host-module executables must be installed to a stable host path. Native
services must not execute code directly from a mutable Git checkout.

External deployment performs a complete preflight before changing host
artifacts. Applying a host module requires Linux, root, and systemd. Check mode
validates the repository and host configuration contracts without requiring a
running systemd instance.

## Configuration model

Git is the source of truth for reusable infrastructure code, configuration
contracts, schemas, documentation, and safe examples.

Each deployed Linux host owns its active runtime configuration under:

```text
/etc/server-infra/
```

Modules define reusable structure. A host selects enabled modules and provides
concrete values without changing the repository.

Secrets, domains, server names, application routes, and machine-specific values
must not be committed. Commit deliberately invalid `*.example` files instead.

The tracked `environments/` layout is a legacy deployment contract retained
only for the migration described in
`rfc/0002-external-runtime-configuration.md`. New runtime configuration must not
be added there.

## Engineering principles

1. Git is the source of truth for reusable infrastructure and configuration
   contracts, not deployed runtime values or secrets.
2. Infrastructure never knows applications.
3. Environments describe servers.
4. Modules are reusable capabilities.
5. Scripts are idempotent.
6. Documentation lives close to the thing it describes.
7. Prefer explicit configuration over implicit behavior.
8. Prefer simple shell and Docker Compose before heavier tools.
9. Ask before changing repository structure.

The approved `backup/` top-level module and its host-driver requirements are
defined in `rfc/0001-backup-stack.md`. The approved non-module `recovery/`
workflow is defined in `rfc/0003-disaster-recovery-orchestrator.md`. The
common pre-configuration host preparation contract is defined in
`rfc/0004-clean-host-bootstrap.md`.
