---
name: commotion-generate-scenarios
description: >-
  Build a realistic test set for a Commotion worker — the simulated callers (personalities) and the
  scenarios they run — so the worker can be evaluated automatically. Ground in the live scenario
  schema, design personas and scenarios from the worker's goal, AI-generate scenarios (or author them
  manually / from a real call), and create them on the platform with each write approved. Use this
  whenever the user wants to test, simulate, stress-test, or "make scenarios / personas / a test set"
  for a worker — e.g. "generate test cases for my renewal bot", "make an angry-caller persona and run
  it against the worker". This is step 2 of the quality loop (create-worker → **generate-scenarios** →
  run-evals → improve-worker). Calls the dev3 backend directly over HTTP (no MCP server).
allowed-tools: Bash, Read, AskUserQuestion
---

# Commotion: Generate Scenarios & Personalities

Turn a worker's goal into a **test set** that exercises it: a set of **scenarios** (each a simulated
conversation with a goal the worker must achieve) driven by **personalities** (the simulated caller's
persona, voice, and behaviour). You supply the judgment — which personas the domain needs, which
happy/failure/jailbreak paths matter, what each scenario's success looks like — and you make the
platform I/O yourself with plain HTTP calls to the dev3 backend (through the Kong gateway). There is
**no MCP server**: this skill carries the endpoints and you fetch request schemas live from the
OpenAPI spec. **Every write is shown to the user and approved before it happens.**

This is **step 2 of the worker quality loop**:

```
create-worker → [generate-scenarios] → run-evals → improve-worker
                                          └──────── repeat until pass-rate ≥ threshold ────────┘
```

Scenarios and personalities created here are the input to `commotion-run-evals` (step 3), which runs
them as a simulation and reports the pass-rate. The whole loop runs against a specific worker
**version** — see the version rule below.

## Prerequisites (verified live — the test set is only runnable if these hold)

- **The worker must be VOICE-enabled.** Simulations/evals only run on voice workers (a chat worker
  fails every run). So build the test set for a voice worker; if the target is chat, enable voice first
  (see `commotion-create-worker`; voice can be turned on via a draft).
- **The worker must have been deployed (live) at least once.** AI scenario-generation and simulation
  both need a live runtime — for a **never-deployed** worker, `POST /scenario/generate` produces
  **nothing** and sims fail with *"Worker is not available"*. (A draft *version* of an already-live
  worker is fine.)
- **Personalities must be voice-enabled** (`voiceEnabled:true` + a voice) to drive voice simulations.

## When to use this

The user wants to build test cases / scenarios / simulated callers for a worker, or asks to "test" or
"simulate" a worker before/after deploying. If they then want to actually run them and read scores,
that's `commotion-run-evals`; if they want to iterate the worker until it passes, that's
`commotion-improve-worker`. You usually arrive here already knowing the worker id (from create-worker);
if not, ask for it or list `GET /aiworker`. **For the whole build → test → improve pipeline in one
request, use the `commotion-quality-loop` orchestrator** (it invokes this skill as its scenario step).

## How this skill talks to the platform (read first)

This skill uses the **same transport** as `commotion-create-worker` — the helper scripts in this
plugin's `scripts/` directory, the same Kong api-key, and the same session credentials file. It's the
**one unified backend**: the scenario / simulation / eval endpoints live in the same OpenAPI spec as
`/aiworker` and `/aiagent`, so nothing about auth or schema-fetching changes. Resolve the scripts dir
once:

```bash
SCRIPTS="${CLAUDE_PLUGIN_ROOT:-/absolute/path/to/commotion-skills}/scripts"
```

> Do not use `${CLAUDE_PLUGIN_ROOT:?…}` — from a clone that variable is empty and would hard-fail.

### Step 0 — Make sure the API key is available (do this first)

`commotion_api.sh` authenticates with a Kong api-key read from the session credentials file
`${TMPDIR:-/tmp}/commotion-mcp/session.env`.

1. **If you already set the key this session** (e.g. you just ran `commotion-create-worker`), it's
   already in that file — reuse it. Confirm with the smoke test below.
