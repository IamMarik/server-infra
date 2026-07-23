# Architecture

## Mission

`server-infra` manages reusable server-level infrastructure.

It is intentionally independent from applications. The same repository should
be able to configure an application server, a database-only server, a
monitoring server, or a future staging server by changing only host-owned
runtime configuration.

## Boundaries

This repository owns:

- reverse proxy infrastructure;
- server monitoring and operational tools;
- server bootstrap and health scripts;
- reusable infrastructure module definitions;
- environment-level infrastructure configuration.

This repository does not own:

- application source code;
- application business logic;
- application-specific Docker Compose files;
- application database schemas or migrations;
- application-specific deployment scripts.

## Core concepts

### Host configuration

Host configuration describes a server identity, role, and enabled modules.

Target:

```text
/etc/server-infra/
├── server.env
├── modules.env
├── proxy/runtime.env
└── monitoring/runtime.env
```

The host decides which modules are enabled and provides concrete runtime
values. The repository provides only the contract and safe examples.

The repository-local `environments/<environment>` model remains temporarily as
an explicit migration and rollback mechanism.

### Module

A module is a reusable server capability.

Examples:

- `proxy` - public HTTP/HTTPS routing;
- `monitoring` - uptime checks and container log viewing.

A module must not know which application is running on the server.

### Script

A script performs one operational action, such as deploy, health, logs, or bootstrap.

Scripts must be idempotent and deterministic. Running the same script multiple times should converge to the same server state.

## Deployment flow

```text
Host configuration
  ↓
Enabled modules
  ↓
Module docker-compose.yml + host runtime config
  ↓
Docker Compose
  ↓
Running infrastructure services
```

The deployment engine should deploy modules generically. It should not contain module-specific branches unless there is a repository-level architectural decision to do so.

## Configuration model

Git is the source of truth for reusable infrastructure code, configuration
contracts, schemas, documentation, and safe examples.

Each deployed Linux host owns its active runtime configuration under:

```text
/etc/server-infra/
```

Modules define reusable structure. A host selects enabled modules and provides
concrete values without changing the repository.

Secrets, domains, server names, application routes, and machine-specific values
must not be committed. Commit deliberately invalid `*.example` files instead.

The tracked `environments/` layout is a legacy deployment contract retained
only for the migration described in
`rfc/0002-external-runtime-configuration.md`. New runtime configuration must not
be added there.

## Engineering principles

1. Git is the source of truth for reusable infrastructure and configuration
   contracts, not deployed runtime values or secrets.
2. Infrastructure never knows applications.
3. Environments describe servers.
4. Modules are reusable capabilities.
5. Scripts are idempotent.
6. Documentation lives close to the thing it describes.
7. Prefer explicit configuration over implicit behavior.
8. Prefer simple shell and Docker Compose before heavier tools.
9. Ask before changing repository structure.
