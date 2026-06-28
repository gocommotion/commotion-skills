# Agents, single vs multi-agent, and orchestration

A **worker** is a container; its conversational behaviour lives in one or more **agents** (the
`/aiagent` resource, called directly over HTTP — see `api-and-auth.md`). This file is the agent-side
companion to `aiworker-lifecycle.md`.

## Endpoints

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/aiagent?workerId=&version=&pageNumber=0&pageSize=10&sortDirection=DESC` | list (find the default agent, verify enablement) |
| GET | `/aiagent/{id}?version=N` | one agent's full record |
| POST | `/aiagent` | create an agent on a DRAFT worker (`AiAgentRequest`) |
| POST | `/aiagent/standard` | create a *standard* agent, e.g. FAQ (`CreateStandardAgentRequest`) |
| PUT | `/aiagent/{id}` | update — tune instructions / toggle `aiAgentEnabled` (`AiAgentRequest`) |
| DELETE | `/aiagent/{id}?version=N` | delete an agent (the `version` query param is **required**) |

Body shapes: `fetch_schema.sh AiAgentRequest` / `CreateStandardAgentRequest`.

## The golden rules (verified against dev3)

1. **Agents can be created/edited only while the worker is a DRAFT.** Creating one on a live worker
   fails: `400 "Agent can only be created when worker is in draft status. Use a draft worker."` To
   change a live worker's agents, revert it to a draft first (see the lifecycle reference).
2. **A new worker is auto-provisioned with one default agent, DISABLED.** Deploy requires it enabled.
3. **`aiAgentEnabled: true` is the deploy gate.** The error `"requires exactly one enabled agent, but
   found 0"` means the agent exists but is disabled — enable it with `PUT /aiagent/{id}`.
4. **`SINGLE_AGENT` allows exactly one agent — total.** Trying to add a second fails: `400 "Cannot
   create another agent. Single Agent setup allows only one agent."` To have more than one, switch
   the worker to `MULTI_AGENT` first (`PUT /aiworker/{id}` on the draft), *then* `POST /aiagent`.

## Setup types

| `agentSetupType` | Meaning | Agents | Worker prompt role |
|---|---|---|---|
| `SINGLE_AGENT` | One agent does everything | exactly 1 | the agent's behaviour |
| `MULTI_AGENT` | Specialists collaborate | many | **orchestrator** — routes each request to the right agent |
| `WORKFLOW` | Predefined sequence of steps | as the flow needs | the flow definition |

Switching type is allowed **only on a draft** (verified: SINGLE_AGENT → MULTI_AGENT via
`PUT /aiworker/{id}`, then a second agent attached and deployed).

**Where the prompt lives (verified live).** The **detailed system prompt / flow logic goes in the
agent's `instructions`**, not `workerLevelPrompt`. `workerLevelPrompt` is a short worker-level role
line (~100 chars, or the orchestrator/router for MULTI_AGENT); the agent's `instructions` carry the
full behaviour. The runtime composes the two.

**CRITICAL — POST-create the prompt-bearing agent, or it won't show/edit in the UI (verified live).**
An agent's prompt only renders (and is editable) in the Commotion UI prompt editor if the agent was
**created via `POST /aiagent` with the `instructions` in the create body**. The auto-provisioned
**default** agent, updated via `PUT`, runs fine on its `instructions` (confirmed via
`POST /aiworker/run`) but its **editor stays blank** — the editor's document is initialised at agent
*create* time, and a `PUT` updates the runtime `instructions` without populating it. Diagnostic that
proved it: one worker with a PUT-updated default agent and a POST-created agent — only the
POST-created one rendered. So in **every** worker, POST the prompt-bearing agent — the only trick is
freeing the slot:
- **`SINGLE_AGENT` → delete the auto-default, then POST (verified live).** A direct POST is rejected
  while the default exists (`400 "Single Agent setup allows only one agent"`), so:
  `DELETE /aiagent/{defaultId}?version=0` (the `version` query param is **required** — without it:
  `400 "version is required"`) → returns `true`, agent count drops to 0 → then `POST /aiagent` the
  real agent with `instructions` + `aiAgentEnabled:true`. Its prompt renders + is editable. So a
  single-agent worker CAN have a UI-visible prompt — you don't have to switch to MULTI_AGENT for that.
- **`MULTI_AGENT` → disable (or delete) the default, then POST each specialist.** Each specialist is a
  separate `POST /aiagent` with its own focused `instructions`; `workerLevelPrompt` is the orchestrator.
