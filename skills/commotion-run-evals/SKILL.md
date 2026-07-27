---
name: commotion-run-evals
description: >-
  Run a Commotion worker against its test scenarios as an automated simulation and report the
  eval score — define eval metrics (optional), launch the simulation for a worker/version, poll it to
  completion, and read the pass-rate plus a per-scenario pass/fail breakdown with failure reasons. Use
  this whenever the user wants to run evals, run a simulation, test a worker against scenarios, get a
  pass-rate / eval score, or "see how the worker does" — e.g. "run my scenarios and tell me the pass
  rate", "evaluate the renewal bot". This is step 3 of the quality loop (create-worker →
  generate-scenarios → **run-evals** → improve-worker). Needs scenarios to exist first
  (commotion-generate-scenarios). Calls the dev3 backend through the thin Commotion MCP server
  (OAuth — no API key in the transcript).
allowed-tools: Read, AskUserQuestion, mcp__commotion__commotion_request, mcp__commotion__commotion_schema
---

# Commotion: Run Evals (Simulate + Score)

Run a worker's scenarios as a **simulation** and get back the **eval score** — the pass-rate (the
percentage, 0–100, of scenarios whose goal the worker achieved), plus a per-scenario breakdown with the reason each
failure failed. Optionally define **eval metrics** (Hallucination, CSAT, latency, custom domain rules)
for richer signal. You make the platform I/O through the connected **Commotion MCP** server's two tools
(`commotion_request` / `commotion_schema`). **Every write (metrics, the run) is shown to the user and approved first.**

**Auth is automatic (browser login).** The Commotion MCP handles auth via OAuth: on first use it
opens a Commotion login in the browser, then attaches the user's token to every `commotion_request` /
`commotion_schema` call for you — the token never enters the conversation. Never ask the user for an
email/password or a token, and don't pass a `token` argument. If the two tools aren't available at
all, the MCP isn't connected — ask the user to add/authorize it via `/mcp`.

This is **step 3 of the worker quality loop**:

```
create-worker → generate-scenarios → [run-evals] → improve-worker
                                         └──────── repeat until pass-rate ≥ threshold ────────┘
```

Its inputs are the scenarios from `commotion-generate-scenarios` (step 2); its output — the pass-rate
and the failing-scenario analysis — feeds `commotion-improve-worker` (step 4), which uses it to decide
whether to keep iterating. The headline **eval score is `SimulationResponse.passRate`** — a
**percentage (0–100)**, not a 0–1 fraction (verified live: an all-pass run returns `100.0`).

## Prerequisites (verified live — evals are voice-only + need a live runtime)

Two hard constraints, both confirmed against dev3:

1. **Simulations/evals only work for VOICE workers.** Running scenarios against a **chat** worker
   fails every run with a generic *"An error has occurred during simulation. Please contact support…"*
   (quality/latency null, `passRate` 0). If the target isn't voice-enabled, it cannot be evaluated
   this way — make it a voice worker first (see `commotion-create-worker`; voice can be enabled on a
   draft). The simulated caller **personalities must also be voice-enabled** (`voiceEnabled:true` + a
   voice) or the sim has no caller audio.
2. **The worker version must have a running runtime — i.e. the worker must have been deployed at
   least once.** A worker that was **never deployed** returns *"Worker is not available for worker
   Id: …"* (from `/aiworker/run`) and its sims/AI-generation fail. Once the worker has a live version,
   a **draft version of it CAN be simulated** (verified: draft v1 simulated while v0 was live) — which
   is what makes the draft-only improve loop work. So: deploy once, then iterate+simulate on drafts.

## When to use this

The user wants to actually run the test set and get a score, or asks to "simulate" / "evaluate" /
"test" a worker. Scenarios must already exist for the worker (run `commotion-generate-scenarios`
first). To then improve the worker until it clears a threshold, that's `commotion-improve-worker`.
**For the whole build → test → improve pipeline in one request, use the `commotion-quality-loop`
orchestrator** (it invokes this skill as its eval step).

## How this skill talks to the platform (read first)

All platform I/O goes through the connected **Commotion MCP** server — two tools, no scripts, no keys.
It's one unified backend (scenario/simulation/eval endpoints share the spec with `/aiworker`), so this
is the **same transport as `commotion-create-worker`**:

