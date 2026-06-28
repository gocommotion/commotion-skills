# Tools & capabilities

How to give a worker the ability to **act**, not just talk — over the dev3 `ai-worker-tool` plane
(called directly over HTTP — see `api-and-auth.md`). A *tool* is a named capability attached to a
worker; the agent(s) decide when to call it during a conversation. This is the companion to
`agents-and-orchestration.md` (what the agents are) and `knowledge-and-rag.md` (what they know).

> Scope of this doc: the kinds wired today — **built-in actions**, **custom (HTTP API) tools**,
> **MCP-server tools**, the **connector** ecosystem (integration apps + OAuth credentials +
> webhooks), and **A2A** (calling another agent) — plus the cross-cutting model (worker-level
> projection, HITL).

## Endpoints

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/ai-worker-tool?aiWorkerId=&version=&aiWorkerToolId=&searchText=&pageNumber=&pageSize=&sortDirection=` | list a worker's tools (or one tool by `aiWorkerToolId`) |
| DELETE | `/ai-worker-tool` | detach tools (array of ids in body; draft only) |
| GET | `/ai-worker-tool/metadata` | built-in action catalog (read first) |
| POST / PUT | `/ai-worker-tool/custom-tool[/{id}]` | HTTP-wrapper tool |
| POST / PUT | `/ai-worker-tool/built-in-actions[/{id}]` | built-in actions |
| POST / PUT | `/ai-worker-tool/mcp-server[/{id}]` | external MCP server (⚠ create 500s) |
| POST / PUT | `/ai-worker-tool/connector[/{id}]` | SaaS connector |
| POST | `/ai-worker-tool/credential` | store a credential |
| GET | `/ai-worker-tool/credentials?appIdentifiers=…` | list stored credentials |
| DELETE | `/ai-worker-tool/credential` | delete credentials (body `{"credentialIds":[…]}`) |
| GET | `/ai-worker-tool/integration-apps?identifiers=&pageNumber=&pageSize=` | available SaaS apps |
| GET | `/ai-worker-tool/app-actions?aiWorkerId=&version=&appIdentifier=&searchText=&…` | an app's actions |
| GET | `/ai-worker-tool/webhooks?appIdentifier=&searchText=&…` | an app's webhooks |
| GET | `/.well-known/agent.json/{workerId}` · POST `/a2a/{workerId}` | A2A card / send |
| POST | `/aiworker/continue` | resume a run paused on a `REQUIRE_APPROVAL` action |

Body shapes: `fetch_schema.sh <Name>` — `CreateCustomToolRequest`, `CreateBuiltInActionsToolRequest`,
`CreateMcpServerRequest`/`UpdateMcpServerRequest`, `CreateConnectorToolRequest`/`UpdateConnectorToolRequest`,
`CreateCredentialRequest`.

## The golden rules (verified against the dev3 spec)

1. **A tool is created on the worker; an agent uses it via its prompt (verified live).** Every
   create body carries only `aiWorkerId` + `version` — there is **no agent↔tool field** anywhere on
   the API (`AiAgentRequest`/`AiAgentResponse` have no tools field; the tool record has no agent
   field). So the tool's only structural home is the worker. An **agent uses a tool by naming it in
   its `instructions`** — the `/Actions` mention, the exact same pattern as `/Knowledge` — which is
   how you scope a tool to a *specific* agent. (Exception: a `WORKFLOW` worker binds a tool to a step
   by `aiWorkerToolId`.) So "attach to the agent" = create on the worker, then reference it in that
   agent's prompt. Don't say "tools are worker-wide" — that's only true until you write the prompts.
2. **Attach only on a DRAFT.** Like agents and knowledge, tools can only be created/updated while the
   worker is a draft. Attach during provisioning (after the agents exist, before deploy); editing a
   live worker means reverting it to a draft first (only one draft exists per worker at a time).
3. **Ground in the catalog + schema first.** `GET /ai-worker-tool/metadata` lists the built-in action
   catalog (the valid `builtInActionId` codes). `fetch_schema.sh <kind-schema>` returns the live JSON
   Schema for any kind's body — never invent a field.
4. **The custom tool is an HTTP wrapper — there is no "code" mode.** `custom-tool` wraps an arbitrary
   HTTP API (url + method + headers + query + body). dev3 has **no** code-snippet/script tool today,
   despite the concept doc's wording — confirmed against the live schema.
5. **Every API the flow calls MUST be a registered tool — naming it in the prompt does NOT call it
   (verified live).** A prompt that says "call API 001" with no registered tool makes the model
   **fabricate a generic `api_call(...)`**; the platform returns `function 'api_call' is not
   registered`, and the agent **loops, re-asking for the same input**. The fix: register each API as a
   `custom-tool` (`POST /ai-worker-tool/custom-tool`) and reference it by its **action name**
   (`[tool:rmn-check-228]`) in the agent's `instructions` — read the action name from
   `GET /ai-worker-tool?aiWorkerId=…&version=…` → `actionMetaDataOutputList[].actionName`. Keep the
   prompt's anti-hallucination/grounding rule (see `agents-and-orchestration.md`) even after the tool
   exists, for tool failures and empty results.
6. **HITL is in-band — on connector & MCP-server actions only (verified live).** Set `hitlMode`
   (`AUTO_RUN` | `REQUIRE_APPROVAL` | `ASK_FOR_DETAILS`) on a connector/MCP action in the create body;
   **built-in actions have no `hitlMode`** (a custom tool's auto-generated action exposes the slot but
   it isn't an input on create). A paused run resumes with `POST /aiworker/continue` (see below).
7. **Show every write before you make it.** Same rule as the rest of the skill — summarise the tool
   you're about to attach (and especially any `REQUIRE_APPROVAL` action) and get a yes.

## Picking the kind

| The worker needs to… | Kind | Endpoint |
|----------------------|------|----------|
| End a call, transfer, or another platform built-in | built-in action | `POST /ai-worker-tool/built-in-actions` |
| Call an arbitrary HTTP/REST API you have a URL for | custom (HTTP wrapper) | `POST /ai-worker-tool/custom-tool` |
| Use actions exposed by an external MCP server | MCP-server | `POST /ai-worker-tool/mcp-server` |
| Use a SaaS app (Zoho, Slack, …) with managed auth | connector | `POST /ai-worker-tool/connector` |
| Call another Commotion agent | A2A | `GET /.well-known/agent.json/{id}` + `POST /a2a/{id}` |

## The bodies (run `fetch_schema.sh <Name>` for the live shape)

**Built-in actions** (`CreateBuiltInActionsToolRequest`) — `aiWorkerId`, `version`, and
`builtInActionMetaDataRequestList[]`; each entry's `builtInActionId` is a `code` from
`GET /ai-worker-tool/metadata` (`end_call`, `transfer_to_human`, `code_interpreter`,
`switch_language`), plus `description`, `builtInActionDisplayName`, and per-action params. **No
`hitlMode`.** The defaults (`end_call`, `switch_language`) are already on every worker — re-adding one
returns `400 "already configured"`, so only add the non-defaults.

**Custom HTTP tool** (`CreateCustomToolRequest`) — `aiWorkerId`, `version`, and `customToolMetadata`:
`name`, `description`, `url`, `customToolMethod` (`GET`/`POST`/`PUT`/`PATCH`/`DELETE`),
`headers` (object), `queryParams[]` and `body[]` (each field `{fieldName, fieldType:
STRING|NUMBER|BOOLEAN|JSON|OBJECT|ANY, required, defaultValue}`). The backend auto-generates the
action name/identifier from `name` (e.g. `lookup_order` → action `lookup-order-189`).

**MCP-server tool** (`CreateMcpServerRequest`) — `mcpServerUrl`, `name`, `aiWorkerId`, `version`,
`requestTimeout`, `maximumTotalTimeout`, and `mcpServerHeaderRequest` (the headers used to
authenticate to that external server). The backend handshakes the server at create time to discover
its actions. **Known issue (verified live):** dev3 returns a generic `500 "Failed to create MCP
server"` on *every* attempt — unreachable public servers **and** a reachable, known-good streamable-HTTP
server (with and without auth). A bad body is a 400, so this is a **backend-side failure in the
create/handshake flow**, not an input/reachability problem — raise with BE before relying on MCP-server tools.

