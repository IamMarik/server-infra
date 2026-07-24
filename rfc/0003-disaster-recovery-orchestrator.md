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

The operator then runs the common clean-host bootstrap defined in RFC 0004
before initializing the recovery session. Bootstrap installs the required
tools and shared runtime roots without creating `/etc/server-infra`.

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

## Delivery increments

The first increment implements:

- `init --break-glass`;
- `plan`;
- `status`;
- strict state and input validation;
- isolated tests with fake Git responses.

The second increment implements:

- `config-snapshots --break-glass`;
- `restore-config --break-glass --snapshot`;
- snapshot pinning before remote access;
- an `in-progress` state that can resume after interruption;
- extraction into root-only temporary storage;
- validation against repository contracts and break-glass identity;
- installation only when `/etc/server-infra` is absent;
- rollback of configuration installed by a handled failed invocation.

The third increment implements:

- `data-snapshots --break-glass`;
- `select-data --break-glass --snapshot`;
- validation of the selected snapshot against server host and data tag;
- one immutable data snapshot ID shared by every project restore;
- idempotent reselection of the same ID and refusal of a different ID.

The fourth increment implements:

- `projects-plan --break-glass`;
- strict validation of recovered `source.conf` and `recovery.conf` identity;
- `clone-project --break-glass --name --git-user`;
- Git execution as an explicit non-root user;
- atomic installation only into an absent recorded `PROJECT_ROOT`;
- exact origin and commit verification with idempotent retry behavior.

The fifth increment implements:

- per-project non-secret phase state under the recovery state root;
- `restore-project-files --break-glass --name --git-user`;
- selective extraction of declared non-database paths from the pinned data
  snapshot;
- explicit exclusion of PostgreSQL staging data;
- refusal to overwrite a different existing path;
- preservation of snapshot ownership and modes with resumable retry behavior.

The sixth increment implements:

- `restore-project-db --break-glass --name --git-user --target-db`;
- use of the session's immutable data snapshot without an operator snapshot
  argument;
- persistence of the isolated target database before restore work begins;
- constrained delegation to the backup module's PostgreSQL restore primitive;
- refusal to change a target on retry and idempotent completed-state handling;
- no application database promotion, connection change, or service cutover.

The seventh increment implements:

- `server-infra-recovery-wizard` as an interactive facade over the existing
  non-interactive recovery operations;
- exact configuration and data snapshot prompts with resumable pinned state;
- checkbox-style project selection without adding a dialog package;
- display of recovered infrastructure modules as a separate deferred plan;
- optional startup of only the configured PostgreSQL Compose service with a
  bounded readiness check;
- restoration of selected PostgreSQL projects into proposed isolated targets;
- no application startup, database promotion, infrastructure deployment, DNS
  change, or traffic activation.

Application validation, deployment, database cutover, and finalization remain
documented manual operations until their contracts are separately implemented
and tested.

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
