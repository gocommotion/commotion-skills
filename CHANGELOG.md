# Changelog

## 2026-07-27 — 1.4.1 — connector credentials are create-time only; cap simulations at 4 runs

Two defects found live: a worker whose Gmail/Calendar connectors silently never registered, and
simulations that "completed" instantly with `passRate 0.0` when too many scenario-runs were submitted at
once. Both were traced to skill wording that taught the wrong thing; no new endpoints.

- **A connector must carry its credential in the create body**
  (`commotion-create-worker/SKILL.md` Phase 6 + `references/tools-and-capabilities.md`). The skills said
  `credentialMetaDataInput` was *optional* — "attach the actions now, `PUT` the credential later". That
  is wrong: without a connected `credentialIdentifier` the `POST /ai-worker-tool/connector` returns `200`
  but the backing managed MCP server never registers (empty `actionName`/`inputSchema`/`outputSchema`, no
  `credentialMetaDataOutput`, and the UI banner *"Tools could not be registered — MCP server failed to
  register, or the MCP authentication token is missing."*). And there is **no** `PUT` path to fix it —
  `UpdateConnectorToolRequest` has no credential field — so a bare connector can only be deleted and
  re-created. The skills now treat the credential as functionally required, tell you to reuse a
  `"connected": true` credential from `GET /ai-worker-tool/credentials`, and never to attach a connector
  before one exists.
- **Display metadata is POST-only too.** A minimal create registers but renders bare in the UI (generic
  "G" icon, empty **Category**, no action chips). The connector recipe now threads `appIconUrl` +
  `appTags` (from `/integration-apps`) and per-action `actionDisplayName` (from `/app-actions`) through
  the same create body. `actionDescription` is accepted but not persisted — don't rely on it.
- **Cap each simulation at 4 total scenario-runs** (`commotion-run-evals/SKILL.md` Phase 2 + guardrails,
  `references/simulation-and-results.md`, `commotion-improve-worker/SKILL.md` Phase 3). A sim runs its
  scenario-runs concurrently over websockets; more than 4 at once exhausts the connections and the excess
  runs fail with connection errors — surfacing as the existing failure signature (`COMPLETED` instantly,
  `passRate 0.0`, `avgLatencyInMillis null`). `maxScenarioRunLimit` (20) is no longer the practical
  ceiling: keep `sum(scenarioIdToRunPerScenarioMap.values()) ≤ 4` per sim and run larger sets as
  sequential batches of ≤4 (poll each to completion, confirm `/scenario-run/active` is clear, then start
  the next), aggregating pass-rates at the end.

## 2026-07-22 — 1.4.0 — browser-login OAuth is live; interim in-chat login removed

The Commotion backend shipped its full OAuth 2.1 authorization server, so auth is now the automatic
**browser login** the skills always pointed toward — the interim "ask for email + password →
`commotion_login`" stopgap is gone. On first use of the Commotion MCP the client opens a Commotion
login in the browser, the user signs in once, and the token is attached to every call automatically;
the raw credential/token never enters the conversation.

- **Skills no longer collect credentials.** All five `SKILL.md` files drop
  `mcp__commotion__commotion_login` from `allowed-tools` and replace the "sign in first (interim)"
  preamble with the automatic-OAuth wording (never ask for an email/password or a token, never pass a
  `token` argument). `commotion-create-worker/references/api-and-auth.md`'s Auth section is rewritten
  from interim in-session login to the OAuth browser flow, and the optional `token` note is removed.
- **MCP server flipped to the Path B end-state** (`commotion-mcp` repo). `interim_mode` is now off:
  `/mcp` is an OAuth resource server that emits the RFC 9728 `401` challenge (so the client opens the
  browser), advertises the BE authorization server
  (`https://auth-tier0.dev3.gocommotion.com/auth/oauth/mcp`) in
  `/.well-known/oauth-protected-resource`, and forwards the bearer to Kong. The token verifier is now
  **decode-and-forward** — the BE issues HS256 JWTs with no JWKS, so it enforces `exp` and forwards
  the token (Kong/BE are the real authorization gate) rather than verifying an RS256/JWKS signature.

## 2026-07-22 — 1.3.0 — migrate to the redesigned Guardrails API + new safety layers

The backend shipped a redesigned Guardrails schema (dev3 Swagger `/v3/api-docs/public`). Guardrails
still live on `AiWorkerRequest.guardrailConfigRequest` set via `POST`/`PUT /aiworker` — transport, the
draft gate, and the inbound-vs-outbound direction philosophy are unchanged — but the nested shape
changed in breaking ways and gained new safety features. The skills documented the old shape, so they
would have built invalid/outdated payloads. All guardrail-facing skill text is updated to the new
schema and the two new capabilities are now taught.

- **Breaking schema fixes** (`commotion-create-worker/references/control-and-reliability.md` + Phase 3):
  - **Toxicity** — `toxicityDetectionMethod:"LLM_BASED_DETECTION"` → `toxicityDetectionModel:"QWEN3_GUARD"`;
    float `toxicityThresholds` → per-category boolean `toxicityCategories`; `actionOnToxicityDetection`
    removed.
  - **Forbidden words** — flat `forbiddenWordsConfigRequestList` → grouped
    `forbiddenWordGroupsConfigRequest:{enabled, wordGroups:[{words, fallbackMessage, endCallOnDetection}]}`.
  - **PII** — `piiByCommotionEnabled`/`piiByCommotionConfigList` → `builtInPiiCategoryConfigRequest`
    (`enabled` + `builtInCategories:[{category, action}]`); regex items gain `maskingRegex`.
  - **Custom checks** — added `inboundEnabled`/`outboundEnabled`/`isVoiceEnabled` toggles + item-level
    `endCallOnDetection`.
- **New safety features now taught**:
  - **`advancedSafetyConfigRequest`** — `manipulationDetectionEnabled` (first-class prompt-injection /
    jailbreak / social-engineering defense) and `focusGuardrailEnabled` (anti-drift / scope re-alignment).
    Wired into Phase 3's interview, the improve-worker symptom→fix table, and the run-evals signal list.
  - **Voice-only controls** — `executionMode` (`STREAMING`/`BLOCKING`), `endCallOnDetection` across
    toxicity / forbidden groups / custom rules, and audio masking for call recordings
    (`audioMaskingConfigRequest`).
- **Scenario coverage** (`commotion-generate-scenarios/SKILL.md`) — adds prompt-injection /
  social-engineering and scope-drift scenarios so the new advanced-safety layers get exercised.
- The category names for `toxicityCategories` and `builtInCategories[].category` remain **dynamic** —
  the skills continue to ground them in `GET /aiworker/metadata`, not hard-coded enums.
- **Verified live** — round-tripped all six blocks on chat + voice draft workers, and drove a deployed
  worker through `POST /aiworker/run` against a no-guardrail control. Findings now baked into the skills:
  the blocking guardrails (toxicity, forbidden-word groups, inbound custom, manipulation detection) do
  **intercept** the tripping input (control worker succeeded on the same inputs); however a block
  currently returns `status:"FAILED"` with a generic *"reference number"* error instead of the
  configured fallback text — a **known code-side/backend bug**, not the guardrail contract, so the skills
  flag it as such and steer guardrail-UX verification to the delivered channel rather than the sync run
  API. PII masking is **not** applied on the sync text run API either; `regexPatternEnabled` is required
  whenever `piiMaskingConfigRequest` is present. All test workers were deleted afterwards. Guardrail
  **endpoints/auth are unchanged** (still `POST`/`PUT /aiworker`), so `api-and-auth.md` needed no
  guardrail change — but its `/aiworker/run` note was corrected with two runtime requirements found while
  testing: a run needs an identity (`userId`/`fingerprintId`/`audienceId`) and a deployed worker with an
  enabled agent.

## 2026-07-22 — 1.2.1 — close production-worker gaps: state vars, quality-loop handoff, guardrail direction

Three gaps surfaced from a real production build (a flight-booking worker) where the model built the
worker/agents/tools/prompt correctly but (a) never added **state variables**, (b) stopped at build
without running the **sim → eval → improve** loop, and (c) configured mostly **outbound** guardrails
when **inbound** is what a transactional worker needs. All three were traced to skill wording that let
those steps be skipped; no new endpoints.

- **State variables are decided during the interview, not forgotten at the end**
  (`commotion-create-worker/SKILL.md`). Phase 1's capability checklist now explicitly asks whether the
  worker must remember caller-provided values (so it doesn't re-ask) or pre-load profile/account/booking
  data — with booking/renewal/lookup flagged as almost-always-yes. Phase 8.5 gained a "state it out
  loud before moving on" forcing line, and the execution-rules note now separates 8.5's two halves:
  **state variables are frequently *necessary***, while **pronunciation** stays the discovered-later one.
- **A build no longer dead-ends before it's proven.** `commotion-quality-loop`'s description now names
  *production / production-ready worker / long detailed problem statement* as its default entry point,
  so a production statement routes to build+test+improve instead of build-only. `commotion-create-worker`
  gained the **`Skill`** tool and its Phase 12 is rewritten from a soft "note" into a proactive
  `AskUserQuestion` that offers to hand the built worker to `commotion-quality-loop` (which handles the
  deployed-voice prerequisite) — for a production use case, testing is mandatory, not a footnote.
- **Inbound vs outbound guardrails are now taught, with the correct default**
  (`commotion-create-worker/SKILL.md` Phase 3 + `references/control-and-reliability.md`). `inbound`
  filters the caller's message; `outbound` filters the model's own output. The model already has
  provider-side safety training, so **default to inbound-only for toxicity** and enable outbound only
  when the model's *own text* is the risk (PII echo-back, competitor/confidential terms it might say, a
  "never say/advise X" rule). Custom checks are directed to the right side ("don't accept X" → inbound;
  "never say X" → outbound); PII masking inherently covers both. The reference calls out the exact
  anti-pattern (outbound-heavy config on a transactional worker) and the recipe now shows inbound-only
  by default.

## 2026-07-21 — 1.2.0 (refinements) — use-case-driven settings, code-block state vars, prompt-write correctness

A review pass on the 1.2.0 Settings work. No new endpoints — sharper judgment about *when* to reach for
each feature (so the agent prompt stays clean), a code-block ↔ state-variable link that couldn't be wired
before the variable API existed, a prompt-update mechanics correction, and verified-live updates.

- **Feature selection is use-case-driven, not blanket-optional** (`commotion-create-worker/SKILL.md`).
  Phase 8.5 reframed: **state variables** are frequently *necessary* (remember caller data / don't
  re-ask / pre-load profile) — defining one keeps that out of the prompt instead of bloating it;
  **pronunciation dictionaries** stay optional and are usually *discovered from a simulation run* rather
  than pre-guessed. The execution-rules note now frames Phases 7/8/8.5 as "run when the goal calls for
  it," and ties guardrails/forbidden-words to the same design-then-tune-from-sims discipline.
- **Simulation runs as a diagnostic signal.** `commotion-run-evals/references/simulation-and-results.md`
  gains a "reading a run for settings signals" section — a mispronunciation shows in the **transcript**
  as a tester-bot ASR mismatch (not in the score); re-asked/forgotten data → a state variable; an
  off-limits or over-blocked answer → a guardrail tune. `improvement-loop.md` notes the transcript cue
  for mispronunciation alongside `evaluationReasoning`.
- **Code-block tools ↔ state variables** (`tools-and-capabilities.md`). Documented that a code-block's
  `stateVariables[].id` is the variable's **`id`** from `POST /ai-worker-variable-schema` (create it in
  Phase 8.5 first), that the UI equivalent is the **`@variable`** insert, and that one variable is
  consumable two ways — the prompt token `[var:<title>]` and a code-block `stateVariables[]` entry.
