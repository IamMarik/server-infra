# Proxy

## Purpose

Public reverse proxy for server-level services.

## Components

- Caddy

## Configuration

Environment-specific values belong in:

```text
environments/<environment>/proxy/config.env
```

Native Caddy configuration lives in:

```text
proxy/Caddyfile
```

## Deployment

This module is deployed through the environment deploy script:

```bash
scripts/deploy.sh prod-app
```

## Operations

Show logs:

```bash
scripts/logs.sh prod-app proxy
```

## Troubleshooting

- Check that ports 80 and 443 are free.
- Check DNS records for public domains.
- Check Caddy logs if certificates fail.
