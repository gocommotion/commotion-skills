#!/usr/bin/env bash
#
# fetch_schema.sh — fetch a named request schema from the live dev3 OpenAPI spec.
#
# Replaces the MCP server's *_request_schema tools. Downloads /v3/api-docs/public ONCE per
# session into a cache file, then bundles the named component schema with its transitive
# $defs (same logic as commotion-mcp/server/utils/openapi.py). Re-running for another schema
# name reuses the cached spec — fetch once, reuse all session.
#
# Usage:
#   fetch_schema.sh <SchemaName> [--refresh]
#
# Common schema names (see references/api-and-auth.md for the full map):
#   AiWorkerRequest                      worker create/update body
#   AiAgentRequest                       agent create/update body
#   CreateAiWorkerKnowledgeItemRequest   one knowledge_create_bulk item
#   CreateCustomToolRequest              custom (HTTP) tool
#   CreateBuiltInActionsToolRequest      built-in actions tool
#   CreateConnectorToolRequest           connector tool
#   CreateCredentialRequest              connector credential
#   CreateMcpServerRequest               MCP-server tool
#
# Cache location: $COMMOTION_SCHEMA_CACHE, else ${TMPDIR:-/tmp}/commotion-mcp/api-docs.json
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

schema_name="${1:-}"
refresh="${2:-}"
if [[ -z "$schema_name" ]]; then
  echo "usage: fetch_schema.sh <SchemaName> [--refresh]" >&2
  exit 2
fi

cache="${COMMOTION_SCHEMA_CACHE:-${TMPDIR:-/tmp}/commotion-mcp/api-docs.json}"
mkdir -p "$(dirname "$cache")"

if [[ "$refresh" == "--refresh" || ! -s "$cache" ]]; then
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT
  if ! bash "$script_dir/commotion_api.sh" GET /v3/api-docs/public >"$tmp"; then
    echo "error: failed to fetch OpenAPI spec from /v3/api-docs/public" >&2
    exit 1
  fi
  mv "$tmp" "$cache"
  trap - EXIT
fi

python3 "$script_dir/bundle_schema.py" "$schema_name" <"$cache"
