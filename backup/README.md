# Backup

## Purpose

Provide encrypted, incremental, off-site host backups without application
knowledge or a Docker dependency.

The module creates a mandatory configuration snapshot and a separately tagged
data snapshot in a server-owned restic repository.

## Components

- restic using the Backblaze B2 S3-compatible API;
- native systemd services with daily, weekly, and monthly timers;
- a standalone runner installed under
  `/usr/local/libexec/server-infra/backup/`;
- an interactive server setup wizard that writes secrets without terminal
  echo or command-line arguments;
- optional, separate Uptime Kuma push reporting for backup, repository check,
  and restore-test jobs.

The host must provide `restic` and system CA certificates. `curl` is required
only when Uptime Kuma monitoring is enabled. Deployment checks mandatory
runtime commands before changing host artifacts.

## Configuration

Active configuration belongs under:

```text
/etc/server-infra/backup/
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
└── restic-password
```

`runtime.env` is mode `0600` because it contains provider credentials and may
contain push-monitor URLs. Use `runtime.env.example` as the key contract.
Leave all three `UPTIME_KUMA_*` values empty to disable monitoring; partial
monitor configuration is rejected.

`paths` contains one absolute data source per line. The runner rejects broad
roots and backs up `/etc/server-infra` separately without data excludes.

`excludes` contains restic exclude patterns. Dollar signs are rejected because
restic expands environment variables in exclude files.

`freshness` contains optional database-dump completion markers:

```text
<maximum-age-seconds> <absolute-marker-path>
```

The owning application or database module must write a completed dump
atomically and update its marker only after success.

`sources.d` is optional. Each child directory is one independently managed
project source. The runner merges its `paths`, `excludes`, and `freshness`
with the three base files. Existing hosts without `sources.d` remain valid.
Duplicate paths are backed up only once.

All exclude files apply to the complete data snapshot, so project-specific
patterns should be anchored to that project's paths when they are not generic.

The restic password file must be root-owned with mode `0600`. Store a second,
recoverable copy of the password outside the server failure domain.

Keep the complete break-glass record outside the server as described in
`RECOVERY.md`. `break-glass.txt.example` defines its fields but contains only
invalid placeholders.

Export a new record directly from the validated active configuration:

```bash
sudo ./scripts/export-break-glass.sh \
  --output /media/encrypted-recovery/server-infra-break-glass.txt
```

The exporter also records the current server-infra `origin` and exact Git
commit. It creates a mode `0600` file without printing secrets and refuses to
overwrite an existing record. A `sudo` export belongs to the invoking operator
rather than root. Import the file into the password manager, complete its
`LAST VERIFIED` evidence, and remove the plaintext export.

## Deployment

Preview backup tool installation:

```bash
./scripts/install-restic.sh --check
```

On a Debian-compatible Linux host, install missing tools from the distribution
repositories:

```bash
sudo ./scripts/install-restic.sh --apply
```

The installer is idempotent: it does not reinstall or upgrade tools that are
already available. If the distribution package is too old for a future module
requirement, use an official restic binary as a separately reviewed
installation change.

Create and validate the active server configuration interactively:

```bash
sudo ./scripts/backup-setup.sh
```

The wizard:

- proposes the hostname, `acceptance`, and the current timezone as defaults;
- constructs the restic repository URL from the Backblaze endpoint, bucket,
  and repository prefix;
- reads the Backblaze secret and restic password without terminal echo;
- optionally collects three Uptime Kuma push URLs;
- adds `backup` while preserving other explicitly configured modules;
- creates active files atomically with root ownership and required modes;
- preserves existing `paths`, `excludes`, and `freshness`;
- keeps retention and prune disabled;
- validates the result and does not contact Backblaze.

It never accepts secrets as command-line arguments. Existing files are changed
only after the final confirmation. If the complete configuration is already
valid, rerunning the wizard only validates it.

The generic layout installer remains available when only examples are wanted:

```bash
sudo ./scripts/install.sh --module backup --apply --install-examples
```

Run deployment preflight, then apply the host module:

```bash
sudo ./scripts/deploy.sh --check
sudo ./scripts/deploy.sh --apply
```

Apply installs the public CLI, internal helpers, and systemd units. Initialize
the remote repository explicitly and create the first backup:

```bash
sudo server-infra-backup init
sudo server-infra-backup run
```

The default schedules use the server timezone:

- backup: daily at `03:30`;
- repository metadata check: Sunday at `04:30`;
- configuration restore test: the first day of each month at `05:30`.

## Project Backup Wizard

The project wizard registers either:

- application files only; or
- application files plus one PostgreSQL database running in Docker Compose.

The checked-in project manifest is non-secret:

```text
<application>/.server-infra/backup/
├── source.conf
├── paths
├── excludes
├── freshness
├── restore-check.sh
└── README.md
```

For a files-only project, run from the application checkout:

```bash
server-infra-backup project init --files-only
```

The repository compatibility wrapper provides the same operation:

```bash
/path/to/server-infra/scripts/backup-project.sh init --files-only
```

