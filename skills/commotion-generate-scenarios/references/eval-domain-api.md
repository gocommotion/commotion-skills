# Eval-domain API & auth — scenarios, simulations, eval metrics, personalities

The "how to call it" reference for the **testing/evaluation** half of the Commotion backend
(scenarios, simulations, scenario-runs, eval-metrics, eval-results, personalities). This is the
**canonical endpoint map** for the quality-loop skills — `commotion-run-evals` and
`commotion-improve-worker` cross-link here. It is the companion to the worker-domain map in
`commotion-create-worker/references/api-and-auth.md`.

## One unified backend — same transport, no new scripts

The scenario/simulation/eval endpoints live in the **same OpenAPI spec and behind the same Kong
gateway** as `/aiworker` and `/aiagent`. So the quality-loop skills reuse the create-worker transport
**unchanged**:

```bash
SCRIPTS="${CLAUDE_PLUGIN_ROOT:-/absolute/path/to/commotion-skills}/scripts"
bash "$SCRIPTS/commotion_api.sh" <METHOD> <PATH> [BODY]      # one authenticated call
bash "$SCRIPTS/fetch_schema.sh"  <SchemaName> [--refresh]    # a bundled request schema (cached/session)
```

- Same Kong api-key (session file `${TMPDIR:-/tmp}/commotion-mcp/session.env`, written in Step 0), same
  headers (`apikey` = `KONG_API_KEY_HEADER`, `X-Route-Selector` = workspace, default `demo_workspace`),
  same base URL (`KONG_BACKEND_URL`, default `https://apigw.dev3.gocommotion.com`).
- **Smoke-test the eval route specifically** before relying on it: `GET /scenario/dropdown-config`
  (verified live: served over the **same** Kong gateway/route as the worker endpoints — no separate
  route selector needed). If it 404s while `/aiworker` works, surface that to the user.
- Swagger UI for humans: `https://api-tier0.dev3.gocommotion.com/swagger-ui/index.html`.

## Error semantics, untrusted ids, list shape

Same as the worker domain: non-2xx → helper prints the backend body and exits non-zero (surface it);
ids interpolated into a path must match `^[A-Za-z0-9_-]+$` (backend ids already do); list endpoints
return a bare JSON array (tolerate a `content`/`items`/`data`/`results` wrapper — parse with `jq`).

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
- **List bodies can contain raw newlines** (e.g. metric `evaluationCriteria`) — parse tolerantly
  (Python `json.loads(strict=False)`; `jq` fails).

## Endpoint map

Paths are relative to the base URL. "Schema" is the `fetch_schema.sh` name for the request body.

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

## Schema names for `fetch_schema.sh`

`ScenarioRequest`, `GenerateScenarioRequest`, `ConversationScenarioGenerateRequest`,
`BulkScenarioCreateRequest`, `PersonalityRequest`, `PersonalityPromptGenerateRequest`,
`RunScenariosRequest`, `SimulationUpdateRequest`, `EvalMetricRequest`, `EvalMetricAlertRequest`,
`LLMConfig`. Response shapes (not fetched, but real): `ScenarioGenerationResponse`,
`SimulationResponse`, `ScenarioRunResponse`, `EvalResultResponse`, `EvalMetricResultEntry`,
`ScenarioResponse`, `EvalMetricResponse`, `ScenarioDropdownConfigResponse`. (Any other component name
in `/v3/api-docs/public` works too.)
