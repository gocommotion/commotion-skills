---
name: commotion-create-worker
description: >-
  Build and configure a Commotion voice or chat worker (AI agent) from a described goal, end to
  end — ground in the live config schema, interview for the goal, draft the worker (name, system
  prompt, voice + languages, guardrails), provision and enable its agent(s), and deploy on approval.
  Use this whenever the user wants to create / build / set up a worker, voice agent, assistant, or
  bot for a use case — e.g. "make a voice agent that books dealership test drives in Hindi and
  English", "set up a multi-agent support bot for my client" — even if they don't say the word
  "worker". Handles the dev3 lifecycle (draft↔live versions, single vs multi-agent, enabling the
  agent, the voice/language schema). Calls the dev3 backend directly over HTTP (no MCP server).
allowed-tools: Bash, Read, AskUserQuestion
---

# Commotion: Create a Worker

Turn a described goal ("a voice bot that books dealership test drives in Hindi and English") into a
configured, deployed Commotion worker. You supply the judgment — the name, the system prompt, the
voice/guardrail choices, the agent instructions — and you make the platform I/O yourself with plain
HTTP calls to the dev3 backend (through the Kong gateway). There is **no MCP server**: this skill
carries the endpoints, and you fetch request schemas live from the OpenAPI spec. Every write to the
platform is **shown to the user and approved before it happens**.

A worker is the **orchestrator** that holds and routes to its **agent(s)** — the actual
conversational behaviour lives in the agents. So creating a working worker is two things: configure
the worker (orchestration, voice, guardrails), then provision + **enable** its agent(s).

**Deploy is never automatic.** Going live is an explicit, user-gated step: always ask the user with
`AskUserQuestion` and get a clear "yes" before `deploy` (Phase 10). Drafting/creating/editing on a
draft is fine to do as you go (each write shown), but **never deploy a worker live without
confirmation.**

## When to use this

The user wants to create / build / set up a worker, voice agent, assistant, or bot. To *change* an
existing **live** worker, see "Editing a live worker" in `references/aiworker-lifecycle.md` (revert
to a draft → edit → redeploy) — the drafting and agent guidance below still applies.

## How this skill talks to the platform (read first)

All platform I/O goes through two helper scripts in this plugin's `scripts/` directory. Resolve it
once at the start of a session:

```bash
# Installed as a plugin, $CLAUDE_PLUGIN_ROOT is set. Running from a clone it is NOT set, so fall
# back to the repo's scripts/ — that's two levels up from this skill's Base directory (shown above),
# i.e. <repo>/scripts. Set SCRIPTS to that absolute path (substitute the real clone path):
SCRIPTS="${CLAUDE_PLUGIN_ROOT:-/absolute/path/to/commotion-skills}/scripts"
```

> Do not use `${CLAUDE_PLUGIN_ROOT:?…}` — from a clone that variable is empty and would hard-fail.

### Step 0 — Provide the API key (do this first, before Phase 0)

The helper scripts authenticate with a Kong api-key, and **this skill does not ship one**. Before
any other work, get it from the user and store it for this session only:

