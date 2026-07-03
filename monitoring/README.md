# Monitoring

## Purpose

Operational visibility for the server.

## Components

- Uptime Kuma - availability monitoring
- Dozzle - Docker log viewer

## Public routes

Expected through proxy:

- status domain -> Uptime Kuma
- logs domain -> Dozzle

## Security note

Dozzle must not be left publicly accessible without authentication or access control.
