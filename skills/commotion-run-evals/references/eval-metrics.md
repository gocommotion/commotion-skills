# Eval metrics — design, the create recipes, and the async-eval mechanism

How to define and populate the quality metrics behind the **Evals dashboard** (`/eval-metric` +
`/eval-result`). Field *shapes* come from `commotion_schema` `{ "schema_name": "EvalMetricRequest" }`;
this file is the behaviour + the **verified-live recipes** (dev3, this repo's live test). Running
scenarios is in `simulation-and-results.md`.

## Two evaluation surfaces — don't conflate them (verified live)

- **Simulation scenario pass/fail** → `SimulationResponse.passRate` + per-scenario
  `scenarioEvaluationResult`. Shown under **Simulations → Runs**. Needs **no metrics**. This is the
  loop's gate.
- **The Evals dashboard** (Evals → Overview/Metrics: *Total calls evaluated, Metrics Evaluated, Pass
  Rate, quality*) → driven by **eval-metrics** scoring calls. Empty until metrics exist **and** their
  evaluation runs (async — see below). `SimulationResponse.avgQuality` is **not** the dashboard's
  source and stays `null` even with metrics.

## The two create recipes (verified live — this is the sharp part)

### Custom metric → FULL body
```jsonc
{ "name":"No Professional Advice", "metricSourceType":"CUSTOM",
  "outputType":"BOOLEAN", "thresholdCondition":"EQ", "thresholdValue":"true", "enumValues":[],
  "evaluationCriteria":"Pass if the agent never gives legal/financial/medical/tax advice…",
  "evaluatorType":"AI_PLATFORM", "evaluationMethod":"LLM_JUDGE", "category":"Compliance",
  "simulation":true, "observability":true, "aiWorkerId":"<id>", "version":<LIVE> }
```
`POST /eval-metric`. Custom metrics create cleanly and render hydrated. Use for domain rules the
standard catalog doesn't cover.

### Standard / predefined metric → POST shell, then PUT to hydrate
A standard metric **cannot** be created hydrated in one call:
- `POST` with the full standard body → **500** (the poison field is `name`).
- `POST` with only `{standardEvalMetricId, aiWorkerId, version, simulation, observability}` → **200 but a
  hollow shell** (blank name/type/thresholds — renders as an empty row and can **break the eval pass**).

The working recipe is **POST the minimal shell, then `PUT /eval-metric/{id}` the full definition**
(mirrored from the catalog), **dropping any empty-string field — especially `evaluationMethod: ""`**
(an empty `evaluationMethod` in the PUT 500s; CORE_PLATFORM metrics like CSAT/Sentiment have it empty,
so omit it):
```
# 1) shell
POST /eval-metric  { "standardEvalMetricId":"csat_score","aiWorkerId":"<id>","version":<LIVE>,"simulation":true,"observability":true }
# 2) hydrate — mirror the catalog record, drop empty-string keys
PUT  /eval-metric/{id}  { name, metricSourceType:"STANDARD", outputType, thresholdCondition, thresholdValue,
                          enumValues, evaluationCriteria, evaluatorType, /* omit evaluationMethod if "" */,
                          category, standardEvalMetricId, simulation:true, observability:true, aiWorkerId, version }
```
Verified: Hallucination, Relevancy, Appropriate Call Termination, **CSAT (RATING)**, **Sentiment (ENUM:
POSITIVE/NEGATIVE/NEUTRAL)** all hydrate this way. The catalog template comes from
`GET /eval-metric?metricSourceType=STANDARD` (see below) — its list body can contain **raw newlines in
`evaluationCriteria`, so parse tolerantly** (Python `json.loads(strict=False)`; `jq` chokes).

## Fetch the standard catalog

`GET /eval-metric?metricSourceType=STANDARD` returns the platform's predefined metrics (fully hydrated,
from a template worker) — use them as the PUT templates and to know the valid `standardEvalMetricId`s:

