# API & auth — how the skill calls dev3 directly

This is the single "how to call it" reference. There is **no MCP server**: every platform action is
a plain HTTP request to the Commotion dev3 backend through the Kong gateway, made with the helper
scripts in this plugin's `scripts/` directory. The domain reference files (`aiworker-lifecycle.md`,
`agents-and-orchestration.md`, …) describe the *behavior*; this file is the *transport*.

## The helpers

```bash
SCRIPTS="$CLAUDE_PLUGIN_ROOT/scripts"            # plugin install; or the repo's scripts/ from a clone
set -a; . "$CLAUDE_PLUGIN_ROOT/.env"; set +a     # load KONG_API_KEY etc.

bash "$SCRIPTS/commotion_api.sh" <METHOD> <PATH> [BODY]   # one authenticated call
bash "$SCRIPTS/fetch_schema.sh"  <SchemaName> [--refresh] # a bundled request schema (cached once/session)
```

- `commotion_api.sh` injects the base URL and auth headers; `BODY` is inline JSON, `@file.json`, or
  `-` (stdin). It prints the response body on stdout; on a non-2xx it prints the backend body and
  exits non-zero.
- `fetch_schema.sh` downloads `/v3/api-docs/public` once per session into a cache, then bundles the
  named component schema with its transitive `$defs` (refs rewritten to `#/$defs/…`). It can fetch
  **any** component schema name in the spec, not just the ones listed below.

## Auth contract (sent on every call)

| Header | Value | Source |
|--------|-------|--------|
| `apikey` (name = `KONG_API_KEY_HEADER`) | the Kong api-key | env `KONG_API_KEY` (secret) |
| `X-Route-Selector` | workspace selector | env `KONG_ROUTE_SELECTOR`, default `demo_workspace` |

Base URL: `KONG_BACKEND_URL`, default `https://apigw.dev3.gocommotion.com`. The api-key is passed to
curl through a temp config file so it never appears in argv / `ps` / the command transcript.
**Secrets are env-only — never commit a key.** (Swagger UI for humans:
`https://api-tier0.dev3.gocommotion.com/swagger-ui/index.html`.)

## Error semantics

On a non-2xx the helper exits non-zero and prints the backend body. dev3 error bodies are sometimes
XML (`<LinkedHashMap>…`), not JSON. Surface the status + message and check it against the relevant
reference's "edges/golden rules" before retrying — most failures are a known gotcha (missing
`version` on a PUT, an action re-added, a live-only retrieve on a draft, …).

## Untrusted-id safety

Any id you interpolate into a path must be a safe segment (`^[A-Za-z0-9_-]+$`). Ids returned by the
backend already satisfy this; don't pass user free-text into a path.

## List-response shape

List endpoints return a bare JSON array today. Tolerate a paged wrapper too — if a response is an
object, the records may be under `content` / `items` / `data` / `results`. Parse defensively with `jq`.

## Endpoint map

Paths are relative to the base URL. "Schema" is the `fetch_schema.sh` name for the request body.

### Workers & models
| Method | Path | Purpose | Schema |
|--------|------|---------|--------|
| GET | `/aiworker` | list workers (live + draft) | — |
| GET | `/aiworker/{id}` | retrieve **live** worker (`?version=N` for a version) | — |
| POST | `/aiworker` | create worker → DRAFT v0 | `AiWorkerRequest` |
| PUT | `/aiworker/{id}` | update draft (full PUT; body needs `version`) | `AiWorkerRequest` |
| POST | `/aiworker/{id}/deploy?version=N` | deploy version N → LIVE | — |
| POST | `/aiworker/{id}/draft?version=N` | save/keep as draft (revert live → new draft) | — |
| GET | `/aiworker/{id}/versions` | version history (status LIVE/DRAFT) | — |
| POST | `/aiworker/continue` | resume a HITL-paused run | `CopilotChatContinueInput` |
| GET | `/aiworker/metadata` | valid config values/defaults | — |
| GET | `/aimodel` | supported models (modelCode/providerCode/id) | — |
| POST | `/aiworker/run` | run the worker in text — TEST it (returns `{response,status,...}`) | `AiWorkerRunRequest` |

`AiWorkerRunRequest` requires `workerId` + `messageText`; reuse `conversationId`/`sessionId` across
turns. Parse the response tolerantly (the body can contain raw newlines) and retry on 5xx (the
endpoint is occasionally flaky). Use this to evaluate prompt adherence and hallucination before handoff.

### Agents
| Method | Path | Purpose | Schema |
|--------|------|---------|--------|
| GET | `/aiagent?workerId=&version=&pageNumber=0&pageSize=10&sortDirection=DESC` | list agents | — |
| GET | `/aiagent/{id}?version=N` | retrieve one agent | — |
| POST | `/aiagent` | create agent on a draft worker | `AiAgentRequest` |
| POST | `/aiagent/standard` | create a *standard* agent (e.g. FAQ) | `CreateStandardAgentRequest` |
| PUT | `/aiagent/{id}` | update agent (enable it, set instructions) | `AiAgentRequest` |
| DELETE | `/aiagent/{id}?version=N` | delete an agent (`version` query param required) | — |

