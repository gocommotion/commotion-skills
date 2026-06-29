#!/usr/bin/env bash
#
# commotion_api.sh — authenticated HTTP call to the Commotion dev3 backend (via Kong).
#
# Replaces the commotion MCP server's transport: injects the Kong auth headers and base
# URL so a skill phase only needs the method + path + body. The api-key is read from the
# KONG_API_KEY environment variable and passed to curl through a temp --config file, so it
# never appears in argv / the process list / the command transcript.
#
# Usage:
#   commotion_api.sh <METHOD> <PATH> [BODY]
#     METHOD  GET | POST | PUT | DELETE
#     PATH    request path starting with "/", query string allowed
#             (e.g. /aiworker  |  /aiagent?workerId=ID&version=0  |  /aiworker/ID/deploy?version=0)
#     BODY    optional JSON request body, one of:
#               '<json string>'   inline JSON
#               @/path/file.json  read from a file
#               -                 read from stdin
#
# Env (non-secret have defaults; mirror commotion-mcp/server/configuration/settings.yaml):
#   KONG_API_KEY          (required, secret)  the Kong api-key for dev3
#   KONG_BACKEND_URL      default https://apigw.dev3.gocommotion.com
#   KONG_API_KEY_HEADER   default apikey
#   KONG_ROUTE_SELECTOR   default demo_workspace
#   COMMOTION_ENV_FILE    default ${TMPDIR:-/tmp}/commotion-mcp/session.env
#
# If KONG_API_KEY is not already in the environment, the KONG_* vars are loaded from
# COMMOTION_ENV_FILE — the session-only credentials file the skill writes in Step 0 (the user
# pastes their key once per session). An exported var / local .env still takes precedence.
#
# On a non-2xx response it prints the backend body and exits non-zero (curl --fail-with-body),
# surfacing the status + message the way the MCP server's tool_error did.
set -euo pipefail

usage() {
  echo "usage: commotion_api.sh <METHOD> <PATH> [BODY|@file|-]" >&2
  exit 2
}

method="${1:-}"
path="${2:-}"
body="${3-}"
[[ -n "$method" && -n "$path" ]] || usage

# Load session credentials (KONG_*) only if the key isn't already in the environment, so an
# exported var / local .env keeps precedence. The skill writes this file in Step 0 (mode 600).
cred_file="${COMMOTION_ENV_FILE:-${TMPDIR:-/tmp}/commotion-mcp/session.env}"
if [[ -z "${KONG_API_KEY:-}" && -f "$cred_file" ]]; then
  set -a
  . "$cred_file"
  set +a
fi

base="${KONG_BACKEND_URL:-https://apigw.dev3.gocommotion.com}"
key_header="${KONG_API_KEY_HEADER:-apikey}"
route="${KONG_ROUTE_SELECTOR:-demo_workspace}"

if [[ -z "${KONG_API_KEY:-}" ]]; then
  echo "error: KONG_API_KEY is not set — run Step 0 to provide the Kong api-key for this session" \
       "(written to ${cred_file}), or export KONG_API_KEY / set it in .env" >&2
  exit 2
fi
case "$path" in
  /*) ;;
  *) echo "error: PATH must start with '/' (got: $path)" >&2; exit 2 ;;
esac
case "$path" in
  *[$' \t\n\"'\`]*) echo "error: PATH contains illegal characters" >&2; exit 2 ;;
esac

cfg="$(mktemp)"
bodyfile=""
cleanup() { rm -f "$cfg" "$bodyfile"; }
trap cleanup EXIT

# Secret header lives in the config file (mode 600), never on the command line.
umask 077
{
  printf 'header = "%s: %s"\n' "$key_header" "$KONG_API_KEY"
  printf 'header = "X-Route-Selector: %s"\n' "$route"
} >"$cfg"

args=(--silent --show-error --fail-with-body --request "$method" "${base}${path}" --config "$cfg")

if [[ -n "$body" ]]; then
  args+=(--header "Content-Type: application/json")
  case "$body" in
    -)  args+=(--data-binary @-) ;;
    @*) args+=(--data-binary "$body") ;;
    *)  bodyfile="$(mktemp)"; printf '%s' "$body" >"$bodyfile"; args+=(--data-binary "@$bodyfile") ;;
  esac
fi

curl "${args[@]}"
