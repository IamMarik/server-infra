# RFC-0002: External Runtime Configuration

## Status

Accepted.

Migration status: Phase 1 repository guardrails, Phase 2 explicit external
configuration validation and deployment integration, and the Phase 3
idempotent host-layout installer are implemented. CI wiring, a dedicated
history secret scan, actual host preparation, and host cutover remain.

## Context

The repository currently models concrete server roles under `environments/`.
Deployment scripts load `server.env`, `modules.env`, and module `config.env`
files from the repository checkout.

Runtime configuration and secrets are properties of a deployed host, not of
the reusable infrastructure repository. Keeping them next to infrastructure
code makes accidental commits more likely and couples the repository layout to
specific servers.

Only the proxy module is currently known to be operational. Its migration must
not implicitly deploy monitoring or change the identity of existing Docker
volumes.

The current proxy implementation builds a custom Caddy image with the Porkbun
DNS provider. Its Caddyfile also contains monitoring routes and concrete
application routes. These are existing runtime behaviors that must be
preserved during cutover, but they are not a precedent for keeping
application-specific configuration in Git.

## Decision

Git remains the source of truth for reusable infrastructure code,
configuration contracts, schemas, documentation, and safe examples.

Each Linux host owns its active runtime configuration under:

```text
/etc/server-infra/
```

Host-managed persistent data and runtime state belong under:

```text
/var/lib/server-infra/
/var/cache/server-infra/
/run/server-infra/
```

Runtime values and secrets must not be committed. Repository examples must use
the complete runtime filename with an `.example` suffix.

The target host configuration starts with:

```text
/etc/server-infra/
├── server.env
├── modules.env
└── proxy/
    ├── runtime.env
    └── conf.d/
        └── service.caddy
```

The proxy is migrated first. Other modules are migrated only after the proxy
has passed its stability and recovery gates.

## Safety Invariants

The migration must preserve all of the following:

1. The active Compose project name.
2. Existing Docker named volumes.
3. The external `server-infra` Docker network.
4. Current proxy routes and HTTPS behavior during the initial cutover.
5. A tested path back to the repository-local configuration.
6. Existing runtime files until backup and restore have been verified.
7. The custom Caddy image capability required for Porkbun DNS challenges.
8. Existing Caddy certificate and account state in the `caddy-data` volume.

Migration commands must never use `docker compose down --volumes`.

The initial proxy project name remains:

```text
server_infra_<stable-instance>_proxy
```

The stable instance value is recorded as `SERVER_INFRA_INSTANCE` in
`server.env`. Changing the project name is a separate migration because
Compose project names affect named-volume identity.

## Migration Plan

### Phase 0: Capture the Working State

Before changing the repository or host:

- record the deployed Git commit;
- record container Compose labels and the effective project name;
- record the active Caddy image ID and digest;
- confirm `dns.providers.porkbun` is present in the active Caddy binary;
- record attached volumes and Docker networks;
- record the locations and permissions of current runtime files;
- inventory all current routes, domains, redirects, authentication rules, and
  upstream container names;
- verify that every expected upstream is attached to the external
  `server-infra` network;
- validate the active Caddy configuration;
- verify every currently expected HTTP and HTTPS route;
- verify wildcard certificate issuance or renewal through Porkbun without
  exposing API credentials;
- store a protected copy of current runtime configuration outside Git.

The phase is complete only when the current proxy can be restored using the
recorded commit, configuration, project name, and volumes.

### Phase 1: Protect Git

Without changing host behavior:

- document the revised source-of-truth boundary;
- ignore known runtime configuration and secret filenames;
- add a repository check that rejects tracked runtime files;
- scan current files and history for committed secrets;
- rotate every secret that has been committed;
- add safe module-local examples with deliberately invalid placeholders.

Concrete environment directories and the legacy deployment path remain
available during this phase.

The repository implements the documentation, example, and filename-guard
portion of this phase:

- root `server.env.example` and `modules.env.example` contracts exist;
- `proxy/runtime.env.example` exists;
- known runtime, credential, private-key, and Caddy backup filenames are
  ignored;
- `scripts/check-repository.sh` rejects forbidden tracked filenames even when
  `.gitignore` is bypassed;
- the custom Porkbun-enabled Caddy build is defined in Git.

CI integration, a dedicated secret scanner, history review, and rotation of
any previously committed secret are still required.

