# Proxy

## Purpose

Public reverse proxy for server-level services.

## Components

- Caddy
- Porkbun DNS provider built through `Dockerfile.caddy`

## Configuration

The target runtime environment belongs on the host:

```text
/etc/server-infra/proxy/runtime.env
```

Use `proxy/runtime.env.example` as the configuration contract. The active file
contains DNS provider credentials and must be owned by `root:root` with mode
`0600`.

The target host-owned route fragments belong in:

```text
/etc/server-infra/proxy/conf.d/
```

The tracked Caddyfile is temporarily preserved during migration. Concrete
domains and application upstreams must move to host-owned route fragments.

The legacy rollback command still reads:

```text
environments/<environment>/proxy/config.env
```

during the migration window.

Reusable native Caddy configuration lives in:

```text
proxy/Caddyfile
```

## Deployment

Prepare the host layout without changing services:

```bash
scripts/install.sh --module proxy --check
```

The legacy rollback deployment remains:

```bash
scripts/deploy.sh prod-app
```

The external deployment preflight is:

```bash
scripts/deploy.sh --check
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
