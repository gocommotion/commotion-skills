# scripts/ — the direct-HTTP transport for the Commotion skills

These three helpers replace the hosted `commotion` MCP server. A skill phase documents the
endpoint, method, and body; these scripts handle authentication and schema fetching so the
Kong api-key never lands in a command transcript and every call is made the same way.

| Script | Replaces | What it does |
|--------|----------|--------------|
| `commotion_api.sh` | the MCP transport (every `mcp__commotion__*` call) | One authenticated HTTP call to dev3 via Kong. Injects base URL + `apikey` + `X-Route-Selector`; on non-2xx prints the backend body and exits non-zero. |
| `fetch_schema.sh` | `*_request_schema` tools | Fetches `/v3/api-docs/public` once per session (cached), then bundles a named component schema with its transitive `$defs`. |
| `bundle_schema.py` | `server/utils/openapi.py:bundle_schema` | Stdlib port of the bundler `fetch_schema.sh` pipes the spec through. Byte-equivalent to the MCP server's output. |

## Environment

Secrets are env-only; non-secrets have defaults (mirrors `commotion-mcp/server/configuration/settings.yaml`).

| Var | Required | Default | Meaning |
|-----|----------|---------|---------|
| `KONG_API_KEY` | yes (secret) | — | Kong api-key for dev3. Provide your own; never commit it. |
| `KONG_BACKEND_URL` | no | `https://apigw.dev3.gocommotion.com` | Kong gateway base URL |
| `KONG_API_KEY_HEADER` | no | `apikey` | header name carrying the api-key |
| `KONG_ROUTE_SELECTOR` | no | `demo_workspace` | `X-Route-Selector` workspace value |
| `COMMOTION_SCHEMA_CACHE` | no | `${TMPDIR:-/tmp}/commotion-mcp/api-docs.json` | per-session spec cache |

Load them from a gitignored `.env` at the repo root (`set -a; . ./.env; set +a`) or export them.

## Usage

```bash
# A call: commotion_api.sh <METHOD> <PATH> [BODY|@file|-]
bash scripts/commotion_api.sh GET /aimodel
bash scripts/commotion_api.sh GET '/aiagent?workerId=ID&version=0'
bash scripts/commotion_api.sh POST /aiworker @worker.json
echo '{"name":"X"}' | bash scripts/commotion_api.sh POST /aiworker -
bash scripts/commotion_api.sh POST '/aiworker/ID/deploy?version=0'

# A schema (fetched once, then served from cache):
bash scripts/fetch_schema.sh AiWorkerRequest
bash scripts/fetch_schema.sh CreateCustomToolRequest
bash scripts/fetch_schema.sh AiWorkerRequest --refresh   # force re-download
```

When installed as a plugin, resolve this directory as `"$CLAUDE_PLUGIN_ROOT/scripts"`; when
running from a clone, it is the repo's `scripts/`.
