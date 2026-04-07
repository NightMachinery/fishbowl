#!/usr/bin/env zsh

set -euo pipefail

tmuxnew () {
	tmux kill-session -t "$1" &> /dev/null || true
	tmux new -d -s "$@"
}

log() {
	print -r -- "==> $*"
}

die() {
	print -ru2 -- "error: $*"
	exit 1
}

retry_command() {
	local max_attempts="$1"
	shift

	local attempt=1
	until "$@"; do
		local exit_code="$?"
		if (( attempt >= max_attempts )); then
			return "$exit_code"
		fi
		print -ru2 -- "warning: command failed (attempt $attempt/$max_attempts), retrying in 5s: $*"
		sleep 5
		((attempt++))
	done
}

usage() {
	cat <<'EOF'
Usage:
  ./self_host.zsh setup [site-address]
  ./self_host.zsh redeploy [site-address]
  ./self_host.zsh start [site-address]
  ./self_host.zsh stop
EOF
	exit 1
}

normalize_site_address() {
	local site_address="$1"
	if [[ "$site_address" == http://* || "$site_address" == https://* ]]; then
		print -r -- "$site_address"
	else
		print -r -- "http://$site_address"
	fi
}

require_command() {
	command -v "$1" &> /dev/null || die "Missing required command: $1"
}

find_postgres_bin_dir() {
	local postgres_bin
	if command -v postgres &> /dev/null; then
		postgres_bin="$(command -v postgres)"
	else
		postgres_bin="$(
			find /usr/lib/postgresql -path '*/bin/postgres' -type f 2> /dev/null \
				| sort -V \
				| tail -n 1
		)"
	fi

	[[ -n "$postgres_bin" ]] || die "Could not find postgres. Install it or add it to PATH."
	print -r -- "${postgres_bin:h}"
}

readonly REPO_ROOT="$(cd -- "${0:A:h}" && pwd)"
readonly COMMAND="${1:-}"
readonly DEFAULT_SITE_ADDRESS="m1.pinky.lilf.ir"
readonly SITE_ADDRESS_INPUT="${2:-${FISHBOWL_SITE_ADDRESS:-$DEFAULT_SITE_ADDRESS}}"
readonly SITE_ADDRESS="$(normalize_site_address "$SITE_ADDRESS_INPUT")"
readonly SITE_ISSUER="$SITE_ADDRESS"

readonly STATE_DIR="$REPO_ROOT/.self-hosting"
readonly HASURA_IMAGE_DIR="$STATE_DIR/hasura-image"
readonly HASURA_ROOTFS="$HASURA_IMAGE_DIR/rootfs"
readonly DATA_DIR="$STATE_DIR/data"
readonly RUN_DIR="$STATE_DIR/run"
readonly LOG_DIR="$STATE_DIR/logs"
readonly PGDATA="$DATA_DIR/postgres"
readonly CADDYFILE="$HOME/Caddyfile"
readonly BUILD_DIR="$REPO_ROOT/app/build"
readonly ACTIONS_BUILD_DIR="$REPO_ROOT/actions-server/build"
readonly NODE_VERSION="${FISHBOWL_NODE_VERSION:-$(if [[ -d "$HOME/.nvm/versions/node/v16.20.2" ]]; then print -r -- 16.20.2; else cat "$REPO_ROOT/.nvmrc"; fi)}"
readonly -a YARN_INSTALL_ARGS=(--frozen-lockfile --network-timeout 600000 --network-concurrency 1 --prefer-offline --link-duplicates)

readonly PG_PORT="${FISHBOWL_PG_PORT:-15432}"
readonly ACTIONS_PORT="${FISHBOWL_ACTIONS_PORT:-13001}"
readonly HASURA_PORT="${FISHBOWL_HASURA_PORT:-18080}"
readonly DB_NAME="${FISHBOWL_DB_NAME:-fishbowl}"
readonly DB_USER="${FISHBOWL_DB_USER:-$(id -un)}"
readonly ADMIN_SECRET="${FISHBOWL_HASURA_ADMIN_SECRET:-myadminsecretkey}"
readonly JWT_KEY="${FISHBOWL_JWT_KEY:-FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE}"
readonly HASURA_IMAGE_TAG="${FISHBOWL_HASURA_IMAGE_TAG:-v1.3.3.cli-migrations-v2}"

readonly SESSION_POSTGRES="fishbowl-postgres"
readonly SESSION_ACTIONS="fishbowl-actions-server"
readonly SESSION_HASURA="fishbowl-hasura"

readonly POSTGRES_BIN_DIR="$(find_postgres_bin_dir)"
readonly POSTGRES_BIN="$POSTGRES_BIN_DIR/postgres"
readonly INITDB_BIN="$POSTGRES_BIN_DIR/initdb"
readonly PG_CTL_BIN="$POSTGRES_BIN_DIR/pg_ctl"
readonly PG_ISREADY_BIN="$(command -v pg_isready)"
readonly CREATEDB_BIN="$(command -v createdb)"
readonly PSQL_BIN="$(command -v psql)"
readonly DATABASE_URL="postgresql://${DB_USER}@127.0.0.1:${PG_PORT}/${DB_NAME}"

copy_env_if_unset() {
	local target_name="$1"
	local source_name="$2"
	local source_value="${(P)source_name:-}"

	if [[ -z "${(P)target_name:-}" && -n "$source_value" ]]; then
		export "$target_name=$source_value"
	fi
}

load_proxy() {
	copy_env_if_unset http_proxy HTTP_PROXY
	copy_env_if_unset HTTP_PROXY http_proxy
	copy_env_if_unset https_proxy HTTPS_PROXY
	copy_env_if_unset HTTPS_PROXY https_proxy
	copy_env_if_unset all_proxy ALL_PROXY
	copy_env_if_unset ALL_PROXY all_proxy

	if [[ -z "${npm_config_proxy:-}" ]]; then
		local proxy_value="${https_proxy:-${HTTPS_PROXY:-${http_proxy:-${HTTP_PROXY:-}}}}"
		if [[ -n "$proxy_value" ]]; then
			export npm_config_proxy="$proxy_value"
		fi
	fi

	if [[ -z "${npm_config_https_proxy:-}" ]]; then
		local https_proxy_value="${https_proxy:-${HTTPS_PROXY:-${http_proxy:-${HTTP_PROXY:-}}}}"
		if [[ -n "$https_proxy_value" ]]; then
			export npm_config_https_proxy="$https_proxy_value"
		fi
	fi

	export npm_config_fetch_retries=5 npm_config_fetch_retry_mintimeout=2000 npm_config_fetch_retry_maxtimeout=120000 npm_config_fetch_timeout=60000
}

clear_proxy() {
	unset npm_config_fetch_retries npm_config_fetch_retry_mintimeout npm_config_fetch_retry_maxtimeout npm_config_fetch_timeout || true
}

bootstrap_nvm() {
	export NVM_DIR="$HOME/.nvm"

	if ! command -v nvm-load &> /dev/null; then
		function nvm-load {
			[[ -s "$HOME/.nvm_load" ]] && source "$HOME/.nvm_load"
			[[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh"
		}
	fi

	nvm-load
	command -v nvm &> /dev/null || die "nvm is not available after nvm-load"
}

resolve_node_version() {
	local requested_version="$1"
	local exact_version

	if [[ "$requested_version" == v*.*.* ]]; then
		print -r -- "$requested_version"
		return
	fi

	exact_version="$(
		python3 - "$requested_version" <<'PY'
import json
import sys
import urllib.request

requested = sys.argv[1].lstrip("v")
with urllib.request.urlopen("https://nodejs.org/dist/index.json") as response:
    versions = json.load(response)

if requested.count(".") == 2:
    target = f"v{requested}"
    for entry in versions:
        if entry["version"] == target:
            print(target)
            break
    else:
        raise SystemExit(f"Could not find Node.js version {target}")
else:
    prefix = f"v{requested}."
    for entry in versions:
        if entry["version"].startswith(prefix):
            print(entry["version"])
            break
    else:
        raise SystemExit(f"Could not find a Node.js release matching {requested}")
PY
	)"

	[[ -n "$exact_version" ]] || die "Could not resolve Node.js version: $requested_version"
	print -r -- "$exact_version"
}

install_node_version_manually() {
	local requested_version="$1"
	local exact_version
	local tmp_dir
	local archive
	local extract_dir
	local destination

	load_proxy
	exact_version="$(resolve_node_version "$requested_version")"
	tmp_dir="$STATE_DIR/tmp/node-$exact_version"
	archive="$tmp_dir/node-$exact_version-linux-x64.tar.xz"
	extract_dir="$tmp_dir/node-$exact_version-linux-x64"
	destination="$HOME/.nvm/versions/node/$exact_version"

	log "Bootstrapping Node.js $exact_version manually"
	rm -rf "$tmp_dir" "$destination"
	mkdir -p "$tmp_dir" "${destination:h}"
	curl -fL --retry 8 --retry-delay 2 --retry-connrefused \
		"https://nodejs.org/dist/$exact_version/node-$exact_version-linux-x64.tar.xz" \
		-o "$archive"
	tar -xJf "$archive" -C "$tmp_dir"
	[[ -d "$extract_dir" ]] || die "Extracted Node.js directory was not found: $extract_dir"
	mv "$extract_dir" "$destination"
	rm -rf "$tmp_dir"
}

load_node() {
	bootstrap_nvm
	load_proxy
	if ! nvm install "$NODE_VERSION"; then
		install_node_version_manually "$NODE_VERSION"
	fi
	nvm use "$NODE_VERSION"
}

ensure_dirs() {
	mkdir -p "$STATE_DIR" "$HASURA_IMAGE_DIR" "$DATA_DIR" "$RUN_DIR" "$LOG_DIR"
}

hasura_path_prefix() {
	print -r -- "$HASURA_ROOTFS/bin:$HASURA_ROOTFS/usr/bin:$PATH"
}

hasura_ld_library_path() {
	local paths=(
		"$HASURA_ROOTFS/lib"
		"$HASURA_ROOTFS/lib64"
		"$HASURA_ROOTFS/usr/lib"
		"$HASURA_ROOTFS/usr/lib/x86_64-linux-gnu"
		"$HASURA_ROOTFS/lib/x86_64-linux-gnu"
	)
	local joined="${(j.:.)paths}"
	if [[ -n "${LD_LIBRARY_PATH:-}" ]]; then
		joined="$joined:$LD_LIBRARY_PATH"
	fi
	print -r -- "$joined"
}

find_hasura_binary() {
	local name="$1"
	local candidate="$(
		find "$HASURA_ROOTFS" -type f -name "$name" 2> /dev/null \
			| sort \
			| head -n 1
	)"
	[[ -n "$candidate" ]] || die "Could not find $name in $HASURA_ROOTFS"
	print -r -- "$candidate"
}

hasura_cli_bin() {
	local candidate="$(
		find "$HASURA_ROOTFS" -type f -name hasura-cli 2> /dev/null \
			| sort \
			| head -n 1
	)"
	if [[ -z "$candidate" ]]; then
		candidate="$(
			find "$HASURA_ROOTFS" -type f -name hasura 2> /dev/null \
				| sort \
				| head -n 1
		)"
	fi
	[[ -n "$candidate" ]] || die "Could not find hasura CLI in $HASURA_ROOTFS"
	print -r -- "$candidate"
}