2. **Otherwise** ask the user for their Commotion **Kong api-key** with `AskUserQuestion` (and, only
   if their workspace isn't the default `demo_workspace`, the route selector). Say it's used only for
   this session and isn't saved. Then write it (substituting the value; **never print the key**):
   ```bash
   mkdir -p "${TMPDIR:-/tmp}/commotion-mcp"
   ( umask 077; printf 'KONG_API_KEY=%s\n' '<the key the user provided>' \
       > "${TMPDIR:-/tmp}/commotion-mcp/session.env" )
   # only for a non-default workspace, also append:
   #   printf 'KONG_ROUTE_SELECTOR=%s\n' '<value>' >> "${TMPDIR:-/tmp}/commotion-mcp/session.env"
   ```
3. **Smoke-test the eval-domain route** (this is the new surface, so verify it specifically):
   `bash "$SCRIPTS/commotion_api.sh" GET /scenario/dropdown-config` should return the dropdown config.
   A 401/403 means the key is wrong — ask again; a 404/route error means the eval endpoints aren't on
   the same route (see `references/eval-domain-api.md`). Don't start Phase 0 until this passes.

- **Make a call** — `bash "$SCRIPTS/commotion_api.sh" <METHOD> <PATH> [BODY]` (inline JSON, `@file.json`,
  or `-` for stdin). On a non-2xx it prints the backend body and exits non-zero — surface that message.
- **Fetch a request schema** — `bash "$SCRIPTS/fetch_schema.sh" <SchemaName>` (cached once per session).
  **Never invent a field that isn't in the schema.**
- **Capture ids** from responses with `jq`.

The endpoint map, header contract, and schema-name list for the scenario/personality/eval domain are
in `references/eval-domain-api.md`. Field *shapes* always come from `fetch_schema.sh`; the reference
files are the *behavior* the schema doesn't tell you. Detailed scenario/personality recipes are in
`references/scenarios-and-personalities.md`.

**Execution rules:** one phase at a time, in order; read the reference named by a phase before acting;
show every write before you make it.

## Phase 0 — Ground yourself in the real schema (always, before drafting)

Never invent field names or values. Read the contracts from the server first:

1. `bash "$SCRIPTS/fetch_schema.sh" GenerateScenarioRequest` and `ScenarioRequest` and
   `PersonalityRequest` → the exact bodies (bundled with `$defs`).
2. `bash "$SCRIPTS/commotion_api.sh" GET /scenario/dropdown-config` → the **valid values** for
   `complexity`, `pathType`, `scenarioGenerationType`, `channelType` (each a `{code,label,isDefault}`)
   **plus `maxScenarioGenerationLimit` and `maxScenarioRunLimit`** — respect these limits.
3. `bash "$SCRIPTS/commotion_api.sh" GET /scenario/intent-values` → existing intent tags (typeahead).
4. `bash "$SCRIPTS/commotion_api.sh" GET /aimodel` → valid provider/model codes for the **simulator
   LLM** (`LLMConfig` on generate + run — the LLM that powers scenario generation and the simulated
   caller).

## Phase 1 — Identify the target worker + version  ·  HUMAN INPUT (only what's missing)

The whole test set is scoped to **one worker and one version**:

- **`aiWorkerId`** — usually carried over from create-worker; else ask or `GET /aiworker` (list).
- **`version`** — **which version are you testing?** In the quality loop you test the *draft* you're
  improving; for a one-off check of a deployed worker you test the live version. Default to the version
  the user is iterating on. (Scenarios are created with this `version` in the body.)
- **Channel** — voice or chat (`aiAgentChannelType`), inferred from the worker; only voice workers can
  run voice scenarios.
- Decide whether to test the **whole worker** or a **specific agent** (`aiAgentId` +
  `isTestSpecificAgent: true`) — useful for a multi-agent worker when you want to test one specialist.

**Version rule (important — verified shape):** list endpoints filter by `aiWorkerId`, **not** by
`version` (there is no `version` query param on `GET /scenario`). Each `ScenarioResponse` carries its
own `version`. So generate/create at the version under test, and when listing, **read each scenario's
`version` field** to know which version it belongs to. See `references/scenarios-and-personalities.md`.

## Phase 2 — Design the personalities (the simulated callers)

A scenario runs against a **personality** — the persona, mood, voice, and behaviour of the simulated
caller. Design the personas **this domain actually faces**, not a generic set: the cooperative caller,
the frustrated/angry caller, the impatient interrupter, the code-switching (e.g. Hinglish) caller, the
caller on a noisy line, the adversarial/jailbreak caller. Each persona is reusable across scenarios.

- **Reuse** what's there first: `GET /personality` (filter by `gender`/`mood`/`voiceEnabled`/`searchText`).
- **AI-draft the persona prompt**: `POST /personality/prompt/generate` `{description}` → returns
  `{generatedPrompt}`. Edit it, then create the persona.
- **Create**: `POST /personality` (`PersonalityRequest` — `name, gender` (MALE/FEMALE), `mood`
  (HAPPY/FRUSTRATED/…), `prompt`). **For voice simulations set `voiceEnabled:true`** + a voice
  (`voiceProvider/voiceModel/voiceId/languages`) — without it the sim has no caller audio. Reuse the
  worker's own voice (verified good: `commotion-tts` / `commotion-laya-v1-5` / voiceId
  `d6d81480-227c-41cd-af4e-f483262cef0b`, which covers en + hi and more). Realism dials:
  `speakingSpeed`, `interruptionLevel`, `backgroundNoise` (e.g. `NONE`), `packetLoss`. For a
  **bilingual / code-switching** persona set `languages:["en","hi"]` and describe the switch in the
  `prompt` (e.g. "open in English, then switch to Hindi").

