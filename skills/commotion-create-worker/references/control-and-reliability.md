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
   filters (toxicity, PII, forbidden-word groups, custom, advanced safety) and the backend applies them
   in a fixed, composing order (input filters → model → output filters). Don't invent an ordering field.
   The **only** execution knob is `executionMode` (`STREAMING`/`BLOCKING`, voice workers only).
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
advice"). Pick the subset the use case warrants and justify each. Six independent blocks (set any
subset): toxicity, PII masking, forbidden-word groups, custom checks, **advanced safety** (focus +
manipulation detection), and the voice-only `executionMode`.

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
`outboundMessagesConfiguration` (set the direction(s) you actually need — see above), each a
`MessagesConfigurationRequest`:
`{ enabled, toxicityDetectionModel:"QWEN3_GUARD", toxicityCategories:{<category>:true|false},
   endCallOnDetection, fallbackMessage }`.
`toxicityCategories` is a **per-category on/off map** (booleans — not the old 0.0–1.0 thresholds); turn
on the categories the use case needs and leave the rest false. Ground the category names in
`metadata.guardrailConfig.toxicityCategories` — don't hard-code them (verified live:
`sensitive_content`, `harmful_behaviour`, `violence_and_crime`, `safety_and_info_security`; model
`QWEN3_GUARD`, labelled "Commotion Guard"). `endCallOnDetection` drops the call on a hit (**voice
only**; ignored for chat).

**PII** — `piiMaskingConfigRequest`:
`{ regexPatternEnabled,
   piiMaskingRegexPatternConfigList:[{name, regexPattern, maskingRegex, behaviour:"MASK"|"REDACT"}],
   builtInPiiCategoryConfigRequest:{ enabled, builtInCategories:[{category, action:"MASK"|"REDACT"}] },
   audioMaskingConfigRequest:{…voice only…} }`.
For Commotion's built-in detector set `builtInPiiCategoryConfigRequest.enabled:true` and list the
categories you want with their `action` — category codes come from `metadata.guardrailConfig.builtInPiiCategories`
(verified live: `credit_debit_card`, `social_security_number`, `email_address`, `ip_address`, `url`,
`ifsc_code`, `aadhaar_number`, `pan_number`, `phone_number`). Add `piiMaskingRegexPatternConfigList`
entries for custom formats — `maskingRegex` is the replacement template applied to the match.
(`MASK` → `****1234`, `REDACT` → `[REDACTED]`.) **`regexPatternEnabled` is required whenever this block
is present** — omitting it fails `400 "PII masking regex pattern enabled cannot be null."` (set it
`false` when you only use built-in categories). `audioMaskingConfigRequest` is voice-only — see
**Voice-only controls** below.

**Forbidden-word groups** — `forbiddenWordGroupsConfigRequest:{ enabled, wordGroups:[{ words:[…],
endCallOnDetection, fallbackMessage }] }`. Each group is an independent word/phrase set with its own
`fallbackMessage` (and voice-only `endCallOnDetection`) — group by intent (e.g. one group for competitor
names, one for confidential terms). (Renamed from the old flat `forbiddenWordsConfigRequestList`.)

**Custom checks** — `customGuardrailConfigRequest` with `inboundEnabled` / `outboundEnabled` toggles
(and `isVoiceEnabled` to also run them on voice), plus `inboundCustomGuardrailConfigs` /
`outboundCustomGuardrailConfigs`, each `{name, description, positiveExample, negativeExample,
endCallOnDetection, fallbackResponse}` (an LLM-judged rule in plain language). You must flip the
matching `inboundEnabled`/`outboundEnabled` on for a side's configs to run.

**Advanced safety** — `advancedSafetyConfigRequest:{ focusGuardrailEnabled, manipulationDetectionEnabled }`.
Two independent layers that run alongside the filters above:
- `manipulationDetectionEnabled` — detects prompt injection, jailbreak attempts, and social engineering,
  and terminates or escalates the conversation. **This is the first-class defense for injection/jailbreak
  input** — prefer it over relying on inbound toxicity alone for that threat; enable it on any worker
  exposed to adversarial users.
