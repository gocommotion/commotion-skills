---
name: commotion-debug
description: >-
  Debug a Commotion worker from a real production call or chat session and fix it — pull the call's
  transcript, turn timeline, latency, tool calls and resolved LLM context from Call Analyzer, establish
  the root cause, reproduce the defect as a **failing simulation before editing anything**, fix the
  worker on a DRAFT, and re-run until the repro passes with no regression. Use this whenever a live
  interaction misbehaved and the user wants it diagnosed or fixed — e.g. "call_6a47ae1895ff transferred
  to a human for no reason, why", "the bot hallucinated a policy number on this call, fix it", "debug
  why calls are dropping on my renewal worker", "RCA this call". This is **not** part of the build-time
  quality loop — it starts from production traffic rather than from a test set, so prefer it over
  commotion-improve-worker whenever the input is a real call id. Calls the dev3 backend and Call
  Analyzer through the thin Commotion MCP server (OAuth — no API key in the transcript).
allowed-tools: Read, AskUserQuestion, Skill, mcp__commotion__commotion_request, mcp__commotion__commotion_schema, mcp__commotion__commotion_analyzer
---

# Commotion: Debug a Production Issue (RCA → repro → fix)

Take one misbehaving **live** interaction and end with a worker that no longer misbehaves. You supply
the judgment — reading a transcript against a turn timeline and a tool-call log, deciding whether the
defect is the prompt, a tool, missing grounding, a config value, or the platform itself, and making the
smallest edit that fixes it. The platform supplies the evidence and the verdict.

The discipline that makes this work is **reproduce before you fix**. A fix chosen from a transcript
alone is a guess; a fix chosen against a simulation that fails the same way is a change you can prove.

**Auth is automatic (browser login).** The Commotion MCP handles auth via OAuth: on first use it opens
a Commotion login in the browser, then attaches the user's token to every `commotion_request` /
`commotion_schema` call for you — the token never enters the conversation. `commotion_analyzer` needs no
token at all (its plane is authenticated server-side). Never ask the user for an email/password or a
token, and don't pass a `token` argument. If the tools aren't available at all, the MCP isn't connected
— ask the user to add/authorize it via `/mcp`.

```
Phase 0     Phase 1      Phase 2      Phase 3      Phase 4    Phase 5     Phase 6
Scope   →   Evidence  →  Root      →  Reproduce →  Fix on  →  Verify   →  Regression
the         from Call    cause         must FAIL    a DRAFT    must PASS   + report,
defect      Analyzer     + class       first                   ≥3 of 4     deploy on yes
                              │                                    │
                              └──────── loop while below the gate ─┘  (max 3 rounds)
```

## When to use this

The user has a real call or chat session that went wrong. You need its id — a `callId`
(`call_6a47ae1895ff`) or a chat `sessionId` (`copilot-…`) — or a filter narrow enough to find it.

**Not** this skill when: the worker doesn't exist yet (`commotion-create-worker`); the worker has no
test set (`commotion-generate-scenarios`); the ask is "raise my pass-rate" from an existing simulation
rather than "this call broke" (`commotion-improve-worker`). And if Phase 2 finds no single root cause,
or Phase 6's regression sweep is failing broadly, this is a quality problem rather than a defect —
hand off to `commotion-improve-worker` (see **Escalation**).

## Prerequisites (verified live)

- **The Call Analyzer plane must be connected.** If `commotion_analyzer` isn't in your tools, the MCP
  server has no Call Analyzer api key configured — say so and stop; there is no fallback source for
  this evidence.
- **Reproduction is voice-only.** Simulations run voice, so the must-fail/must-pass gates only close
  for a voice call on a worker that has been **deployed at least once** (a never-deployed worker returns
  *"Worker is not available"*). For a **chat** session you can still do Phases 0–2 and 4, but the gate
  is weaker — see **Chat sessions** below. Say which gate you are operating under; never imply a text
  spot-check proved what a simulation would have.

## How this skill talks to the platform (read first)

**Two planes, three tools.** The worker lives on the dev3 BE REST plane; the evidence lives on the Call
Analyzer plane. Both go through the connected **Commotion MCP** server:

