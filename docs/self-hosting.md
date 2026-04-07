# Self-hosting

Use `./self_host.zsh` to run Fishbowl locally without Docker.

## What it does

- builds the React app for self-hosted/offline use
- builds the Hasura actions server
- starts Postgres, Hasura, and the actions server in tmux
- serves the built SPA through Caddy
- updates `~/Caddyfile` with a Fishbowl site block

The self-hosted client does not rely on Google Fonts, Locize, Sentry, Google Analytics, or PostHog at runtime, so it stays usable on an intranet.

## Commands

```zsh
./self_host.zsh setup [site-address]
./self_host.zsh redeploy [site-address]
./self_host.zsh start [site-address]
./self_host.zsh stop
```

Default site address input:

```text
m1.pinky.lilf.ir
```

The script normalizes bare hosts to `http://...` so Caddy does not try to get a certificate. That means the default ends up as:

```text
http://m1.pinky.lilf.ir
```

`site-address` is written into `~/Caddyfile` as an HTTP site address unless you explicitly include a scheme. Examples:

- `m1.pinky.lilf.ir`
- `fishbowl.example.com`
- `http://192.168.1.50`

If you are not using the default address, pass the same `site-address` again on later `start` / `redeploy` runs so the managed Caddy block stays pointed at the right host.

## Prerequisites

- `tmux`
- `caddy`
- `python3`
- `curl`
- `yarn`
- Node via `nvm`
- Postgres server binaries available either on `PATH` or under `/usr/lib/postgresql/*/bin`

## First deploy

```zsh
./self_host.zsh setup
```

Or with a custom address:

```zsh
./self_host.zsh setup http://192.168.1.50
```

`setup` will:

1. export the requested proxy variables for downloads
2. load Node with `nvm-load` / `nvm use`
3. install JS dependencies
4. download/extract the official Hasura `v1.3.3.cli-migrations-v2` image filesystem locally without using Docker
5. initialize a local Postgres data dir in `.self-hosting/`
6. build the frontend and actions server
7. update `~/Caddyfile`
8. start tmux-managed services
9. apply Hasura migrations and metadata

## Redeploy local changes

```zsh
./self_host.zsh redeploy
```

This rebuilds and restarts from your current local checkout. It does **not** `git pull`.

## Start / stop

```zsh
./self_host.zsh start
./self_host.zsh stop
```

`start` reuses the existing build outputs and database.

## tmux sessions

- `fishbowl-postgres`
- `fishbowl-actions-server`
- `fishbowl-hasura`

Examples:

```zsh
tmux ls
tmux attach -t fishbowl-hasura
```

Logs are also written under:

```text
.self-hosting/logs/
```

## Caddy

The script manages the `# BEGIN fishbowl self-host` / `# END fishbowl self-host` block in `~/Caddyfile` and tries to reload Caddy after updating it.

The generated Fishbowl site block is intentionally HTTP-only.

If your Caddy process is managed elsewhere, reload it with your usual command after running setup/redeploy.

## Ports used

- frontend: served by Caddy from `app/build`
- Hasura: `18080`
- actions server: `13001`
- Postgres: `15432`

Port `3000` is not used.
