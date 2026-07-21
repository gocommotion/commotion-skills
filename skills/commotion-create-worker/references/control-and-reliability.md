# Control & reliability — guardrails, fallback models (and structured output)

The worker-definition dials that make a worker customer-ready: **guardrails** (safety filters),
**fallback models** (resilience), and **structured output** (strict parseable shape). All are fields
on the `AiWorkerRequest` / `AiAgentRequest` — **no new tools**; you set them with `POST /aiworker` /
`PUT /aiworker/{id}` (and, for the structured agent, delete the default + `POST /aiagent` so the prompt
renders in the UI — see `agents-and-orchestration.md`). Ground the valid values in
`GET /aiworker/metadata` (`guardrailConfig`, `llmConfig`) and `GET /aimodel`. (Structured output's
agent side lives in `agents-and-orchestration.md`; this file is the worker-config side.)

## Golden rules (verified live against dev3)

1. **These are worker-definition config, set on a DRAFT, shown before write** — same gate as everything
   else. Request fields use `…Request` suffixes; a `retrieve` response uses `…Response` (don't copy a
   response back as a request — map field-by-field, like the voice block).
2. **Guardrail order is backend-enforced.** There is no order knob in the schema — you configure the
   filters (toxicity, PII, forbidden words, custom) and the backend applies them in a fixed, composing
   order (input filters → model → output filters). Don't invent an ordering field.
3. **Structured output is single-agent only.** Setting `structuredOutputEnabled: true` makes the
   worker's auto-provisioned default agent a **`STRUCTURED_OUTPUT`** agent (born **disabled**) — you
   *update* it with the schema and enable it; you do **not** create a second agent.
4. **Fallback ≠ retry.** `numberOfRetries` (0–10) is how many times the **primary** is retried before
   falling through to the next model in the fallback list.

## Guardrails — `AiWorkerRequest.guardrailConfigRequest`

**Design guardrails from the use case — not a fixed template.** Look at what the domain handles and
protect exactly that: a banking/insurance/health bot → PII masking + regex masking for card/account/
Aadhaar/policy numbers; a brand bot → forbidden words for competitors and confidential terms; any
customer-facing bot → toxicity, plus custom checks for domain rules ("no financial/medical
advice"). Pick the subset the use case warrants and justify each. Four independent blocks (set any
subset).

### Inbound vs outbound — decide direction deliberately (verified: they are separate configs)

Every filter that has a direction (`toxicity`, `customGuardrail`) splits into an **inbound** config
(applied to the **caller's** message, before the model sees it) and an **outbound** config (applied to
the **model's own output**, before it's spoken/sent). They are independent — enabling one does **not**
enable the other. Choose per the risk, don't set both by reflex:

- **Inbound is the one you almost always want.** It catches abusive / toxic / jailbreak / prompt-
  injection input and masks PII the caller volunteers. This is the primary line of defence for a
  customer-facing bot.
- **Outbound is usually redundant for toxicity** — the model has provider-side safety training and
  won't emit toxic content unprompted, so an outbound *toxicity* filter mostly adds latency for no
  catch. Enable outbound only when the **model's text itself** is the risk: masking PII it might read
  back, blocking competitor/confidential/off-limits terms in what it *says*, or a "never say / never
  advise X" rule. If you can't name why the output is risky, leave outbound off.
- **Put custom checks on the side that matters.** A "don't *accept* X" rule → `inboundCustomGuardrailConfigs`;
  a "never *say* X" rule → `outboundCustomGuardrailConfigs`. **PII masking is the exception that
  legitimately runs both directions** (mask what the caller says *and* what the model echoes back).

Common failure (the anti-pattern this note exists to prevent): configuring mostly **outbound**
guardrails on a transactional worker (e.g. flight booking) — that leaves abusive/injection *input*
unfiltered while spending latency policing output the model was never going to produce. Flip it:
inbound toxicity + inbound custom checks, outbound only where the output is the actual risk.