ensure_hasura_rootfs() {
	local version_file="$HASURA_IMAGE_DIR/tag"
	local rootfs_version=""
	local graphql_engine_existing=""

	if [[ -f "$version_file" ]]; then
		rootfs_version="$(<"$version_file")"
	fi

	if [[ -d "$HASURA_ROOTFS" ]]; then
		graphql_engine_existing="$(
			find "$HASURA_ROOTFS" -type f -name graphql-engine 2> /dev/null \
				| sort \
				| head -n 1
		)"
	fi

	if [[ "$rootfs_version" == "$HASURA_IMAGE_TAG" && -n "$graphql_engine_existing" && -x "$graphql_engine_existing" ]]; then
		return
	fi

	log "Downloading Hasura image filesystem: hasura/graphql-engine:$HASURA_IMAGE_TAG"
	load_proxy
	rm -rf "$HASURA_ROOTFS"
	mkdir -p "$HASURA_ROOTFS"

	python3 - "$HASURA_ROOTFS" "$HASURA_IMAGE_TAG" <<'PY'
import json
import sys
import tarfile
import urllib.request

rootfs = sys.argv[1]
tag = sys.argv[2]
repo = "hasura/graphql-engine"

auth_url = f"https://auth.docker.io/token?service=registry.docker.io&scope=repository:{repo}:pull"
with urllib.request.urlopen(auth_url) as response:
    token = json.load(response)["token"]