1. Ask the user for their Commotion **Kong api-key** with `AskUserQuestion` (and, *only* if their
   workspace isn't the default `demo_workspace`, the route selector). Say it's used only for this
   session and isn't saved.
2. Write it to the session credentials file with restricted permissions, substituting the value the
   user gave — and **never print the key** (no `echo`/`cat` of it, don't repeat it back):
   ```bash
   mkdir -p "${TMPDIR:-/tmp}/commotion-mcp"
   ( umask 077; printf 'KONG_API_KEY=%s\n' '<the key the user provided>' \
       > "${TMPDIR:-/tmp}/commotion-mcp/session.env" )
   # only if the user gave a non-default workspace, also append:
   #   printf 'KONG_ROUTE_SELECTOR=%s\n' '<value>' >> "${TMPDIR:-/tmp}/commotion-mcp/session.env"
   ```
   `commotion_api.sh` auto-loads this file on every call, so you set it once. (An already-exported
   `KONG_API_KEY` or a local `.env` still takes precedence — handy for repeated local runs.)
3. **Smoke-test it:** `bash "$SCRIPTS/commotion_api.sh" GET /aimodel` should return the model list. A
   401/403 means the key is wrong — ask again. Do not start Phase 0 until this passes.

> The key lives only in this session's temp file (mode 600) and the conversation context — it is
> never committed, never written to `.env` by the skill, and never embedded in the skill bundle.

- **Make a call** — `bash "$SCRIPTS/commotion_api.sh" <METHOD> <PATH> [BODY]`. It injects the Kong
  base URL + auth headers (`apikey`, `X-Route-Selector`) so you only supply method + path + body.
  `BODY` is inline JSON, `@file.json`, or `-` (stdin). On a non-2xx it prints the backend body and
  exits non-zero — **surface that message** and check it against the reference notes before retrying.
  For bodies of any size, write the JSON to a temp file and pass `@/tmp/body.json`.
- **Fetch a request schema** — `bash "$SCRIPTS/fetch_schema.sh" <SchemaName>`. It pulls
  `/v3/api-docs/public` **once per session** (cached) and prints the named schema bundled with its
  `$defs`. Re-use it; **never invent a field that isn't in the schema.**
- **Capture ids** from responses with `jq` (e.g. `... | jq -r '.id'`).

The full endpoint map, header contract, error semantics, and schema-name list are in
`references/api-and-auth.md` — the single "how to call it" reference. Field *shapes* always come
from `fetch_schema.sh`; the reference files are the *behavior* the schema doesn't tell you.

**Execution rules:** one phase at a time, in order; read the reference named by a phase before you
act on it; show every write before you make it. Optional phases (7, 8) only run when the goal needs
them.

## Phase 0 — Ground yourself in the real schema (always, before drafting)

Never invent field names or values. Read the contracts from the server first:

1. `bash "$SCRIPTS/fetch_schema.sh" AiWorkerRequest` → the exact JSON Schema of the worker body
   (bundled with `$defs`). Cached for the session.
2. `bash "$SCRIPTS/commotion_api.sh" GET /aiworker/metadata` → valid *values* and defaults
   (`agentSetupType` options; `guardrailConfig` toxicity categories/ranges + PII behaviours;
   `llmConfig` retry range). Top-level keys: `voiceConfig`, `guardrailConfig`, `workerConfig`, `llmConfig`.
3. `bash "$SCRIPTS/commotion_api.sh" GET /aimodel` → valid model / provider codes — for the voice
   block **and** for the primary + fallback models (Phase 3).

For the agent body fields (`AiAgentRequest`), see `references/agents-and-orchestration.md`; for
attaching source material / FAQ grounding, see `references/knowledge-and-rag.md`; for guardrails,
fallback models, and structured output, see `references/control-and-reliability.md`.

If the goal implies the worker must **act** (do something, not just answer), also ground in the tool
surface: `GET /ai-worker-tool/metadata` (the built-in action catalog) and
`fetch_schema.sh <kind-schema>` for whatever kinds you'll attach — see `references/tools-and-capabilities.md`.

## Phase 1 — Understand the goal (interview only for what's missing)  ·  HUMAN INPUT

Extract: business goal, language(s), **voice or chat**, domain, tone, hard constraints, whether the
work is **one job (single agent)** or **several distinct skills that should be routed between
(multi-agent / workflow)**, and **which optional capabilities** the goal needs — knowledge grounding
(Phase 7), tools/actions (Phase 8), structured output, guardrails beyond the safety floor. Ask only
for what you can't infer — `AskUserQuestion`, batched, few.

## Phase 2 — Choose the setup type

**Infer the setup type from the use case — the user will rarely say "multi-agent".** Read the goal
and decide whether the work splits into distinct, specialised responsibilities. If it does, prefer
**`MULTI_AGENT`** so each agent owns its specialty and does it well (a billing agent, a renewal
agent, an FAQ agent, …) instead of one giant prompt trying to do everything. Use one agent only when
the work genuinely is a single responsibility. **When you're unsure how to split it, ask the user**
(`AskUserQuestion`).

- **`MULTI_AGENT`** — specialist agents collaborate; the worker's `workerLevelPrompt` is the
  **orchestrator** that routes each request to the right agent. Each specialist is a separate,
  focused prompt.
- **`SINGLE_AGENT`** — one agent owns the whole job. Simplest, but one prompt carries everything.
- **`WORKFLOW`** — a fixed, predefined sequence of steps.

Tell the user which you chose and why. (Setup type is changeable later, but only while the worker is
a draft — see the lifecycle reference.)

Choose the setup type purely on the **use case** (above) — prompt visibility no longer forces the
choice. In **both** setups you make the prompt UI-visible the same way: by **`POST`-creating** the
prompt-bearing agent (only POSTed agents render in the editor; a PUT-updated default stays blank). The
only difference is freeing the slot (Phase 6): for `SINGLE_AGENT`, **delete the auto-default then POST**
the one agent; for `MULTI_AGENT`, disable the default and POST each specialist. See
`references/agents-and-orchestration.md` ("POST-create the prompt-bearing agent").

**Structured output** is a `SINGLE_AGENT` variant: when the goal is to **return a strict, parseable
shape** for a downstream system to consume (not hold a conversation), set `structuredOutputEnabled:
true` and plan a single `STRUCTURED_OUTPUT` agent (Phase 6). Single-agent only.

## Phase 3 — Draft the worker config (this is the value you add)

Build a candidate `AiWorkerRequest` grounded in Phase 0. Write it to a temp file (e.g.
`/tmp/worker.json`) so you can pass it as `@/tmp/worker.json` in Phase 5.

- **`name`** — short, human, from the goal.
- **`agentSetupType`** — from Phase 2.
- **`workerGoal`** — one or two sentences: the outcome the worker drives toward.
- **`workerLevelPrompt`** — a **concise** worker-level role/identity + cardinal rules, NOT the full
  behaviour. **For `SINGLE_AGENT` the detailed system prompt / flow logic goes in the agent's
  `instructions` (Phase 6), not here** — verified live: on real single-agent workers
  `workerLevelPrompt` is a short role line (~100 chars) while the agent's `instructions` carry the
  actual behaviour. For `MULTI_AGENT`, this is the **orchestrator/routing** prompt (which agent
  handles what). Voice workers: spoken-style — short sentences, no markdown/lists/special characters,
  one question at a time, read names/numbers back (this style applies to whatever the agent *says*).
- **Voice + languages** (if voice-enabled) — set the voice block; list every language in
  `workerVoiceSettingsRequest.workerVoiceConfiguration.allowedLanguages` (that block also needs
  `model` / `provider` / `voiceId`, or let backend defaults stand). **Multilingual language rule
  (bake into the prompt):** stay in the caller's spoken language and continue the WHOLE call in it;
  treat a mobile number, policy number, OTP, or amount read out in English digits as normal data and
  do **NOT** switch the conversation language — and do **NOT** trigger the `Switch Language` built-in
  action — just because numbers are spoken in English. Only switch when the caller actually changes
  their conversational language. (Verified live: without this, the agent flips Hindi→English the
  moment the caller says their number in English.) Exact voice-block path in `references/aiworker-lifecycle.md`.
- **Guardrails** (`guardrailConfigRequest`) — **design them from the use case, don't apply a generic
  set.** Think about what THIS domain handles and protect it, grounded in `/aiworker/metadata`:
  - Handles personal/financial data (insurance, banking, healthcare)? → **PII masking** (Commotion
    detector) plus **regex masking** for the specific sensitive fields it sees (card numbers, account
    numbers, Aadhaar/SSN, policy numbers) with `MASK`/`REDACT`.
  - Company/brand context? → **forbidden words** for competitor names, internal/confidential terms,
    off-limits topics (+ a fallback response).
  - Any customer-facing bot → **toxicity** inbound + outbound (the four categories at sensible
    thresholds), and **custom checks** for domain rules (e.g. "never give medical/financial advice").
  Pick the subset the use case warrants and justify each to the user. They apply in a fixed backend
  order — you don't set order. (e.g. a banking assistant → PII + card/account masking + competitor
  forbidden words + toxicity + a "no financial advice" custom check.)
- **Models + fallback** — choose the primary model and an ordered fallback so a provider hiccup
  doesn't take the worker down. **Where this lives depends on channel (verified live):** a **voice**
  worker sets its LLM provider/model **and its fallback** in the **Voice Settings** block
  (`workerVoiceSettingsRequest.workerLLMConfigurationRequest` + the voice-settings fallback fields —
  this is the "LLM Settings → Fallback Provider/Model" you see under Voice Settings in the UI), NOT in
  `workerAdvancedSettingsRequest` (which a voice worker / `VOICE_AGENT` rejects). A **chat** worker
  sets primary + `workerFallbackModelConfigurationRequestList` + `numberOfRetries` in
  `workerAdvancedSettingsRequest`, or on a `CHAT_AGENT` member's `advancedSettingsRequest`. Get codes
  from `/aimodel`. See `references/control-and-reliability.md`.
- **Structured output** — if chosen in Phase 2, set `structuredOutputEnabled: true` here (the agent's
  schema is configured in Phase 6).

- **Anti-hallucination discipline (bake into the prompt).** If the agent's job depends on backend
  data (policy details, account status, eligibility, prices, "is X registered?"), the prompt MUST
  forbid stating or assuming any such fact unless a **tool/API actually returned it** in the
  conversation, and tell it what to do when it can't get the data (say it can't verify, hand off /
  call back — never guess). **Verified live:** a worker prompted to "call API 001 / API 002 …" with
  **no tools wired** confidently fabricated a backend result (declared a number "not registered" and
  proceeded) — a prompt that merely *names* an API does not make the agent call anything. Worse
  (verified live): when the prompt says "call API 001" with no registered tool, the model **fabricates
  a generic `api_call(...)` tool**, the platform returns `function 'api_call' is not registered`, and
  the agent **loops re-asking** for the same input. The real fix is to **register each API as a custom
  tool (Phase 8) and reference it by its action name** (`[tool:rmn-check-228]`) in the prompt, so the
  agent calls a real registered tool. Until tools are wired, the grounding rule keeps it honest. Keep
  the rule even after tools exist, for tool failures/empty results.
