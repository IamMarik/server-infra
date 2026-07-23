# RFC 0003: Disaster Recovery Orchestrator

- Status: accepted
- Date: 2026-07-24

## Context

The backup module can create, validate, and restore encrypted snapshots. It
also records enough project Git metadata to reconstruct application checkouts.
The complete-server runbook defines the correct manual order.

After total VM loss, an operator must still coordinate several systems:

- temporary Git access and an exact server-infra checkout;
- restic credentials from the external break-glass record;
- restoration of `/etc/server-infra`;
- selection of one immutable data snapshot;
- reconstruction of project repositories;
- PostgreSQL and file restoration;
- delayed reverse-proxy activation;
- validation and creation of a new backup point.

Putting this coordination inside the backup module would make that module own
deployment and application lifecycle. A separate repository would add another
Git dependency to the earliest recovery stage.

## Decision

Add an approved top-level `recovery/` operator workflow to this repository.

`recovery/` is not a module. It has no `module.env`, runtime service, timer, or
deployment-driver branch. It coordinates existing generic interfaces while
leaving ownership where it already belongs:

- `backup/` owns restic and generic PostgreSQL restore primitives;
- `/etc/server-infra` owns active host configuration;
- `backup/sources.d/*/recovery.conf` owns discovered project Git inventory;
- application repositories own startup, migrations, and integrity checks;
- the operator owns fencing, Git authorization, and traffic cutover.

No concrete server, project, domain, credential, or private key is committed.

## Bootstrap boundary

The repository cannot automate steps required before it is available. The
minimum manual entry procedure is:

1. create and fence a clean recovery host;
2. connect over SSH;
3. use trusted SSH-agent forwarding or authorize a new temporary key;
4. clone the repository URL from the break-glass record;
5. check out its exact recorded commit.

Copying an existing private SSH key to the failed server's replacement is not
part of the workflow. Git credentials are not stored in restic or recovery
state.

## Break-glass input

`init` accepts the absolute path to a version 1
`server-infra-break-glass.txt`. The file is parsed as text, never executed.

Initialization validates:

- regular-file and `0600` permission requirements;
- all credentials required to open the restic repository;
- a credential-free HTTPS or SSH infrastructure repository URL;
- an exact Git commit;
- equality with the current checkout's `origin` and `HEAD`;
- absence of tracked Git changes.

Secrets are neither printed nor persisted in session state.

## Session state

Recovery progress is stored by default under:

```text
/var/lib/server-infra/recovery/session.env
```

The state directory is `0700`; the state file is `0600`. The file uses the
repository's non-executable `KEY=VALUE` parser and contains only non-secret
metadata:

```text
RECOVERY_STATE_VERSION
RECOVERY_SESSION_ID
RECOVERY_INSTANCE
RECOVERY_STARTED_AT
RECOVERY_BREAK_GLASS_GENERATED_AT
RECOVERY_INFRA_REPOSITORY_URL
RECOVERY_INFRA_REPOSITORY_REF
RECOVERY_STATUS
RECOVERY_PHASE_REPOSITORY
RECOVERY_PHASE_CONFIG
RECOVERY_CONFIG_SNAPSHOT
RECOVERY_PHASE_DATA
RECOVERY_DATA_SNAPSHOT
RECOVERY_PHASE_PROJECTS
RECOVERY_PHASE_FINALIZE
```

The initial write is atomic and refuses overwrite. Re-running `init` validates
and reuses a matching session. A future reset operation must be explicit and
destructive.

## Recovery phases

The state machine is intentionally coarse:

1. repository verified;
2. configuration restored and validated;
3. one exact data snapshot selected;
4. projects reconstructed and restored;
5. applications validated, infrastructure finalized, and traffic enabled.

The selected data snapshot ID is persisted once and reused for every project.
No long recovery workflow may use a moving `latest` selector.

Caddy is finalized only after application-owned checks pass. The orchestrator
must not blindly copy a restored tree over Git checkouts, run arbitrary hooks
from host configuration, promote databases, change DNS, or make application
schema decisions.

## Initial implementation

The accepted first increment implements only:

- `init --break-glass`;
- `plan`;
- `status`;
- strict state and input validation;
- isolated tests with fake Git responses.

Configuration restoration, snapshot selection, project reconstruction,
resume transitions, and finalization remain documented manual operations until
their contracts are separately implemented and tested.

## Consequences

### Benefits

- The earliest recovery code ships with the exact infrastructure commit.
- Recovery can become resumable without hiding state in shell history.
- Secrets stay in the external break-glass record.
- Existing backup and project contracts remain reusable.
- Public traffic activation can be explicitly delayed.

### Costs

- A short pre-clone procedure remains manual.
- The operator must retain the break-glass record during early phases.
- Until later increments land, the CLI guides rather than performs restores.
- The new top-level workflow expands repository structure and requires its own
  tests and documentation.
