# Style Guide

## General

- Keep the repository boring and predictable.
- Prefer explicit names over clever abstractions.
- Use lowercase kebab-case for files and directories.
- Keep configuration close to the environment that owns it.

## Shell

All shell scripts must:

- use `#!/usr/bin/env bash`;
- use `set -Eeuo pipefail`;
- expose `--help`;
- fail with non-zero exit code on errors;
- avoid interactive prompts;
- be safe to run multiple times.

## Docker Compose

- One `docker-compose.yml` per module.
- No application-specific services in server-level modules.
- Use explicit container names only when operationally useful.
- Use named volumes for persistent service data.
- Do not commit secrets.

## Host Modules

- Declare host executables with `HOST_EXECUTABLES`.
- Expose only operator-facing host commands with `HOST_PUBLIC_EXECUTABLES`;
  keep implementation helpers under `libexec`.
- Keep declared executables directly under the module's `bin/` directory.
- Declare apply-time dependencies with `HOST_REQUIRED_COMMANDS`.
- Keep module preflight read-only and declare it with
  `HOST_PREFLIGHT_EXECUTABLE`.
- Declare persistent and cache directories with `HOST_STATE_DIRS` and
  `HOST_CACHE_DIRS`.
- Declare all systemd units with `SYSTEMD_UNITS`.
- Declare the subset enabled by deployment with `SYSTEMD_ENABLE_UNITS`.
- Keep declared units directly under the module's `systemd/` directory.
- Do not execute native services directly from the Git checkout.
- Do not add module-specific branches to the host driver.

## Configuration

- Active host configuration belongs under `/etc/server-infra`.
- Use `runtime.env` as the main runtime environment filename for a module.
- Append `.example` to the complete runtime filename for tracked examples.
- Examples must use deliberately invalid domains, credentials, and tokens.
- Document whether each example value is required, sensitive, and operationally
  disruptive to change.
- Use uppercase snake case for environment variables.
- Prefix repository orchestration variables with `SERVER_INFRA_`.
- Preserve upstream-standard names such as `RESTIC_*` and `AWS_*`.
- Do not source host runtime configuration as executable shell code.
- Runtime environment files support blank lines, whole-line comments, and one
  uppercase `KEY=VALUE` assignment per line.
- A complete value may be wrapped in matching single or double quotes. Values
  are treated literally; shell expansion, `export`, and inline comments are not
  supported.
- Do not commit domains, server names, application routes, passwords, private
  keys, API tokens, or provider credentials.
- Declare required non-secret module files with `REQUIRED_CONFIG_FILES`.

## Documentation

Module READMEs should include:

- Purpose
- Components
- Configuration
- Deployment
- Operations
- Troubleshooting

Root documentation explains repository-wide concepts only.

## Repository Evolution

- Prefer extending contracts over adding special cases.
- Prefer metadata over hardcoded conditions.
- Do not add module-specific branches to generic scripts.
- Do not introduce new top-level directories without an architecture decision.
- Keep infrastructure independent from application projects.
