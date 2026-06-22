# Agents, single vs multi-agent, and orchestration

A **worker** is a container; its conversational behaviour lives in one or more **agents** (the
`/aiagent` resource, surfaced as the `aiagents_*` MCP tools). This file is the agent-side companion
to `aiworker-lifecycle.md`.

## The golden rules (verified against dev3)

1. **Agents can be created/edited only while the worker is a DRAFT.** Creating one on a live worker
   fails: `400 "Agent can only be created when worker is in draft status. Use a draft worker."` To
   change a live worker's agents, revert it to a draft first (see the lifecycle reference).
2. **A new worker is auto-provisioned with one default agent, DISABLED.** Deploy requires it enabled.
3. **`aiAgentEnabled: true` is the deploy gate.** The error `"requires exactly one enabled agent, but
   found 0"` means the agent exists but is disabled — enable it with `aiagents_update`.
4. **`SINGLE_AGENT` allows exactly one agent — total.** Trying to add a second fails: `400 "Cannot
   create another agent. Single Agent setup allows only one agent."` To have more than one, switch
   the worker to `MULTI_AGENT` first (`aiworkers_update` on the draft), *then* `aiagents_create`.

## Setup types

| `agentSetupType` | Meaning | Agents | Worker prompt role |
|---|---|---|---|
| `SINGLE_AGENT` | One agent does everything | exactly 1 | the agent's behaviour |
| `MULTI_AGENT` | Specialists collaborate | many | **orchestrator** — routes each request to the right agent |
| `WORKFLOW` | Predefined sequence of steps | as the flow needs | the flow definition |

Switching type is allowed **only on a draft** (verified: SINGLE_AGENT → MULTI_AGENT via
`aiworkers_update`, then a second agent attached and deployed).

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

## The tools

- `aiagents_list(worker_id?, version?, page_number?, page_size?, sort_direction?)` — list agents,
  filter by `worker_id` (+ `version`). Use it to find the default agent's id and to verify enablement.
- `aiagents_retrieve(agent_id, version?)` — one agent's full record.
- `aiagents_create(config)` — `POST /aiagent`; create an agent on a **draft** worker (`MULTI_AGENT`
  only adds beyond the first).
- `aiagents_update(agent_id, config)` — `PUT /aiagent/{id}`; the way to **enable** the default agent
  and to tune its instructions. (Delete and the `/aiagent/standard` shortcut are not exposed.)

## Recipes

**Enable a single-agent worker (the common case):**
```
agents = aiagents_list(worker_id=<id>, version=0)      # finds the default "Chat Agent", disabled
aiagents_update(agents[0].id, { ...keep fields..., "aiAgentEnabled": true })
# now exactly one enabled agent → aiworkers_deploy(id, version=0)
```

**Build a multi-agent worker:**
```
# worker created/updated with agentSetupType = MULTI_AGENT (on a draft)
aiagents_update(defaultAgentId, { "aiAgentEnabled": true, ... })
aiagents_create({ aiWorkerId:<id>, version:0, name:"Billing", description:"...",
                  agentType:"VOICE_AGENT", instructions:"...", aiAgentEnabled:true })
# the worker's workerLevelPrompt is the orchestrator that routes to these agents
# → aiworkers_deploy(id, version=0)
```
