# Changelog

## 2026-07-02 — 0.5.0 — Add the `commotion-quality-loop` orchestrator (single entry point)

The four skills were independent — chaining relied on the model following the "step N of the loop"
prose. Added a thin **coordinator** skill so the whole pipeline runs from one request, with the
iterate-until-threshold control flow owned in one place.

- **`commotion-quality-loop`** — the end-to-end orchestrator. Triggers on compound requests ("build a
  voice bot for X and make it pass 90%", "test and improve my worker until 80%") and **invokes the four
  specialists in order via the `Skill` tool** (`allowed-tools` now includes `Skill`): ensure a deployed
  **voice** worker (build via create-worker if needed) → generate-scenarios → run-evals (baseline) →
  improve-worker (loops on a draft until `passRate ≥ threshold` or max rounds) → deploy on approval. It
  carries shared state (worker id, version, scenario ids, SIM_ID, pass-rate, threshold, max rounds)
  between steps and owns the threshold/max-rounds/deploy gates; it does **not** duplicate the
  specialists' internals.
- **Routing:** compound "whole loop" requests → the coordinator; single-step requests → the specialist
  directly. Added a "for the full loop, use `commotion-quality-loop`" pointer to each specialist's
  "When to use this", and listed the coordinator as the entry point in the README.
- Enforces the live-verified prerequisite up front (a **deployed voice** worker) so the loop doesn't
  start against a chat/never-deployed worker that can't be simulated. Bumped to 0.5.0.

## 2026-07-01 — 0.4.1 — Live-test hardening of the quality-loop skills (dev3)

Dogfooded the full loop end-to-end on a real dev3 worker (`Acme Support Triage`): built it, generated
personas + scenarios, ran voice simulations, drove an improve round (ETA-gap scenario `0%→100%` after
a prompt edit), added Hindi/English language switching, and populated eval-metrics. Folded every
backend behavior the live run surfaced into the skills.

- **Evals/simulations are VOICE-ONLY, and need a deployed worker.** A chat worker fails every sim run
  ("An error has occurred during simulation"); a **never-deployed** worker returns *"Worker is not
  available"* and AI scenario-gen yields nothing. A **draft version of an already-live worker CAN be
  simulated** — which is what makes the draft-only improve loop actually work. Added prerequisites to
  run-evals, generate-scenarios, and improve-worker; noted in create-worker Phase 12.
- **`passRate` is a percentage 0–100** (not 0–1). Default loop threshold corrected to **80**.
  `SimulationResponse.avgQuality` stays `null` (not wired to eval-metrics).
- **Eval-metric create recipes (the sharp part).** *Custom* = full body (`metricSourceType:"CUSTOM"` +
  criteria/threshold). *Standard/predefined* = **POST a minimal shell → PUT the full definition,
  dropping empty-string fields** (an empty `evaluationMethod` 500s; full-body POST 500s on `name`;
  minimal POST alone = a hollow shell). `version` must be the **live** version. Fetch the catalog via
  `GET /eval-metric?metricSourceType=STANDARD`. Verified Hallucination/Relevancy/Appropriate Call
  Termination/CSAT/Sentiment all hydrate this way. Rewrote `run-evals/references/eval-metrics.md`.
- **Two evaluation surfaces.** Simulation scenario pass/fail (Simulations → Runs) ≠ the **Evals
  dashboard** (eval-metric results). The dashboard is empty unless metrics exist *and* their evaluation
  runs — which is **async**: sim calls create eval-results in `status: PENDING`; force scoring with
  `POST /eval-result/trigger?voiceCallId=<voiceInteractionId>` (the **`voiceInteractionId`**, not
  `voiceCallMongoId`); a scenario-run's `id` **is** the call's `sessionId`. Rewrote
  `run-evals/references/simulation-and-results.md`.
- **Agent type is immutable via PUT** — change it by delete + re-POST (added to
  `create-worker/references/agents-and-orchestration.md`).
- **Language switching (en + hi) pattern**, validated live: worker
  `workerVoiceConfiguration.allowedLanguages:["en","hi"]` + an agent prompt rule (mirror the caller's
  language; **don't** switch on English-spelled numbers/emails). Documented in generate-scenarios
  (bilingual personas) and improve-worker (a config-level fix example).
- **Misc verified:** `/aiworker/{id}/versions` returns `{"items":[…]}`, superseded status is
  **PAUSED**; scenario/metric list bodies can contain **raw newlines** (parse tolerantly);
  dropdown-config codes (SIMPLE/MODERATE/COMPLEX, HAPPY/JAILBREAK, VOICE/CHAT, limits 20/20); AI
  scenario-gen is async with **no progress endpoint** and needs a live worker (manual `POST /scenario`
  is the reliable fallback). Bumped to 0.4.1.

## 2026-06-30 — 0.4.0 — Close the quality loop: generate-scenarios, run-evals, improve-worker

Three new skills extend the plugin from "build a worker" to "build, **test, evaluate, and iteratively
improve** a worker until it clears an eval-score threshold" — the loop create-worker →
generate-scenarios → run-evals → improve-worker.

- **`commotion-generate-scenarios`** — builds a worker's test set: simulated-caller **personalities**
  (`/personality`, with AI-drafted prompts) and **scenarios** (`/scenario`) — AI-generated (async
  `POST /scenario/generate` → poll), manual, or from a real call. References: `eval-domain-api.md`
  (the canonical endpoint map for the scenario/sim/eval domain) + `scenarios-and-personalities.md`.
- **`commotion-run-evals`** — optionally defines **eval metrics** (`/eval-metric`), runs the scenarios
  as a **simulation** (`POST /simulation/run`), polls `GET /simulation/{id}`, and reports the
  **pass-rate** + per-scenario failures (`GET /scenario-run?simulationId=`). References:
  `eval-metrics.md` + `simulation-and-results.md`.
- **`commotion-improve-worker`** — owns the **iterate-until-threshold loop**: diagnoses failing
  scenarios (`failureReason`/`evaluationReasoning`), edits the worker on a **draft** (reusing
  create-worker's machinery), re-runs the evals, and repeats until `passRate ≥ threshold` or a round
  cap — then deploys on approval. Reference: `improvement-loop.md` (loop control, regression guard,
  version-pinning, failure→fix taxonomy).
- **Locked design decisions** (from build session): the improvement loop is **draft-only** (never
  auto-deploys mid-loop; the live worker is untouched until the user approves the final version), and
  the gate is the **scenario pass-rate** (`SimulationResponse.passRate`; default target 0.8, default
  max 3 rounds, both asked at runtime).
- **Transport reuse — no new scripts.** Verified against the live OpenAPI spec
  (`/v3/api-docs/public`, 193 paths) that the scenario/simulation/eval endpoints are part of the
  **same unified backend** as `/aiworker`/`/aiagent`, so all three skills reuse `commotion_api.sh` +
  `fetch_schema.sh` + the Step-0 Kong-key flow unchanged. Each skill smoke-tests the eval route
  (`GET /scenario/dropdown-config`) first.
- **Open items flagged for live testing** (folded into the references): eval-domain route parity
  through Kong; version carry-over of scenarios/metrics across a new draft; `standardEvalMetricId`
  predefined-metric catalog; scenario-run → session/call id linkage for per-metric scores; async
  scenario-generation poll shape; simulating a draft end-to-end. There is **no server-side
  "improve prompt" endpoint** — improvement is model reasoning + the create-worker editing machinery.
- Bumped `plugin.json` / `marketplace.json` to 0.4.0 and widened the descriptions. Skills are
  auto-discovered from `skills/*/SKILL.md` (no manifest enumeration needed).

## 2026-06-29 — 0.3.6 — Prompt for the Kong api-key at session start (no committed/embedded key)

The skill no longer needs a committed `.env` or an embedded secret — it asks the user for the Kong
api-key as its **first step** and keeps it for the session only.

- **SKILL.md:** added **Step 0 — Provide the API key** (before Phase 0): ask via `AskUserQuestion`,
  write it to `${TMPDIR:-/tmp}/commotion-mcp/session.env` with `umask 077` (never printed), then
  smoke-test with `GET /aimodel`. Removed the old `.env`-sourcing setup line and the now-redundant
  prerequisites bullet.
- **`scripts/commotion_api.sh`:** auto-loads `COMMOTION_ENV_FILE` (default the session file above)
  when `KONG_API_KEY` isn't already in the environment, so the key set once in Step 0 reaches every
  call (each Bash invocation is a fresh shell). An exported var / local `.env` still takes precedence;
  the not-set error now points at Step 0.
- **`.env.example`:** documented that `.env` is now optional (Step 0 is the default path).
- Security: the key lives only in the session temp file (mode 600) + conversation context — never
  committed, never embedded in the bundle. Bumped `plugin.json` / `marketplace.json` to 0.3.6.

## 2026-06-28 — 0.3.5 — Single-agent prompts CAN render (delete-default-then-POST)

Found + verified live: a `SINGLE_AGENT` worker *can* have a POST-created (UI-rendering, editable)
prompt after all — you just delete the auto-provisioned default first.

- **Recipe:** `DELETE /aiagent/{defaultId}?version=0` (the `version` query param is **required**) →
  agent count 0 → `POST /aiagent` the real agent with `instructions` + `aiAgentEnabled:true`. Its
  prompt renders + is editable. (A direct POST while the default exists is rejected with
  `"Single Agent setup allows only one agent"`.)
- **Setup type is now a pure use-case decision** (single vs multi based on whether the work splits),
  no longer forced toward MULTI_AGENT for prompt visibility. In BOTH setups you POST the
  prompt-bearing agent; the only difference is freeing the slot — single: delete the default; multi:
  disable the default + POST each specialist.
- Updated SKILL.md (Phases 2/6), `agents-and-orchestration.md` (+ `DELETE /aiagent/{id}?version=N`
  in the endpoint tables and `api-and-auth.md`), and the saved memory.

## 2026-06-28 — 0.3.4 — Skill refinements from user review

- **Deploy is always user-gated** — added an explicit `AskUserQuestion` confirmation requirement to
  the intro and Phase 10; never deploy live without a clear "yes".
- **Setup type is inferred, not defaulted** — Phase 2 now tells the model to read the use case and
  prefer `MULTI_AGENT` when the work splits into specialised responsibilities (the user won't say
  "multi-agent"); ask when unsure. Worker reframed as the **orchestrator** of its agents.
- **Single-agent POST is blocked (verified live)** — `POST /aiagent` on a `SINGLE_AGENT` worker →
  `400 "Single Agent setup allows only one agent"`. So a UI-visible/editable prompt requires
  `MULTI_AGENT` + a POST-created agent (a single flow = one specialist + thin orchestrator). Updated
  Phases 2/6 and the agents reference.
- **Models + fallback for voice corrected** — a voice worker's LLM **and its fallback** live in the
  **Voice Settings** block (`workerVoiceSettingsRequest.workerLLMConfigurationRequest`), shown in the
  UI as *Voice Settings → LLM Settings → Fallback Provider/Model* — not `workerAdvancedSettingsRequest`
  (which voice rejects). Fixed `control-and-reliability.md` and `aiworker-lifecycle.md` (previously
  wrongly said "fallback is chat-only").
- **Guardrails are designed from the use case** — Phase 3 and the reference now derive guardrails per
  domain (e.g. banking → PII + card/account masking + competitor forbidden words + toxicity +
  no-advice custom check), not a fixed template.
- **Tools phase reframed** — Phase 8 now says to actively decide what belongs in tools so the prompt
  doesn't do the heavy lifting (ask when unsure), and restates that **every API must be a registered
  tool** (naming an API in the prompt makes the model fabricate `api_call` and loop).
- **Anti-repetition refined** — don't re-ask for info **already given**; re-asking once for info that
  wasn't actually provided (or was unclear) is fine.

## 2026-06-26 — 0.3.3 — UI rendering, tools, language & repetition (HDFC ERGO live test)

Learnings from the user testing the HDFC worker in the Commotion UI:

- **POST-create the prompt-bearing agent, or it won't render/edit in the UI (verified by a
  controlled A/B).** An agent's prompt only shows in the UI prompt editor if the agent was created
  via `POST /aiagent` with `instructions` in the create body. PUT-updating the auto-provisioned
  default agent runs at runtime but leaves the editor blank (the editor doc is set at *create*).
  → A `SINGLE_AGENT` worker (only the un-POST-able default) can't have a UI-editable prompt via API;
  build `MULTI_AGENT` with a thin orchestrator + the real agent **POST-created**. Updated SKILL.md
  (Phases 2/5/6) and `agents-and-orchestration.md`. This also corrects/clears up the long
  "empty prompt editor" investigation (it was never the field, content, size, or trigger cruft).
- **Register APIs as real tools — naming an API in the prompt makes the model fabricate `api_call`.**
  Verified live: with no registered tool, the agent invented `api_call({"api_name":"API 001"...})`,
  got `function 'api_call' is not registered`, and **looped re-asking**. Fix: register each API as a
  custom tool (`POST /ai-worker-tool/custom-tool`) and reference it by action name (`[tool:rmn-check-228]`).
- **Multilingual voice: don't switch language on English digits.** Added a prompt rule (and skill
  guidance): stay in the caller's language; treat numbers/policy-numbers/amounts read in English as
  data; never trigger the `Switch Language` action because of them.
- **Anti-repetition:** never re-ask for given info; call each tool once; on tool error take the
  failure path once — don't loop.

## 2026-06-25 — 0.3.2 — Corrections from live-testing the agent (HDFC ERGO)

Ran the HDFC worker via `POST /aiworker/run` to evaluate real behaviour (not just CRUD). Findings &
fixes:

- **Agent prompt drives runtime, may not show in UI editor.** API-set `instructions` are what the
  agent actually runs on (the live run followed the prompt) even though the UI rich prompt editor can
  render empty. An empty editor box ≠ no prompt. Documented in SKILL.md Phase 6 + agents reference.
- **Corrected a wrong 0.3.1 note:** the agent type DOES stick — the request field `agentType` is
  echoed back as **`aiAgentType`** (the `agentType` key is request-only and reads `null`). Fixed
  SKILL.md, `agents-and-orchestration.md`, and the saved memory.
- **Hallucination from un-wired tools (the key finding).** A prompt that *names* APIs ("call API
  001/002…") with no tools wired makes the agent **fabricate** results — it declared a phone number
  "not registered" with nothing backing it. Added an explicit anti-hallucination rule to the HDFC
  prompt (redeployed v1) and a prompt-authoring rule to SKILL.md Phase 3 + agents reference: never
  assert a backend fact without a tool result; wire the APIs as tools to make it functional.
- **Added Phase 12 (test the agent)** to SKILL.md and documented `POST /aiworker/run` in
  `api-and-auth.md` — the skill now ends by exercising branches/failure paths and checking for
  hallucination, not at "deployed".

## 2026-06-25 — 0.3.1 — Corrections from the first live build (HDFC ERGO Health Renewal)

Dogfooded the skill end-to-end by building + deploying a real production voice worker — the HDFC
ERGO Health Renewal flow (`6a3cfb5a5d29f47d6e6b08c7`, dev3 `demo_workspace`): SINGLE_AGENT, voice
(en+hi, S2S `commotion-laya-v1-5`), toxicity + Commotion-PII guardrails, full 14-section renewal
flow in the agent instructions. Fixes from what the live run surfaced:

- **Scripts-dir resolution:** the `${CLAUDE_PLUGIN_ROOT:?…}` line hard-failed when running from a
  clone (the var is only set for an installed plugin). Replaced with a `:-` fallback + guidance.
- **Prompt placement (correctness):** for SINGLE_AGENT the detailed system prompt / flow logic goes
  in the **agent's `instructions`**, not `workerLevelPrompt` (which is a short role line) — verified
  against a live worker. Fixed SKILL.md Phase 3/6 and `agents-and-orchestration.md`.
- **Voice default agent:** documented that a voice worker's default agent is **"Voice Agent"** with
  `agentType: null`, and that `agentType: "VOICE_AGENT"` doesn't stick (harmless; `aiAgentEnabled`
  is the deploy gate). Fixed SKILL.md Phase 5/6 and `agents-and-orchestration.md`.
- **Voice config:** corrected the live pipeline set (HALF_CASCADE / SPEECH_TO_SPEECH / COLLOQUIAL —
  no FULL_CASCADE/TRANSCRIPTION_BASED) and added a verified-good en+hi voice block to
  `aiworker-lifecycle.md`.
- Knowledge (P7) and tools (P8) were correctly skipped: the flow is API-driven, and wiring the
  HDFC APIs as custom tools needs their real endpoint specs (the prompt encodes every call-point).

## 2026-06-25 — 0.3.0 — Skills-only: call dev3 directly over HTTP (drop the MCP server)

Restructured the plugin so the skills call the Commotion dev3 backend **directly over HTTP** (via
Kong) instead of through the hosted `commotion-mcp` server. Modeled on Cekura's skills: the skill
carries the endpoints and fetches request schemas live from the OpenAPI spec.

- **Removed** `.mcp.json` and all `mcp__commotion__*` tool calls. The `commotion-mcp` repo is left
  in place but is no longer referenced.
- **Added** `scripts/`: `commotion_api.sh` (authenticated request wrapper — injects the Kong base
  URL + `apikey` + `X-Route-Selector`, keeps the key off the command line, surfaces backend errors),
  `fetch_schema.sh` (fetches `/v3/api-docs/public` once per session, caches it, bundles a named
  schema with its `$defs`), and `bundle_schema.py` (stdlib port of
  `commotion-mcp/server/utils/openapi.py:bundle_schema` for byte-equivalent schemas).
- **Rewrote** `commotion-create-worker/SKILL.md` into explicit phases (P0 ground → P1 interview →
  P2 setup type → P3 draft → P4 approve → P5 create → P6 enable agents → P7 knowledge (optional) →
  P8 tools (optional) → P9 readiness → P10 deploy → P11 confirm), each with the exact endpoint + the
  reference to read; `allowed-tools` is now `Bash, Read, AskUserQuestion`.
- **Ported** all reference files MCP→HTTP (endpoint tables added; every gotcha/error-string/field
  path preserved) and added `references/api-and-auth.md` — the endpoint map, header contract, error
  semantics, and `fetch_schema.sh` schema-name list.
- **Config:** `.env` now carries `KONG_API_KEY` (secret) + `KONG_BACKEND_URL` /
  `KONG_API_KEY_HEADER` / `KONG_ROUTE_SELECTOR` (non-secret defaults); added `.env.example`.
  Bumped `plugin.json` / `marketplace.json` to 0.3.0 and updated descriptions.
- **Verified live** against dev3 through the new transport: `GET /aimodel`, `GET /aiworker/metadata`,
  and `fetch_schema.sh AiWorkerRequest` (28 `$defs`, includes `guardrailConfigRequest`), with the
  spec cached and reused across schema names.
