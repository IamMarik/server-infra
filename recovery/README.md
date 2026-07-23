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

The first version provides:

- `init` to validate the break-glass record against the current repository;
- a root-owned, resumable, non-secret recovery session;
- `plan` to display ordered recovery phases;
- `status` to inspect pinned metadata and phase state.

It does not yet restore configuration or data, clone projects, deploy
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
- selected snapshot IDs when future phases implement selection;
- phase statuses.

`init` never overwrites an existing session. Re-running it with the same
break-glass record validates and reuses that session. A mismatch fails.

## Operations

After fencing the failed VM, authorizing temporary Git access, cloning
`server-infra`, and checking out the break-glass ref:

```bash
sudo ./recovery/bin/server-infra-recovery init \
  --break-glass /home/ubuntu/server-infra-break-glass.txt

sudo ./recovery/bin/server-infra-recovery plan
sudo ./recovery/bin/server-infra-recovery status
```

Use `--state-root` only for tests or an explicitly reviewed non-standard host
layout.

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
- An existing session is never silently replaced. Session reset will be a
  separate, explicitly destructive operation if it is introduced later.
