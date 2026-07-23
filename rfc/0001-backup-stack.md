# RFC-0001: Backup Stack

## Status

Accepted.

Implementation status: the architecture, rollout plan, generic host-module
driver, daily backup, weekly integrity check, safe restore command, and
monthly configuration restore test are implemented. The project-source wizard
and constrained PostgreSQL Compose producer are also implemented. Schedule
overrides, generic health/status reporting, and production rollout remain.

## Context

Server backups must remain independent from applications, be safe to run
repeatedly, and store recovery data outside the server failure domain.

The backup system must support:

- encrypted off-site storage;
- incremental snapshots and deduplication;
- explicit retention;
- unattended scheduling;
- repository integrity checks;
- documented restore operations;
- application-provided, consistent database dumps.

Copying live database files is outside the backup module contract because it
does not guarantee a recoverable database snapshot.

The repository already models reusable capabilities as modules selected by
host-owned configuration. Compose is appropriate for long-running services,
but a backup process needs direct and auditable access to host paths and must
remain usable when Docker is unavailable.

## Decision

Use the following stack:

- restic as the backup and restore engine;
- Backblaze B2 as off-site object storage;
- the Backblaze S3-compatible API as the restic backend;
- systemd timers for scheduling;
- native database dump tools before restic snapshots;
- optional Uptime Kuma push monitoring for backup job results.

### Module Model

Add `backup/` as an approved top-level infrastructure module with:

```text
backup/
├── README.md
├── module.env
├── runtime.env.example
├── paths.example
├── excludes.example
├── freshness.example
├── bin/
├── systemd/
└── tests/
```

The backup module uses `MODULE_DRIVER=host`. It is installed and operated by
the same generic module workflow as Compose modules, but it runs as native
systemd services and timers instead of a Docker Compose project.

The generic deployment engine may dispatch by module driver. It must not
contain branches for the backup module itself. Adding another host module
should not require another deployment-engine branch.

The host driver owns generic operations such as:

- validating declared host artifacts;
- installing versioned executables outside the Git checkout;
- installing systemd units atomically;
- reloading systemd after unit changes;
- enabling only the units declared by module metadata;
- providing a check mode that makes no host changes.

Systemd must not execute backup code directly from a mutable Git checkout.

Initial backup configuration may be created by a module-owned interactive
setup helper. The helper must not accept secrets as command-line arguments,
must disable terminal echo for secret input, must write active files with the
declared ownership and modes, must require confirmation before replacing
existing configuration, and must validate locally without initializing or
contacting the remote repository.

### Repository and Host Ownership

Git owns reusable implementation, module metadata, systemd unit templates,
validation rules, documentation, and deliberately invalid examples.

Each server owns active configuration and secrets:

```text
/etc/server-infra/
├── server.env
├── modules.env
└── backup/
    ├── runtime.env
    ├── paths
    ├── excludes
    ├── freshness
    └── restic-password
```

Host-managed backup data and temporary restore data use the existing runtime
layout:

```text
/var/lib/server-infra/backup/
├── staging/
└── state/

/var/cache/server-infra/backup/
└── restore-tests/
```

Active configuration, repository passwords, provider credentials, server
names, repository URLs, and push-monitor URLs must not be committed.

### Storage Isolation

Each production server uses:

- one Backblaze bucket;
- one restic repository;
- one restricted set of provider credentials;
- one independent restic repository password.

Development or staging servers may share a bucket only when each server uses
a separate repository prefix and repository password. A prefix is a logical
repository boundary, not an assumed security boundary.

Servers must not share one restic repository. This avoids cross-server
retention mistakes and limits the impact of a compromised server.

The repository URL is configured explicitly. The implementation must not
derive a bucket or repository URL from `SERVER_INFRA_INSTANCE`.

### Snapshot Model

Each scheduled backup job creates two independently tagged snapshots:

1. A configuration snapshot containing `/etc/server-infra`.
2. A data snapshot containing the server-owned paths from
   `/etc/server-infra/backup/paths`.

The configuration snapshot:

- always includes `/etc/server-infra`;
- does not use the operator-managed data exclusion list;
- uses a stable configuration tag;
- may contain encrypted secrets and therefore requires the independently
  stored repository password for recovery.

The data snapshot:

- reads its source paths from host configuration;
- applies `/etc/server-infra/backup/excludes`;
- includes application or database dumps only through the staging contract;
- uses a stable data tag.