- **Prompt-write correctness (POST vs PUT).** Every *newer* spot that bound a `[var:]`/`[tool:]`/
  `[knowledge:]` token via a bare `PUT /aiagent/{id}` now points at the canonical Phase-6 rule: compose
  the token into `instructions` and **(re-)`POST`** so the prompt renders in the UI — a bare `PUT` writes
  the runtime only and leaves the editor stale. **Verified live 2026-07-21:** a `PUT` on the
  auto-provisioned default left the UI prompt editor **blank**; a fresh `POST` **rendered** the prompt
  (with `[var:]`/`[tool:]` tokens shown as plain text, not chips). Corrected two agent types too:
  **structured-output** now uses the same **delete-default + `POST`** flow (verified `POST /aiagent`
  accepts `STRUCTURED_OUTPUT` → 200) so its prompt renders; **FAQ** is the sole exception — `POST /aiagent`
  rejects FAQ types and `/aiagent/standard` has no `instructions` field, so FAQ instructions are
  `PUT`-only and never render in the UI editor (edit in the UI for visibility). The single-agent
  "common case" recipe was also switched from PUT-enabling the default to delete-default + POST.
- **Verified-live updates** (`settings-variables-pronunciation.md`): the TTS **applies** a pronunciation
  entry and an **`EXTRACTED`** variable **is populated** from a real call — both verified;
  `LOADED`-fetch stays not-yet-verified. Live A/B on dev3 also confirmed: **code-block ↔ state variable**
  (`stateVariables:[{id}]` binding + `/code-block/run` substitution, where the placeholder injects a
  **pre-quoted literal** — `x = {{[statevar:title]}}`, not `"…"`), and that state variables /
  pronunciation entries render under **Settings** in the UI.