Files-only mode asks for at least one absolute file or directory path. It does
not ask for Compose settings, create a staging directory, or install a project
dump timer.

For files plus PostgreSQL, run the interactive wizard without
`--files-only`. The manifest records absolute host paths:

```bash
server-infra-backup project init
```

The wizard asks for:

- a stable lowercase project name;
- optional absolute file or directory paths to include in addition to the
  generated database dump;
- the Compose file and PostgreSQL service;
- an optional Compose env-file path;
- daily dump time and maximum permitted dump age.

The selected Compose env file is automatically added to `paths`; it does not
need to be entered a second time as an application path. If `.env` exists in
the application root, the wizard offers it as the default.

It creates `.server-infra/backup` inside the application repository. Review
and commit those files. They contain paths and service metadata but no
database password. `README.md` documents the project-local workflow.
`restore-check.sh <restore-root>` verifies that every configured path exists
under a separate restic restore target; PostgreSQL sources also require a
non-empty restored dump. Customize it with application-specific integrity or
database import checks. The backup scheduler never executes it automatically.
Re-running `init` on an existing manifest creates either support file when it
is missing, but does not overwrite a customized copy.

The non-interactive files-only form is:

```bash
server-infra-backup project init \
  --files-only \
  --non-interactive \
  --project-root /opt/my-app \
  --name my-app \
  --include /etc/my-app \
  --include /srv/my-app/uploads
```

The equivalent non-interactive PostgreSQL command is:

```bash
server-infra-backup project init \
  --non-interactive \
  --project-root /opt/my-app \
  --name my-app \
  --include /srv/my-app/uploads \
  --compose-file /opt/my-app/docker-compose.yml \
  --compose-service postgres \
  --compose-env-file /opt/my-app/.env \
  --dump-time 02:45 \
  --max-age-seconds 14400
```

Validate the project manifest:

```bash
cd /opt/my-app
server-infra-backup project validate
```

Preview server installation:

```bash
sudo server-infra-backup project install --check
```

Install the active source and enable its dump timer:

```bash
sudo server-infra-backup project install
```

`validate` and `install` use `$PWD/.server-infra/backup` by default. Pass
`--manifest /absolute/path` only when running from another directory or CI.

Installation copies the reviewed manifest to
`/etc/server-infra/backup/sources.d/my-app`, creates the root-owned staging
directory for PostgreSQL sources, and installs their project-specific service
and timer. A files-only source installs only the active configuration and has
no producer timer. Use `--no-enable` for PostgreSQL when the timer must be
enabled only after a manual dump test.

Installation also records the checkout's Git `origin` and exact `HEAD` in the
root-owned `recovery.conf`. It does not contact the remote repository. Run
`project install` after application deployment so the recovery commit remains
current. HTTPS remotes containing credentials are rejected instead of being
stored in the configuration snapshot. Installation also refuses tracked Git
changes because they cannot be reconstructed from the recorded commit. The
complete `.server-infra/backup` manifest must already be committed in that
same checkout.

List installed sources:

```bash
sudo server-infra-backup project list
```

List the paths, repositories, and exact commits needed after complete server
loss:

```bash
sudo server-infra-backup project recovery-list
```

`MISSING` indicates a non-Git checkout or missing `origin`/`HEAD`. Fix and
reinstall that source before considering the server disaster-ready.

Preview removal:

```bash
sudo server-infra-backup project remove --name my-app --check
```

Remove the active source and its dump timer:

```bash
sudo server-infra-backup project remove --name my-app
```

Removal archives the active source configuration under
`/etc/server-infra/backup/removed-sources`, removes only the generated systemd
service and timer, and reloads systemd. It does not delete the staging dump or
the application repository's `.server-infra/backup` manifest. Reinstall the
manifest to register the source again.

Run the producer manually:

```bash
cd /opt/my-app
sudo server-infra-backup project dump
sudo server-infra-backup project status
sudo server-infra-backup project logs
sudo server-infra-backup project restore-db \
  --target-db my_app_restore \
  --jobs 4 \
  --start-service
```

These commands resolve the source name from
`.server-infra/backup/source.conf`. From another directory, select the
installed source explicitly with `--name my-app`. `status` reports both the
generated service and timer; `logs` prints the latest 100 service journal
entries. The full systemd unit names remain available for low-level
troubleshooting.

`restore-db` selects the latest data snapshot by default. Use
`--snapshot <id>` for a specific snapshot. It extracts only this project's
`postgres.dump` under a root-owned temporary directory, verifies the custom
archive, streams it into a mode `0600` regular file owned by the PostgreSQL
Compose service user, creates a new empty database from `template0`, and runs
`pg_restore` from that regular archive file. Other project files in the data
snapshot are not downloaded.

By default the PostgreSQL Compose service must already be running. With
`--start-service`, the helper runs `docker compose up -d --no-deps` for only
the configured PostgreSQL service and waits up to 60 seconds for
`pg_isready`. It never starts the application or Compose dependencies.

During complete-server recovery, use
`server-infra-recovery restore-project-db` instead of calling this primitive
directly. The orchestrator supplies the one snapshot already pinned for the
session and records the isolated target database for safe retries.