**Connector tool** (`CreateConnectorToolRequest`) — required: `aiWorkerId`, `version`,
`appMetaDataInput` (`appIdentifier` + display fields, from `GET /ai-worker-tool/integration-apps`),
`actionMetaDataListInput[]` (each `actionIdentifier` from `GET /ai-worker-tool/app-actions`, with a
per-action `hitlMode`). **`credentialMetaDataInput` is optional** (verified) — you can attach the
actions now and add the credential later via `PUT /ai-worker-tool/connector/{id}`. Optional
`toolWebhookMetaDataInputList[]` (from `GET /ai-worker-tool/webhooks`). The update body
(`UpdateConnectorToolRequest`) is partial — the action/webhook lists you pass **replace** the existing
ones. An app-action object is `{identifier, displayName, existsInAiWorker}`.

**Credential** (`CreateCredentialRequest`, only `appIdentifier` required) — `name`, `displayName`,
`appIdentifier`, `authIdentifier`, and the auth payload. An app advertises its auth methods in
`GET /ai-worker-tool/integration-apps` → `credentials[]`: `authIdentifier` is `OAUTH_AUTHORIZATION_CODE`,
`OAUTH_CLIENT_CREDENTIALS`, or `OTHER` (API-key/token), each with an `inputConfigList` of fields.
- OAuth apps → pass `authorizationCode` (`code` + PKCE `codeVerifier`) from a completed consent flow.
- `OTHER` apps → pass the key(s) as a JSON string in `data` (e.g. `data:"{\"apiKey\":\"…\"}"`).
**The backend validates the credential** — an invalid/dummy key returns **`200 {"id":"","success":false}`**
(no error text), so you can't fake a working credential (verified with a dummy Clockify key). Credentials
are shared — one can back several connector tools.

