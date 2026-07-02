# Simulations & results — running scenarios and reading the score

How a simulation runs and how to read results (`/simulation`, `/scenario-run`, `/eval-result`). Field
*shapes* come from `fetch_schema.sh`; this file is the verified-live behaviour (dev3).

## Hard prerequisites (verified live)

- **Simulations only work for VOICE workers.** A chat worker fails every run with a generic *"An error
  has occurred during simulation. Please contact support with reference number …"* (quality/latency
  null, `passRate` 0). Personalities must be `voiceEnabled:true` with a voice.
- **The worker must have a live runtime** (deployed at least once). A never-deployed worker →
  `/aiworker/run` returns *"Worker is not available for worker Id: …"* and sims fail. **A draft version
  of an already-live worker CAN be simulated** (verified: draft v1 ran while v0 was live) — this is
  what makes the draft-only improve loop work.

## `RunScenariosRequest` (POST `/simulation/run`)

| Field | Notes |
|---|---|
| `aiWorkerId`, `version` | worker + **version under test** (a draft of a deployed worker is fine) |
| `scenarioIdToRunPerScenarioMap` | `{scenarioId: nRuns}` — run a scenario N times for consistency. Total ≤ `maxScenarioRunLimit` (20) |
| `maxDuration` | per-scenario cap in seconds (voice) — e.g. 300 |
| `maxTurns` | per-scenario cap on turns — e.g. 20 |
| `llm` | simulator LLM (`{provider,model}`) — codes from `/aimodel`. **Optional**; omit to use the platform default simulator |

Returns `SimulationResponse` with `id` (`SIM_ID`) and `scenarioRunIds`. **One sim at a time** — check
`GET /scenario-run/active?aiWorkerId=` first (starting a second while one is active is blocked).

## Poll → the score

```bash
bash "$SCRIPTS/commotion_api.sh" GET "/simulation/$SIM_ID"
```
| Field | Meaning |
|---|---|
| `status` / `statusLabel` | PENDING → COMPLETED (unconstrained string — gate on the counts, not a hard token) |
| `passRate` | **the eval score — a percentage 0–100** (all-pass = `100.0`) |
| `passCount` / `totalScenarios` / `completedScenarios` | the raw counts |
| `avgLatencyInMillis` | avg agent latency (~650–740ms in tests) — populates on success |
| `avgQuality` | **stays `null`** — NOT wired to eval-metrics; ignore it as a quality signal |

**Failure signature (verified):** a run that reaches `COMPLETED` almost instantly with
`avgLatencyInMillis: null` and `passRate 0.0` did **not** actually run — the scenario-runs FAILED. A
genuine voice run takes minutes (several PENDING polls). The `/simulation/run` path is also
**occasionally flaky** (same generic error) — retry a transient failure once.

## Per-scenario breakdown (the diagnosis fuel)

```bash
bash "$SCRIPTS/commotion_api.sh" GET "/scenario-run?simulationId=$SIM_ID"
```
`ScenarioRunResponse`: `status` (QUEUED→RUNNING→COMPLETED→EVALUATION_*→FAILED), `scenarioEvaluationResult`
(PASS/FAIL), `quality`, `evaluationReasoning` (**the richest field — the evaluator's turn-by-turn
justification; this is what improve-worker reads**), `failureReason` (backend error text when a run
failed). It does **not** expose a `sessionId`/`callId` field — **but the scenario-run `id` IS the
call's `sessionId`** (verified: run id == the SIMULATION conversation's sessionId), which is how you
reach the eval-metric results below.

## Eval-metric scores per call — the async plumbing (verified live)

Metric results are separate from scenario pass/fail and are populated **asynchronously**:

1. Find the sim's calls: `GET /conversation/worker-conversations?workerId=&mode=SIMULATION` →
   each `sessionId` (== a scenario-run id).
2. `GET /eval-result/session/{sessionId}` → an `EvalResultResponse`. Fresh sims come back
   **`status: PENDING` with `results: []`** — the async evaluator hasn't scored yet.
3. Force scoring: `POST /eval-result/trigger?voiceCallId=<voiceInteractionId>` — use the
   **`voiceInteractionId`** (e.g. `call_9dc8…`) from the eval-result, **not** `voiceCallMongoId`
   (500s). CORE_PLATFORM metrics (CSAT/Sentiment) score within seconds; LLM_JUDGE metrics lag.
4. Re-read: `results[]` (`EvalMetricResultEntry`) → `metricName`, `evaluation` (score/value),
   `thresholdMet`. (Verified: an irate-caller call scored `CSAT 44.9 (fail)`, `Sentiment NEGATIVE
   (fail)`.)

The pass-rate gate does **not** need any of this — use it only for metric-level detail / to populate
the Evals dashboard.

## List / manage

`GET /simulation?aiWorkerId=` lists sims; `PUT /simulation/{id}` renames; `DELETE /simulation/{id}`
(or bulk `DELETE /simulation` with an id array) removes. `/aiworker/{id}/versions` returns
`{"items":[…]}` (not a bare array); a superseded version's status is **PAUSED**.
