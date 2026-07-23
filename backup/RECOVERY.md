# Disaster Recovery

## Scope

This runbook covers complete loss of a server. The recovery model is rebuild
plus restore; the restic repository is not a bootable virtual-machine image.

Application source comes from Git. Restic provides encrypted host
configuration, application runtime files, uploaded data, and staged database
dumps.

## Break-glass record

Keep one secret record named `server-infra-break-glass.txt` outside the server
failure domain. Generate it from the active server configuration and the
current server-infra Git checkout:

```bash
sudo ./scripts/export-break-glass.sh \
  --output /media/encrypted-recovery/server-infra-break-glass.txt
```

The destination directory must already exist. The exporter validates the
backup configuration, refuses a Git checkout with tracked changes, rejects
repository URLs containing credentials, and creates a new file with mode
`0600`. When invoked through `sudo`, the file belongs to the invoking operator
so it can be imported without making it broadly readable. The exporter never
prints secret values and never overwrites an existing record.
`backup/break-glass.txt.example` documents the resulting format.

Store the completed record as a password-manager secure document. An encrypted
offline copy is optional. Never commit it, attach it to an issue, or leave a
permanent plaintext copy on the server. After import, update the `LAST
VERIFIED` fields with the latest successful restore evidence, then securely
remove the exported plaintext file.

The record contains only the information needed before the configuration
snapshot can be opened:

- logical server instance;
- server-infra Git repository and recovery ref;
- restic repository URL and password;
- Backblaze recovery credentials and region;
- date and evidence of the latest recovery test.

Do not store Git tokens or SSH private keys in the record. Authorize a new key
through the Git provider during recovery.

## Project recovery inventory

Every successful `project install` inspects the application checkout without
contacting the network and writes:

```text
/etc/server-infra/backup/sources.d/<project>/recovery.conf
```

The file records the `origin` URL and exact Git commit deployed at install
time. It is root-owned, non-secret, and included in the configuration
snapshot. HTTPS origins containing credentials and checkouts with tracked
changes are rejected. The complete project backup manifest must also be
tracked by that commit.

Review the inventory with:

```bash
sudo server-infra-backup project recovery-list
```

`MISSING` means the source must be fixed and reinstalled before the server is
considered disaster-ready.

Run `project install` after every application deployment so the recorded
commit follows the deployed checkout.

## Recovery order

### 1. Fence the failed server

Prevent split brain. Stop the old VM when possible and do not direct traffic
to both old and recovered databases.

### 2. Prepare a clean host

Install the operating system, SSH access, Docker Compose, Git, and system CA
certificates. Authorize a fresh Git key, then clone the server-infra repository
from the break-glass record and check out its recorded ref.

Initialize the recovery session. This verifies the break-glass record against
the checkout without copying its secrets:

```bash
sudo ./recovery/bin/server-infra-recovery init \
  --break-glass /home/ubuntu/server-infra-break-glass.txt
sudo ./recovery/bin/server-infra-recovery plan
```

Install restic:

```bash
sudo ./scripts/install-restic.sh --apply
```

### 3. Restore host configuration

Use the break-glass values to list snapshots tagged
`server-infra-config`. Restore a selected configuration snapshot into a new,
empty temporary directory. Never restore directly over `/etc`.

Verify that the restored tree contains:

```text
etc/server-infra/server.env
etc/server-infra/modules.env
etc/server-infra/backup/runtime.env
etc/server-infra/backup/restic-password
```

Copy the reviewed `etc/server-infra` tree to `/etc/server-infra`, preserving
ownership and permissions. Recovery phase transitions are not automated yet;
use `server-infra-recovery plan` together with this runbook.

### 4. Validate restored configuration

```bash
./scripts/validate-config.sh
sudo ./scripts/deploy.sh --check
```

Do not apply the complete infrastructure yet. In particular, keep Caddy out of
the traffic path until projects and databases are restored and validated.

### 5. Freeze one data snapshot

Select one exact snapshot tagged `server-infra-data`. Record its ID and use
that same ID for every project. Do not use a moving `latest` selector during a
long recovery.

Restore the data snapshot into a separate temporary directory:

```bash
sudo ./scripts/restore.sh \
  --kind data \
  --snapshot <data-snapshot-id> \
  --target /var/tmp/server-infra-data-restore
```

### 6. Recreate application checkouts

Save the absolute infrastructure checkout path once in the current recovery
shell before changing into application directories:

```bash
SERVER_INFRA_ROOT="$(pwd -P)"
```

Read the recovered inventory:

```bash
sudo "$SERVER_INFRA_ROOT/backup/bin/server-infra-backup" \
  project recovery-list
```

For each project:

1. Clone `REPOSITORY_URL` into `PROJECT_ROOT`.
2. Check out `DEPLOY_COMMIT`.
3. Restore only the declared `.env`, uploads, and other application paths from
   the temporary data tree.
4. Run `"$SERVER_INFRA_ROOT/backup/bin/server-infra-backup" project validate`.
5. Run `sudo "$SERVER_INFRA_ROOT/backup/bin/server-infra-backup" project
   install`.

Do not copy a restored data tree blindly over a Git checkout.

### 7. Restore PostgreSQL projects

Start only the PostgreSQL Compose service first. Keep the application stopped.

```bash
sudo "$SERVER_INFRA_ROOT/backup/bin/server-infra-backup" project restore-db \
  --snapshot <data-snapshot-id> \
  --target-db <project>_recovered \
  --jobs 4
```

Validate the restored database with the application-owned checks. Then update
the application connection settings, recreate affected containers, and start
the application. The helper does not perform this cutover.

Repeat for every project in dependency order.

### 8. Deploy infrastructure, restore traffic, and establish a new backup point

After application-owned validation passes, apply the complete infrastructure.
The last flag is expected because Compose infrastructure does not yet exist on
the replacement VM:

```bash
sudo ./scripts/deploy.sh --apply --allow-new-project
```

Verify application health, update DNS to the new VM, and confirm TLS issuance.
Run a fresh database dump and complete backup:

```bash
sudo server-infra-backup project dump
sudo server-infra-backup run
sudo server-infra-backup check
```

Keep the failed host fenced until the new server and backup are verified.
Inspect the recovery session at any point with:

```bash
sudo "$SERVER_INFRA_ROOT/recovery/bin/server-infra-recovery" status
```

## Known limits

- Docker named volumes are not restored unless their data is explicitly
  included by a project source.
- Caddy certificate state may be regenerated; provider rate limits still
  apply.
- Uptime Kuma state requires an explicit backup source if its history and
  configuration must survive total VM loss.
- Git recovery metadata reflects the last `project install`, not necessarily
  the newest commit present in the checkout.
- Application validation, DNS cutover, migrations, and database promotion
  remain application-owned operations.