This split makes the mandatory configuration backup enforceable without
trying to interpret every possible restic exclusion pattern.

The complete scheduled job is unhealthy if either required snapshot fails.

### Database Dump Staging Contract

The component that owns a database also owns creation and validation of its
logical dump:

- an application-owned database is dumped by the application;
- a database owned by a future infrastructure `database` module is dumped by
  that module;
- the backup module never contains database names, container names,
  credentials, or database-specific dump commands.

Producers write dumps beneath:

```text
/var/lib/server-infra/backup/staging/
```

A producer must:

1. Write the dump to a temporary file in the destination filesystem.
2. Validate completion using its database-native tooling where practical.
3. Atomically rename the completed dump into its final path.
4. Atomically update a freshness marker only after the dump is complete.

Host configuration declares which freshness markers are required and their
maximum permitted age in `/etc/server-infra/backup/freshness`. Each entry
identifies one absolute marker path and its maximum age using a documented,
non-executable data format. The backup job fails before the data snapshot when
a required marker is missing, invalid, or stale.

The first version does not execute arbitrary application hooks from a
`pre-backup.d` directory. Such hooks would move application execution and
credentials into the infrastructure module.

An opt-in project wizard may install a constrained PostgreSQL Compose dump
producer. This is a built-in, validated adapter rather than an arbitrary
command hook. Its project manifest is non-secret, the active copy is installed
under `/etc/server-infra/backup/sources.d/<project>`, and an env file is passed
only to `docker compose --env-file`; it is never sourced as shell code.

The same wizard may register a `files-only` source. That source contributes
reviewed paths and exclusions but has no database settings, staging directory,
or producer timer.

The adapter:

- supports PostgreSQL only in its first version;
- executes `pg_dump` and archive validation inside the selected service;
- uses the container's `POSTGRES_USER` and `POSTGRES_DB`;
- publishes the dump and freshness marker atomically;
- removes the current marker before dump creation so an overlapping or failed
  producer cannot make an old dump appear fresh;
- never stores or prints the database password.

Project-specific source configuration may be reviewed in the application
repository, but systemd and the backup runner consume only the root-owned copy
installed into the host configuration tree.

Operators manage these sources through one public command namespace:
`server-infra-backup project init|install|validate|list|remove`. The
PostgreSQL producer remains an internal helper under `libexec`. Removal
archives active configuration within `/etc/server-infra`, removes generated
systemd units, and deliberately preserves staged dumps and the application
manifest.

Initialization also creates a project-local `README.md` and
`restore-check.sh`. The restore check is an application-owned manual
verification scaffold and is never copied into active host configuration or
executed by the server backup scheduler.

### Schedule, Retention, and Monitoring

The initial schedule and retention policy are:

- create one snapshot daily at `03:30` in the server timezone;
- keep 14 daily snapshots;
- keep 8 weekly snapshots;
- keep 12 monthly snapshots;
- run a repository metadata check weekly;
- perform and document a restore test monthly.

Host configuration owns:

- the list of data paths included in a snapshot;
- data exclude rules;
- the restic repository URL;
- Backblaze credentials and any required S3-compatible endpoint settings;
- the repository password file location;
- optional, separate Uptime Kuma push URLs for backup, repository check, and
  restore test jobs;
- required dump freshness markers and their maximum age;
- schedule and retention overrides.

The implementation should preserve upstream-standard variables such as
`RESTIC_*` and `AWS_*`. It must avoid storing the same endpoint, bucket, or
repository value in multiple configuration keys.

When monitoring is enabled, backup, repository check, and restore test jobs use
distinct push monitors so that a successful daily backup cannot hide a failed
weekly or monthly job. All three URLs are configured together or left empty.

The repository is initialized only through an explicit operator command.
Scheduled jobs must fail when the configured repository does not exist and
must never initialize a replacement repository automatically.

## Security

Restic encrypts backup contents, but credentials with delete access can still
be used to destroy a repository.

Backblaze bucket versioning or Object Lock must be configured so that a
compromised server cannot immediately destroy all usable snapshots. The exact
retention settings must be validated with restic `forget` and `prune` behavior
before automatic pruning is enabled.

Automatic prune is disabled by default. Enabling it requires a documented
server-specific validation of:

- the active Backblaze versioning or Object Lock policy;
- the credentials used by the server;
- `restic forget` behavior;
- `restic prune` behavior;
- recovery of a retained snapshot after the test.

The restic repository password must also be stored outside the backed-up
server. Losing this password makes recovery impossible.

