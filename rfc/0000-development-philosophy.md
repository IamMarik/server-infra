# RFC-0000: Development Philosophy

## Status

Accepted.

RFC-0002 amends the runtime configuration boundary described below.

## Context

This repository should remain useful for more than one server and more than one application. It must avoid becoming a collection of one-off scripts and project-specific assumptions.

## Decision

The repository follows these principles:

1. Git is the source of truth for reusable infrastructure code and
   configuration contracts, not deployed runtime values or secrets.
2. Infrastructure never knows applications.
3. Host-owned configuration describes servers.
4. Modules are reusable capabilities.
5. Scripts are idempotent and deterministic.
6. Documentation lives close to the thing it describes.
7. Manual deployment is preferred over hidden automation.
8. Simplicity is preferred over cleverness.

## Consequences

- Application deployment logic does not belong here.
- Application databases and migrations do not belong here unless they become server-level infrastructure.
- Deployment scripts operate on modules generically.
- New modules should not require changes to the deployment engine.
- Active runtime configuration belongs under `/etc/server-infra`.