## 2026-07-20 — 1.2.0 — Settings: pronunciation dictionaries + state variables (and eval-domain reconcile)

The backend shipped worker **Settings** APIs the skills didn't cover. Added them to
`commotion-create-worker` (they're worker-definition config, so they extend that skill rather than a
new one) and reconciled the eval-domain endpoint map against the live spec. All grounded in the live
OpenAPI spec (`/v3/api-docs/public`, 215 paths) and verified with real CRUD against a throwaway voice
worker on dev3 (`6a5dce0cff0a5eea9a86c6c9`, draft v0).

- **New reference `settings-variables-pronunciation.md`** (under `commotion-create-worker/references/`)
  + **Phase 8.5** in the SKILL, covering two worker-scoped resources (full CRUD; created on a draft,
  `(worker, version)`-scoped — **not** fields on `AiWorkerRequest`):
  - **Pronunciation dictionaries** (`/ai-pronunciation-dict`, `AiPronunciationDictRequest`) — teach the
    TTS domain terms. `pronunciationType` ∈ `ALIAS`/`IPA`/`CMU`/`SYMBOL`/`PHONEME`; `inputText` unique
    per worker+version. **Gotcha (verified live):** the id comes back as **`pronunciationDictId`**, not
    `id`; a duplicate `inputText` → `400 "… already exists."`
  - **State variables** (`/ai-worker-variable-schema`, `AiWorkerVariableSchemaRequest`) — values tracked
    across a call. `variableSource` `EXTRACTED` (LLM pulls from the conversation) vs `LOADED` (fetched
    from a tool). **Gotchas (verified live):** id comes back as **`id`**; a `LOADED` variable **requires
    `loadingStrategy`** (`400 "Loading strategy is required when variable source is LOADED"`) + a
    `toolReference`; creating a variable does **not** bind it — an agent must reference `[var:<title>]`
    in its prompt (this replaces the old "state appears on its own" note in Phase 8).