- **`commotion_request`** — one authenticated call: `{ "method": "GET|POST|PUT|DELETE", "path": "/…",
  "body": <JSON, for writes> }` → `{ "status", "body" }` (a non-2xx is **returned, not thrown** —
  read it and adjust). Pass a **path** (the base URL is fixed server-side) and the request payload as
  `body` — no temp files.
- **`commotion_schema`** — a bundled request schema: `{ "schema_name": "RunScenariosRequest" }` → the
  JSON Schema with its `$defs`. Any component name in the live spec works. **Never invent a field that
  isn't in the schema.**

**Auth is automatic — there is no key.** The MCP client owns OAuth: the first time the
Commotion MCP is used it opens a Commotion login in the browser, then attaches the user's token to
every call. Never ask the user for a token. If the two tools aren't available, the Commotion MCP
isn't connected — ask the user to add/authorize it (in Claude Code: `/mcp` → **commotion** →
Authenticate), then continue.

**Read ids from results, not `jq`:** `commotion_request` returns the parsed `body` — after `POST
/simulation/run` the run id is `body.id`; from a list it's `body[0].id`. Feed that id into the next
call's `path`.

The endpoint map is in `commotion-generate-scenarios/references/eval-domain-api.md` (the canonical
map). Eval-metric design is in `references/eval-metrics.md`; the run lifecycle + how to read scores is
in `references/simulation-and-results.md`.

**Execution rules:** one phase at a time; read the reference a phase names before acting; show every
write before making it; **never start a run while another is active** (Phase 2).

## Phase 0 — Establish the target, then ground in the real schema