def get_json(url: str, accept: str):
    request = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": accept,
        },
    )
    with urllib.request.urlopen(request) as response:
        return json.load(response)

manifest = get_json(
    f"https://registry-1.docker.io/v2/{repo}/manifests/{tag}",
    "application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json",
)

if manifest.get("mediaType", "").endswith("manifest.list.v2+json"):
    chosen = None
    for item in manifest.get("manifests", []):
        platform = item.get("platform", {})
        if platform.get("os") == "linux" and platform.get("architecture") == "amd64":
            chosen = item
            break
    if not chosen:
        raise SystemExit("Could not find a linux/amd64 Hasura image manifest")
    manifest = get_json(
        f"https://registry-1.docker.io/v2/{repo}/manifests/{chosen['digest']}",
        "application/vnd.docker.distribution.manifest.v2+json",
    )

layers = manifest.get("layers", [])
for index, layer in enumerate(layers, start=1):
    digest = layer["digest"]
    size = layer.get("size", 0)
    print(f"Extracting Hasura layer {index}/{len(layers)} ({size} bytes)", file=sys.stderr)
    request = urllib.request.Request(
        f"https://registry-1.docker.io/v2/{repo}/blobs/{digest}",
        headers={"Authorization": f"Bearer {token}"},
    )
    with urllib.request.urlopen(request) as response:
        with tarfile.open(fileobj=response, mode="r|*") as archive:
            archive.extractall(rootfs)
