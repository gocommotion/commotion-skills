# Simulations & results — running scenarios and reading the score

How a simulation runs and how to read results (`/simulation`, `/scenario-run`, `/eval-result`). Field
*shapes* come from `commotion_schema`; this file is the verified-live behaviour (dev3).

## Hard prerequisites (verified live)

- **Every channel simulates through the same endpoint.** `POST /simulation/run` serves VOICE, CHAT and
  STRUCTURED_OUTPUT workers; the channel is carried by each **scenario's `aiAgentChannelType`**
  (`VOICE`/`CHAT`), and an all-chat batch echoes **`onlyChatScenarios: true`**. Verified live
  2026-08-03: chat worker → `passRate 100.0`; `STRUCTURED_OUTPUT` worker → `PASS`. A `STRUCTURED_OUTPUT`
  agent sits on the **CHAT** channel. Personalities must be `voiceEnabled: true` **for voice scenarios
  only** — for chat/SO, `voiceEnabled: false` is correct.
- **A generic *"An error has occurred during simulation…"* is not a channel verdict.** It arrives with
  `duration 0.0` / `Simulation Error` and hides the real cause. Read the run's own session before
  concluding: `/api/chat/session/<scenario-run-id>` (chat/SO) → `errors[]`, or
  `/api/calls?requestId=<scenario-run-id>` (voice). One verified cause was a worker LLM credential
  fault (`litellm.AuthenticationError: Incorrect API key provided`), not the channel.
- **The worker must have a live runtime** (deployed at least once). A never-deployed worker →
  `/aiworker/run` returns *"Worker is not available for worker Id: …"* and sims fail. **A draft version
  of an already-live worker CAN be simulated** (verified: draft v1 ran while v0 was live) — this is
  what makes the draft-only improve loop work.

## `RunScenariosRequest` (POST `/simulation/run`)

| Field | Notes |
|---|---|
| `aiWorkerId`, `version` | worker + **version under test** (a draft of a deployed worker is fine) |
| `scenarioIdToRunPerScenarioMap` | `{scenarioId: nRuns}` — run a scenario N times for consistency. Total ≤ `maxScenarioRunLimit` (20), **but keep it ≤4 per sim** — see batch note below |
| `maxDuration` | per-scenario cap in seconds (voice) — e.g. 300 |
| `maxTurns` | per-scenario cap on turns — e.g. 20 |
| `llm` | simulator LLM (`{provider,model,voiceProviderCredentialId,reasoningEnabled}`) — codes from `/aimodel`. **Optional**; omit to use the platform default simulator (both verified passing runs omitted it). If you do set it, keep it a **`commotion` provider** — a non-Commotion provider needs a `voiceProviderCredentialId` you cannot obtain over the API (see `commotion-create-worker/references/aiworker-lifecycle.md`, "Providers and credentials") |

There is **no channel field on this request** — the channel is decided per scenario by
`aiAgentChannelType`. Mixing voice and chat scenarios in one batch is therefore possible; keep batches
single-channel so `onlyChatScenarios` and the failure signatures stay unambiguous.

Returns `SimulationResponse` with `id` (the `<sim-id>`, read from `body`) and `scenarioRunIds`. **One
sim at a time** — check `GET /scenario-run/active?aiWorkerId=` first (starting a second while one is
active is blocked).

**⚠ Batch of 4 (verified operationally).** A sim runs its scenario-runs concurrently over websockets;
submitting more than **4 total runs** (`sum(scenarioIdToRunPerScenarioMap.values())`) exhausts the
websocket connections and the excess runs **fail with connection errors** — they surface as the
failure signature below (`COMPLETED` instantly, `passRate 0.0`, `avgLatencyInMillis null`). Keep each
`/simulation/run` to **≤4 total runs**; for a larger set, run sequential batches of ≤4 (poll each to
completion, confirm `/scenario-run/active` is clear, then start the next) and aggregate the pass-rates.

## Poll → the score

Repeatedly call `commotion_request` `{ "method": "GET", "path": "/simulation/<sim-id>" }` and read
these from `body`:

| Field | Meaning |
|---|---|
| `status` / `statusLabel` | PENDING → COMPLETED (unconstrained string — gate on the counts, not a hard token; verified terminal value is `COMPLETED` / `"Completed"`) |
| `passRate` | **the eval score — a percentage 0–100** (all-pass = `100.0`). ⚠ denominator is **decided** runs — see below |
| `passCount` / `totalScenarios` / `completedScenarios` | the raw counts. `completedScenarios` counts **any** terminal run, `FAILED` included |
| `timeToComplete` | **the batch's end-to-end duration, in MILLISECONDS** — `75593` = 75.6 s. ✅ the only trustworthy duration; report this |
| `executionTime` | seconds — an aggregate of per-run durations. ⚠ under-counts when a run errors. Populates while still PENDING, so useful **only** as a liveness check |
| `totalExecutionTime` | seconds — same aggregate, same caveat. ⚠ don't present it as a duration |
| `avgLatencyInMillis` | avg agent latency (~560–740ms in tests) — populates on success |
| `avgQuality` | **stays `null`** — NOT wired to eval-metrics; ignore it as a quality signal |

**⚠ Timing is server-side — read it, never narrate your own polling wall-clock.** Three live voice
batches, measured 2026-08-06:

| | per-run `duration` | `timeToComplete` | `executionTime` | `totalExecutionTime` |
|---|---|---|---|---|
| A — 2 runs (1 pass, 1 error) | 53.04 + 75.49 | 75593 ms (75.6 s) | 64.27 (mean of both) | 128.53 (sum of both) |
| B — 2 runs (1 pass, 1 error) | 51.99 + 71.81 | 69475 ms (69.5 s) | **51.99** | **51.99** |
| C — 4 runs (3 pass, 1 error) | 62.82, 63.40, 63.53, 64.48 | 101876 ms (101.9 s) | 63.56 (mean of all 4) | 254.23 (sum of all 4) |
| D — 4 runs (3 pass, 1 error) — **same worker + scenario as C** | ~54 s each | **374236 ms (6.2 min)** | 54.19 | 216.75 |

Runs execute **concurrently**, so a batch costs far less than the sum — but it is **not** just the
longest run either, and the overhead on top is **highly variable**. C and D are the *same* 4-run batch
on the *same* worker and scenario, with near-identical per-run durations, yet D took **3.7× longer**
end-to-end. **Budget 2–7 min for a ≤4-run voice batch and never infer a fault from elapsed time
alone** — D finished at `passRate 100.0`.

**Liveness, not the clock, tells you a batch is alive.** `totalExecutionTime` and `completedScenarios`
both climb while work is happening — observed on D across successive polls: `totalExecutionTime`
105.9 → 154.2 → 216.8 while `completedScenarios` went 2 → 3 → 4. Suspect a stall only when **both are
frozen across several consecutive polls spanning 10+ minutes.**

The two `*ExecutionTime` fields are **not consistent**: A and C included their errored run in both
aggregates, B silently dropped it and reported only the passing run's 51.99 s for both. It is a race
on whether a run has posted its duration by aggregation time, so an errored run may or may not be
counted. Treat them as an aggregate-of-whatever-had-posted and **never** as a duration to report.

An agent's own elapsed-time estimate includes its waits and retries and drifts wildly high — reporting
tens of minutes for a batch whose `timeToComplete` is ~70 s is a reporting defect, not a slow platform.

**⚠ `passRate`'s denominator is decided runs (verified live 2026-08-06).** A 2-run batch with one
`PASS` and one `Simulation Error` returned `passRate: 100.0`, `passCount: 1`, `totalScenarios: 2` —
1/1 decided. The backend already drops undecided runs, so **don't recompute the percentage**; just
report it as "X% (n of N decided)" so a 100% resting on one decided run can't read as a clean sweep.

**Failure signature (verified):** a run that reaches a terminal state almost instantly with
`avgLatencyInMillis: null` and `passRate 0.0` did **not** actually run — the scenario-runs FAILED. A
genuine voice run takes ~40–90 s. The `/simulation/run` path is also **occasionally flaky** (same
generic error) — retry a transient failure once.

**⚠ `duration: 0.0` on a `QUEUED`/`RUNNING` run is normal, not a stall.** Per-run `duration` is only
written when the run reaches a terminal state; every in-flight run reads `0.0`. The near-zero-duration
failure signature above applies **only to terminal runs**. Don't declare a batch stuck — or abandon
it — because in-flight runs show `0.0`.

**⚠ But that signature is ambiguous — do not read it as "the runs didn't happen" on its own**
(verified live 2026-07-28). A simulation reported `COMPLETED`, `passRate 0.0`, `avgLatencyInMillis: null`
while **all four of its calls existed** with 42–57-second durations and full transcripts: the number was
`0.0` only because nothing could be *evaluated*. Discriminate on the **terminal per-run `duration`** —
near-zero on a run that has *finished* means it really didn't happen; 40–90 s means it ran and the
evaluator failed (see below). On a run still `QUEUED`/`RUNNING`, `duration` is always `0.0` and tells
you nothing.