The PostgreSQL Compose service must be running, either before the command or
through `--start-service`, and its standard `postgres` maintenance database
must be available. The configured source database itself does not need to
accept connections or still exist.

The target database:

- must use lowercase snake_case;
- must differ from the configured `POSTGRES_DB`;
- must not already exist.

The command never stops the application, changes its connection string,
renames a database, or removes the configured source database. A failed import
removes only the new incomplete target. Successful completion removes the
temporary host and container dump but keeps the restored database for
application-owned validation and cutover.

Parallel restore defaults to four jobs and accepts `--jobs 1` through
`--jobs 32`. More jobs are not always faster; choose a value appropriate for
the PostgreSQL host CPU and storage.

The producer passes the optional env-file to `docker compose --env-file`; it
never executes the env-file with `source`. `pg_dump` and `pg_restore --list`
run inside the selected container. They use `POSTGRES_USER` when set, otherwise
`postgres`; `POSTGRES_DB` defaults to the selected database user. The dump is
written and checked under a temporary filename, then atomically renamed. The
freshness marker is published last.

The generated dump timer should run before the main `03:30` backup. If a dump
starts but does not finish, its marker remains absent and the main backup
fails instead of silently copying an old database dump.

## Operations

Validate the complete active configuration and current project runtime paths:

```bash
sudo ./scripts/backup.sh validate
```

`validate --allow-missing-project-paths` is reserved for the disaster-recovery
orchestrator before application checkouts exist. It still validates backup
runtime values and project manifest structure; routine preflight must not use
this exception.

Initialize a new repository explicitly:

```bash
sudo ./scripts/backup.sh init
```

The scheduled job never initializes a repository.

Run a backup manually:

```bash
sudo ./scripts/backup.sh run
```

Apply retention explicitly after provider-policy validation:

```bash
sudo ./scripts/backup.sh retention
```

Run the same metadata-only repository check used by the weekly timer:

```bash
sudo ./scripts/backup.sh check
```

Restore the latest configuration snapshot into a new or empty directory:

```bash
sudo ./scripts/restore.sh \
  --kind config \
  --target /var/tmp/server-infra-restore
```

Use `--kind data` for the tagged data snapshot. Use
`--snapshot <snapshot-id>` to select an exact snapshot instead of `latest`.
Use `--include <absolute-path>` to extract only one configured path or a child
of it. An include outside the selected config or data paths is rejected.
The command rejects symlinks, broad system paths, the live configuration
root, and non-empty destinations. A failed manual restore leaves its target in
place for inspection.

Run the monthly configuration restore test manually:

```bash
sudo ./scripts/backup.sh restore-test
```

The test restores the latest configuration snapshot selected by server
instance and tag, validates the expected layout and permissions, and removes
only the temporary directory it created under
`/var/cache/server-infra/backup/restore-tests`.

`BACKUP_RETENTION_ENABLED` and `BACKUP_PRUNE_ENABLED` default to `false`.
Automatic prune must remain disabled until Object Lock or versioning behavior
has been validated for the server.

Inspect the timer and service:

```bash
systemctl status \
  server-infra-backup.timer \
  server-infra-backup-check.timer \
  server-infra-backup-restore-test.timer
journalctl -u server-infra-backup.service
journalctl -u server-infra-backup-check.service
journalctl -u server-infra-backup-restore-test.service
```

Uptime Kuma is optional. When it is enabled, create three independent push
monitors: a successful daily backup must not mask a failed weekly check or
monthly restore test. Leave all three URLs empty when monitoring is not yet
available. Scheduled jobs then continue normally and log that status reporting
was skipped.

Run the module lifecycle and safety test without contacting a real repository
or monitor:

```bash
./backup/tests/test-runner.sh
./backup/tests/test-project-wizard.sh
./backup/tests/test-setup-wizard.sh
./backup/tests/test-break-glass-export.sh
./backup/tests/test-output.sh
```

The generic restore test proves that encrypted configuration files can be
retrieved with their expected structure and permissions. It does not prove
that an application-owned logical database dump can be imported; every
application that stages such a dump must own and document that import test.

## Troubleshooting

- A missing repository causes `run` to fail; use the explicit `init` operation
  only after verifying the repository URL.
- A stale or missing required marker stops the data snapshot and reports the
  job as failed.
- `project` commands require the backup module to have been deployed first so
  that `server-infra-backup` and its internal helper are installed.
- PostgreSQL project sources require Docker Compose and `pg_dump`/`pg_restore`
  inside the selected service.
- `project restore-db` restores only into a new database; production cutover
  and application-level verification remain owned by the application.
- A deployment or another backup operation prevents a concurrent backup.
- Push URLs must be HTTPS base URLs without query parameters.
- `check` validates repository metadata only. A full `--read-data` scan is an
  intentionally separate operator decision because it downloads all pack
  data.
- A restore test failure reports to its own monitor and still removes only the
  temporary test directory created for that invocation.
- Complete-server recovery requires the externally stored break-glass record;
  see `RECOVERY.md`.