PY

	clear_proxy
	print -r -- "$HASURA_IMAGE_TAG" > "$version_file"
}

run_hasura_cli() {
	clear_proxy
	ensure_hasura_rootfs
	env \
		PATH="$(hasura_path_prefix)" \
		LD_LIBRARY_PATH="$(hasura_ld_library_path)" \
		"$(hasura_cli_bin)" \
		"$@"
}

update_caddy_block() {
	log "Updating $CADDYFILE"
	python3 - "$CADDYFILE" "$SITE_ADDRESS" "$BUILD_DIR" "$HASURA_PORT" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1]).expanduser()
site_address = sys.argv[2]
build_dir = sys.argv[3]
hasura_port = sys.argv[4]

begin = "# BEGIN fishbowl self-host"
end = "# END fishbowl self-host"
block = f"""{begin}
{site_address} {{
\tencode zstd gzip

\t@fishbowl_backend path /healthz /console /console/* /v1 /v1/* /v2 /v2/*
\thandle @fishbowl_backend {{
\t\treverse_proxy 127.0.0.1:{hasura_port}
\t}}

\troot * {build_dir}
\ttry_files {{path}} /index.html
\tfile_server
}}
{end}
"""

text = path.read_text() if path.exists() else ""
if begin in text and end in text:
    start = text.index(begin)
    finish = text.index(end, start) + len(end)
    while finish < len(text) and text[finish] == "\n":
        finish += 1
    before = text[:start].rstrip()
    after = text[finish:].lstrip()
    text = before
    if text:
        text += "\n\n"
    text += block
    if after:
        text += "\n\n" + after
    else:
        text += "\n"
else:
    text = text.rstrip()
    if text:
        text += "\n\n"
    text += block + "\n"

path.write_text(text)
PY
}

reload_caddy() {
	clear_proxy
	require_command caddy
	log "Validating Caddy config"
	caddy validate --config "$CADDYFILE"
	if caddy reload --config "$CADDYFILE" &> /dev/null; then
		log "Reloaded Caddy"
	else
		print -ru2 -- "warning: Could not reload Caddy automatically. Reload it with your normal Caddy command."
	fi
}