First fix what you're testing: the **worker id + version** to evaluate (`<worker-id>` — in the loop,
the **draft** under improvement) and the **scenario ids** to run (from `commotion-generate-scenarios`
— `commotion_request` `{ "method": "GET", "path": "/scenario?aiWorkerId=<worker-id>" }`, reading each
record's `version` from `body`). Then ground in the schema:

1. `commotion_schema` `{ "schema_name": "RunScenariosRequest" }` and `{ "schema_name": "EvalMetricRequest" }`.
2. `commotion_request` `{ "method": "GET", "path": "/eval-metric?aiWorkerId=<worker-id>" }` → metrics
   already on the worker (don't re-create duplicates).
3. `commotion_request` `{ "method": "GET", "path": "/scenario/dropdown-config" }` → `maxScenarioRunLimit`
   (cap on runs-per-scenario × scenarios) — respect it.
4. `commotion_request` `{ "method": "GET", "path": "/aimodel" }` → provider/model codes for the **simulator LLM**.

## Two evaluation surfaces (read before Phase 1 — verified live)

The platform has **two separate things** both loosely called "evals," and they populate different UI
tabs. Don't conflate them:

1. **Simulation scenario pass/fail** — from `POST /simulation/run` → `SimulationResponse.passRate` +
   per-scenario `scenarioEvaluationResult` (PASS/FAIL against each scenario's **goal**). Shown under
   **Simulations → Runs**. **This is the loop's gate** and needs no metrics.
2. **The Evals dashboard** (Evals → Overview/Metrics/Alerts: *Total calls evaluated, Metrics Evaluated,
   Pass Rate, quality*) — driven by **eval-metrics** (`/eval-metric` + `/eval-result`). It stays **empty
   (0 / No Data)** until you (a) create eval-metrics with `simulation:true` and (b) run a simulation so
   they score the calls. `SimulationResponse.avgQuality` is also `null` until metrics exist.

So: scenario pass-rate ≠ Evals-dashboard data. If the user asks "why is the Evals dashboard empty?",
the answer is almost always "no eval-metrics defined." Phase 1 fills it.

## Phase 1 — Define eval metrics (optional for the pass-rate gate; REQUIRED to populate the Evals dashboard)

Skip if the user only wants the scenario pass-rate. Do this when they want metric-level quality
(Hallucination, CSAT, tone, compliance) or the Evals dashboard populated. Design from the use case.

You can create **both standard (predefined) and custom** metrics — but the two bodies differ sharply,
and standard has a trap (verified live):

- **Standard / predefined → POST a minimal shell, then PUT to hydrate.** A standard metric can't be
  created hydrated in one call: a full-body POST 500s (poison field: `name`), and a minimal POST
  (`{standardEvalMetricId, aiWorkerId, version, simulation, observability}`) returns 200 but a **hollow
  shell** (blank name/type — which can also break the eval pass). So POST the shell, then
  `PUT /eval-metric/{id}` the full definition (mirrored from the catalog) **dropping any empty-string
  field — especially `evaluationMethod: ""`** (empty `evaluationMethod` 500s the PUT; CORE_PLATFORM
  metrics like CSAT/Sentiment have it empty, so omit it). Fetch the catalog + valid ids with
  `GET /eval-metric?metricSourceType=STANDARD` (hallucination, relevancy, response_consistency,
  csat_score, sentiment, appropriate_call_termination, latency, tool_call_success_rate,
  conversation_progression, …). Include NUMERIC/RATING ones (hallucination, csat_score, relevancy) for
  richer quality signal. Full recipe in `references/eval-metrics.md`.
- **Custom → FULL body.** For domain rules the catalog doesn't cover, supply everything:
  ```jsonc
  { "name":"No Professional Advice", "metricSourceType":"CUSTOM", "outputType":"BOOLEAN",
    "thresholdCondition":"EQ", "thresholdValue":"true", "enumValues":[],
    "evaluationCriteria":"Pass if the agent never gives legal/financial/medical/tax advice…",
    "evaluatorType":"AI_PLATFORM", "evaluationMethod":"LLM_JUDGE", "category":"Compliance",
    "simulation":true, "observability":true, "aiWorkerId":"<id>", "version":<LIVE> }
  ```

Shared rules (verified): `version` must be the worker's **LIVE** version (a never-deployed draft
version and `null` both 500 — deploy first, create metrics at the live version); `simulation:true`
scores simulated calls (`observability:true` for live). `outputType` ∈ BOOLEAN/NUMERIC/RATING/ENUM;
`thresholdCondition` ∈ EQ/LTE/GTE; `thresholdValue` is a **string** ("true"/"10"/"70"). The list body
can contain raw newlines (parse tolerantly). Show each before writing. Full detail + catalog in
`references/eval-metrics.md`.

> The loop's **gate is the scenario pass-rate** (surface 1). Metrics (surface 2) add quality signal +
> the dashboard; they are not required for the pass-rate gate.

## Phase 2 — Select scenarios and run the simulation  ·  HUMAN INPUT REQUIRED

1. **Check nothing is already running** — `commotion_request` `{ "method": "GET", "path":
   "/scenario-run/active?aiWorkerId=<worker-id>" }` → if `body` is `true`, wait (the platform runs
   simulations **sequentially**; starting a second is blocked).
2. **Choose scenarios + runs-per-scenario.** `RunScenariosRequest.scenarioIdToRunPerScenarioMap` maps
   each `scenarioId` → how many times to run it (run a scenario several times to test consistency).
   Keep total runs within `maxScenarioRunLimit`.
3. **⚠ Cap each simulation at 4 total scenario-runs, and batch anything larger (verified operationally).**
   A single `/simulation/run` runs its scenario-runs concurrently over websockets; more than **4** at
   once exhausts the websocket connections and runs start **failing with websocket connection errors**
   (they come back `COMPLETED`-instantly with `passRate 0.0`/`avgLatency null` — the failure signature).
   So keep **`sum(scenarioIdToRunPerScenarioMap.values()) ≤ 4` per simulation**. If the user picked more
   scenarios/runs than that, **split into sequential batches of ≤4**: run one batch, poll it to
   completion (Phase 3), then start the next (each batch is a fresh `/simulation/run` — check
   `/scenario-run/active` is clear first), and aggregate the pass-rates across batches at the end.
4. **Confirm and run** — show the user which scenarios, how many runs each (and, if batching, the batch
   plan), and the simulator `llm`; on yes, call `commotion_request` `{ "method": "POST", "path":
   "/simulation/run", "body": {aiWorkerId, version, scenarioIdToRunPerScenarioMap:{<scenarioId>:<nRuns>,…}
   (≤4 total), maxDuration, maxTurns, llm:{provider,model}} }` and read the run id from the result:
   **`<sim-id> = body.id`** (reused in every later call). **Run against the version under test** (the
   draft, in the loop).

## Phase 3 — Poll to completion and read the score

Repeatedly call `commotion_request` `{ "method": "GET", "path": "/simulation/<sim-id>" }` and read the
headline numbers from `body` — `passRate`, `passCount` / `totalScenarios`, `avgQuality`,
`avgLatency(InMillis)`, `completedScenarios` — until the run is genuinely terminal. A simulation runs
scenarios sequentially and voice sims run real audio, so expect several polls where it's still
in-progress; space them out rather than hammering the endpoint.

**Wait for evaluation to finish before reading `passRate` as final.** Each scenario-run passes through
EVALUATION_* states *after* its conversation completes, and `passRate` isn't final until every run is
evaluated — so don't stop the moment the simulation looks done: confirm `completedScenarios ==
totalScenarios` and no runs are still in an EVALUATION_* state (`commotion_request` `{ "method": "GET",
"path": "/scenario-run?simulationId=<sim-id>" }`, checking each record's `status` in `body`) before
trusting the number. (`SimulationResponse.status` is an unconstrained string — read `statusLabel` and
the counts rather than matching a hard-coded token; confirm the live terminal label.) See
`references/simulation-and-results.md` for the full status progression.

`SimulationResponse.passRate` **is the eval score — a percentage 0–100** (verified live; an all-pass
run returns `100.0`). Report it with the raw count (e.g. "6 of 10 passed = 60%") plus `avgQuality` and
`avgLatency`. (Note: `avgQuality` is often `null` unless custom eval-metrics are defined — the
scenario-goal PASS/FAIL is the signal that drives `passRate`.) A simulation runs scenarios
sequentially — expect it to take a while (voice sims run real audio); poll at a sensible interval.

## Phase 4 — Per-scenario breakdown (the diagnosis fuel)

Call `commotion_request` `{ "method": "GET", "path": "/scenario-run?simulationId=<sim-id>" }` and read
the per-scenario records from `body`. Each `ScenarioRunResponse` gives `status`, `quality`,
`scenarioEvaluationResult` (pass/fail), and — for failures — `failureReason` + `evaluationReasoning`.
Present a table: scenario name · pass/fail · why-it-failed. **This is exactly what
`commotion-improve-worker` consumes** to decide what to fix.

If you defined metrics (Phase 1) and want their per-call scores (or to populate the Evals dashboard),
note metric evaluation is **async** (verified live): the sim's calls come back as eval-results in
`status: PENDING` with no scores until the evaluator runs. To read/force them: `commotion_request` `{
"method": "GET", "path": "/eval-result/session/<session-id>" }` where **`<session-id>` == the
scenario-run `id`** → if `body` is PENDING, `commotion_request` `{ "method": "POST", "path":
"/eval-result/trigger?voiceCallId=<voiceInteractionId>" }` (use the result's `voiceInteractionId`,
NOT `voiceCallMongoId`). `results[]` (`EvalMetricResultEntry`) gives `metricName`, `evaluation`,
`thresholdMet`. The pass-rate gate doesn't need this — it's for metric detail / the Evals dashboard.
Full plumbing in `references/simulation-and-results.md`.

## Phase 5 — Verdict + handoff

State the **pass-rate vs the user's target** (ask the target if they haven't said one — a common bar is
80, since `passRate` is a 0–100 percentage). If it clears the bar, you're done — the worker meets the quality goal at this version. If it's
below, summarize the failing scenarios and their reasons and hand off to `commotion-improve-worker`
(step 4), which diagnoses, edits a draft, and re-runs this skill until the bar is met. Keep the
`<sim-id>` and the failing-scenario analysis — they're the loop's state.

## Principles

- **The eval score is `SimulationResponse.passRate`** — report it with the raw count and the
  per-scenario reasons, not just a number.
- Scenario-goal evaluation is automatic; eval-metrics are optional, secondary signal — don't block the
  run on them.
- **Sequential runs** — always check `GET /scenario-run/active` before starting; respect
  `maxScenarioRunLimit`.
- **Batch of 4** — never submit more than **4 total scenario-runs** in one `/simulation/run`; more
  overloads the websocket layer and runs fail with connection errors. For larger sets, run sequential
  batches of ≤4 and aggregate the pass-rates.
- Run against the **version under test** (the draft in the loop); everything is `(aiWorkerId, version)`
  scoped and `version` is on each record, not a list filter.
- Show every write (metric, run) before making it; surface backend errors and check the references.