The concrete `pathetic.gay`, `saveproof.app`, and `saveproof.org` routes in the
repository Caddyfile are temporary migration input. They must move to host
configuration in Phase 5.

### Phase 2: Add an Explicit External Configuration Mode

Deployment and validation scripts gain an explicit `--config-root` option.
The target default is `/etc/server-infra`, but migration testing must select
the new mode explicitly until cutover.

The configuration reader must:

- use absolute paths;
- validate the supported `KEY=VALUE` format;
- reject malformed and unknown configuration where applicable;
- avoid sourcing untrusted runtime files as Bash;
- avoid silently falling back between host and repository configuration;
- isolate Compose from unexpected caller-exported variables;
- support a preflight that makes no runtime changes.

The legacy mode remains available only for the rollback window.

The repository provides `scripts/validate-config.sh` for read-only
configuration validation. `scripts/deploy.sh --config-root ... --check` adds
Compose resolution without runtime changes. External deployment is enabled
only by an explicit `--config-root ... --apply`; the positional environment
mode remains the rollback path.

External apply also requires the expected Compose project to exist. An
explicit `--allow-new-project` is required for an intentional first deployment
of a new module and must not be used for the initial proxy migration.

The current Compose expression:

```text
${MODULE_ENV_FILE:-./runtime.env}
```

is treated as legacy compatibility. The external configuration mode must pass
an absolute environment path and must not silently select `./runtime.env`.

### Phase 3: Prepare the Host for Proxy Only

Create `/etc/server-infra` idempotently and install only proxy configuration.
The initial `modules.env` enables only the confirmed working module:

```bash
ENABLED_MODULES="proxy"
```

Copy current proxy values without changing their meaning. Apply these default
permissions:

```text
directories:        root:root 0750
non-secret config:  root:root 0640
secret files:       root:root 0600
```

Installation must not overwrite an existing active runtime file. New values
are written to temporary files, validated, assigned their final ownership and
permissions, and atomically renamed into place.

The old runtime files remain untouched.

The repository provides `scripts/install.sh` for this phase. It requires an
explicit `--check` or `--apply`, selects modules generically through metadata,
and can install only `*.example` files. Apply requires Linux and root and uses
the shared `/run/server-infra/operation.lock`.

The initial proxy runtime file must account for every variable referenced by
the deployed Caddyfile, including:

- Caddy account email;
- monitoring route domains and log authentication values, when those routes
  remain active;
- Porkbun API key and API secret key;
- any other values used by current application routes.

Because Porkbun credentials are present, the complete proxy runtime file is
treated as a secret file with mode `0600`.

### Phase 4: Switch Only the Proxy Environment Source

The first production cutover changes only the location of proxy environment
values. The existing Caddyfile and routes remain unchanged.

Before deployment:

- validate required files, keys, ownership, and permissions;
- run `docker compose config --quiet`;
- confirm the resolved Compose project name;
- confirm the resolved named volumes match the active volumes;
- build the custom Caddy image before the maintenance window;
- verify the built binary contains `dns.providers.porkbun`;
- record the candidate image ID and preserve the previous image ID for
  rollback;
- validate the Caddy configuration without printing secrets.

Deploy with `docker compose up -d` using absolute paths and the preserved
project name. Do not stop or recreate volumes explicitly.

After deployment:

- verify container health and restart count;
- verify ports 80, 443 TCP, and 443 UDP where applicable;
- verify expected HTTP and HTTPS routes;
- verify redirects and basic authentication behavior;
- verify the wildcard TLS route and its certificate;
- verify the same named volumes are attached;
- review Caddy logs;
- repeat the deployment and confirm it is idempotent.

Rollback uses the recorded commit and legacy runtime files with the same
Compose project name and previous Caddy image. The external configuration
remains in place for diagnosis.

### Phase 5: Externalize Proxy Routes

After Phase 4 is stable, make the repository Caddyfile generic:

```caddyfile
{
  email {$CADDY_EMAIL}
}

import /etc/caddy/conf.d/*.caddy
```

Mount `/etc/server-infra/proxy/conf.d` read-only. Initially copy the current
routes without changing their behavior. Removing obsolete monitoring routes is
a separate reviewed change.

Move all concrete application domains, upstreams, redirects, authentication
rules, and wildcard TLS policies out of the repository Caddyfile. This
includes the current `pathetic` and `saveproof` routes.