**⚠ A `500 Simulation trigger failed. Please try again.` is not always transient.** If the worker's agent
was deleted and re-POSTed (an agent-type change, or a replacement — prompt edits now go through `PUT`,
which keeps the id), the scenario still stores the **old `aiAgentId`** and
every trigger will 500 until the scenario is re-pointed. Check
`GET /scenario/<id>` → `aiAgentId` against `GET /aiagent?workerId=…&version=…` before retrying.

## Per-scenario breakdown (the diagnosis fuel)

Call `commotion_request` `{ "method": "GET", "path": "/scenario-run?simulationId=<sim-id>" }` and read
the records from `body`.

`ScenarioRunResponse`: `status` (QUEUED→RUNNING→COMPLETED→EVALUATION_*→FAILED), `scenarioEvaluationResult`
(PASS/FAIL — **and also `ERROR` or `''`**, see below), `quality`, `evaluationReasoning` (**the richest
field — the evaluator's turn-by-turn justification; this is what improve-worker reads**), `failureReason`
(backend error text when a run failed), plus `scenarioRunStatusLabel`, `failuresReasoning[]` and
`passesReasoning[]`. It does **not** expose a `sessionId`/`callId` field — **but the scenario-run `id` IS
the call's `sessionId`** (verified: run id == the SIMULATION conversation's sessionId), which is how you
reach the eval-metric results below.

**⚠ The evaluator often returns no verdict at all (verified live 2026-07-28: 0 of 8 runs decided).**
`scenarioEvaluationResult` is not limited to PASS/FAIL — it also comes back as **`ERROR`** or an **empty
string**, with `scenarioRunStatusLabel` of `Evaluation Error` or `Simulation Error`, on calls that ran
40–60 seconds with complete transcripts. One observed cause is an evaluator-side bug:
*"Goal completion evaluation failed: 3 validation errors for EvaluationMessage …
`channel_types.0` Input should be 'voice' or 'chat' [input_value='customer']"*.

So `status: COMPLETED` does **not** mean the run was evaluated, and `passRate`/`passCount` can be `0`
purely because nothing scored. **Exclude no-verdict runs from any pass-rate you report**, say how many
were decided (`n of 4 decided`), and get the missing verdicts from the transcript — `commotion-debug`
does this via Call Analyzer (`/api/calls?requestId=<scenario-run-id>` → `?fields=transcript,metrics`);
see `commotion-debug/references/repro-and-gates.md` §1a. Reporting a `0.0` pass-rate that is really
"unevaluated" will send an improvement loop chasing a defect that may not exist.

## Reading a run for settings signals (not only prompt fixes)

The transcript + `evaluationReasoning` are also the primary signal for the worker's **Settings** and
guardrails — reach for the matching feature rather than stuffing the prompt:

- **Mispronunciation** rarely shows in the score — it shows in the **transcript** as an ASR mismatch: the
  tester-bot "heard" a different word than the worker was told to say (e.g. `NPCL` transcribed as
  "nipple"). So scan the conversation, not just `evaluationReasoning`. → add a **pronunciation dictionary**
  entry (`commotion-create-worker/references/settings-variables-pronunciation.md`).
- **Re-asked / forgotten data** — the worker asks again for something already given, or that should have
  been pre-loaded. → define a **state variable** (same reference).
- **Answered an off-limits topic, or blocked a legitimate one.** → add / loosen a **guardrail** or a
  forbidden-word group (`commotion-create-worker/references/control-and-reliability.md`).
- **Fell for a jailbreak / prompt-injection attempt, or drifted off-scope over a long chat.** → enable
  **advanced safety** (`manipulationDetectionEnabled` for injection, `focusGuardrailEnabled` for drift)
  (`commotion-create-worker/references/control-and-reliability.md`).

**A guardrail interception currently errors on the run path (known bug).** Verified live: when a
guardrail intercepts, the turn should return your fallback text, but today it comes back as a **FAILED**
run with a generic *"An error has occurred … reference number …"* message — a **code-side/backend
issue**, not the intended behaviour. So on an adversarial/off-limits scenario, a FAILED turn with that
error may be the guardrail intercepting rather than a prompt/logic bug — confirm by checking the input
and re-testing in the delivered channel before "fixing" the worker.

`commotion-improve-worker` turns these into edits automatically; the full symptom→fix table is its
`improvement-loop.md`.

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
