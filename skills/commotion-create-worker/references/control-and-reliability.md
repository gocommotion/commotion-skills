# Control & reliability — guardrails, fallback models (and structured output)

The worker-definition dials that make a worker customer-ready: **guardrails** (safety filters),
**fallback models** (resilience), and **structured output** (strict parseable shape). All are fields
on the `AiWorkerRequest` / `AiAgentRequest` — **no new tools**; you set them with `POST /aiworker` /
`PUT /aiworker/{id}` (and, for the structured agent, `PUT /aiagent/{id}`). Ground the valid values in
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

Four independent blocks (set any subset; the ticket's floor is toxicity + PII + forbidden words):

**Toxicity** — `toxicityDetectionConfigRequest` with `inboundMessagesConfiguration` and
`outboundMessagesConfiguration`, each:
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

## Fallback models — chat only (verified live)

**Fallback models are a chat-side feature** — verified live, they are rejected on voice:
- Worker-level on a voice worker → `400 "Worker advanced settings can not be provided when
  voiceEnabled is true."`
- On a `VOICE_AGENT` → `400 "Advanced settings is not supported for VOICE_AGENT type."`

So set fallback on a **chat worker** (`voiceEnabled:false`, worker LM settings) or on a **`CHAT_AGENT`**
member (agent LM settings — works even inside a voice-enabled multi-agent worker). A voice worker's
voice agents use the voice LLM (`workerLLMConfigurationRequest`) and have no fallback list.

`workerAdvancedSettingsRequest.workerLanguageModelSettingsRequest` (chat worker):
`{ maximumOutputTokens, temperature,
   workerLanguageModelConfigurationRequest:{modelCode, providerCode},   // the PRIMARY
   workerFallbackModelConfigurationRequestList:[{modelCode, providerCode}],  // tried in order
   numberOfRetries:0–10 }`.
`modelCode`/`providerCode` come from `GET /aimodel`. **Agent-level fallback** (a `CHAT_AGENT` member)
lives at `advancedSettingsRequest.languageModelSettingsRequest.fallbackModelConfigurationRequestList` —
and here each entry **requires `id` + `modelCode` + `providerCode`** (worker-level entries accept
`modelCode`/`providerCode` alone). `languageModelSettingsRequest` requires `maximumOutputTokens`,
`numberOfRetries`, `reasoningEffortEnabled`. Get the model `id`s from `GET /aimodel` (e.g.
`commotion-medium` = `69fc2c6ece21b786c1e36258`, `gpt-4o-india` = `6a354c1e20939d72a7122099`).

## Recipes

**Guardrails + fallback on a worker (create or update a draft):**
```
GET /aiworker/metadata          # guardrailConfig (categories/ranges, PII behaviours) + llmConfig (retry range)
PUT /aiworker/<id>  { ...keep name/voice/setup..., version:<draft>,
  guardrailConfigRequest:{
    toxicityDetectionConfigRequest:{ inboundMessagesConfiguration:TOX, outboundMessagesConfiguration:TOX },
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
  (disabled); `PUT /aiagent/{id}` added the `schemaFields` schema + enabled it; schema round-tripped.

Also on the **voice** multi-agent worker `6a379970421f279076ad4668` (draft v2): guardrails (toxicity
in+out with custom thresholds, PII Commotion-mask, forbidden words) applied and round-tripped while the
voice/setup config was preserved; a `CHAT_AGENT` "Billing Specialist" member took an agent-level
fallback chain (`gpt-4o-india` → `commotion-large`, retries 2). The voice rejections above (worker
advanced settings + `VOICE_AGENT` advanced settings) were both hit here first.

Limits (need a live conversation, like HITL): that guardrails actually *fire* in order, that the
structured agent *returns* a strict shape, and that a primary-model failure *falls through* — all
runtime behaviours, not assertable from config round-trip alone.