install_node_dependencies() {
	load_proxy
	load_node

	log "Installing app dependencies"
	(
		cd "$REPO_ROOT/app"
		retry_command 6 yarn install "${YARN_INSTALL_ARGS[@]}"
	)

	log "Installing actions-server dependencies"
	(
		cd "$REPO_ROOT/actions-server"
		retry_command 6 yarn install "${YARN_INSTALL_ARGS[@]}"
	)

	clear_proxy
}

build_artifacts() {
	load_node
	clear_proxy

	log "Building actions server"
	(
		cd "$REPO_ROOT/actions-server"
		yarn build
	)

	log "Building frontend"
	(
		cd "$REPO_ROOT/app"
		GENERATE_SOURCEMAP=false \
		REACT_APP_SELF_HOST=1 \
		REACT_APP_FISHBOWL_GRAPHQL_ENDPOINT= \
		REACT_APP_FISHBOWL_WS_GRAPHQL_ENDPOINT= \
		yarn build
	)
}

ensure_postgres_cluster() {
	if [[ -s "$PGDATA/PG_VERSION" ]]; then
		return
	fi

	log "Initializing Postgres cluster"
	mkdir -p "$PGDATA"
	"$INITDB_BIN" \
		-D "$PGDATA" \
		--username="$DB_USER" \
		--auth-host=trust \
		--auth-local=trust
}

wait_for_postgres() {
	local attempt
	for attempt in {1..60}; do
		if "$PG_ISREADY_BIN" -h 127.0.0.1 -p "$PG_PORT" -U "$DB_USER" &> /dev/null; then
			return
		fi
		sleep 1
	done
	die "Postgres did not become ready"
}

wait_for_hasura() {
	local attempt
	for attempt in {1..60}; do
		if curl -fsS "http://127.0.0.1:$HASURA_PORT/healthz" &> /dev/null; then
			return
		fi
		sleep 1
	done
	die "Hasura did not become ready"
}

ensure_database_exists() {
	local exists
	exists="$(
		"$PSQL_BIN" \
			-h 127.0.0.1 \
			-p "$PG_PORT" \
			-U "$DB_USER" \
			-d postgres \
			-tAc "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME';"
	)"

	if [[ "$exists" != "1" ]]; then
		log "Creating database $DB_NAME"
		"$CREATEDB_BIN" -h 127.0.0.1 -p "$PG_PORT" -U "$DB_USER" "$DB_NAME"
	fi
}

start_postgres() {
	local log_file="$LOG_DIR/postgres.log"
	local command="exec ${(q)POSTGRES_BIN} -D ${(q)PGDATA} -h 127.0.0.1 -p ${(q)PG_PORT} -k ${(q)RUN_DIR} >> ${(q)log_file} 2>&1"
	log "Starting Postgres in tmux ($SESSION_POSTGRES)"
	tmuxnew "$SESSION_POSTGRES" zsh -lc "$command"
	wait_for_postgres
	ensure_database_exists
}

start_actions_server() {
	local log_file="$LOG_DIR/actions-server.log"
	local command="
		export NVM_DIR=${(q)$HOME/.nvm}
		nvm-load() {
			[[ -s ${(q)$HOME/.nvm_load} ]] && source ${(q)$HOME/.nvm_load}
			[[ -s \$NVM_DIR/nvm.sh ]] && source \$NVM_DIR/nvm.sh
		}
		nvm-load
		nvm use ${(q)NODE_VERSION}
		cd ${(q)$REPO_ROOT/actions-server}
		export NODE_ENV=production
		export SELF_HOST=1
		export PORT=${(q)ACTIONS_PORT}
		export HASURA_ENDPOINT=http://127.0.0.1:${HASURA_PORT}/v1/graphql
		export HASURA_GRAPHQL_JWT_SECRET=${(q)JWT_KEY}
		export JWT_ISSUER=${(q)SITE_ISSUER}
		exec node build/server.js >> ${(q)log_file} 2>&1
	"
	log "Starting actions server in tmux ($SESSION_ACTIONS)"
	tmuxnew "$SESSION_ACTIONS" zsh -lc "$command"
}

