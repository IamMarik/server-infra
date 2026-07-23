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

It does not yet restore project files or databases, clone projects, deploy
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

## Session state

Default state:

```text
/var/lib/server-infra/recovery/
└── session.env
```

The directory is mode `0700`; `session.env` is mode `0600`. State contains
only:

- server instance and recovery session timestamps;
- break-glass generation timestamp;
- server-infra repository URL and exact commit;
- the pinned configuration snapshot and, later, data snapshot;
- phase statuses.

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
- An existing session is never silently replaced. Session reset will be a
  separate, explicitly destructive operation if it is introduced later.