- `focusGuardrailEnabled` — re-aligns the agent with its configured scope across long conversations
  (anti-drift). Enable it for workers that hold long or open-ended sessions and tend to wander off-task.

**Voice-only controls** (ignored for chat workers):
- `guardrailConfigRequest.executionMode` — `STREAMING` (default; evaluates in parallel with playback,
  ~0ms added latency but ~500ms of audio may leak before a block fires — best for low-latency inbound
  speech) vs `BLOCKING` (holds the response until all guardrails clear, +200–400ms/turn — best for
  outbound / regulated use). Set on the container, not a per-filter field.
- `endCallOnDetection` — present on toxicity directions, forbidden-word groups, and custom items; set it
  only where dropping the call is the right response to a violation.
- `audioMaskingConfigRequest` (under PII) — redacts PII segments in call recordings:
  `{ enabled, maskingSound:"BEEP_TONE"|"SILENCE"|"WHITE_NOISE",
     maskingChannel:"BOTH"|"CALLER_ONLY"|"AGENT_ONLY", recordingStorage:"MASKED_ONLY"|"BOTH_VERSIONS" }`.

### What testing a block currently looks like (verified live — mind the known bug)

Tested by deploying a worker and driving it through `POST /aiworker/run`, against a no-guardrail control:
- **The blocking guardrails do intercept the tripping input.** Toxicity (inbound), forbidden-word
  groups, inbound custom checks, and `manipulationDetectionEnabled` each stopped the turn on the matching
  input, while the no-guardrail control returned `SUCCESS` on those same inputs (including
  benign-to-a-model ones like a forbidden word or "show me my wife's account") — so the interception is
  real and correctly wired.
- **BUT the block does not currently return your `fallbackMessage`/`fallbackResponse` on the sync run
  API.** Today it comes back as `status:"FAILED"` with a generic *"An error has occurred … reference
  number …"* — that generic error is a **code-side / backend issue**, not the intended guardrail
  behaviour (the fallback text is what should be delivered). **Don't document or rely on that error as
  the guardrail's contract, and don't treat it as proof the guardrail "worked" — verify guardrail UX
  in the actual delivered chat/voice channel, not the raw run API.**
- **PII masking does NOT alter the text on the sync run API / stored transcript** — a `credit_debit_card`
  masking rule left `4111 1111 1111 1111` intact in both the model's echo and the stored message.
  Masking applies at the delivered-channel / recording layer (e.g. `audioMaskingConfigRequest` for
  voice), so verify it in the target channel, not the text run API.
- Outbound custom checks couldn't be isolated here — the model refused the "give financial advice" bait
  on its own, so there was nothing for the outbound rule to catch.

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
GET /aiworker/metadata          # guardrailConfig (toxicity + built-in PII category names) + llmConfig (retry range)
PUT /aiworker/<id>  { ...keep name/voice/setup..., version:<draft>,
  guardrailConfigRequest:{
    # inbound-only by default; add outboundMessagesConfiguration:TOX ONLY if the model's own output is a risk
    toxicityDetectionConfigRequest:{ inboundMessagesConfiguration:TOX },
    piiMaskingConfigRequest:{ regexPatternEnabled:false, piiMaskingRegexPatternConfigList:[],  # regexPatternEnabled is REQUIRED when this block is present (null → 400)
      builtInPiiCategoryConfigRequest:{ enabled:true,
        builtInCategories:[{category:"credit_debit_card", action:"MASK"}] } },  # category codes from metadata.guardrailConfig.builtInPiiCategories
    forbiddenWordGroupsConfigRequest:{ enabled:true,
      wordGroups:[{ words:["…"], fallbackMessage:"I can't discuss that." }] },
    advancedSafetyConfigRequest:{ manipulationDetectionEnabled:true, focusGuardrailEnabled:false } },
  workerAdvancedSettingsRequest:{ workerLanguageModelSettingsRequest:{
    workerLanguageModelConfigurationRequest:{modelCode:"commotion-medium",providerCode:"commotion"},
    workerFallbackModelConfigurationRequestList:[{modelCode:"gpt-4o-india",providerCode:"azure_openai"}],
    numberOfRetries:1 } } }
