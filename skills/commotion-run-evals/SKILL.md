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
  (commotion-generate-scenarios). Calls the dev3 backend directly over HTTP (no MCP server).
allowed-tools: Bash, Read, AskUserQuestion
---

# Commotion: Run Evals (Simulate + Score)

Run a worker's scenarios as a **simulation** and get back the **eval score** — the pass-rate (the
percentage, 0–100, of scenarios whose goal the worker achieved), plus a per-scenario breakdown with the reason each
failure failed. Optionally define **eval metrics** (Hallucination, CSAT, latency, custom domain rules)
for richer signal. You make the platform I/O yourself with plain HTTP calls to the dev3 backend; there
is **no MCP server**. **Every write (metrics, the run) is shown to the user and approved first.**

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

**Same transport as `commotion-create-worker`** — same helper scripts, same Kong api-key, same session
credentials file. It's one unified backend (scenario/simulation/eval endpoints share the spec with
`/aiworker`). Resolve the scripts dir once:

```bash
SCRIPTS="${CLAUDE_PLUGIN_ROOT:-/absolute/path/to/commotion-skills}/scripts"
```

> Do not use `${CLAUDE_PLUGIN_ROOT:?…}` — empty from a clone, would hard-fail.

### Step 0 — Make sure the API key is available (do this first)

`commotion_api.sh` reads the Kong api-key from `${TMPDIR:-/tmp}/commotion-mcp/session.env`.

1. **Already set this session** (e.g. from a prior skill)? Reuse it — just run the smoke test.
2. **Otherwise** ask the user for the Kong api-key with `AskUserQuestion` (+ route selector only if not
   `demo_workspace`), say it's session-only and unsaved, then write it (**never print the key**):
   ```bash
   mkdir -p "${TMPDIR:-/tmp}/commotion-mcp"
   ( umask 077; printf 'KONG_API_KEY=%s\n' '<the key the user provided>' \
       > "${TMPDIR:-/tmp}/commotion-mcp/session.env" )
   ```
3. **Smoke-test the eval-domain route:** `bash "$SCRIPTS/commotion_api.sh" GET /scenario/dropdown-config`
   should return 2xx (no worker id needed — `WORKER_ID` is established in Phase 0). A 401/403 = wrong
   key; a route error = see `references/eval-domain-api.md`. Don't start Phase 0 until this passes.

- **Call** — `bash "$SCRIPTS/commotion_api.sh" <METHOD> <PATH> [BODY]`. **Fetch a schema** —
  `bash "$SCRIPTS/fetch_schema.sh" <SchemaName>`. **Never invent a field that isn't in the schema.**

The endpoint map is in `commotion-generate-scenarios/references/eval-domain-api.md` (the canonical
map). Eval-metric design is in `references/eval-metrics.md`; the run lifecycle + how to read scores is
in `references/simulation-and-results.md`.

**Execution rules:** one phase at a time; read the reference a phase names before acting; show every
write before making it; **never start a run while another is active** (Phase 2).

## Phase 0 — Establish the target, then ground in the real schema