## Recipes

**Built-in action** (no `hitlMode`; skip the catalog defaults `end_call`/`switch_language`):
```
GET  /ai-worker-tool/metadata                 # codes: end_call, transfer_to_human, code_interpreter, switch_language
POST /ai-worker-tool/built-in-actions  { aiWorkerId:<id>, version:<draft>,
  builtInActionMetaDataRequestList:[
    { builtInActionId:"transfer_to_human", builtInActionDisplayName:"Transfer to human",
      description:"Escalate to a human agent" } ] }
```

**Custom HTTP tool:**
```
fetch_schema.sh CreateCustomToolRequest       # confirm the field shape
POST /ai-worker-tool/custom-tool  { aiWorkerId:<id>, version:<draft>, customToolMetadata:{
  name:"lookup_order", description:"Fetch an order by id",
  url:"https://api.example.com/orders", customToolMethod:"GET",
  headers:{ Authorization:"Bearer …" },
  queryParams:[{ fieldName:"orderId", fieldType:"STRING", required:true, defaultValue:"" }] } }
```

**MCP-server tool** (⚠ currently 500s on create — dev3 bug):
```
POST /ai-worker-tool/mcp-server  { aiWorkerId:<id>, version:0, name:"Docs MCP",
  mcpServerUrl:"https://mcp.example.com", requestTimeout:5000, maximumTotalTimeout:30000,
  mcpServerHeaderRequest:{ Authorization:"Bearer …" } }
# response's actionMetaDataOutputList is the discovered actions (when the BE bug is fixed)
```

**Connector (SaaS app) — discover, attach, then wire credential:**
```
GET  /ai-worker-tool/integration-apps                                       # pick the app; note credentials[].authIdentifier
GET  /ai-worker-tool/app-actions?aiWorkerId=<id>&version=<draft>&appIdentifier=clockify   # -> {identifier, displayName}
# attach the action(s) now — credential is OPTIONAL:
POST /ai-worker-tool/connector  { aiWorkerId:<id>, version:<draft>,
  appMetaDataInput:{ appIdentifier:"clockify", appDisplayName:"Clockify" },
  actionMetaDataListInput:[ { actionIdentifier:"create_client", hitlMode:"REQUIRE_APPROVAL" } ] }
# then add a credential when you have real auth, and reference it:
GET  /ai-worker-tool/credentials?appIdentifiers=clockify                    # reuse one if it exists
# PUT /ai-worker-tool/connector/<toolId>  { …, credentialMetaDataInput:{ credentialIdentifier:"<id>" } }
```