- **Knowledge settings** (`/aiworker/km-setting`, `KMSettingUpdateRequest`) documented in
  `knowledge-and-rag.md`: an **auto-provisioned** indexing/embedding/chunking config edited by id —
  `GET /aiworker/km-setting/{workerId}` → read `settingId` → `PUT …/setting/{settingId}`. (This is what
  `KMSettingUpdateRequest` actually is — Knowledge Settings, **not** conversation analysis, which has no
  dedicated endpoint in the current spec.)
- **Eval-domain reconcile** (`eval-domain-api.md`): added the newly-shipped surfaces —
  `/eval-insight-group` (+ `/refresh`, `EvalInsightGroupRequest`; grouped failure-mode analysis),
  `/eval-result/count` and the filterable `/eval-result` list, and `/schedule` (`ScheduleConfigInput`,
  delayed-webhook scheduler). Marked as secondary/analysis surfaces — the loop's gate is still the
  scenario `passRate`. (`PersonalityRequest`'s voice/noise fields — `speakingSpeed`,
  `interruptionLevel`, `backgroundNoise*`, `packetLoss` — were already documented in
  `scenarios-and-personalities.md`, so no change there.)
- **`improvement-loop.md`** failure→fix taxonomy gained two rows: re-asks for known data → define a
  **state variable**; mispronounces a brand/acronym → add a **pronunciation dictionary** entry.