| id | outputType | threshold | evaluator/method |
|---|---|---|---|
| `hallucination` | NUMERIC | LTE 10 | AI_PLATFORM / LLM_JUDGE |
| `relevancy` | NUMERIC | GTE 40 | AI_PLATFORM / LLM_JUDGE |
| `response_consistency` | NUMERIC | GTE 40 | AI_PLATFORM / LLM_JUDGE |
| `conversation_progression` | NUMERIC | GTE 40 | AI_PLATFORM / LLM_JUDGE |
| `appropriate_call_termination` | BOOLEAN | EQ true | AI_PLATFORM / LLM_JUDGE |
| `csat_score` | RATING | GTE 70 | CORE_PLATFORM / (empty) |
| `sentiment` | ENUM | EQ POSITIVE | CORE_PLATFORM / (empty) |
| `tool_call_success_rate` | RATING | GTE 90 | CORE_PLATFORM / (empty) |
| `latency` | NUMERIC | LTE 10 | CORE_PLATFORM / (empty) |
| `average_pitch_assistant` | NUMERIC | LTE 350 | AI_PLATFORM / AUDIO_ANALYSIS |
| `assistant_interrupting_user` | RATING | LTE 5 | AI_PLATFORM / AUDIO_ANALYSIS |
| `user_interrupting_assistant` | RATING | LTE 10 | AI_PLATFORM / AUDIO_ANALYSIS |

## Field reference (verified)

- `outputType`: BOOLEAN / NUMERIC / RATING / ENUM. `thresholdCondition`: EQ / LTE / GTE.
  `thresholdValue` is a **string** ("true", "10", "70", "POSITIVE"). `enumValues` for ENUM.
- `evaluatorType`: AI_PLATFORM (LLM/audio judged) / CORE_PLATFORM (platform-computed).
  `evaluationMethod`: LLM_JUDGE / AUDIO_ANALYSIS / omit when empty.
- `metricSourceType`: STANDARD / CUSTOM.
- **`version` must be the worker's LIVE version** (a never-deployed draft version and `null` both 500).
  Metrics are effectively **worker-scoped** — `GET /eval-metric?aiWorkerId=` lists them all (no
  `version` query param); they persist across deploys.
- `simulation:true` → scores simulated calls; `observability:true` → scores live/test calls;
  `sampling:true` → a fraction of live calls. Set at least `simulation:true` for the loop.

## Getting the dashboard to actually show data (verified live — the async trap)

Creating metrics is **not enough**. Metric evaluation is an **async job**:
1. A simulation (or live call) creates an **`eval-result` in `status: PENDING` with 0 metrics scored**.
2. The async evaluator scores it — **CORE_PLATFORM metrics (CSAT/Sentiment) score fast; LLM_JUDGE
   metrics lag**, and the record stays PENDING until all complete. The Evals Overview counts only
   completed evals, so it reads 0 until the job finishes.
3. Force it: `POST /eval-result/trigger?voiceCallId=<voiceInteractionId>` — **use the
   `voiceInteractionId`** (e.g. `call_9dc8…`) from the eval-result, **not** `voiceCallMongoId` (that
   500s). Read results with `GET /eval-result/session/{sessionId}` where **`sessionId` == the
   scenario-run `id`**; each `results[]` entry (`EvalMetricResultEntry`) has `metricName`, `evaluation`
   (the score/value), `thresholdMet`. See `simulation-and-results.md` for the call→result plumbing.

> So the honest failure modes for "empty Evals dashboard": (a) no metrics defined; (b) metrics are
> hollow shells (standard created without the PUT-hydrate); (c) eval-results still PENDING (async job
> hasn't scored — trigger them). All three were hit and resolved in the live test.

## Alerts — `/eval-metric-alert`

`POST /eval-metric-alert` (`EvalMetricAlertRequest`: `name, evalMetricId, aiWorkerId, severity,
channels, emails, everyOneInWorkspace, userOrUserGroupIds, enabled`) fires when a metric breaches on
live calls. Most useful once the worker serves real traffic; a sensible first set is CSAT-low,
Hallucination-high, Appropriate-Call-Termination-false.