**Credentials — verified live.** The backend **validates** the credential, so dummy/fake keys don't
work: `POST /ai-worker-tool/credential` returns `200 {"id":"","success":false}` (no error text) for an
invalid key.
- **`OTHER` (API-key) apps** → put the key in `data` as JSON: `data:"{\"apiKey\":\"<real key>\"}"`.
- **OAuth apps** → needs an `authorizationCode` (`code` + PKCE) from a completed consent screen;
  there's no headless way to mint that, so the OAuth handshake happens in the **Commotion UI** and the
  skill references the resulting `credentialIdentifier`.
Check `GET /ai-worker-tool/credentials?appIdentifiers=…` first and reuse an existing credential rather
than re-authorising. Because `credentialMetaDataInput` is optional, you can attach the connector's
actions immediately and add the credential later (`PUT /ai-worker-tool/connector/{id}`) once real auth exists.

## Binding a tool to an agent (the `/` mention) — REQUIRED

Creating a tool attaches it to the **worker**, but an **agent only calls a tool its prompt
references** — exactly like knowledge. In the agent prompt editor this is the **`/` command**
("Type / to add tools and more"); over the API it is a **mention token in the agent's
`instructions`** (set with `PUT /aiagent/{id}`). The tokens (all verified live):

| What | Token | Has id? |
|------|-------|---------|
| A tool/action | `[tool:<action name>]` | **no** — name only |
| Knowledge | `[knowledge:<name>\|id:<knowledgeId>]` | yes |
| Another agent (hand off to it) | `[agent:<name>\|id:<agentId>]` | yes |
| A variable | `[var:<name>]` | no |

The `<action name>` is the tool's **action** name, not the tool name and not its id — read it from
`GET /ai-worker-tool?aiWorkerId=<id>&version=<draft>` → each tool's `actionMetaDataOutputList[].actionName`.
A custom tool named `lookup_order` gets action `lookup-order-189`; connector actions look like
`google-sheet-get-rows-686`. So:

```
GET /ai-worker-tool?aiWorkerId=<id>&version=<draft>        # find the action name(s)
PUT /aiagent/<agentId>  { …, instructions:
  "…When the caller gives an order id, look it up.\n\n[tool:lookup-order-189]\n\n…" }
```

Verified live: writing `[tool:lookup-order-189]` into an agent's `instructions` via `PUT /aiagent/{id}`
round-trips intact (same as the `/Knowledge` token). **Only the agents whose prompt carries the
`[tool:…]` mention call that tool** — that is how you scope a worker tool to a specific agent.
Built-in actions (`end_call`, `transfer_to_human`, …) are referenced by their action name the same
way; describe when to use them in the prose.

## HITL — the pause and the resume

Flag any action with `hitlMode:"REQUIRE_APPROVAL"` (vs `AUTO_RUN`, or `ASK_FOR_DETAILS` to collect
missing input). At runtime, when the worker wants to run that action it **pauses** and asks the human
to approve. Resume the run with:

```
POST /aiworker/continue  { workerId, agentId, sessionId, runId, agentRunId,
                           userInput:{ <the approval/decision> }, toolName? }
```

(The `sessionId`/`runId`/`agentRunId` come from the paused conversation, so the resume is driven by
whatever is hosting the live conversation — not by the build flow itself.) Use `REQUIRE_APPROVAL` for
anything side-effecting or risky (sending money, deleting records, contacting a customer); leave
read-only lookups on `AUTO_RUN`.

## Auto-capabilities: reasoning & state (NOT tools)

Two capabilities aren't tools — you don't attach them, you turn them on (or they appear on their own):

- **Reasoning** — a config flag, not a tool. Set it on the agent's advanced settings:
  `advancedSettingsRequest.languageModelSettingsRequest.reasoningEffortEnabled: true` +
  `reasoningEffort: "LOW" | "MEDIUM" | "HIGH"` (also available at worker LM settings). Only works on a
  model that supports it — `GET /aimodel` shows `reasoningEffortEnabled` per model. Use it for agents
  that must plan/decompose; leave it off for simple Q&A (latency/cost).
