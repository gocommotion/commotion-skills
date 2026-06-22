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
  agent, the voice/language schema).
allowed-tools: mcp__commotion__aiworker_metadata, mcp__commotion__aiworker_request_schema, mcp__commotion__aimodels_list, mcp__commotion__aiworkers_create, mcp__commotion__aiworkers_update, mcp__commotion__aiworkers_deploy, mcp__commotion__aiworkers_list, mcp__commotion__aiworkers_retrieve, mcp__commotion__aiagents_list, mcp__commotion__aiagents_retrieve, mcp__commotion__aiagents_create, mcp__commotion__aiagents_update, AskUserQuestion
---

# Commotion: Create a Worker

Turn a described goal ("a voice bot that books dealership test drives in Hindi and English") into a
configured, deployed Commotion worker. You supply the judgment — the name, the system prompt, the
voice/guardrail choices, the agent instructions — and the `commotion` MCP tools do the platform
I/O. Every write to the platform is **shown to the user and approved before it happens**.

A worker is a container; the actual conversational behaviour lives in its **agent(s)**. So creating
a working worker is two things: configure the worker, then provision + **enable** its agent(s).

## When to use this

The user wants to create / build / set up a worker, voice agent, assistant, or bot. To *change* an
existing **live** worker, see "Editing a live worker" in `references/aiworker-lifecycle.md` (revert
to a draft → edit → redeploy) — the drafting and agent guidance below still applies.

## Step 0 — Ground yourself in the real schema (always, before drafting)

Never invent field names or values. Read the contracts from the server first:

1. `aiworker_request_schema` → the exact JSON Schema of the worker `config` (bundled with `$defs`).
2. `aiworker_metadata` → valid *values* and defaults (the `agentSetupType` options, ranges, etc.).
3. If voice-enabled, `aimodels_list` → valid model / provider / voice options.

For the agent body fields (`AiAgentRequest`), see `references/agents-and-orchestration.md`.

## Step 1 — Understand the goal (interview only for what's missing)

Extract: business goal, language(s), **voice or chat**, domain, tone, hard constraints, and whether
the work is **one job (single agent)** or **several distinct skills that should be routed between
(multi-agent / workflow)**. Ask only for what you can't infer — `AskUserQuestion`, batched, few.

## Step 2 — Choose the setup type

- **`SINGLE_AGENT`** (default) — one agent handles everything. Simplest; use unless the goal clearly
  splits into distinct sub-skills.
- **`MULTI_AGENT`** — several specialist agents collaborate; the worker's `workerLevelPrompt` acts as
  the **orchestrator** that routes each request to the right agent.
- **`WORKFLOW`** — a fixed, predefined sequence of steps.

Tell the user which you chose and why. (Setup type is changeable later, but only while the worker is
a draft — see the lifecycle reference.)

## Step 3 — Draft the worker config (this is the value you add)

Build a candidate `AiWorkerRequest` grounded in Step 0:

- **`name`** — short, human, from the goal.
- **`agentSetupType`** — from Step 2.
- **`workerGoal`** — one or two sentences: the outcome the worker drives toward.
- **`workerLevelPrompt`** — for `SINGLE_AGENT`, the system prompt. For `MULTI_AGENT`, the
  **orchestrator/routing** prompt (which agent handles what). Voice workers: spoken-style — short
  sentences, no markdown/lists/special characters, one question at a time, read names/numbers back.
- **Voice + languages** (if voice-enabled) — set the voice block; list every language in
  `workerVoiceSettingsRequest.workerVoiceConfiguration.allowedLanguages` (that block also needs
  `model` / `provider` / `voiceId`, or let backend defaults stand). Multilingual → add a prompt line
  telling it to mirror the caller's language. Exact path in `references/aiworker-lifecycle.md`.
- **Guardrails** — propose sensible ones for the domain, shaped to the schema.

## Step 4 — Show the draft and get approval

Summarize in plain language (name, setup type, what it does, languages, guardrails, and the planned
agent(s)) — not a raw JSON dump. Get an explicit "yes" before any write.

## Step 5 — Create the worker

`aiworkers_create(config)` → a **DRAFT at version 0**. Capture the `id`. A new worker is provisioned
with a **default agent** (commonly "Chat Agent"), initially **disabled**. (A draft isn't visible to
`aiworkers_retrieve`, which is live-only — confirm via `aiworkers_list`.)

## Step 6 — Provision + enable the agent(s)  ← the step people miss

Agents can only be created/edited while the worker is a **DRAFT**. List what's there with
`aiagents_list(worker_id=<id>, version=0)`, then:

- **`SINGLE_AGENT`** — there is exactly one agent and there can only ever be one. Configure it with
  `aiagents_update(agent_id, {... , "aiAgentEnabled": true})` — set `aiAgentEnabled: true` (this is
  what the deploy gate checks) and optionally tailor its `instructions`/`agentType` to the goal.
- **`MULTI_AGENT`** — enable the default agent and add the specialists with
  `aiagents_create({aiWorkerId, version, name, description, agentType, instructions, aiAgentEnabled: true})`.
  The worker's orchestrator prompt (Step 3) routes to them.

If the API enable ever fails, fall back to enabling the agent in the Commotion UI, then continue.
See `references/agents-and-orchestration.md` for the agent fields, `agentType` values, and the rules.

## Step 7 — Deploy readiness gate

Confirm with `aiagents_list` before deploying:

- `SINGLE_AGENT` → **exactly one enabled agent** (else deploy 400s "requires exactly one enabled
  agent, but found 0").
- `MULTI_AGENT` → the agents the orchestrator needs are present and enabled.

## Step 8 — Deploy

On approval and once readiness passes: `aiworkers_deploy(id, version=0, draft=False)`. A fresh
worker's first deploy is **version 0**. (To only persist a draft without going live, use
`aiworkers_deploy(id, version=0, draft=True)`.)

## Step 9 — Confirm live

`aiworkers_retrieve(id)` now returns the live worker — show the user the result and its agents.

## Principles

- Ground before you draft; never invent a field that isn't in the schema.
- A worker isn't usable until its agent is **enabled** — treat Step 6 as mandatory, not optional.
- Show every write before you make it; the user approves going live.
- Agents are editable only on a draft; editing a live worker means reverting it to a draft first.
- If a platform call errors, surface the backend's message and check it against the reference notes
  before retrying.