**Toxicity** — `toxicityDetectionConfigRequest` with `inboundMessagesConfiguration` and
`outboundMessagesConfiguration` (set the direction(s) you actually need — see above), each:
`{ enabled, toxicityDetectionMethod:"LLM_BASED_DETECTION", toxicityThresholds:{<category>:0.0–1.0},
   actionOnToxicityDetection:"REPLACE_WITH_FALLBACK_MESSAGE", fallbackMessage }`.
Categories (from `metadata.guardrailConfig.toxicityDetections`, default 0.5, step 0.1):
`sensitive_content`, `harmful_behaviour`, `violence_and_crime`, `safety_and_info_security`.

**PII** — `piiMaskingConfigRequest`:
`{ regexPatternEnabled, piiByCommotionEnabled,
   piiMaskingRegexPatternConfigList:[{name, regexPattern, behaviour:"MASK"|"REDACT"}],
   piiByCommotionConfigList:[{actionToBeTaken:"MASK"}] }`.
Use `piiByCommotionEnabled:true` + `[{actionToBeTaken:"MASK"}]` for Commotion's built-in PII detector;
add regex entries for custom patterns. (`MASK` → `****1234`, `REDACT` → `[REDACTED]`.)

**Forbidden words** — `forbiddenWordsConfigRequestList:[{ standardFallbackResponseEnabled,
standardFallbackResponse, forbiddenWords:[…] }]`.

**Custom checks** — `customGuardrailConfigRequest` with `inboundCustomGuardrailConfigs` /
`outboundCustomGuardrailConfigs`, each `{name, description, positiveExample, negativeExample,
fallbackResponse}` (an LLM-judged rule in plain language).

## Models + fallback — where they live depends on channel (verified live)

The **primary model and its fallback both exist for voice and chat — but in different blocks.** The
trap is only `workerAdvancedSettingsRequest`: a voice worker rejects it.

**Voice worker — set the LLM + fallback in the Voice Settings block, NOT advanced settings.** In the
UI this is *Voice Settings → LLM Settings*: Provider, Model, **Fallback Provider / Fallback Credential
/ Fallback Model**, Temperature. Over the API these live under
`workerVoiceSettingsRequest.workerLLMConfigurationRequest` (provider/model/temperature) plus the
voice-settings fallback fields — fetch the exact field names with `commotion_schema` `{ "schema_name":
"AiWorkerRequest" }` (inspect `WorkerVoiceSettingsRequest` / `workerLLMConfigurationRequest`). Do
**NOT** put a voice
worker's models in `workerAdvancedSettingsRequest`:
- `workerAdvancedSettingsRequest` on a voice worker → `400 "Worker advanced settings can not be
  provided when voiceEnabled is true."`
- `advancedSettingsRequest` on a `VOICE_AGENT` → `400 "Advanced settings is not supported for
  VOICE_AGENT type."`
So a voice worker DOES get a fallback model — configure it in Voice Settings, not advanced settings.

**Chat worker — always set the model on the AGENT; that's the only place the UI shows it.** A chat
worker has *two* places a model can be set, and they behave differently (verified live):

- **Worker-level default — drives the runtime, but is NOT shown in the UI.**
  `workerAdvancedSettingsRequest.workerLanguageModelSettingsRequest`:
  `{ maximumOutputTokens, temperature,
     workerLanguageModelConfigurationRequest:{modelCode, providerCode},   // the PRIMARY
     workerFallbackModelConfigurationRequestList:[{modelCode, providerCode}],  // tried in order
     numberOfRetries:0–10 }`. `modelCode`/`providerCode` come from `GET /aimodel`. This config is real
  and round-trips on `GET /aiworker/{id}`, **but a chat worker has no worker-level Language Model panel
  in the UI.** So if you set the model *only* here, the UI's *Language Model* screen (which lives on the
  **agent**) shows **blank** and users conclude it wasn't saved — even though it drives the runtime.

