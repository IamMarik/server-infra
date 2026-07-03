# Monitoring

## Purpose

Server-level monitoring and operational visibility.

## Components

- Uptime Kuma - uptime checks and alerts.
- Dozzle - Docker container logs in a web UI.

## Configuration

Environment-specific values belong in:

```text
environments/<environment>/monitoring/config.env
```

## Deployment

```bash
scripts/deploy.sh prod-app
```

## Operations

Show logs:

```bash
scripts/logs.sh prod-app monitoring
```

## Troubleshooting

- Uptime Kuma listens internally on port `3001`.
- Dozzle listens internally on port `8080`.
- Public routing belongs to the proxy module.