- The empty editor box is otherwise **not** a sign of a missing prompt — `GET /aiagent/{id}`
  (`instructions`) + a `POST /aiworker/run` test are the source of truth, not the editor.
- To revise a POST-created agent's prompt, edit it in the UI (syncs both) or re-`POST` a fresh agent
  (delete the old via `DELETE /aiagent/{id}?version=N`); a plain API `PUT` may update the runtime
  without refreshing the editor.

**Voice worker default agent (verified live).** A voice worker's auto-provisioned default agent is
named **"Voice Agent"** (chat workers get "Chat Agent") and starts disabled. The request field
`agentType` is echoed in the **response** as **`aiAgentType`** — so after `PUT /aiagent/{id}` with
`agentType:"VOICE_AGENT"`, read it back from `aiAgentType` (it sticks); the `agentType` key itself is
request-only and reads back `null`, which is *not* a failure to save. `aiAgentEnabled: true` is the
deploy gate.

**Prompt set via API drives the runtime, but may not render in the UI editor (verified live).** The
agent's `instructions` set over the API are what the worker actually runs on — confirmed by
`POST /aiworker/run` (the agent followed the prompt). They may **not appear in the UI's rich prompt
editor** (which renders its own structured doc), so an empty editor box does *not* mean the agent has
no prompt — check `GET /aiagent/{id}` (`instructions`) and a test run, not the editor.

**Anti-hallucination (verified live).** An agent whose prompt says "call API X" but has **no tool
wired** will *fabricate* the result rather than call anything — e.g. it declared a phone number "not
registered" with nothing backing it. Naming an API in the prompt does not make the agent call it.
Worse (verified live): when the prompt says "call API 001" with no registered tool, the model
**fabricates a generic `api_call(...)` tool**, the platform returns `function 'api_call' is not
registered`, and the agent then **loops — re-asking for the same input** instead of failing. Two
fixes, use both:
1. **Wire each API as a real tool** and reference it by its **action name** (`[tool:rmn-check-228]`)
   in the agent's `instructions` (see `tools-and-capabilities.md`) — so the agent calls a registered
   tool, not a hallucinated `api_call`.
2. **Give the prompt an explicit grounding rule** (keep it even after tools exist, for tool
   failures/empty results): never state/assume a backend fact unless a tool actually returned it; if
   you can't get it, say you can't verify and hand off / call back — never guess.

**Don't re-ask for what's already given (verified live — bake into the prompt).** Once the caller HAS
provided a detail, acknowledge it and move on — don't ask for the same thing again. (If they haven't
actually given it, or it was unclear/incomplete, asking *once* is correct.) Call each tool **at most
once per attempt**; on a tool error/empty result take the failure path **once** (can't-verify →
transfer/callback) rather than looping back to re-ask for information you already have. This is the
same loop the fabricated-`api_call` case triggers — the grounding rule and the call-once rule
together keep the agent from spinning.

## The agent body (`AiAgentRequest`)

Required: **`aiWorkerId`**, **`version`**, **`name`**, **`description`**. Useful optional fields:

- **`agentType`** — one of `FAQ`, `FAQ_CHAT`, `FAQ_VOICE`, `VOICE_AGENT`, `CHAT_AGENT`,
  `STRUCTURED_OUTPUT`, `CUSTOM`.
- **`instructions`** — the agent's system prompt / behaviour.
- **`aiAgentEnabled`** — boolean; must be `true` to count toward the deploy gate.
- Also available: `advancedSettingsRequest`, `modelConfigurationRequestList`,
  `aiAgentSubscriptionRequestList`, `aiAgentTriggerInputList`, `structuredOutputConfig`, `imageUrl`.

`version` is the worker version you're editing (e.g. `0` for a fresh worker, or the draft's version
when editing a live worker's draft).

## FAQ agents (answer strictly from docs)

An **FAQ agent** answers only from attached knowledge — no invention, no live lookups. There is no
"strict" flag; the behaviour is **prompt-led**. Creating one has a sharp edge (verified live):

1. **FAQ types must be created via `POST /aiagent/standard`, NOT `POST /aiagent`.** The plain
   `POST /aiagent` rejects them: `400 "Only VOICE_AGENT, CHAT_AGENT & STRUCTURED_OUTPUT agent type is
   supported."` Use `POST /aiagent/standard` with `{agentType:"FAQ_CHAT", aiWorkerId:<id>, version:<draft>}`
   (or `FAQ_VOICE` / `FAQ`).