- Endpoint map + `commotion_schema` name list in `api-and-auth.md` extended with the three new families
  (`AiPronunciationDictRequest`, `AiWorkerVariableSchemaRequest`, `KMSettingUpdateRequest`). Bumped
  `plugin.json` / `marketplace.json` to 1.2.0.
- **Not yet verified (need a live conversation, not config round-trip):** that the TTS applies a
  pronunciation entry at runtime, that an `EXTRACTED` variable is populated from a real call, and that a
  `LOADED` variable fetches from its tool. Noted in the new reference's "verified live" block.

## 2026-07-20 — 1.1.0 — Interim in-session login (until the Commotion browser login ships)

Each skill now **signs in in-session** before calling the platform: it asks for the user's Commotion
email + password (`AskUserQuestion`), calls the new **`commotion_login`** MCP tool to get a per-user
access token, and passes that token on every `commotion_request` / `commotion_schema` call — so dev3
attributes actions to the signed-in user. This is a stopgap until the Commotion **browser login**
ships (then auth becomes automatic again, no in-chat credentials). Adds
`mcp__commotion__commotion_login` to each skill's `allowed-tools`; the full flow lives in
`commotion-create-worker/references/api-and-auth.md`.

## 2026-07-10 — 1.0.0 — Transport moves to the thin Commotion MCP server (OAuth)

The skills no longer call dev3 with local scripts and a Kong api-key. All platform I/O now goes
through the **thin Commotion MCP** server (repo `commotion-mcp`), which holds the credential and
proxies each call. Two tools replace the old `scripts/`:

- **`commotion_request`** — one authenticated call: `{ method, path, body? }` → `{ status, body }`
  (a non-2xx is **returned, not thrown**; `path` is relative — the base URL is fixed server-side; the
  request payload is the `body` argument, so there are no temp files). Replaces `commotion_api.sh`.
- **`commotion_schema`** — a bundled request schema by component name: `{ schema_name, refresh? }`.
  Replaces `fetch_schema.sh` (+ `bundle_schema.py`); the spec is bundled server-side.

- **Auth is OAuth, owned by the MCP client — no API key, no "Step 0".** On first use the client opens
  a Commotion login in the browser and attaches the user's token to every call automatically; the raw
  token never enters the conversation. If the tools aren't connected, authorize via `/mcp` →
  **commotion** → Authenticate.