First fix what you're testing: the **worker id + version** to evaluate (`WORKER_ID` — in the loop, the
**draft** under improvement) and the **scenario ids** to run (from `commotion-generate-scenarios` —
`GET /scenario?aiWorkerId=$WORKER_ID`, reading each record's `version`). Then ground in the schema:

1. `bash "$SCRIPTS/fetch_schema.sh" RunScenariosRequest` and `EvalMetricRequest`.
2. `bash "$SCRIPTS/commotion_api.sh" GET "/eval-metric?aiWorkerId=$WORKER_ID"` → metrics already on the
   worker (don't re-create duplicates).
3. `bash "$SCRIPTS/commotion_api.sh" GET /scenario/dropdown-config` → `maxScenarioRunLimit` (cap on
   runs-per-scenario × scenarios) — respect it.
4. `bash "$SCRIPTS/commotion_api.sh" GET /aimodel` → provider/model codes for the **simulator LLM**.

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

1. **Check nothing is already running** — `GET /scenario-run/active?aiWorkerId=$WORKER_ID` → if `true`,
   wait (the platform runs simulations **sequentially**; starting a second is blocked).
2. **Choose scenarios + runs-per-scenario.** `RunScenariosRequest.scenarioIdToRunPerScenarioMap` maps
   each `scenarioId` → how many times to run it (run a scenario several times to test consistency).
   Keep total runs within `maxScenarioRunLimit`.
3. **Confirm and run** — show the user which scenarios, how many runs each, and the simulator `llm`;
   on yes:
   ```bash
   bash "$SCRIPTS/commotion_api.sh" POST /simulation/run @run.json | tee /tmp/sim.json
   SIM_ID=$(jq -r '.id' /tmp/sim.json)
   ```
   Body: `{aiWorkerId, version, scenarioIdToRunPerScenarioMap:{<scenarioId>:<nRuns>,…}, maxDuration,
   maxTurns, llm:{provider,model}}`. **Run against the version under test** (the draft, in the loop).

## Phase 3 — Poll to completion and read the score

```bash
bash "$SCRIPTS/commotion_api.sh" GET "/simulation/$SIM_ID"
# poll until the run is genuinely terminal, THEN read the headline numbers:
#   passRate, passCount / totalScenarios, avgQuality, avgLatency(InMillis), completedScenarios
```

**Wait for evaluation to finish before reading `passRate` as final.** Each scenario-run passes through
EVALUATION_* states *after* its conversation completes, and `passRate` isn't final until every run is
evaluated — so don't stop the moment the simulation looks done: confirm `completedScenarios ==
totalScenarios` and no runs are still in an EVALUATION_* state (`GET /scenario-run?simulationId=$SIM_ID`)
before trusting the number. (`SimulationResponse.status` is an unconstrained string — read
`statusLabel` and the counts rather than matching a hard-coded token; confirm the live terminal label.)
See `references/simulation-and-results.md` for the full status progression.

`SimulationResponse.passRate` **is the eval score — a percentage 0–100** (verified live; an all-pass
run returns `100.0`). Report it with the raw count (e.g. "6 of 10 passed = 60%") plus `avgQuality` and
`avgLatency`. (Note: `avgQuality` is often `null` unless custom eval-metrics are defined — the
scenario-goal PASS/FAIL is the signal that drives `passRate`.) A simulation runs scenarios
sequentially — expect it to take a while (voice sims run real audio); poll at a sensible interval.

## Phase 4 — Per-scenario breakdown (the diagnosis fuel)

```bash
bash "$SCRIPTS/commotion_api.sh" GET "/scenario-run?simulationId=$SIM_ID"
```

Each `ScenarioRunResponse` gives `status`, `quality`, `scenarioEvaluationResult` (pass/fail), and —
for failures — `failureReason` + `evaluationReasoning`. Present a table: scenario name · pass/fail ·
why-it-failed. **This is exactly what `commotion-improve-worker` consumes** to decide what to fix.

If you defined metrics (Phase 1) and want their per-call scores (or to populate the Evals dashboard),
note metric evaluation is **async** (verified live): the sim's calls come back as eval-results in
`status: PENDING` with no scores until the evaluator runs. To read/force them:
`GET /eval-result/session/{sessionId}` where **`sessionId` == the scenario-run `id`** → if PENDING,
`POST /eval-result/trigger?voiceCallId=<voiceInteractionId>` (use the result's `voiceInteractionId`,
NOT `voiceCallMongoId`). `results[]` (`EvalMetricResultEntry`) gives `metricName`, `evaluation`,
`thresholdMet`. The pass-rate gate doesn't need this — it's for metric detail / the Evals dashboard.
Full plumbing in `references/simulation-and-results.md`.

## Phase 5 — Verdict + handoff

State the **pass-rate vs the user's target** (ask the target if they haven't said one — a common bar is
80, since `passRate` is a 0–100 percentage). If it clears the bar, you're done — the worker meets the quality goal at this version. If it's
below, summarize the failing scenarios and their reasons and hand off to `commotion-improve-worker`
(step 4), which diagnoses, edits a draft, and re-runs this skill until the bar is met. Keep the
`SIM_ID` and the failing-scenario analysis — they're the loop's state.

## Principles

- **The eval score is `SimulationResponse.passRate`** — report it with the raw count and the
  per-scenario reasons, not just a number.
- Scenario-goal evaluation is automatic; eval-metrics are optional, secondary signal — don't block the
  run on them.
- **Sequential runs** — always check `GET /scenario-run/active` before starting; respect
  `maxScenarioRunLimit`.
- Run against the **version under test** (the draft in the loop); everything is `(aiWorkerId, version)`
  scoped and `version` is on each record, not a list filter.
- Show every write (metric, run) before making it; surface backend errors and check the references.