- **Don't re-ask for what's already given (bake into the prompt).** Once the caller HAS provided a
  detail, acknowledge it and move on — don't ask for the same thing again. (If the caller hasn't
  actually given it, or it was unclear/incomplete, asking — once — is correct.) Call each tool at most
  once per attempt; on a tool error/empty result, take the failure path ONCE (can't-verify →
  transfer/callback) rather than looping back to re-ask for information you already have.

Shapes, valid values, and worked examples for guardrails / fallback / structured output are in
`references/control-and-reliability.md`.

## Phase 4 — Show the draft and get approval  ·  HUMAN INPUT REQUIRED

Summarize in plain language (name, setup type, what it does, languages, guardrails, and the planned
agent(s)) — not a raw JSON dump. Get an explicit "yes" before any write.

## Phase 5 — Create the worker

```bash
bash "$SCRIPTS/commotion_api.sh" POST /aiworker @/tmp/worker.json | tee /tmp/worker.created.json
WORKER_ID=$(jq -r '.id' /tmp/worker.created.json)
```

`POST /aiworker` returns a **DRAFT at version 0**. Capture the `id`. A new worker is provisioned with
a **default agent**, initially **disabled** — named "Chat Agent" on a chat worker and **"Voice Agent"
on a voice worker** (verified live; its `agentType` starts `null`). (A draft isn't visible to
`GET /aiworker/{id}`, which is live-only — confirm via `GET /aiworker` (list) if needed.)

