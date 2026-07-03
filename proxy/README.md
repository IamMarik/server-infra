# Proxy

## Purpose

Public reverse proxy for HTTP/HTTPS traffic.

## Components

- Caddy

## Responsibilities

- terminate HTTPS
- route public domains to internal services
- keep service ports closed from the public internet

## Configuration

- `Caddyfile` contains routes.
- environment values live in `environments/<env>/proxy/config.env`.

## Deployment

```bash
./scripts/deploy.sh <environment>
```