- **State access** — appears automatically once the worker *has* state. State variables are produced by
  workflow Set-State steps or captured from tool/API responses (`stateVariableTo…Map`), and an agent
  reads them in its prompt via the **`[var:<name>]`** mention (the same `/` family as `[tool:…]` /
  `[knowledge:…]`). Nothing to create — if state exists, reference it with `[var:…]`.

## A2A — calling another agent

A2A (agent-to-agent) lets one agent use another Commotion agent. **It is a separate protocol, not an
`ai-worker-tool` kind** (verified against the spec): a worker exposes itself at `POST /a2a/{workerId}`
and advertises a card at `GET /.well-known/agent.json/{workerId}`. The calls:

```
GET  /.well-known/agent.json/<other worker id>    # 200: a real A2A agent card (skills, capabilities)
POST /a2a/<other worker id>
     { jsonrpc:"2.0", id:"1", method:"message/send",
       params:{ message:{ role:"user", parts:[{ kind:"text", text:"…" }], messageId:"m1" } } }
```

**Verified live (two gaps):**
1. **No attach-as-tool.** There is **no `ai-worker-tool` path** to bind a remote agent into a worker's
   toolset — the tool record has an `a2aAgentMetaDataOutput` slot, but no public endpoint populates it.
   These calls only *discover* and *invoke* an agent over A2A.
2. **The target must be A2A-enabled.** The card fetch returns a card for any worker, but
   `POST /a2a/{id}` to a worker that isn't enabled as an A2A server comes back (HTTP 200) with the
   JSON-RPC error `"Worker is not enabled as A2A server"`. There is **no A2A-enable field on
   `AiWorkerRequest`** — that toggle lives outside the documented API (UI), so enabling it isn't
   possible from the skill yet.

## Where this sits in the create-worker flow

Attach tools **after the agent(s) are provisioned and before the deploy gate** (SKILL.md Phase 8).
Create each tool on the worker draft, then **reference it in the prompt of the agent(s) that should
use it** (the `/Actions` mention, like `/Knowledge`) — that's how you scope which member calls what on
a `MULTI_AGENT` worker. Show the user each tool (and each HITL gate) before you write it, then verify
with `GET /ai-worker-tool?aiWorkerId=<id>&version=<draft>` before deploying.

## Verified live (worker `6a379970421f279076ad4668`, draft v2)

A real run that attached a custom tool + a built-in action and created an "Order Concierge" agent:

- **Custom tool** `lookup_order` → 200; backend returned action id `lookup-order-189`, `hitlMode: null`.
- **Built-in** `transfer_to_human` → 200; first attempt also sent `end_call` → `400 "already configured"`
  (it's a default). Built-in entries carried **no** `hitlMode`.
- **MCP-server** → `500` on every attempt: public DeepWiki `/mcp` + `/sse`, **and** a reachable
  known-good `/mcp`. Decisive: a direct `POST /mcp initialize` to that same URL returns **200 with a
  valid MCP result** (proven from outside), yet create still 500s — so reachability, auth, protocol,
  trailing-slash, and input are all ruled out. **Definitively a dev3 backend bug in `mcp-server` create.**
- **A2A** — card fetch 200; `POST /a2a/{id}` → `"Worker is not enabled as A2A server"`. No enable
  field/path exists in the spec and no attach-as-tool endpoint → can't be made via the API at all (UI/internal).
- **Connector** — `integration-apps` → 50 apps; `app-actions` (clockify) → `create_client` …;
  `POST /ai-worker-tool/connector` with that action and **no credential** → 200
  (`hitlMode:REQUIRE_APPROVAL` round-tripped). `POST /ai-worker-tool/credential` with a dummy Clockify
  key → `200 {"id":"","success":false}` (keys are validated — dummies don't take).
- **Binding** — embedding `[tool:lookup-order-189]` in the Order Concierge agent's `instructions` via
  `PUT /aiagent/{id}` round-tripped intact, wiring the custom tool to that agent. Token vocabulary across
  the workspace (a 500-agent scan): `[tool:…]` ×540 (name only, no id), `[knowledge:…|id:…]` ×280,
  `[var:…]` ×390, `[agent:…|id:…]` ×90.
- Error bodies are **XML** (`<LinkedHashMap>…`), not JSON. Tools attach only on the **draft** (v2);
  the live worker was v1.
