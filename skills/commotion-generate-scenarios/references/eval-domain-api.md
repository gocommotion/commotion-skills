# Eval-domain API & transport — scenarios, simulations, eval metrics, personalities

The "how to call it" reference for the **testing/evaluation** half of the Commotion backend
(scenarios, simulations, scenario-runs, eval-metrics, eval-results, personalities). This is the
**canonical endpoint map** for the quality-loop skills — `commotion-run-evals` and
`commotion-improve-worker` cross-link here. It is the companion to the worker-domain map in
`commotion-create-worker/references/api-and-auth.md`.

## One unified backend — the two Commotion MCP tools

The scenario/simulation/eval endpoints live in the **same OpenAPI spec** as `/aiworker` and
`/aiagent`, reached through the **same connected Commotion MCP server** as create-worker — two tools,
no scripts, no keys:

- **`commotion_request`** — one authenticated call. Arguments:
  `{ "method": "GET|POST|PUT|DELETE", "path": "/…", "body": <JSON, for writes> }`. `path` starts
  with `/` and may carry a query string (e.g. `/scenario?aiWorkerId=ID`); the base URL is fixed
  server-side, so pass a **path, not a URL**. Returns `{ "status": <http status>, "body": <parsed
  JSON | text | null> }` — a non-2xx is **returned, not thrown**, so read the status and body and
  adjust. `body` is a tool argument, so there are no temp files for request payloads.
- **`commotion_schema`** — a bundled request schema. Arguments:
  `{ "schema_name": "GenerateScenarioRequest", "refresh": false }`. Returns the named OpenAPI
  component bundled self-contained with its `$defs` (refs rewritten to `#/$defs/…`). Any component
  name in the live spec works, not just those listed below; the spec is cached server-side after the
  first call. **Never invent a field that isn't in the schema.**

Read ids straight from a result — after `POST /scenario` the new id is `body.id`; from a list call
it's `body[0].id`; the async `POST /scenario/generate` returns `body.scenarioGenerationId`. Feed that
value into the next call's `path`. (No shell, no `jq` — you read the JSON the tool returns.)

## Auth — handled by the MCP connection (nothing to do per call)

Auth is **OAuth**, owned by the MCP client, not the skill — identical to create-worker (it's the same
MCP server and the same one unified backend). The first time the Commotion MCP is used, the client
opens a Commotion login in the browser, then stores the token and attaches it to every
`commotion_request` / `commotion_schema` call automatically. **There is no API key and no per-session
setup step — never ask the user for a token, and the raw token never enters the conversation.**

If the two tools aren't available, the Commotion MCP isn't connected/authorized — ask the user to add
and authorize it (in Claude Code: `/mcp` → **commotion** → Authenticate; a browser login opens once).
(Swagger UI for humans: `https://api-tier0.dev3.gocommotion.com/swagger-ui/index.html`.)

## Error semantics, untrusted ids, list shape

Same as the worker domain: `commotion_request` returns `{ "status", "body" }` for every call — a
non-2xx is **returned, not thrown**, with the backend body (surface it); ids interpolated into a path
must match `^[A-Za-z0-9_-]+$` (backend ids already do); list endpoints return a bare JSON array
(tolerate a `content`/`items`/`data`/`results` wrapper).

## Scoping rule (read this)