## Restore Requirements

A backup job is not considered operational until all of the following succeed:

1. The repository is initialized in Backblaze B2.
2. The first snapshot completes.
3. `restic check` succeeds.
4. A snapshot is restored to a temporary location.
5. A database dump, when present, passes an application-owned restore test.
6. Uptime Kuma reports the scheduled job as healthy, when monitoring is
   configured.

Restore operations must target an empty temporary directory by default.
Restoring in place requires an explicit operator action.

The monthly generic restore test restores the configuration snapshot into an
empty directory under `/var/cache/server-infra/backup/restore-tests`, verifies
the expected configuration structure and permissions, records the result, and
removes or rotates temporary test data safely.

Database dump restore tests remain application-owned. A generic restore test
does not prove that a logical database dump can be imported successfully.

## Implementation Plan

### Phase 1: Complete the Generic Host Driver

Status: implemented.

- Make module dispatch depend on `MODULE_DRIVER`, not a module name.
- Keep the current Compose workflow unchanged for Compose modules.
- Require Docker only when at least one selected module uses the Compose
  driver.
- Keep `--check` read-only and usable without systemd on a development host.
- Require Linux, root, and systemd only when applying a host module.
- Install host executables and units atomically from declarative module
  metadata.
- Do not enable or start units until the complete module preflight succeeds.
- Preserve the shared operation lock for install and deployment changes.

The phase is complete when a fixture host module can pass check mode and the
existing Compose modules still resolve without behavioral changes.

### Phase 2: Add the Backup Module

Status: implemented for the default daily schedule. Host-owned schedule
overrides remain before the phase is complete.

- Add the approved `backup/` top-level module.
- Define safe runtime, path, exclusion, freshness, schedule, and retention
  configuration contracts.
- Add repository filename guard coverage for backup secrets and active files.
- Implement explicit repository initialization.
- Implement configuration and data snapshots with distinct tags.
- Implement optional Uptime Kuma success and failure reporting without
  printing push URLs.
- Install and enable the daily systemd timer only after active configuration
  validates.

Automatic prune remains disabled in this phase.

### Phase 3: Add Integrity and Restore Operations

Status: integrity and restore operations implemented. Generic health/status
reporting remains.

- Add the weekly metadata check service and timer. Implemented.
- Add safe restore commands that require an empty destination by default.
  Implemented.
- Add the monthly configuration restore test. Implemented.
- Document application-owned database dump restore testing. Implemented.
- Add optional project source registration and a constrained PostgreSQL
  Compose dump producer. Implemented.
- Add health and status operations for the host module.

### Phase 4: Production Rollout

Status: not started.

For each server:

1. Create the isolated Backblaze bucket, credentials, and repository password.
2. Store an independent recoverable copy of the password outside the server
   failure domain.
3. Install host configuration without committing it.
4. Initialize the repository explicitly.
5. Run the first configuration and data snapshots manually.
6. Run `restic check`.
7. Restore into an empty temporary directory and validate configuration files
   and permissions.
8. Restore and import each required database dump through its owning
   application procedure.
9. Confirm all configured push monitors report healthy, when enabled.
10. Enable timers.
11. Validate Object Lock or versioning and retention behavior before enabling
    automatic prune.

The backup module may be added to a host's `ENABLED_MODULES` only after the
host driver is operational. The external runtime migration may retire legacy
configuration only after the backup and restore gate in RFC-0002 succeeds.

## Non-Goals

The initial implementation does not:

- provide a backup web UI;
- copy live database files as the primary database backup;
- discover application containers or databases;
- execute arbitrary application hooks;
- initialize repositories from scheduled jobs;
- enable automatic prune before provider-policy validation;
- restore in place by default;
- share one restic repository between servers.

## Consequences

- Backups remain reusable across server roles.
- Backup storage is outside the primary server failure domain.
- Database consistency remains owned by the component that owns the database.
- `backup/` becomes an approved top-level repository module.
- The deployment engine gains a reusable host driver in addition to the
  existing Compose driver.
- Production servers gain independent storage credentials and repositories.
- Backup configuration and secrets remain host-owned under
  `/etc/server-infra`.
- Applications that own databases must implement and monitor the staging
  contract.
- Two snapshots per scheduled job trade a small amount of operational
  complexity for an enforceable configuration-backup invariant.
- Backrest is not part of the initial stack. It may be reconsidered if a web UI
  becomes operationally necessary.