- **`commotion_request`** — one authenticated call to the dev3 backend: `{ "method": "GET|POST|PUT|
  DELETE", "path": "/…", "body": <JSON, for writes> }` → `{ "status", "body" }` (a non-2xx is
  **returned, not thrown** — read it and adjust). Pass a **path**; the base URL is fixed server-side.
- **`commotion_schema`** — a bundled request schema: `{ "schema_name": "RunScenariosRequest" }`.
  **Never invent a field that isn't in the schema.**
- **`commotion_analyzer`** — one **GET** against Call Analyzer: `{ "path": "/api/call/<id>?fields=…" }`
  → `{ "status", "body" }`, plus `"truncated": true` and `"dropped": {<key>: <n>}` when the response was
  too large. It is read-only by construction — there is no `method` argument, so nothing here can
  change production. **A truncated body is incomplete evidence**: re-query narrower (fewer `fields=`
  sections, a shorter log window, a line filter) rather than concluding from what survived.

**Read ids/fields from results, not `jq`:** both tools return the parsed `body` — read the value you
need straight off it (a worker's live `version` is `body.version`; a call's worker is
`body.workerId`) and feed it into the next call's `path`. No shell, no `jq`.

References this skill leans on:
- The Call Analyzer endpoint map, `fields=` sections, payload sizes and gotchas:
  `references/call-analyzer-api.md`. **Read it before Phase 1.**
- Failure classes and the platform-artifact signature table: `references/rca-taxonomy.md`.
  **Read it before Phase 2.**
- Repro construction, the stochastic gates, the overfitting check, loop bounds:
  `references/repro-and-gates.md`. **Read it before Phase 3.**
- The eval endpoint map: `commotion-generate-scenarios/references/eval-domain-api.md`; simulation
  lifecycle and result shapes: `commotion-run-evals/references/simulation-and-results.md`.
- The edit machinery (reused, not duplicated): `commotion-improve-worker/references/improvement-loop.md`
  plus `commotion-create-worker/references/aiworker-lifecycle.md`, `…/agents-and-orchestration.md`,
  `…/control-and-reliability.md`, `…/tools-and-capabilities.md`, `…/knowledge-and-rag.md`.

**Execution rules:** one phase at a time, in order; **read the reference a phase names before you act on
it**; never edit live; show every write before you make it; quote evidence rather than paraphrasing it.

## Phase 0 — Scope the defect  ·  HUMAN INPUT (batched, minimal)

Ask only for what you don't have, in one batch: **which interaction** (a `callId` / `sessionId`, or a
filter) and **what the user saw go wrong** in their words. **Do not browse for a bad call unprompted** —
the user knows which one broke, and a call you picked yourself is a different investigation.

