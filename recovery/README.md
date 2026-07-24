# Disaster Recovery Orchestrator

## Purpose

Coordinate complete-server recovery without moving application deployment
logic or server-specific values into this repository.

`recovery/` is an operator workflow, not an infrastructure module. It consumes:

- the external secret break-glass record;
- the current `server-infra` Git checkout;
- host configuration restored from `/etc/server-infra`;
- project Git inventory under `backup/sources.d`.

It does not replace restic, the backup module, application restore checks, or
the manual disaster-recovery runbook.

## Current scope

The current implementation provides:

- `init` to validate the break-glass record against the current repository;
- a root-owned, resumable, non-secret recovery session;
- `plan` to display ordered recovery phases;
- `status` to inspect pinned metadata and phase state.
- `config-snapshots` to list matching configuration snapshots;
- `restore-config` to pin, restore, validate, and install one snapshot.
- `data-snapshots` to list data snapshots after configuration recovery;
- `select-data` to validate and pin one data snapshot for all projects.
- `projects-plan` to validate and print the recovered Git inventory;
- `clone-project` to recreate one checkout at its recorded exact commit.
- `restore-project-files` to restore declared non-database paths from the
  pinned data snapshot without overwriting live paths.

It does not yet restore databases, reinstall project backup sources, deploy
infrastructure, or start public traffic.

## Security model

The break-glass file must:

- be an absolute regular file without symlinks;
- have mode `0600`;
- belong to root or the operator invoking `sudo`;
- contain a complete version 1 record.

The CLI parses the record as data and never sources it as shell code. It
verifies that the current Git `origin` and exact `HEAD` match the record and
refuses a checkout with tracked changes.

Provider credentials and the restic password are validated but never copied to
the session state or printed. The operator retains and removes the break-glass
file separately.

`restore-config` passes those values to restic through the child process
environment, never as command-line arguments or a generated shell file. It
rejects symlinks and special files in restored configuration, verifies that
the restored credentials and server identity match the break-glass record,
and refuses to overwrite an existing active configuration.

Project file restoration revalidates the exact checkout, reads only the
selected source's `paths`, and excludes its PostgreSQL `STAGING_DIR`. Restic
extracts into root-only temporary storage. Symlinks and special files are
rejected. Every declared path is installed only when its destination is
absent; a pre-existing destination must exactly match the selected snapshot.
Ownership and modes from the snapshot are preserved.

## Session state

Default state:

```text
/var/lib/server-infra/recovery/
├── session.env
└── projects/
    └── <project>.env
```

The directory is mode `0700`; `session.env` is mode `0600`. State contains
only:

- server instance and recovery session timestamps;
- break-glass generation timestamp;
- server-infra repository URL and exact commit;
- the pinned configuration snapshot and, later, data snapshot;
- phase statuses.

Each project state stores only its name, the same pinned data snapshot ID, and
file/database phase statuses. It contains no restored application values.

`init` never overwrites an existing session. Re-running it with the same
break-glass record validates and reuses that session. A mismatch fails.

Configuration restore changes its phase to `in-progress` and pins the selected
snapshot before contacting restic. A retry must use the same snapshot. After a
crash, the command either resumes the restore or validates an already
installed configuration before marking the phase complete. Recovery mutations
are serialized with a PID lock; a lock whose process no longer exists is
reclaimed on retry.

Data selection is allowed only after the installed configuration is validated.
The selected snapshot must match both the server instance and
`server-infra-data` tag. Once stored, another snapshot ID is rejected so all
project restores use one consistent recovery point.

Project cloning is allowed only after that data point is pinned. The recovered
`source.conf` and `recovery.conf` remain authoritative for the project name,
type, destination, repository URL, and full commit. Git runs as the explicit
ordinary account passed with `--git-user`; it never runs as root. The command
clones into a same-filesystem staging directory, validates origin, commit,
ownership, and tracked-file cleanliness, then installs only when
`PROJECT_ROOT` is absent. A matching existing checkout is accepted on retry;
anything different is left untouched and rejected.

## Operations

After fencing the failed VM, authorizing temporary Git access, cloning
`server-infra`, and checking out the break-glass ref:

```bash
sudo ./recovery/bin/server-infra-recovery init \
  --break-glass /home/ubuntu/server-infra-break-glass.txt

sudo ./recovery/bin/server-infra-recovery plan
sudo ./recovery/bin/server-infra-recovery status
```

List matching configuration snapshots, choose one explicit ID, then restore
it:

```bash
sudo ./recovery/bin/server-infra-recovery config-snapshots \
  --break-glass /home/ubuntu/server-infra-break-glass.txt

sudo ./recovery/bin/server-infra-recovery restore-config \
  --break-glass /home/ubuntu/server-infra-break-glass.txt \
  --snapshot <config-snapshot-id>
```

List and pin one data snapshot:

```bash
sudo ./recovery/bin/server-infra-recovery data-snapshots \
  --break-glass /home/ubuntu/server-infra-break-glass.txt

sudo ./recovery/bin/server-infra-recovery select-data \
  --break-glass /home/ubuntu/server-infra-break-glass.txt \
  --snapshot <data-snapshot-id>
```

Validate the project inventory, then recreate one checkout. Repeat
`clone-project` for each row in dependency order:

```bash
sudo ./recovery/bin/server-infra-recovery projects-plan \
  --break-glass /home/ubuntu/server-infra-break-glass.txt

sudo ./recovery/bin/server-infra-recovery clone-project \
  --break-glass /home/ubuntu/server-infra-break-glass.txt \
  --name <project-name> \
  --git-user ubuntu
```

The parent of the recorded `PROJECT_ROOT` must already exist. For SSH remotes,
the selected Git user must have temporary repository access through its own
SSH key. With agent forwarding, preserve the socket when entering `sudo`, for
example `sudo --preserve-env=SSH_AUTH_SOCK ...`.

`clone-project` deliberately stops after the exact Git checkout. It does not
copy `.env` or uploads, restore PostgreSQL, install the recovered project
source, or start Compose services.

Restore the declared `.env`, uploads, and other non-database paths:

```bash
sudo ./recovery/bin/server-infra-recovery restore-project-files \
  --break-glass /home/ubuntu/server-infra-break-glass.txt \
  --name <project-name> \
  --git-user ubuntu
```

The command uses the data snapshot already recorded by `select-data`; it has
no snapshot option. It never restores `STAGING_DIR`, because `project
restore-db` extracts only `postgres.dump` directly during the separate
database phase. Parent directories of external declared paths must already
exist.

The restore uses `/var/cache/server-infra/recovery` for a root-only restic
cache and temporary extraction. Plaintext extraction is removed on success or
handled failure. The cache can remain because restic stores repository cache
data, not plaintext configuration secrets.

Use `--state-root` only for tests or an explicitly reviewed non-standard host
layout. `--config-root` and `--work-root` exist for tests and reviewed
non-standard hosts; production recovery uses their defaults.

The break-glass path is not saved. Keep it available for the future
configuration restore phase, import the authoritative copy into the password
manager, and remove temporary plaintext copies after recovery.

## Recovery order

1. Fence the failed server and authorize temporary Git access.
2. Verify this repository and its exact commit.
3. Restore and validate `/etc/server-infra`.
4. Select one exact data snapshot for the entire recovery.
5. Clone recorded project commits and restore files and PostgreSQL.
6. Validate applications, deploy Caddy, open traffic, and create a fresh
   backup.

Caddy is deliberately part of the final phase. A recovery must not expose
empty databases or partially restored applications.

## Testing

Run without contacting GitHub, Backblaze, or a real restic repository:

```bash
./recovery/tests/test-recovery.sh
```

## Troubleshooting

- `origin does not match` means the wrong repository was cloned or its remote
  was rewritten after the break-glass record was generated.
- `commit does not match` means the recorded recovery ref was not checked out.
- `tracked files are modified` means the checkout cannot be reproduced
  exactly; restore or commit the changes before initialization.
- `session is not initialized` means `init` has not completed for the selected
  state root.
- `already restored from another snapshot` protects a pinned recovery from
  mixing configuration points.
- `active configuration already exists` protects a server that is not a clean
  recovery target.
- A failed configuration extraction remains pinned as `in-progress`; rerun
  `restore-config` with the same snapshot ID.
- `configuration recovery must complete` prevents a data point from being
  selected before the host configuration is trustworthy.
- `data snapshot is already pinned` prevents different projects from using
  different points in time.
- `project parent directory not found` means the parent of recovered
  `PROJECT_ROOT` must be created before cloning.
- `existing project ... differs` protects a non-empty or mismatched checkout
  from being overwritten.
- `existing project file differs` means a declared path exists but does not
  match the pinned snapshot; it is never overwritten automatically.
- A file restore left `in-progress` can be rerun. Already installed matching
  paths are accepted, and plaintext extraction is removed after each handled
  invocation.
- An existing session is never silently replaced. Session reset will be a
  separate, explicitly destructive operation if it is introduced later.