- **`plugin.json`** now registers the MCP server (`mcpServers.commotion`, a hosted HTTP endpoint).
  **Removed** `scripts/` (`commotion_api.sh`, `fetch_schema.sh`, `bundle_schema.py`, `scripts/README.md`)
  and `.env.example` — nothing on the client to configure.
- **All five skills** rewritten: each skill's "Step 0 / Kong key" preamble is gone; every call site
  now uses the two tools; id-threading reads the returned `body` (no `jq`) and poll loops are
  model-driven (no `bash`/`sleep`). `allowed-tools` updated (MCP tools added; `Bash` kept only in
  `create-worker` for the direct Azure Blob presigned-URL byte-PUT, which isn't a dev3 call; `Skill`
  kept in the quality-loop orchestrator). Endpoint maps, schema names, and all behavioural guidance
  are unchanged — only the transport + auth changed.
- **Verified live end-to-end (2026-07-10):** minted an OAuth token through the login flow and drove
  the two MCP tools against dev3 — `commotion_schema`, `GET /aimodel`, **create worker**, **add agent**
  (list → delete default → POST new), and **add a code-block tool** — all succeeded; the eval-domain
  read endpoints (`/scenario/dropdown-config`, `/scenario/intent-values`, `/eval-metric`,
  `/personality`) are reachable too. Confirmed the proxy returns a non-2xx as `{status, body}` rather
  than throwing. New gotcha captured: **worker names are globally unique** — a duplicate `POST
  /aiworker` returns `400 "a worker with the name 'X' already exists"` (now noted in create-worker
  Phase 5).

## 2026-07-07 — 0.6.0 — Add the `code-block` tool kind (sandboxed Python)

dev3 shipped a new AI-worker tool kind — **`code-block`**, custom **Python** run in a sandbox. The
skills previously stated the opposite ("the custom tool is an HTTP wrapper — there is no code mode"),
which is now false. Documented the kind end-to-end and corrected the stale negations, all grounded in
the live spec and a real dev3 probe (created + listed + test-ran + cleaned up a throwaway worker).

- **New endpoints** (in `references/tools-and-capabilities.md` + `references/api-and-auth.md`):
  `POST/PUT /ai-worker-tool/code-block[/{id}]` (create/update, schema `CreateCodeBlockToolRequest`) and
  `POST /ai-worker-tool/code-block/run` (stateless sandbox test-run, schema `RunCodeBlockRequest`).
- **`codeBlockMetadata`:** required `name` (unique in version), `description`, `language` (`PYTHON`
  only), `sourceCode`; optional `hitlMode` (this kind **does** support HITL), `contextPrompt`,
  `outputAsJson`, `toolUsageTypes` (`LLM`/`PRE_LOAD`), and variable refs (`stateVariables[]`,
  `llmVariableIds[]`, `systemVariableIds[]`) referenced in source via `{{[statevar:..]}}` /
  `{{[llmvar:..]}}` / `{{[sysvar:..]}}` placeholders (distinct from the prompt `[var:..]` token).
- **Binding (verified live):** for `CODE_BLOCK`, `actionMetaDataOutputList` is **empty** — the bindable
  name is `codeBlockMetadataOutput.lowerCaseName` (your `name`, used as-is, no numeric suffix). Bind
  with `[tool:<name>]` in the agent's `instructions`.
- **Sandbox limits kept prominent:** no network, no filesystem — external calls still go through a
  `custom-tool`. Updated golden rules 4 (HTTP-vs-code) and 6 (HITL now includes code-block), the
  "picking the kind" table, the per-kind body + recipe, the binding section, and Phase 8 of the SKILL.
- Added `CreateCodeBlockToolRequest` / `RunCodeBlockRequest` to the `fetch_schema.sh` name hints.
  Other skills (`improve-worker` reuses this reference; scenarios/evals/quality-loop) inherit it.
  Bumped to 0.6.0.

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
