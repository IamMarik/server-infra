# Clean Host Bootstrap

## Purpose

Prepare a newly provisioned Debian or Ubuntu server for `server-infra` without
creating active host configuration or exposing public traffic.

Bootstrap is the common foundation for:

- a new server configured from scratch;
- complete-server disaster recovery;
- a future planned project migration.

The repository must already be present on the host. Creating the VM,
establishing SSH access, and obtaining the initial trusted Git checkout remain
outside the script because the script cannot run before its own code is
available.

## Components

The implementation is `scripts/bootstrap.sh`. It provides:

- Git and the OpenSSH client;
- system CA certificates and curl;
- jq and dialog for snapshot inventory and the optional terminal recovery UI;
- restic from the Debian or Ubuntu repository;
- Docker Engine, Buildx, and Docker Compose;
- shared roots under `/run`, `/var/lib`, and `/var/cache`.

The `/run/server-infra` root is declared through
`/etc/tmpfiles.d/server-infra.conf` so it is recreated after reboot.

Docker is installed from the
[official Docker apt repository](https://docs.docker.com/engine/install/)
only when the `docker` command is absent. A complete existing Docker and
Compose installation is accepted without replacement or upgrade.

If Docker exists without the Compose plugin, or conflicting distribution
packages are present before a new Docker installation, bootstrap stops for
operator review. It does not remove or replace an existing container runtime.

## Security boundary

Bootstrap never creates or changes:

- `/etc/server-infra`;
- SSH keys, SSH authorization, or SSH daemon configuration;
- firewall rules;
- Docker group membership;
- application checkouts or databases;
- Caddy, DNS, or public traffic.

Docker group membership is intentionally excluded because it grants
root-equivalent host access. Firewall changes remain separate because Docker
published ports require an explicitly reviewed firewall policy.
Bootstrap also does not create, modify, or validate operator accounts. The
administrator establishes the SSH operator and decides whether that account
may use sudo or Docker before running this script.

## Operations

Inspect the host without changing it:

```bash
./scripts/bootstrap.sh --check
```

Prepare a supported clean host:

```bash
sudo ./scripts/bootstrap.sh --apply
```

Apply is idempotent. Installed tools are not upgraded merely because the
command is repeated. Managed Docker repository files must either match the
bootstrap contract or be absent; a different existing file is never
overwritten.

`dialog` is presentation-only. If a terminal cannot render it, the recovery
wizard remains available through `--ui plain`. `jq` parses restic's
machine-readable snapshot inventory; it does not process secret configuration
files.

Bootstrap never deletes operating-system accounts. A `deploy` account created
by an earlier repository version is no longer used by this contract, but its
removal remains a separate operator decision after checking file ownership and
running processes.

After bootstrap:

- a new server creates its own `/etc/server-infra` with the host setup flow;
- disaster recovery restores `/etc/server-infra` from one selected snapshot;
- both flows then use the existing install and deploy contracts;
- project Git checkouts remain owned by the operator who performs deployment.

## Testing

Run the isolated contract test without package installation or network access:

```bash
./bootstrap/tests/test-bootstrap.sh
```

The test covers supported distribution detection, repeatable Docker repository
configuration, runtime roots, and the guarantee that bootstrap does not create
`/etc/server-infra` or operator accounts.

## Troubleshooting

- `Unsupported distribution` means only official Debian and Ubuntu hosts are
  currently supported.
- `Existing Docker installation does not provide Docker Compose` protects a
  partially managed runtime from an implicit replacement.
- `Conflicting Docker package is installed` requires the operator to review
  and remove or retain the existing runtime explicitly.
- `Existing Docker apt source differs` protects an administrator-managed apt
  source from being overwritten.
- Docker installation can affect firewall behavior for published container
  ports. Review Docker's official firewall guidance before exposing services.