### Knowledge & files
| Method | Path | Purpose | Schema |
|--------|------|---------|--------|
| GET | `/aiworker/knowledge?aiWorkerId=&pageNumber=&pageSize=&knowledgeType=&knowledgeStatus=&sortDirection=` | list a worker's knowledge (poll `aiWorkerKnowledgeStatus`) | — |
| GET | `/aiworker/knowledge/{id}` | retrieve one item | — |
| POST | `/aiworker/knowledge/bulk` | create item(s) (array body) | `CreateAiWorkerKnowledgeItemRequest` (per item) |
| POST | `/aiworker/knowledge/by-global/{globalId}?aiWorkerId=` | attach a global KB | — |
| GET | `/aiworker/knowledge/global?pageNumber=&pageSize=&sortDirection=` | global-KB catalogue | — |
| POST | `/aiworker/knowledge/index` | index items (array of ids; sync→bool) | — |
| PUT | `/aiworker/knowledge/{id}` | rename an item | `UpdateAiWorkerKnowledgeNameRequest` |
| DELETE | `/aiworker/knowledge` | delete items (array of ids in body) | — |
| POST | `/aiworker/file-upload/text` | upload inline text | `CreateAndUploadTextFileRequest` |
| POST | `/aiworker/file-upload/url` | presigned upload URL for a document | `FileUploadUrlRequest` |
| DELETE | `/aiworker/file-upload/delete` | delete uploaded files | `FileDeleteRequest` |

The byte PUT to the returned `preSignedUrl` is **not** through Kong — `curl -X PUT --upload-file
<file> -H 'x-ms-blob-type: BlockBlob' "<preSignedUrl>"` (Azure Blob Storage; success is `201`).

### Tools (`ai-worker-tool`) & connectors
| Method | Path | Purpose | Schema |
|--------|------|---------|--------|
| GET | `/ai-worker-tool?aiWorkerId=&version=&aiWorkerToolId=&searchText=&pageNumber=&pageSize=&sortDirection=` | list a worker's tools / one tool | — |
| DELETE | `/ai-worker-tool` | delete tools (array of ids in body) | — |
| GET | `/ai-worker-tool/metadata` | built-in action catalog | — |
| POST / PUT | `/ai-worker-tool/custom-tool[/{id}]` | custom HTTP-wrapper tool | `CreateCustomToolRequest` |
| POST / PUT | `/ai-worker-tool/built-in-actions[/{id}]` | built-in actions tool | `CreateBuiltInActionsToolRequest` |
| POST / PUT | `/ai-worker-tool/mcp-server[/{id}]` | external MCP-server tool (⚠ create 500s — dev3 bug) | `CreateMcpServerRequest` / `UpdateMcpServerRequest` |
| POST / PUT | `/ai-worker-tool/connector[/{id}]` | SaaS connector tool | `CreateConnectorToolRequest` / `UpdateConnectorToolRequest` |
| POST | `/ai-worker-tool/credential` | store a connector credential | `CreateCredentialRequest` |
| GET | `/ai-worker-tool/credentials?appIdentifiers=clockify&appIdentifiers=slack` | list stored credentials | — |
| DELETE | `/ai-worker-tool/credential` | delete credentials (body `{"credentialIds":[…]}`) | — |
| GET | `/ai-worker-tool/integration-apps?identifiers=&pageNumber=&pageSize=` | available SaaS apps | — |
| GET | `/ai-worker-tool/app-actions?aiWorkerId=&version=&appIdentifier=&searchText=&pageNumber=&pageSize=` | an app's actions | — |
| GET | `/ai-worker-tool/webhooks?appIdentifier=&searchText=&pageNumber=&pageSize=` | an app's webhooks | — |

### A2A (agent-to-agent — a separate protocol)
| Method | Path | Purpose |
|--------|------|---------|
| GET | `/.well-known/agent.json/{workerId}` | the worker's advertised agent card |
| POST | `/a2a/{workerId}` | send a JSON-RPC message to the worker |

## Schema names for `fetch_schema.sh`

`AiWorkerRequest`, `AiAgentRequest`, `CreateStandardAgentRequest`, `CreateAiWorkerKnowledgeItemRequest`,
`UpdateAiWorkerKnowledgeNameRequest`, `CreateAndUploadTextFileRequest`, `FileUploadUrlRequest`,
`FileDeleteRequest`, `CreateCustomToolRequest`, `CreateBuiltInActionsToolRequest`,
`CreateMcpServerRequest`, `UpdateMcpServerRequest`, `CreateConnectorToolRequest`,
`UpdateConnectorToolRequest`, `CreateCredentialRequest`, `CopilotChatContinueInput`.
(Any other component name in `/v3/api-docs/public` works too.)