start_hasura() {
	ensure_hasura_rootfs
	local graphql_engine_bin="$(find_hasura_binary graphql-engine)"
	local log_file="$LOG_DIR/hasura.log"
	local hasura_path="$(hasura_path_prefix)"
	local hasura_ld_library_path="$(hasura_ld_library_path)"
	local jwt_secret_json="{\"type\":\"HS256\",\"key\":\"$JWT_KEY\"}"
	local command="
		cd ${(q)$REPO_ROOT}
		export PATH=${(q)hasura_path}
		export LD_LIBRARY_PATH=${(q)hasura_ld_library_path}
		export HASURA_GRAPHQL_ADMIN_SECRET=${(q)ADMIN_SECRET}
		export HASURA_GRAPHQL_JWT_SECRET=${(q)jwt_secret_json}
		export HASURA_GRAPHQL_ENABLE_CONSOLE=false
		export HASURA_GRAPHQL_ENABLE_TELEMETRY=false
		export ACTION_BASE_ENDPOINT=http://127.0.0.1:${ACTIONS_PORT}
		exec ${(q)graphql_engine_bin} --database-url ${(q)DATABASE_URL} serve --server-port ${(q)HASURA_PORT} --enabled-log-types startup,http-log,webhook-log,websocket-log,query-log --unauthorized-role anonymous >> ${(q)log_file} 2>&1
	"
	log "Starting Hasura in tmux ($SESSION_HASURA)"
	tmuxnew "$SESSION_HASURA" zsh -lc "$command"
	wait_for_hasura
}

apply_hasura_metadata() {
	log "Applying Hasura migrations"
	run_hasura_cli \
		migrate apply \
		--project "$REPO_ROOT/graphql-server" \
		--endpoint "http://127.0.0.1:$HASURA_PORT" \
		--admin-secret "$ADMIN_SECRET"

	log "Applying Hasura metadata"
	run_hasura_cli \
		metadata apply \
		--project "$REPO_ROOT/graphql-server" \
		--endpoint "http://127.0.0.1:$HASURA_PORT" \
		--admin-secret "$ADMIN_SECRET"
}

ensure_build_outputs() {
	[[ -f "$BUILD_DIR/index.html" ]] || die "Missing app/build/index.html. Run ./self_host.zsh setup or redeploy first."
	[[ -f "$ACTIONS_BUILD_DIR/server.js" ]] || die "Missing actions-server/build/server.js. Run ./self_host.zsh setup or redeploy first."
}

stop_services() {
	log "Stopping services"
	tmux kill-session -t "$SESSION_HASURA" &> /dev/null || true
	tmux kill-session -t "$SESSION_ACTIONS" &> /dev/null || true
	if [[ -s "$PGDATA/postmaster.pid" ]]; then
		"$PG_CTL_BIN" -D "$PGDATA" -m fast stop &> /dev/null || true
	fi
	tmux kill-session -t "$SESSION_POSTGRES" &> /dev/null || true
}

start_services() {
	clear_proxy
	ensure_dirs
	ensure_postgres_cluster
	ensure_build_outputs
	update_caddy_block
	reload_caddy
	start_postgres
	start_actions_server
	start_hasura
	apply_hasura_metadata
}

ensure_common_commands() {
	require_command tmux
	require_command caddy
	require_command curl
	require_command python3
	require_command yarn
	require_command pg_isready
	require_command createdb
	require_command psql
}

do_setup() {
	ensure_common_commands
	require_command yarn

	ensure_dirs
	install_node_dependencies
	ensure_hasura_rootfs
	build_artifacts
	stop_services
	start_services
	log "Fishbowl is available at $SITE_ADDRESS"
}

do_redeploy() {
	ensure_common_commands
	require_command yarn

	ensure_dirs
	install_node_dependencies
	ensure_hasura_rootfs
	build_artifacts
	stop_services
	start_services
	log "Redeployed Fishbowl at $SITE_ADDRESS"
}

do_start() {
	ensure_common_commands
	ensure_dirs
	ensure_hasura_rootfs
	start_services
	log "Fishbowl is running at $SITE_ADDRESS"
}

case "$COMMAND" in
	setup)
		do_setup
		;;
	redeploy)
		do_redeploy
		;;
	start)
		do_start
		;;
	stop)
		stop_services
		;;
	*)
		usage
		;;
esac