Show the planned personas in plain language and **approve before each `POST`**. Capture each
`personalityId`.

## Phase 3 — Create the scenarios (cover the real paths, not just the greeting)

A **scenario** is one simulated conversation with a **goal** the worker must achieve to "pass". Build a
set that exercises the **branches and failure paths**: happy path, missing/invalid data, the caller
who won't cooperate, guardrail/jailbreak attempts, language switching, tool-failure handling. Three
ways to create them — pick per goal, usually (a) for breadth + (b) for the precise edge cases:

- **(a) AI-generate (breadth)** — `POST /scenario/generate` (`GenerateScenarioRequest`:
  `aiWorkerId, version, instructions, numScenarios, personalityIds, generationType, aiAgentChannelType,
  llm`). `instructions` steers the generator toward the use cases you care about. This is **async** and
  returns only `{scenarioGenerationId}`; **poll** `GET /scenario?scenarioGenerationId=<id>&aiWorkerId=<id>`
  until scenarios appear (there is **no generation-progress endpoint**). Keep `numScenarios` ≤
  `maxScenarioGenerationLimit`. **Verified caveat:** generation needs a **deployed (live)** worker —
  against a never-deployed draft it returns a generation id but produces **zero** scenarios (and no
  error). If it comes back empty, fall back to (b). `CHAT` channel is accepted by the API even though
  the UI marks auto-gen voice-only.
- **(b) Manual (precise edge cases)** — `POST /scenario` (`ScenarioRequest`: `name, aiWorkerId, version,
  intent, complexity, pathType, personalityId, situation, userScript, scenarioGoal, extraContext,
  aiAgentChannelType`). Use `complexity`/`pathType` codes from the dropdown-config. `userScript` is what
  the simulated caller says/shares; `scenarioGoal` is the pass criterion the evaluator checks.
- **(c) From a real call** — `POST /scenario/generate-from-conversation` (`conversationId, aiWorkerId,
  version, aiAgentChannelType`) turns a recorded interaction (e.g. a failure you saw in Observability)
  into a regression scenario. Review and complete the generated fields.

(Bulk CSV/Excel import also exists via `GET /scenario/import/csv|excel` → fill the file → `POST
/scenario/bulk` — see the reference; reserve it for large hand-authored sets.)

## Phase 4 — Review and write  ·  HUMAN INPUT REQUIRED

Summarize the planned test set in plain language — the personas, and a short table of scenarios (name,
path type, what it tests, its goal) — **not** a raw JSON dump. Get an explicit "yes", then create
(personalities first so scenarios can reference their `personalityId`). Show each write; surface any
backend error and check it against the references before retrying.

## Phase 5 — Confirm the test set

```bash
bash "$SCRIPTS/commotion_api.sh" GET "/scenario?aiWorkerId=$WORKER_ID"   # then read each .version
bash "$SCRIPTS/commotion_api.sh" GET "/personality"
```

Show the user the created scenarios (and their ids) for the version under test, and hand them to
`commotion-run-evals` (step 3) — that skill selects scenarios + runs-per-scenario and runs the
simulation. If the user wants to go straight to running, continue into the run-evals skill.

## Principles

- Ground before you draft; never invent a field that isn't in the schema (`fetch_schema.sh`).
- A test set is only as good as its **coverage** — design personas + scenarios from the domain's real
  happy/failure/jailbreak paths, not a template. The `scenarioGoal` is the pass criterion, so make it
  concrete and checkable.
- Everything is scoped to `(aiWorkerId, version)` — create at the version under test; `version` is in
  each response, not a list filter.
- AI generation is **async** — poll `GET /scenario?scenarioGenerationId=` until the scenarios appear;
  respect `maxScenarioGenerationLimit` / `maxScenarioRunLimit` from the dropdown-config.
- Show every write before you make it (personalities before scenarios that reference them).
- If a platform call errors, the helper surfaces the backend's status + message — read it and check it
  against the references before retrying.
