# RFC 0004: Clean Host Bootstrap

- Status: accepted
- Date: 2026-07-24

## Context

The repository can deploy infrastructure from `/etc/server-infra` and recover
configuration and projects from restic. A replacement or newly provisioned
server still requires a consistent operating-system foundation before either
flow can begin.

The previous `scripts/bootstrap.sh` only checked for Docker. Operators had to
install Git, Docker Compose, restic, and shared runtime directories manually.
That made disaster recovery longer and made an ordinary server move use a
different undocumented preparation path.

## Decision

Extend the existing `scripts/bootstrap.sh` into the single clean-host
preparation contract:

```text
scripts/bootstrap.sh --check
scripts/bootstrap.sh --apply
```

The contract supports official Debian and Ubuntu hosts with apt and systemd.
Apply is non-interactive and idempotent. It provides:

- Git and the OpenSSH client;
- CA certificates and curl;
- jq and dialog for the recovery snapshot inventory and optional terminal UI;
- restic;
- Docker Engine, Buildx, and Docker Compose;
- `/run/server-infra`;
- `/var/lib/server-infra`;
- `/var/cache/server-infra`.

Bootstrap is not a module and does not depend on active host configuration.
It runs before `/etc/server-infra` exists.

`dialog` does not become a recovery authority or state store. The recovery
wizard falls back to plain terminal interaction, and all underlying recovery
operations remain non-interactive. `jq` is limited to parsing restic's JSON
snapshot inventory.

The volatile runtime root is declared with
`/etc/tmpfiles.d/server-infra.conf` so scheduled native services retain their
lock-root contract after reboot.

## Docker installation policy

A complete existing Docker and Compose installation is accepted without
replacement or upgrade.

When Docker is absent, bootstrap uses Docker's official apt repository and
installs `docker-ce`, `docker-ce-cli`, `containerd.io`,
`docker-buildx-plugin`, and `docker-compose-plugin`.

Bootstrap refuses:

- Docker without a working Compose plugin;
- conflicting distribution container packages before a new installation;
- symlinked managed paths;
- an existing Docker signing key or apt source that differs from the expected
  content.

It never removes an existing runtime or container data.

## Security boundary

Bootstrap does not own:

- VM provisioning;
- initial SSH access or the first trusted repository transfer;
- operator users, SSH authorization, SSH hardening, or Docker group
  membership;
- firewall rules;
- `/etc/server-infra`;
- application source or databases;
- Caddy, DNS, or traffic cutover.

Those operations can lock out the operator, grant root-equivalent access, or
expose services, so they require separate explicit contracts.
Project checkout ownership is intentionally left with the existing SSH
operator. Recovery performs Git operations as `SUDO_USER` while retaining root
only for host configuration, restic, database, and recovery-state operations.

## Flow composition

After the initial trusted checkout:

```text
clean host
  -> bootstrap
  -> new host configuration OR restored host configuration
  -> infrastructure deployment
  -> new project installation OR project recovery
  -> validation and traffic cutover
```

Disaster recovery restores the same logical server identity and all selected
projects. A planned move of one project to a differently configured server is
a separate future workflow and must not be implemented by pretending the new
host is the failed server.

## Consequences

### Benefits

- New installation and recovery share one tested OS foundation.
- Recovery no longer requires separate manual Docker and restic installation.
- Active host configuration remains absent until its owning flow creates or
  restores it.
- Existing Docker installations are not silently replaced.
- Recreated project checkouts remain manageable by the recovery operator.

### Costs

- The initial VM, SSH access, and trusted repository checkout remain manual or
  provider automation.
- Only Debian and Ubuntu are supported initially.
- Docker's official apt repository becomes an external bootstrap dependency
  on hosts where Docker is absent.
- Git authorization, SSH hardening, firewall policy, and planned project
  migration still need separately approved workflows.