Pass only explicitly allowed environment variables to the Caddy container. In
addition to `CADDY_EMAIL`, the temporary allowlist includes the variables
referenced by active route fragments, such as:

- `LOGS_AUTH_USER`;
- `LOGS_AUTH_PASSWORD_HASH`;
- `PORKBUN_API_KEY`;
- `PORKBUN_API_SECRET_KEY`.

Domain variables may remain temporarily while routes are copied verbatim, but
concrete domains should ultimately live directly in host-owned Caddy
fragments. Do not inject the complete `runtime.env`.

File-backed secrets are preferred only when the Caddy DNS plugin and
configuration contract can consume them directly. Until then, Porkbun values
remain explicitly allowlisted container environment variables and the runtime
file remains mode `0600`.

Validate the complete mounted configuration before deployment and repeat all
proxy checks after deployment.

Rollback restores the previous Caddyfile and Compose mount while preserving
the Phase 4 runtime configuration.

### Phase 6: Back Up and Restore Host Configuration

Make `/etc/server-infra` a mandatory backup source that operators cannot
exclude through the data-backup exclusion list.

The configuration backup is operational only after:

1. A snapshot succeeds.
2. Repository integrity validation succeeds.
3. The snapshot is restored into an empty temporary directory.
4. Required files and permissions are verified.
5. The restic password has a recoverable copy outside the server failure
   domain.

Old runtime files must not be retired before this gate passes.

### Phase 7: Retire the Legacy Layout

The rollback window closes only after:

- at least two successful, idempotent proxy deployments;
- a successful proxy container restart;
- a successful host reboot test where practical;
- stable HTTPS and routing;
- successful validation of the custom Porkbun-enabled Caddy binary;
- successful wildcard TLS operation;
- confirmation that the original volumes remain attached;
- a successful configuration backup and restore test;
- an observation period of at least three days.

Archive old runtime files securely outside Git for a short recovery window,
then remove them from the checkout. Remove concrete tracked `environments/`
only after the host no longer depends on them.

### Phase 8: Migrate Additional Modules

Monitoring, backup, database, and security are handled as separate changes.
Each module must pass the same prepare, preflight, cutover, verification, and
rollback sequence.

Monitoring is not enabled merely because it appears in an example module
list. It must first be deployed privately, have its volumes and health
verified, and only then receive public proxy routes.

General module metadata, `module.conf`, lifecycle hooks, and image-version
updates are separate refactors after the proxy migration is stable.

## Compose Contract

The deployment wrapper supplies:

- an absolute runtime environment path;
- an absolute module configuration directory;
- an explicit project directory;
- a stable project name;
- a controlled process environment.

The explicit project directory must also make the custom Caddy Dockerfile and
build context resolve predictably.

Compose CLI interpolation and container environment injection are treated as
different mechanisms. Each service explicitly allowlists the environment
variables it needs. File-backed Compose secrets are preferred for credentials
when supported by the image.

Validation uses `docker compose config --quiet`. Fully rendered configuration
must not be written to logs because it may contain secrets.

The Caddy base image and Porkbun plugin version should be pinned to compatible
versions before rebuilds are treated as reproducible. Until version pinning is
implemented, each rollout must record the exact built image ID and retain the
previous working image for rollback.

## Installation Contract

A future idempotent `scripts/install.sh` owns host directory and repository
unit installation. It must:

- require Linux and root privileges for host installation;
- verify required host tools;
- create directories without weakening existing permissions;
- never generate or overwrite active secrets;
- install examples only as `*.example`;
- update repository-owned systemd units atomically;
- use a deployment lock under `/run/server-infra`;
- support `--check`, `--config-root`, and `--help`.

`scripts/bootstrap.sh` remains responsible for base prerequisite checks.

## Consequences

- Runtime configuration is no longer recoverable from Git alone.
- Host configuration requires its own tested backup and recovery procedure.
- Deployments become safer across multiple hosts because repository code is
  independent of host values.
- Proxy migration takes multiple small deployments instead of one large
  cutover.
- The reusable Porkbun-enabled Caddy build remains in Git, while Porkbun
  credentials and wildcard domain policy belong to host runtime
  configuration.
- Legacy configuration temporarily coexists with the new contract to provide
  an explicit rollback path.
- Application code, application deployment logic, domains, server names, and
  production labels remain outside reusable infrastructure modules.
