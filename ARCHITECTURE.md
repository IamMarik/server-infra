# Architecture

## Mission

`server-infra` manages reusable server-level infrastructure.

It is intentionally independent from applications. The same repository should be able to configure an application server, a database-only server, a monitoring server, or a future staging server by changing only the selected environment.

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

### Environment

An environment describes a server role.

Example:

```text
environments/prod-app/
├── server.env
├── modules.env
├── proxy/
└── monitoring/
```

The environment decides which modules are enabled and provides environment-specific values.

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
Environment
  ↓
Enabled modules
  ↓
Module docker-compose.yml + environment config
  ↓
Docker Compose
  ↓
Running infrastructure services
```

The deployment engine should deploy modules generically. It should not contain module-specific branches unless there is a repository-level architectural decision to do so.

## Configuration model

Configuration belongs to environments.

Modules define reusable structure. Environments provide concrete values.

Secrets and machine-specific values must not be committed. Commit `*.example` files instead.

## Engineering principles

1. Git is the source of truth.
2. Infrastructure never knows applications.
3. Environments describe servers.
4. Modules are reusable capabilities.
5. Scripts are idempotent.
6. Documentation lives close to the thing it describes.
7. Prefer explicit configuration over implicit behavior.
8. Prefer simple shell and Docker Compose before heavier tools.
9. Ask before changing repository structure.