- **Agent-level — this is what the UI shows and edits.** The UI's *Agent → Advanced → Language Model*
  panel reads the **agent** record, so to make the model + fallback **visible/editable in the UI**, set
  them on the agent (`AiAgentRequest`):
  - **PRIMARY → `modelConfigurationRequestList: [{id, modelCode, providerCode}]`** (top-level on
    `AiAgentRequest`; the UI's *Provider / Model*).
  - **FALLBACK → `advancedSettingsRequest.languageModelSettingsRequest.fallbackModelConfigurationRequestList:
    [{id, modelCode, providerCode}]`** (the UI's *Fallback Provider / Model*).
  - Every **agent-level** entry **requires `id` + `modelCode` + `providerCode`** (worker-level entries
    accept `modelCode`/`providerCode` alone). `languageModelSettingsRequest` requires
    `maximumOutputTokens`, `numberOfRetries`, `reasoningEffortEnabled` (optional `temperature`,
    `reasoningEffort`). Get the model `id`s from `GET /aimodel` (e.g. `commotion-medium` =
    `69fc2c6ece21b786c1e36258`, `gpt-4o-india` = `6a354c1e20939d72a7122099`). The response echoes back
    as `modelConfigurationResponseList` + `advancedSettingsResponse.languageModelSettingsResponse`.
  - **Set this on the agent every time a chat worker has a model/fallback — it is the default, not an
    optional extra.** An agent with no override still inherits the worker-level default at runtime, but
    the UI panel shows **blank**, which reads as "not saved" *every time* someone opens it. So don't
    rely on the worker-level config alone: mirror the model + fallback onto the agent so they are always
    visible and editable in the UI (this is also where you'd override the model per-agent).
  - **Editing the agent needs the worker in DRAFT.** If it's already LIVE, the agent `PUT` fails
    `400 "Agent can only be updated/deleted when worker is in draft status."` — revert first
    (`POST /aiworker/{id}/draft?version=N` → a new draft version, live keeps serving), edit the agent on
    that new version, then redeploy (`POST /aiworker/{id}/deploy?version=N`).

**Mixed multi-agent worker (a `VOICE_AGENT` and a `CHAT_AGENT` in one worker) — model config resolves
per agent type (verified live).** In a voice-enabled `MULTI_AGENT` worker that holds both, there is no
single "worker model" that every agent shares — each agent resolves by its own type:
- **`VOICE_AGENT` → the worker's Voice-Settings LLM.** It **cannot** hold its own model config:
  `advancedSettingsRequest` on a `VOICE_AGENT` is rejected (`400 "Advanced settings is not supported for
  VOICE_AGENT type."`), so it draws its brain (and fallback) from the worker's
  `workerVoiceSettingsRequest.workerLLMConfigurationRequest` (the *Voice Settings → LLM Settings* block).
  (The `advancedSettingsRequest` path is the verified rejection; a top-level `modelConfigurationRequestList`
  override on a `VOICE_AGENT` hasn't been tested — assume the voice agent follows the worker LLM.)
- **`CHAT_AGENT` member → its own agent-level config.** It carries its own primary + fallback exactly as
  the chat-worker case above (`modelConfigurationRequestList` + `advancedSettingsRequest.languageModelSettingsRequest`),
  and that's what the UI's *Agent → Advanced → Language Model* panel shows/edits for it.

Verified live on the voice multi-agent worker `6a379970421f279076ad4668`: its `CHAT_AGENT` "Billing
Specialist" member took an agent-level fallback chain (`gpt-4o-india` → `commotion-large`, retries 2)
while the `VOICE_AGENT` advanced-settings and `workerAdvancedSettingsRequest` calls were both rejected —
i.e. the voice side falls back to the worker's Voice-Settings LLM, the chat side owns its own.

## Recipes

**Guardrails + fallback on a worker (create or update a draft):**
```
GET /aiworker/metadata          # guardrailConfig (categories/ranges, PII behaviours) + llmConfig (retry range)
PUT /aiworker/<id>  { ...keep name/voice/setup..., version:<draft>,
  guardrailConfigRequest:{
    # inbound-only by default; add outboundMessagesConfiguration:TOX ONLY if the model's own output is a risk
    toxicityDetectionConfigRequest:{ inboundMessagesConfiguration:TOX },
    piiMaskingConfigRequest:{ regexPatternEnabled:false, piiByCommotionEnabled:true,
      piiMaskingRegexPatternConfigList:[], piiByCommotionConfigList:[{actionToBeTaken:"MASK"}] },
    forbiddenWordsConfigRequestList:[{ standardFallbackResponseEnabled:true,
      standardFallbackResponse:"I can't discuss that.", forbiddenWords:["…"] }] },
  workerAdvancedSettingsRequest:{ workerLanguageModelSettingsRequest:{
    workerLanguageModelConfigurationRequest:{modelCode:"commotion-medium",providerCode:"commotion"},
    workerFallbackModelConfigurationRequestList:[{modelCode:"gpt-4o-india",providerCode:"azure_openai"}],
    numberOfRetries:1 } } }
# TOX = { enabled:true, toxicityDetectionMethod:"LLM_BASED_DETECTION",
#         toxicityThresholds:{sensitive_content:0.5,harmful_behaviour:0.5,violence_and_crime:0.5,safety_and_info_security:0.5},
#         actionOnToxicityDetection:"REPLACE_WITH_FALLBACK_MESSAGE", fallbackMessage:"Sorry, I can't help with that." }
```

Remember `PUT /aiworker/{id}` is a **full PUT** — resend the worker's existing top-level fields (name,
`voiceEnabled`, `agentSetupType`, voice block) or they reset.

## Verified live (worker `6a3ad4c71778706cdf8df295`, draft v0)

One `SINGLE_AGENT` worker created with all three dials → all round-tripped on
`GET /aiworker/{id}?version=0`:
- Guardrails: toxicity inbound+outbound enabled, PII (Commotion, MASK), forbidden words
  `["acmerival","secretproject"]` — all four `…Response` blocks present.
- Fallback: primary `commotion-medium`, fallback `gpt-4o-india`/`azure_openai`, `numberOfRetries:1`.
- Structured output: `structuredOutputEnabled:true` → default agent auto-born `STRUCTURED_OUTPUT`
  (disabled); delete the default + `POST /aiagent` a fresh `STRUCTURED_OUTPUT` agent with the
  `schemaFields` schema (verified live: `POST /aiagent` accepts `STRUCTURED_OUTPUT` → 200, so the prompt
  renders in the UI; a `PUT` on the default sets the runtime only). Schema round-trips intact.

Also on the **voice** multi-agent worker `6a379970421f279076ad4668` (draft v2): guardrails (toxicity
in+out with custom thresholds, PII Commotion-mask, forbidden words) applied and round-tripped while the
voice/setup config was preserved; a `CHAT_AGENT` "Billing Specialist" member took an agent-level
fallback chain (`gpt-4o-india` → `commotion-large`, retries 2). The voice rejections above (worker
advanced settings + `VOICE_AGENT` advanced settings) were both hit here first.

Also on the **chat** single-agent worker `6a48a082f731d86f4fec0067` (agent `6a48a0aa0598df4d16e7e091`):
the worker-level LLM (`gpt-4o-india` primary / `commotion-medium` fallback, 1 retry) round-tripped but
rendered **blank** on the agent's *Advanced → Language Model* UI panel. Setting the same config on the
**agent** — `modelConfigurationRequestList:[{id,modelCode:"gpt-4o-india",providerCode:"azure_openai"}]`
plus `advancedSettingsRequest.languageModelSettingsRequest.fallbackModelConfigurationRequestList:
[{id,modelCode:"commotion-medium",providerCode:"commotion"}]` (retries 1, maxTokens 1024, temp 0.3) —
made both the primary and fallback **appear and stay editable in the UI**. The worker was LIVE, so the
agent `PUT` first failed the draft-status check; reverting to a fresh draft (v1), editing the agent
there, and re-reading confirmed the round-trip.

Limits (need a live conversation, like HITL): that guardrails actually *fire* in order, that the
structured agent *returns* a strict shape, and that a primary-model failure *falls through* — all
runtime behaviours, not assertable from config round-trip alone.