2. **A standard FAQ agent is born DISABLED with empty instructions.** Follow up with
   `PUT /aiagent/{id}` with `{... , instructions:"<strict grounding>", aiAgentEnabled:true}` to add
   the prompt and enable it. (FAQ types are rejected by `POST /aiagent` but **accepted by `PUT`**.)
   Strict-grounding instructions, e.g. *"Answer only from the worker's attached knowledge; if a
   topic isn't in it, say you don't know — never guess, no outside knowledge, no live lookups."*

An FAQ agent is only useful once a knowledge base is **attached and indexed** — see
`references/knowledge-and-rag.md`. `CHAT_AGENT`/`VOICE_AGENT`/`STRUCTURED_OUTPUT` agents are created
normally with `POST /aiagent` (instructions inline).

## Structured-output agents (the 4th type — strict parseable output)

A `STRUCTURED_OUTPUT` agent returns a **strict, schema-conforming shape** instead of free prose — for
when a downstream system parses the worker's output. It is **single-agent only** (one agent, total),
and the worker carries `structuredOutputEnabled: true`. The config + verified flow:

1. **Create the worker with `structuredOutputEnabled: true`** (`SINGLE_AGENT`). Verified live: the
   auto-provisioned default agent is then born as **`STRUCTURED_OUTPUT`** (disabled) — you don't create
   a second one (single-agent), you **update** that default.
2. **Add the schema + enable** with `PUT /aiagent/{defaultAgentId}` and body `{ agentType:"STRUCTURED_OUTPUT",
   instructions:"…extract into the schema, no prose…", aiAgentEnabled:true, structuredOutputConfig:{…} }`.
   (`STRUCTURED_OUTPUT` is also accepted by `POST /aiagent` directly.)

`structuredOutputConfig` = `{ maxRetries, schemaFields:[ SchemaField… ] }`. Each **`SchemaField`**:
- `name`, `type`: `STRING | INTEGER | FLOAT | BOOLEAN | OBJECT`, `description`.
- `required`, `multiValue` (array of that type).
- `enumEnabled: true` + `enumValues:[…]` for a closed set.
- `properties` — nested `SchemaField`s when `type: OBJECT`.
- `validation` — `{ minLength, maxLength, pattern, format: DATE_TIME|TIME|DATE|EMAIL|DURATION,
  minValue, maxValue, multipleOf, minItems, maxItems, … }`.

```
PUT /aiagent/{defaultAgentId}  body:
{ aiWorkerId:<id>, version:<draft>, name:"Order Extractor",
  description:"Extracts an order summary", agentType:"STRUCTURED_OUTPUT", aiAgentEnabled:true,
  instructions:"Extract the order details into the schema; never add prose.",
  structuredOutputConfig:{ maxRetries:2, schemaFields:[
    { name:"order_id", type:"STRING", required:true, description:"The order id" },
    { name:"amount",   type:"FLOAT" },
    { name:"status",   type:"STRING", required:true, enumEnabled:true,
      enumValues:["PENDING","SHIPPED","DELIVERED"] } ] } }
```

Verified live (worker `6a3ad4c71778706cdf8df295`): the schema round-trips intact. That the agent
actually *returns* a conforming shape is a runtime behaviour — needs a live conversation to confirm.
See `references/control-and-reliability.md` for the worker-side `structuredOutputEnabled` + guardrails
+ fallback config.

## Recipes

**Enable a single-agent worker (the common case):**
```
GET /aiagent?workerId=<id>&version=0                # finds the default "Chat Agent", disabled
PUT /aiagent/<agentId>  { ...keep fields..., "aiAgentEnabled": true }
# now exactly one enabled agent → POST /aiworker/<id>/deploy?version=0
```

**Build a multi-agent worker:**
```
# worker created/updated with agentSetupType = MULTI_AGENT (on a draft)
PUT  /aiagent/<defaultAgentId>  { "aiAgentEnabled": true, ... }
POST /aiagent  { aiWorkerId:<id>, version:0, name:"Billing", description:"...",
                 agentType:"VOICE_AGENT", instructions:"...", aiAgentEnabled:true }
# the worker's workerLevelPrompt is the orchestrator that routes to these agents
# → POST /aiworker/<id>/deploy?version=0
```