Scenarios, eval-metrics, and simulations are all scoped to **`(aiWorkerId, version)`** — the body
carries both. **But the list endpoints filter by `aiWorkerId` only — there is no `version` query
param.** Each response object carries its own `version`. So: create at the version under test, and
when listing, **read the `version` field on each record** to know which version it belongs to.
(Eval-metrics are effectively worker-scoped — they persist across deploys — and their `version` on
create must be the worker's **LIVE** version, else 500.)

## Verified-live constraints (dev3 — the ones that bite)

- **Evals/simulations are VOICE-ONLY.** A chat worker fails every sim run with a generic *"An error has
  occurred during simulation…"*. Make the worker voice-enabled first.
- **The worker must be deployed (live) at least once.** A never-deployed worker → sims fail
  (*"Worker is not available"*) and AI scenario-generation yields nothing. A **draft version of an
  already-live worker CAN be simulated** (this is what makes the draft-only improve loop work).
- **`passRate` is a percentage 0–100** (not a fraction). `SimulationResponse.avgQuality` stays `null`
  (not wired to eval-metrics).
- **`/aiworker/{id}/versions` returns `{"items":[…]}`** (not a bare array); a superseded version's
  status is **PAUSED**; `GET /aiworker/{id}` is LIVE-only.
- **Agent type is immutable** — change CHAT_AGENT↔VOICE_AGENT by delete + re-POST, not PUT.
- **Metric evaluation is async.** Sim/live calls create eval-results in `status: PENDING`; force
  scoring with `POST /eval-result/trigger?voiceCallId=<voiceInteractionId>` (use the
  **`voiceInteractionId`**, not `voiceCallMongoId`). A scenario-run's `id` **is** the call's
  `sessionId` for `GET /eval-result/session/{sessionId}`.
- **List bodies can contain raw newlines** (e.g. metric `evaluationCriteria`) — `commotion_request`
  hands back the parsed `body`, so just read those multi-line string fields as-is.

## Endpoint map

Paths are relative to the base URL. "Schema" is the `commotion_schema` name for the request body.

### Scenarios
| Method | Path | Purpose | Schema |
|--------|------|---------|--------|
| GET | `/scenario?aiWorkerId=&complexity=&pathType=&sourceType=&aiAgentChannelType=&intent=&personalityId=&scenarioGenerationId=&searchText=&pageNumber=&pageSize=` | list scenarios (filter; `version` is on each record) | — |
| GET | `/scenario/{scenarioId}` | one scenario | — |
| POST | `/scenario` | create one scenario | `ScenarioRequest` |
| PUT | `/scenario/{scenarioId}` | update a scenario | `ScenarioRequest` |
| DELETE | `/scenario/{scenarioId}` · `/scenario` (array body) | delete one / bulk | — |
| POST | `/scenario/generate` | **AI-generate (async)** → `{scenarioGenerationId}`, then poll `GET /scenario?scenarioGenerationId=` | `GenerateScenarioRequest` |
| POST | `/scenario/generate-from-conversation` | scenario from a recorded call | `ConversationScenarioGenerateRequest` |
| POST | `/scenario/bulk` | bulk-create from an uploaded file | `BulkScenarioCreateRequest` |
| GET | `/scenario/import/csv` · `/scenario/import/excel` | presigned import URL (template) | — |
| GET | `/scenario/dropdown-config` | valid `complexity`/`pathType`/`scenarioGenerationType`/`channelType` (`{code,label,isDefault}`) + `maxScenarioGenerationLimit` / `maxScenarioRunLimit` | — |
| GET | `/scenario/intent-values` | existing intent tags (typeahead) | — |

### Personalities (simulated callers)
| Method | Path | Purpose | Schema |
|--------|------|---------|--------|
| GET | `/personality?gender=&mood=&voiceProvider=&voiceEnabled=&searchText=&pageNumber=&pageSize=` | list personas | — |
| GET | `/personality/{personalityId}` | one persona | — |
| POST | `/personality` | create a persona | `PersonalityRequest` |
| PUT | `/personality/{personalityId}` | update a persona | `PersonalityRequest` |
| DELETE | `/personality/{personalityId}` · `/personality` (array body) | delete one / bulk | — |
| POST | `/personality/prompt/generate` | AI-draft a persona prompt → `{generatedPrompt}` | `PersonalityPromptGenerateRequest` |

### Simulations & scenario-runs
| Method | Path | Purpose | Schema |
|--------|------|---------|--------|
| POST | `/simulation/run` | **run scenarios** for a worker/version → `SimulationResponse` (`id, scenarioRunIds`) | `RunScenariosRequest` |
| GET | `/simulation/{simulationId}` | poll a simulation → `passRate, passCount, avgQuality, avgLatency, totalScenarios, completedScenarios, status` | — |
| GET | `/simulation?aiWorkerId=&status=&searchText=&pageNumber=&pageSize=` | list simulations | — |
| PUT | `/simulation/{simulationId}` | rename a simulation | `SimulationUpdateRequest` |
| DELETE | `/simulation/{simulationId}` · `/simulation` (array) | delete one / bulk | — |
| GET | `/scenario-run?simulationId=&scenarioId=&status=&pageNumber=&pageSize=` | per-scenario run records (the diagnosis fuel) | — |
| GET | `/scenario-run/{scenarioRunId}` | one run → `status, quality, scenarioEvaluationResult, failureReason, evaluationReasoning` | — |
| GET | `/scenario-run/active?aiWorkerId=` | is a run already in progress? (sequential — boolean) | — |
| GET | `/conversation/worker-conversations?workerId=&mode=SIMULATION` | a sim's calls; each `sessionId` == a scenario-run `id` (use to reach eval-results) | — |

### Eval metrics, alerts & results
| Method | Path | Purpose | Schema |
|--------|------|---------|--------|
| GET | `/eval-metric?aiWorkerId=&category=&metricSourceType=&pageNumber=&pageSize=` | list a worker's metrics; **`?metricSourceType=STANDARD`** (no worker id) fetches the predefined-metric catalog | — |
| GET | `/eval-metric/{evalMetricId}` | one metric | — |
| POST | `/eval-metric` | create a metric (scoped to `aiWorkerId`+`version`) | `EvalMetricRequest` |
| PUT | `/eval-metric/{evalMetricId}` | update a metric | `EvalMetricRequest` |
| DELETE | `/eval-metric/{evalMetricId}` · `/eval-metric` (array) | delete one / bulk | — |
| GET / POST / PUT / DELETE | `/eval-metric-alert[/{id}]` | metric breach alerts | `EvalMetricAlertRequest` |
| POST | `/eval-result/trigger?voiceCallId=` | force (async) metric evaluation for a call — pass the **`voiceInteractionId`** (e.g. `call_9dc8…`), NOT `voiceCallMongoId` (500s) | — |
| GET | `/eval-result/{id}` · `/eval-result/call/{callId}` · `/eval-result/session/{sessionId}` | read eval results → `results[]` of `EvalMetricResultEntry` (`thresholdMet`, reasoning) | — |
| GET | `/eval-result?aiWorkerId=&sessionId=&voiceInteractionId=&status=&metricName=&channelType=&pageNumber=&pageSize=&sortBy=&sortDirection=` | list/filter eval-results across a worker | — |
| GET | `/eval-result/count?aiWorkerId=&status=&metricName=&…` | count eval-results matching a filter (dashboard totals) | — |

### Eval insight groups & scheduling (grouped analysis; new)
| Method | Path | Purpose | Schema |
|--------|------|---------|--------|
| GET | `/eval-insight-group?aiWorkerId=&type=&simulationId=&sourceMetricId=&pageNumber=&pageSize=&sortBy=&sortDirection=` | list grouped eval insights (failure-mode / deep-research style analysis over a set of calls) | — |
| GET | `/eval-insight-group/{evalInsightGroupId}` | one insight group | — |
| POST | `/eval-insight-group` | create an insight group (`name, type, aiWorkerId, version, callIds, dynamic, filter, llm, firstCallDate, lastCallDate`) | `EvalInsightGroupRequest` |
| PUT | `/eval-insight-group/{evalInsightGroupId}` | update a group | `EvalInsightGroupRequest` |
| POST | `/eval-insight-group/{evalInsightGroupId}/refresh` | recompute the group's insights | — |
| DELETE | `/eval-insight-group?ids=` | bulk delete | — |
| POST | `/schedule` | schedule a delayed webhook callback (`webhookUrl, delay, delayUnit, payload`) — generic scheduler, e.g. deferred eval/run triggers | `ScheduleConfigInput` |

These are **secondary/analysis** surfaces — the loop's gate is still the scenario `passRate` (below).
Insight groups summarise *why* a batch of calls failed a metric; `/schedule` fires a webhook after a
delay. Neither is needed for a basic run-and-score. Ground shapes with `commotion_schema`
(`EvalInsightGroupRequest`, `ScheduleConfigInput`) before writing.

## Schema names for `commotion_schema`

`ScenarioRequest`, `GenerateScenarioRequest`, `ConversationScenarioGenerateRequest`,
`BulkScenarioCreateRequest`, `PersonalityRequest`, `PersonalityPromptGenerateRequest`,
`RunScenariosRequest`, `SimulationUpdateRequest`, `EvalMetricRequest`, `EvalMetricAlertRequest`,
`EvalInsightGroupRequest`, `ScheduleConfigInput`, `LLMConfig`. Response shapes (not fetched, but real): `ScenarioGenerationResponse`,
`SimulationResponse`, `ScenarioRunResponse`, `EvalResultResponse`, `EvalMetricResultEntry`,
`ScenarioResponse`, `EvalMetricResponse`, `ScenarioDropdownConfigResponse`. (Any other component name
in `/v3/api-docs/public` works too.)