Confirm the MCP is live with one read: `commotion_request` `{ "method": "GET", "path": "/aimodel" }`
(a 2xx means you're good).

Then resolve the target from the call's shell — `commotion_analyzer` `{ "path": "/api/call/<call-id>" }`
(no `fields=`, ~1 KB) — and hold:

| Hold | From | Note |
|---|---|---|
| `<call-id>` | `body.callId` | also the eval domain's `voiceInteractionId` |
| `<worker-id>` | `body.workerId` **with any `_N` suffix stripped** | ⚠ the field is `<aiWorkerId>_<version>`; `N` is the version the call ran on |
| `<call-version>` | the `_N` suffix | the version to reproduce against |
| `<workspace-id>`, `<org-id>` | `body.workspaceId` / `body.orgId` | scope for any later list query |
| `<request-id>` | `body.requestId` | the session id for a log query |
| the symptom | `body.stopReason`, `body.status`, `body.wasConnected`, `body.duration`, `body.disconnectReason` | the first, cheapest signal |

If the id was a chat `sessionId` instead, use `/api/chat/session/<session-id>` and read `header.workerId`
(same `_N` convention).

## Phase 1 — Pull the evidence

Start with the RCA payload, in **two** calls rather than one — a five-section fetch is ~60 KB for a
28-second call and gets truncated, and `config` alone is ~41 KB of it (measured live):

1. `commotion_analyzer` `{ "path": "/api/call/<call-id>?fields=transcript,metrics,analysis" }` (~12 KB)
   — the transcript, per-turn latency, the tool calls with their arguments and results, and the
   context-corruption / token-growth analysis.
2. `commotion_analyzer` `{ "path": "/api/call/<call-id>?fields=config" }` — only once the transcript
   tells you the prompt or the tool wiring is implicated. This carries `context[]` (what the model
   actually saw) and `callMetadata.registered_tools` / `state_configurations` / `state_load_errors`.

**3. Read the logs — on every call, not only when something looks broken.** The transcript says what was
said and `toolCallMetrics` says what a tool returned, but **only the logs say why the call ended and what
config it actually ran with.** Escalate by level, cheapest first:

**Logs scope by session id on both surfaces** — for voice that id is the call's `requestId`, for chat it is
the `sessionId` and the route applies it (and the window) for you:

```
voice:  BASE = /api/call/<call-id>/logs?session_id=<request-id>
               &start=<createdAt − duration − 90s>&end=<createdAt + 90s>
chat:   BASE = /api/chat/session/<session-id>/logs        (scope + window are automatic)

1. BASE&level=error     →  3 rows / 2.3 KB   the failure
2. BASE&level=warning   →  4 rows / 2.8 KB   the [ALERT] trail into it
3. BASE&level=info      → 21 rows / 13 KB    Transcript turns, latency, session lifecycle
4. BASE&level=debug&filter=|~:<what you want>  →  the configs (targeted, 3–61 KB)
```

⚠ **On the chat endpoint a `filter` silently drops the session scoping** — verified live, `filter=|=:.`
returned 4239 rows of which only 837 were that session. So on chat, carry the id in the filter chain
yourself: `?filter=|=:<session-id>&filter=|~:ERROR|ALERT`. `level=` and `q=` are safe. Voice is unaffected.

⚠ **Never `level=debug` without a `filter`** — that is 1488 rows / 985 KB. Targeted, it's cheap:

| To answer | `filter=` |
|---|---|
| what config did this call run with? | `\|~:Raw Config\|Worker Config\|Request Config` |
| **what system prompt did the model actually get?** | `\|~:system instruction` |
| **were my tools wired at all?** | `\|~:tools configured\|No .* configured` |
| did a tool reference dangle? | `\|~:not registered` |

⚠ **The window matters more than it looks: `createdAt` is not the call start.** Verified live, it sat 42 s
*after* the first log line, and the **config load happens before it** — so a window anchored at
`createdAt − 30s` misses the entire startup phase. Weight the window backwards as shown.

⚠ **Do not scope by label.** `label=` alone returns `400 "No search criteria"`, and `/logs/labels` is
cluster-wide — scoping by `request_id` returned **0 rows** for a call that has 1488.

What to look for: the `[ALERT]` chain explaining the `stopReason` (a `pipeline_error` is often *"silent LLM
response + **no fallback configured**"* — a worker config gap, not a platform fault); the
`pipeline_factories.setup_*_tools` inventory, which reports *"No custom code tools configured"* at setup
and is the **earliest possible catch for a dangling `[tool:…]`**, ~10 s before the LLM tries it; and
`base_llm: Using system instruction:` — the composed prompt as the model received it, which is ground
truth for any prompt defect. Full technique and module map: `references/call-analyzer-api.md`.

Then follow the symptom, not a checklist — one targeted endpoint per hypothesis
(`references/call-analyzer-api.md` has the full map):

| Symptom the user described | Next read |
|---|---|
| Bot talked over the caller / missed speech / long silences | `?fields=timeline` (turn boundaries), then `/vad-plot` |
| Robotic gaps, clipped audio, "line was bad" | `/raw-inbound/gap-analysis` (`audioLossPercent`, `avgJitterMs`, `delays[]`) |
| Bot misheard a word, name or number | `/stt-segment-audio/summary` |
| Call died / cut off unexpectedly, or **any** `stopReason` you can't explain | `/logs` — see step 3, this is what logs are for |
| Tool "ran" but nothing happened | `toolCallMetrics[]` from `?fields=metrics` — read each `result` |

**Then decide one-off vs systemic**, because it changes the fix:

- `commotion_analyzer` `{ "path": "/api/calls?workerId=<worker-id>&limit=20" }` — how many recent calls
  share this `stopReason`? ⚠ query **both** the suffixed (`<id>_<N>`) and bare `<worker-id>` forms; both
  occur in call records.
- `commotion_analyzer` `{ "path": "/api/reports/latest" }` — the fleet baseline (`stop_reasons`,
  error/success rate, latency, tool metrics). One bad call against a clean baseline is a defect; a
  matching pattern across the fleet is a systemic issue and probably not a prompt fix.

## Phase 2 — Root cause + failure class  ·  GATE: user confirms

Read `references/rca-taxonomy.md`, then do both passes in order:

1. **Classify the failure** against the class table — *prompt gap · prompt conflict · ambiguity ·
   missing/misfiring tool · missing grounding · config or state defect · platform artifact*.
2. **Check it against the platform-artifact signature table.** A harness, infra or config artifact must
   never be prompt-fixed — you would burn a round and change nothing. The rule cuts both ways: an infra
   artifact must not suppress a real prompt finding, and a real finding must not launder an infra
   artifact.

Present a five-slot RCA record, with **verbatim** evidence — quote the turn, the tool `result`, the
metric value. If you cannot quote it, you have not established it:

```
What the caller said        <verbatim transcript turn(s)>
What the worker did wrong   <verbatim turn + why it is wrong>
Root cause                  <one sentence>
Failure class + surface     <class> → <the config surface that owns it>
Evidence                    <the signals that prove it, quoted, with the endpoint each came from>
Scope                       one-off | systemic (N of 20 recent calls, fleet baseline X)
```

> **Gate — do not proceed to Phase 3 without the user's confirmation.** Ask three things: is this the
> right root cause; is anything they observed missing; do they want it reproduced and fixed now. A wrong
> assumption here wastes every phase after it.

## Phase 3 — Reproduce  ·  the hardest gate

Read `references/repro-and-gates.md`. Build a scenario that recreates the defect, then prove it fails.

1. **Build the repro scenario.** Prefer `commotion_request` `{ "method": "POST", "path":
   "/scenario/generate-from-conversation", "body": { conversationId, aiWorkerId, version,
   aiAgentChannelType } }`. The `conversationId` is a BE-side id, not the Call Analyzer `callId` —
   resolve it via `GET /conversation/worker-conversations?workerId=<worker-id>` and match on the record
   whose `voiceInteractionId` is `<call-id>`. **If that mapping doesn't resolve, fall back** to
   authoring the scenario through `commotion-generate-scenarios` from the transcript.
2. **Copy the caller's turns verbatim.** STT artifacts, garbled words and truncations are what the
   model actually received — they are the trigger, not noise. Do not tidy them.
3. **Run it against `<call-version>`** — the version the prod call ran on, not the current live one:
   `commotion_request` `{ "method": "GET", "path": "/scenario-run/active?aiWorkerId=<worker-id>" }`
   first (if `body` is `true`, wait — sims run sequentially), then `{ "method": "POST", "path":
   "/simulation/run", "body": { aiWorkerId, version, scenarioIdToRunPerScenarioMap: {<repro-scenario-id>: 4},
   maxDuration, maxTurns } }` → `<repro-sim-id> = body.id`. **4 runs, one simulation** — the cap is
   4 total scenario-runs per sim; more exhausts the websocket connections.
4. **Poll to genuinely terminal**: `GET /simulation/<repro-sim-id>` until `completedScenarios ==
   totalScenarios`, then `GET /scenario-run?simulationId=<repro-sim-id>` and confirm no record is still
   in an `EVALUATION_*` state. Only then read the per-run `scenarioEvaluationResult`.

**Pre-flight, or the run is worthless:** confirm the scenario's personality has **`voiceEnabled: true`**
(`GET /personality`). A personality with `voiceEnabled: false` produces a **mute caller** — verified
live, four 55-second calls where the caller never spoke and the worker just greeted and hung up.

> ## ⛔ Phase 3 gate — hard stop, evidence only
>
> **Reproduced** means the repro scenario **FAILED in ≥ 2 of the 4 decided runs** *and* the failure mode
> is visible turn-by-turn in a failing run's transcript, matching the prod call. Report it as
> `3/4 failed`, never as a bare verdict.
>
> **⚠ Get the verdict from the transcript, not from `scenarioEvaluationResult`.** Verified live: **0 of 8
> runs** returned a usable PASS/FAIL — they came back `ERROR` or empty with
> `scenarioRunStatusLabel: Evaluation Error | Simulation Error`, on calls that had run 40–60 seconds and
> demonstrated the defect perfectly. So: bucket each run, exclude the no-verdict ones from the
> denominator, and for each of those find its call (`/api/calls?requestId=<scenario-run-id>`) and judge
> the transcript yourself. Full procedure in `references/repro-and-gates.md` §1a.
>
> **"The evaluator did not run" is not "not reproducible."** Those are different findings with different
> owners — never report the second when you mean the first.
>
> These are **not** reproductions: a run whose call never connected; a transcript that merely looks wrong
> to you; and a mute-caller run (`userTurnCount: 0`). Note that `passRate 0.0` with
> `avgLatencyInMillis null` is **ambiguous, not proof the runs didn't happen** — check the per-run
> `duration` and whether the calls exist in Call Analyzer.
>
> Do not reason "it didn't work, so the bug is probably there." That produces a fix you cannot test.
>
> Below 2 of 4 decided → work the diagnosis ladder in `references/repro-and-gates.md`. If it still won't
> reproduce, **stop and show the user** the repro transcript beside the prod transcript and ask whether
> it matches. Do not guess, and do not proceed.

## Phase 4 — Fix on a DRAFT (never on live)

Establish the draft and hold it as `<draft-version>`:
- Worker is live → `GET /aiworker/<worker-id>` (live is `body.version`) → `POST
  /aiworker/<worker-id>/draft?version=<live-version>` → the new draft is `body.version`.
- A draft already exists → `GET /aiworker/<worker-id>` is **live-only and 400s**; use `GET
  /aiworker/<worker-id>/versions`, find the entry under `items` whose `status == DRAFT`, and edit that.

Apply the smallest change that addresses the confirmed root cause, on the surface the failure class
named — the mechanics are `commotion-improve-worker`'s, unchanged (prompt → **delete the agent + `POST
/aiagent`**, never a bare `PUT`; tools → `POST /ai-worker-tool/…` then `[tool:<action>]` in the prompt;
knowledge → attach + index, bind with `[knowledge:<name>|id:<id>]`; guardrails/fallback/voice →
**full** `PUT /aiworker/{id}` resending every field you want to keep, plus `version`).

**Show the edit before you make it**, as a before/after with what it addresses. One surface per round,
so the pass-rate change is attributable.

> ⚠ **After a delete + re-POST of an agent, re-point the repro scenario or Phase 5 cannot even start.**
> The re-POST assigns a **new `aiAgentId`**, and the scenario still stores the old one, so
> `POST /simulation/run` returns `500 Simulation trigger failed. Please try again.` — which looks exactly
> like the known transient flake and is not. Verified live. Fix: `GET /aiagent?workerId=…&version=<draft>`
> for the new id, then `PUT /scenario/<repro-scenario-id>` with it. See `references/repro-and-gates.md`
> §4a. The agent-write rules themselves (`agentType` required on POST and read back as **`aiAgentType`**,
> `DELETE /aiagent/{id}?version=`, the SINGLE_AGENT auto-default that must be deleted before a POST) are
> already in `commotion-create-worker/references/agents-and-orchestration.md` — re-confirmed live here.

Then run the **overfitting check** from `references/repro-and-gates.md`. You just read a failing
transcript, and that leaks: a verbatim quote, a test-specific name or number, or a hyper-narrow clause
turns a general instruction into a string match against one call. Revise rather than strip when a flag
is genuine but the fix depends on it.

## Phase 5 — Verify

Re-run the **same** repro scenario — do not build a new one — against `<draft-version>`, 4 runs, polled
the same way as Phase 3.

> **Phase 5 gate.** Fixed means the repro scenario **PASSES in ≥ 3 of the 4 decided runs**. Report the
> rate (`4/4 pass, transcript-derived`), never a bare "fixed". A single passing run proves nothing on a
> stochastic voice stack — that is the origin of most "worked in dev, regressed in prod" calls. Expect to
> derive these verdicts from Call Analyzer transcripts rather than from `scenarioEvaluationResult`
> (Phase 3 gate, and `references/repro-and-gates.md` §1a) — and say so when you do.

Below the gate → back to Phase 4, up to **3 rounds** total. A round whose pass-rate went *down* is
reverted and reconsidered, not built on, and does not count against the cap. At 3 rounds without
clearing the gate, stop: report where it plateaued, what each round changed, and the next manual step.

## Phase 6 — Regression + report  ·  ALWAYS ASK FIRST

1. **Sweep for regressions.** Run the worker's existing scenarios against `<draft-version>` in
   sequential batches of **≤4 runs each** (poll each to completion, confirm `/scenario-run/active` is
   clear, then start the next) and compare the aggregate pass-rate to the same set's pre-fix rate. A fix
   that repairs one call and breaks three is not a fix.
2. **Report**:

```
Defect          <one line> — prod call <call-id> (worker <worker-id> v<call-version>)
Root cause      <one line>, class <class>
Evidence        <the quoted signals, with endpoints>
Reproduced      <n>/4 failed   — simulation <repro-sim-id>
Fixed           <n>/4 passed   — simulation <verify-sim-id>, draft v<draft-version>
Edits           <round: surface, before → after>
Regression      <pre-fix pass-rate> → <post-fix pass-rate> over <N> scenarios
Scope           one-off | systemic (…)
```

3. **Deploy only on an explicit yes.** `AskUserQuestion` → Deploy now / Keep as draft. On yes:
   `commotion_request` `{ "method": "POST", "path": "/aiworker/<worker-id>/deploy?version=<draft-version>" }`,
   then confirm with `GET /aiworker/<worker-id>`. **Never deploy a regression** — if the sweep went
   down, say so and recommend keeping the draft.

## Chat sessions (weaker gate — say so)

Phases 0–2 work fully: `/api/chat/session/<session-id>` carries `runs`, `performance.perTurn`,
`errors[]`, `sessionState` and the resolved per-agent prompts. **Logs work the same and are easier** —
`/api/chat/session/<session-id>/logs` scopes by the path's session id and derives the window itself, so
Phase 1 step 3's whole ladder applies with no `session_id`/`start`/`end` to supply (mind the filter
unscoping trap). Chat logs come from the same stream and the same config-logging modules as voice, so the
config mining — `|~:Worker Config`, `|~:system instruction`, `|~:tools configured|No .* configured` —
works unchanged. Phase 4's edits are identical. What you cannot do is Phase 3 and Phase 5 — simulations
are voice-only. Verify instead with a text spot-check: `commotion_request` `{ "method": "POST", "path":
"/aiworker/run", "body": { … } }` (needs an identity — `userId` / `fingerprintId` / `audienceId` — and a
deployed worker with an enabled agent), replaying the caller's turns verbatim.

State the difference plainly in the report: **`repro: n/a (chat — text spot-check only)`**. A text
spot-check is not a reproduction and does not license the confidence a 3-of-4 simulation would.

## Escalation

Hand off to **`commotion-improve-worker`** when the problem is breadth rather than a defect: Phase 2
finds no single root cause, Phase 5 plateaus across 3 rounds, or Phase 6's sweep is failing broadly.
Pass it `<worker-id>` and the latest `<sim-id>` as its baseline, and say why you're handing over — its
gate is the fleet pass-rate over the whole scenario set, this skill's is one defect. Don't run both
loops at once.

## Principles

- **Reproduce before you fix.** A fix chosen from a transcript is a guess. The must-fail-first gate is
  what makes the must-pass gate mean anything.
- **Quote, don't paraphrase.** Every RCA claim carries the turn, the `result`, or the metric that proves
  it, and the endpoint it came from. If you can't quote it, you haven't established it.
- **A rate, never a verdict.** `3/4 pass`. One voice run false-passes often enough that a bare "fixed"
  is misinformation.
- **Truncated evidence is not evidence.** When `commotion_analyzer` reports `truncated`, re-query
  narrower — never conclude from the surviving fragment.
- **Classify before you edit.** A platform artifact prompt-fixed is a wasted round and a false fix.
- **Draft-only; deploy on an explicit yes.** Live keeps serving its version until the user says
  otherwise, and a regression is never deployed.
- **Smallest attributable change.** One surface per round, so the pass-rate delta means something.
- **Reuse, don't reinvent.** The edit mechanics are `commotion-improve-worker`'s and
  `commotion-create-worker`'s; this skill owns the *single-defect* loop around them.
