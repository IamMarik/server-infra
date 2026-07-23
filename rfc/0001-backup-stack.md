# RFC-0001: Backup Stack

## Status

Accepted

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

## Decision

Use the following stack:

- restic as the backup and restore engine;
- Backblaze B2 as off-site object storage;
- the Backblaze S3-compatible API as the restic backend;
- systemd timers for scheduling;
- native database dump tools before restic snapshots;
- Uptime Kuma push monitoring for backup job results.

The initial schedule and retention policy are:

- create one snapshot daily at `03:30` in the server timezone;
- keep 14 daily snapshots;
- keep 8 weekly snapshots;
- keep 12 monthly snapshots;
- run a repository metadata check weekly;
- perform and document a restore test monthly.

Environment configuration owns:

- the list of paths included in a snapshot;
- exclude rules;
- the restic repository URL;
- the Backblaze endpoint, region, bucket, and credentials;
- the repository password file location;
- the Uptime Kuma push URL;
- schedule and retention overrides.

The reusable backup implementation must not know application names, container
names, database names, or database credentials. Applications or an
infrastructure-owned database module must write consistent dumps to an
environment-configured staging directory before the backup starts.

Secrets must not be committed. Only example configuration files may be stored
in Git.

## Security

Restic encrypts backup contents, but credentials with delete access can still
be used to destroy a repository.

Backblaze bucket versioning or Object Lock must be configured so that a
compromised server cannot immediately destroy all usable snapshots. The exact
retention settings must be validated with restic `forget` and `prune` behavior
before automatic pruning is enabled.

The restic repository password must also be stored outside the backed-up
server. Losing this password makes recovery impossible.

## Restore Requirements

A backup job is not considered operational until all of the following succeed:

1. The repository is initialized in Backblaze B2.
2. The first snapshot completes.
3. `restic check` succeeds.
4. A snapshot is restored to a temporary location.
5. A database dump, when present, passes an application-owned restore test.
6. Uptime Kuma reports the scheduled job as healthy.

Restore operations must target an empty temporary directory by default.
Restoring in place requires an explicit operator action.

## Consequences

- Backups remain reusable across server roles.
- Backup storage is outside the primary server failure domain.
- Database consistency remains owned by the component that owns the database.
- The server gains a host-level systemd installation step in addition to the
  existing Docker Compose module deployment flow.
- Backrest is not part of the initial stack. It may be reconsidered if a web UI
  becomes operationally necessary.