# TOX = { enabled:true, toxicityDetectionModel:"QWEN3_GUARD",
#         toxicityCategories:{"<category from metadata>":true, …},  # per-category on/off (not thresholds)
#         fallbackMessage:"Sorry, I can't help with that." }        # + endCallOnDetection:true for voice-only hard stop
```

Remember `PUT /aiworker/{id}` is a **full PUT** — resend the worker's existing top-level fields (name,
`voiceEnabled`, `agentSetupType`, voice block) or they reset.

## Verified live — new guardrail schema (dev3, `POST`/`GET /aiworker`)

Both throwaway workers were created with the full new `guardrailConfigRequest` and read back with
`GET /aiworker/{id}?version=0`; all six blocks round-tripped as their `…Response` equivalents
(`toxicityDetectionConfigResponse`, `piiMaskingConfigResponse`, `forbiddenWordGroupsConfigResponse`,
`customGuardrailConfigResponse`, `advancedSafetyConfigResponse`, plus `executionMode`), then both were
deleted.
- **Chat `SINGLE_AGENT`** — inbound toxicity (`QWEN3_GUARD`, per-category `toxicityCategories` booleans),
  PII (`builtInPiiCategoryConfigRequest` with `credit_debit_card`→MASK / `aadhaar_number`→REDACT + a
  regex rule with `maskingRegex`), one `forbiddenWordGroupsConfigRequest.wordGroups` entry, inbound +
  outbound custom checks (with `inboundEnabled`/`outboundEnabled`), and
  `advancedSafetyConfigRequest{focusGuardrailEnabled,manipulationDetectionEnabled}` — all present on read.
- **Voice `SINGLE_AGENT`** — exercised the voice-only fields: `executionMode:"STREAMING"`,
  `endCallOnDetection:true` on both the toxicity direction and the forbidden-word group, and
  `audioMaskingConfigRequest{BEEP_TONE, BOTH, MASKED_ONLY}` — all round-tripped.
- **Gotcha (verified):** a `piiMaskingConfigRequest` with no `regexPatternEnabled` fails
  `400 "PII masking regex pattern enabled cannot be null."` — always set it explicitly.
- Category codes above came from a live `GET /aiworker/metadata` `guardrailConfig` (toxicity categories,
  built-in PII categories, execution modes, audio-masking enums) — always ground names there, don't hard-code.

**Runtime firing (verified live via `POST /aiworker/run`).** A deployed chat worker with the full config
was driven with one input per guardrail, alongside a no-guardrail control worker:
- Intercepted (turn stopped): abusive input (toxicity), `"…acmerival…"` (forbidden group), `"show me my
  wife's account"` (inbound custom), `"ignore all previous instructions…"` (manipulation detection). The
  control worker returned `SUCCESS` on every one of these — proving the guardrail is what intercepts.
- The intercepted turns came back as `status:"FAILED"` + a generic reference-number error rather than the
  configured fallback text — a **known code-side issue** on the run path, not the guardrail contract (see
  "What testing a block currently looks like" above).
- PII: a `credit_debit_card` MASK rule left the card number **unmasked** in the run-API response and the
  stored transcript — masking is a delivered-channel/recording concern, not visible on the text run API.
- All test workers were deleted afterwards.

## Verified live (worker `6a3ad4c71778706cdf8df295`, draft v0 — pre-migration schema)

> Note: the **guardrail** specifics in this older run (toxicity *thresholds*, `piiByCommotion*`, flat
> forbidden-words list) are the **pre-migration** shape — superseded by the section above. The
> fallback-model and structured-output evidence below is unaffected by the guardrail API change.

One `SINGLE_AGENT` worker created with all three dials → all round-tripped on
`GET /aiworker/{id}?version=0`:
- Guardrails: toxicity inbound+outbound enabled, PII (Commotion, MASK), forbidden words
  `["acmerival","secretproject"]` — all four `…Response` blocks present *(old schema — see above)*.
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