## Phase 6 — Provision + enable the agent(s)  ← the step people miss

Agents can only be created/edited while the worker is a **DRAFT**. **Golden rule (verified live):**
the prompt only renders/edits in the UI for agents created via **`POST /aiagent`**. PUT-updating the
auto-provisioned default sets `instructions` for the runtime but leaves the editor blank. So in BOTH
setups you **POST** the prompt-bearing agent — the only difference is making room for it. List what's
there first: `GET /aiagent?workerId=$WORKER_ID&version=0`.

- **`SINGLE_AGENT`** — delete the auto-default, then POST the real agent into the freed slot:
  ```bash
  DEF=$(bash "$SCRIPTS/commotion_api.sh" GET "/aiagent?workerId=$WORKER_ID&version=0" | jq -r '.[0].id')
  bash "$SCRIPTS/commotion_api.sh" DELETE "/aiagent/$DEF?version=0"          # version=0 is REQUIRED
  bash "$SCRIPTS/commotion_api.sh" POST   /aiagent @/tmp/agent.json          # body below, aiAgentEnabled:true
  ```
  (POSTing before the delete fails: `400 "Single Agent setup allows only one agent"`.) The POSTed
  agent's prompt renders + is editable. Agent body: `{aiWorkerId, version:0, name, description,
  agentType, instructions, aiAgentEnabled:true}`. The request `agentType` echoes back as `aiAgentType`
  (the `agentType` key reads back `null` — that's normal; the type still sticks).
- **`MULTI_AGENT`** — disable the auto-default (`PUT /aiagent/{defaultId}` `aiAgentEnabled:false`, or
  delete it as above), then `POST /aiagent` each specialist with its own focused `instructions` +
  `aiAgentEnabled:true`. The worker's `workerLevelPrompt` (Phase 3) is the orchestrator that routes to them.

Either way: **put the full prompt in the POSTed agent's `instructions`; keep `workerLevelPrompt`
concise.** To later revise a POSTed agent's prompt, edit it in the UI (syncs the editor) or re-`POST`
a fresh agent (delete/disable the old) — a plain `PUT` updates the runtime but may not refresh the editor.

**Structured-output agent (strict parseable shape).** If you set `structuredOutputEnabled: true`
(Phase 3), the default agent is auto-born as **`STRUCTURED_OUTPUT`** (disabled) — verified live.
**Update** it (don't add a second — single-agent): `PUT /aiagent/{agentId}` with `{agentType:
"STRUCTURED_OUTPUT", instructions:"…extract into the schema, no prose…", aiAgentEnabled:true,
structuredOutputConfig:{maxRetries, schemaFields:[…]}}`. The `schemaFields` shape (types, enums,
nested objects, validation) is in `references/control-and-reliability.md` /
`references/agents-and-orchestration.md`.

**FAQ agent (answers strictly from docs).** When the goal is "answer questions from this material —
don't make things up," provision an **FAQ agent** (`agentType` `FAQ_CHAT`/`FAQ_VOICE`/`FAQ`). Two
gotchas (verified live): FAQ types **must** be created with `POST /aiagent/standard`
(`POST /aiagent` rejects them — only VOICE_AGENT/CHAT_AGENT/STRUCTURED_OUTPUT), and the standard
agent is born **disabled with empty instructions** — follow up with `PUT /aiagent/{id}` to add
strict-grounding `instructions` (*answer only from the attached knowledge; if it isn't there, say
you don't know — never invent, no outside lookups*) and set `aiAgentEnabled: true`. An FAQ agent is
only useful once a knowledge base is attached and indexed (Phase 7). See
`references/agents-and-orchestration.md` for the full pattern.

If the API enable ever fails, fall back to enabling the agent in the Commotion UI, then continue.
See `references/agents-and-orchestration.md` for the agent fields, `agentType` values, and the rules.

## Phase 7 — Attach knowledge (optional — when the use-case needs grounding)

Skip this phase if the worker needs no source material. Otherwise attach a knowledge base so the
worker **grounds** its answers in it (grounding is automatic once knowledge is created and indexed
for the worker's `aiWorkerId` — there is no RAG toggle). Pick the source(s) the user has; the full
recipes (field shapes, enums, the presigned-PUT) are in `references/knowledge-and-rag.md`:

- **Inline / pasted text** → `POST /aiworker/file-upload/text` (`{content, fileName, fileType}`) →
  `POST /aiworker/knowledge/bulk` → `POST /aiworker/knowledge/index`.
- **Uploaded document** (PDF/docx/txt) → `POST /aiworker/file-upload/url` (`{fileName, fileType}`),
  then **PUT the file bytes to the returned `preSignedUrl` yourself** — `curl -X PUT --upload-file
  ./doc.pdf -H 'x-ms-blob-type: BlockBlob' "<preSignedUrl>"` (bytes go straight to Azure Blob
  Storage, **not** through the backend; the header is required or Azure 400s; success is `201`) →
  `POST /aiworker/knowledge/bulk` → `POST /aiworker/knowledge/index`.
- **Existing global KB** → `GET /aiworker/knowledge/global` →
  `POST /aiworker/knowledge/by-global/{globalId}?aiWorkerId=$WORKER_ID` (already published — no index step).

Run `fetch_schema.sh CreateAiWorkerKnowledgeItemRequest` first if unsure of the bulk item shape.
Indexing is **synchronous** but the material isn't searchable instantly — **poll
`GET /aiworker/knowledge?aiWorkerId=$WORKER_ID` and wait until each item's `aiWorkerKnowledgeStatus`
is ready before deploying**. Show the user what you're attaching before each write.

**Then bind the KB to each grounded agent (required).** Worker-level attach alone does *not* make an
agent use it — the agent's prompt must reference the KB. Over the API this is a mention token in the
agent's `instructions`: `PUT /aiagent/{agentId}` with `{..., instructions: "<prose telling it to
search the knowledge base>\n\n[knowledge:<knowledge name>|id:<knowledgeId>]"}`. There is no separate
agent↔knowledge field. See `references/knowledge-and-rag.md` ("Binding knowledge to an agent").

## Phase 8 — Attach tools (think hard about what should be a tool)

Don't treat this as "skip unless the worker obviously acts." **Actively work out what the worker
should NOT be doing in the prompt and turn that into tools** — every lookup, status check, link
generation, record write, or external call belongs in a tool, so the prompt orchestrates and the
tools do the work (the prompt shouldn't carry data or fake results). **When you're unsure whether
something should be a tool, ask the user.**

- **Every API the flow calls MUST be a registered tool — never let the agent "call an API" from the
  prompt.** Naming an API in the prompt (e.g. "call API 001") does NOT make a call: the model
  fabricates a generic `api_call(...)`, the platform returns `function 'api_call' is not registered`,
  and the agent loops (verified live). Register each API as a `custom-tool` (`POST
  /ai-worker-tool/custom-tool`) and reference it by its **action name** (`[tool:rmn-check-228]`) in the
  agent's `instructions`. Read each tool's action name from
  `GET /ai-worker-tool?aiWorkerId=…&version=…` → `actionMetaDataOutputList[].actionName`.

The full per-kind recipes, body shapes, HITL, and the projection model are in
`references/tools-and-capabilities.md`. Tools attach to the **draft** worker (body carries
`aiWorkerId` + `version`), so do this before the deploy gate.

- **Decide what it must do**, and map each need to a kind: a platform built-in (end call, transfer) →
  `POST /ai-worker-tool/built-in-actions` (codes from `GET /ai-worker-tool/metadata`); an arbitrary
  HTTP API → `POST /ai-worker-tool/custom-tool` (an HTTP wrapper — **there is no code-snippet mode**);
  an external MCP server → `POST /ai-worker-tool/mcp-server`; a managed SaaS app (Zoho, Slack, …) → a
  **connector**: `GET /ai-worker-tool/integration-apps` → `GET /ai-worker-tool/app-actions` /
  `GET /ai-worker-tool/webhooks` → `POST /ai-worker-tool/credential` (OAuth) →
  `POST /ai-worker-tool/connector` (see the connector recipe in the reference); another Commotion
  agent (A2A) → discover its card with `GET /.well-known/agent.json/{workerId}` and call it with
  `POST /a2a/{workerId}` (A2A is a separate resource, not an `ai-worker-tool` — see the reference's A2A note).
- **Worker vs agent (verified live).** A tool is *created* on the worker (`aiWorkerId` + `version`) —
  that's its only structural home; there is no agent↔tool field on the API. An **agent only calls a
  tool its prompt references**: embed a mention token in `instructions` — `[tool:<action name>]`
  (name only, no id; the action name comes from `GET /ai-worker-tool?aiWorkerId=…&version=…`'s
  `actionMetaDataOutputList[].actionName`, e.g. `lookup-order-189`). Same family as
  `[knowledge:<name>|id:<id>]`, `[agent:<name>|id:<id>]` (hand off to another agent), and `[var:…]`.
  So: create on the worker, then `PUT /aiagent/{id}` with `[tool:…]` in `instructions` — that's how
  you scope a tool to a specific agent. See `references/tools-and-capabilities.md` ("Binding a tool to an agent").
- **Built-ins:** the catalog defaults (`end_call`, `switch_language`) are **already configured** on
  every worker — re-adding one is a 400. Add only non-defaults (e.g. `transfer_to_human`). Built-in
  actions have **no** `hitlMode`.
- **HITL:** `hitlMode: "REQUIRE_APPROVAL"` lives on **connector and MCP-server** actions (not built-in);
  at runtime that action pauses for approval and resumes via `POST /aiworker/continue`.
- **Connector credentials are validated** — a dummy/invalid key gives `200 {"id":"","success":false}`
  (no error). `credentialMetaDataInput` is **optional**, so attach the connector's actions first and add
  the credential (`PUT /ai-worker-tool/connector/{id}`) once you have real auth (OAuth → done in the UI).
- **MCP-server tools** currently fail with a backend `500` on every create (verified live) — a dev3
  defect, not your input; don't promise this kind until BE fixes it.
- **Auto-capabilities (turn on, don't attach):** *reasoning* via
  `advancedSettingsRequest.languageModelSettingsRequest.reasoningEffortEnabled:true` +
  `reasoningEffort:LOW|MEDIUM|HIGH` (model must support it — see `/aimodel`); *state* appears on its own
  when the worker has it — agents read it in the prompt via `[var:<name>]`. Neither is a tool.
- **Show every write before you make it** (especially each HITL gate); confirm with
  `GET /ai-worker-tool?aiWorkerId=$WORKER_ID&version=0`.

## Phase 9 — Deploy readiness gate

Confirm with `GET /aiagent?workerId=$WORKER_ID&version=0` before deploying:

- `SINGLE_AGENT` → **exactly one enabled agent** (else deploy 400s "requires exactly one enabled
  agent, but found 0").
- `MULTI_AGENT` → the agents the orchestrator needs are present and enabled.
- If you attached knowledge (Phase 7) → every item's `aiWorkerKnowledgeStatus` is ready (not still
  indexing/failed), so the worker actually grounds on it from the first live conversation.
- If you attached tools (Phase 8) → `GET /ai-worker-tool?aiWorkerId=$WORKER_ID&version=0` shows them as expected.

## Phase 10 — Deploy  ·  ALWAYS ASK FIRST

**Never deploy without an explicit user "yes".** Once readiness passes, summarise what will go live
and ask with `AskUserQuestion` (e.g. "Deploy this worker live now?" — Deploy now / Keep as draft).
Only on a clear yes:

```bash
bash "$SCRIPTS/commotion_api.sh" POST "/aiworker/$WORKER_ID/deploy?version=0"
```

A fresh worker's first deploy is **version 0**. If the user is not ready, leave it as a draft (you
can persist a draft without going live with `POST "/aiworker/$WORKER_ID/draft?version=0"`). Deploying
is the one irreversible-feeling step for the user — gating it on confirmation is mandatory, not optional.

## Phase 11 — Confirm live

```bash
bash "$SCRIPTS/commotion_api.sh" GET "/aiworker/$WORKER_ID"
```

This now returns the live worker — show the user the result and its agents.

## Phase 12 — Test the agent (don't stop at CRUD)

Creating the worker is not the goal — a worker that behaves well is. Drive a few real turns through
the agent and judge prompt adherence, functionality, and **hallucination**:

```bash
bash "$SCRIPTS/commotion_api.sh" POST /aiworker/run \
  '{"workerId":"'$WORKER_ID'","messageText":"<a realistic opening line>","conversationId":"t1","sessionId":"t1","userId":"t1"}'
# continue the conversation by reusing the same conversationId/sessionId
```

`POST /aiworker/run` runs the worker in text and returns `{response,status,...}` (parse tolerantly —
the body can contain raw newlines; the endpoint is occasionally flaky, so retry on 5xx). Pick
scenarios that exercise the **branches and the failure paths**, not just the happy greeting. Watch
for the agent **asserting backend facts it never fetched** (the #1 failure) — if it invents
data, tighten the grounding rule (Phase 3) and/or wire the tools (Phase 8), redeploy, and re-test.
Editing the live worker means revert-to-draft → edit the agent at the new draft version → redeploy
(see `references/aiworker-lifecycle.md`).

## Principles

- Ground before you draft; never invent a field that isn't in the schema (`fetch_schema.sh`).
- A worker isn't usable until its agent is **enabled** — treat Phase 6 as mandatory, not optional.
- Grounding needs both halves: knowledge must be **created and indexed** — attaching without
  indexing (or deploying before indexing finishes) means the worker has nothing to ground on.
- Show every write before you make it; the user approves going live.
- Tools are created on the **worker** (draft only); an agent uses one by **naming it in its prompt**
  (like knowledge), so scope per agent there. Flag risky connector/MCP actions `REQUIRE_APPROVAL`.
- Guardrails + fallback models are worker-definition config (set on the draft, shown before write);
  guardrail order is backend-enforced. Structured output is **single-agent only** (`structuredOutputEnabled`
  + a `STRUCTURED_OUTPUT` agent).
- Agents are editable only on a draft; editing a live worker means reverting it to a draft first.
- If a platform call errors, the helper surfaces the backend's status + message — read it and check
  it against the reference notes before retrying.
