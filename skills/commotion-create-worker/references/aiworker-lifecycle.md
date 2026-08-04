# dev3 aiworker lifecycle — draft/live, versions, and the sharp edges

Operational behavior of the `/aiworker` backend, reached through the two Commotion MCP tools
(`commotion_request` / `commotion_schema` — see `api-and-auth.md`). Read this when a create / update /
deploy call behaves unexpectedly. Field *shapes* come from `commotion_schema` `{ "schema_name":
"AiWorkerRequest" }`; this file is the *behavior* the schema doesn't tell you. Agent specifics live in
`agents-and-orchestration.md`.

## Endpoints

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/aiworker` | create → DRAFT v0 |
| PUT | `/aiworker/{id}` | update the draft (full PUT; body needs `version`) |
| POST | `/aiworker/{id}/deploy?version=N` | deploy version N → LIVE |
| POST | `/aiworker/{id}/draft?version=N` | revert a live worker to a new editable draft |
| GET | `/aiworker` | list (live + draft) |
| GET | `/aiworker/{id}` | retrieve **live** (`?version=N` for a specific version) |
| GET | `/aiworker/{id}/versions` | version history |
| GET | `/aiworker/metadata` · `/aimodel` | valid values / supported **language** models |
| GET | `/aiworkervoice?providerId=&modelId=&languageId=&accentId=` | **the TTS voice catalogue** (`voiceId`, `voiceName`, sample audio) — one word, no separator |

## State machine

```
POST /aiworker                        -> DRAFT, version 0     (auto-provisions a default agent, DISABLED)
PUT  /aiagent/{id} | POST /aiagent    -> edit agents          (only while the worker is a DRAFT)
PUT  /aiworker/{id}  (body w/ version)-> edit the draft       (full PUT; needs `version`)
POST /aiworker/{id}/deploy?version=0  -> LIVE, version 0
```

Editing something that is already **LIVE**:

```
POST /aiworker/{id}/draft?version=0
        -> creates a NEW editable DRAFT version (e.g. v1) alongside the still-serving LIVE v0
edit the draft (worker config and/or its agents) at that new version
POST /aiworker/{id}/deploy?version=1  -> the draft becomes LIVE; the old version is superseded
```

`GET /aiworker/{id}/versions` shows the history, one entry per version with its `status`
(`LIVE` / `DRAFT`). Only **one draft can exist at a time** per worker.

## The edges

- **A new worker is DRAFT v0 and comes with a default agent, disabled.** It is not usable until that
  agent is enabled (`aiAgentEnabled: true`). See `agents-and-orchestration.md`.
- **`agentSetupType` is required on create** (`SINGLE_AGENT` / `MULTI_AGENT` / `WORKFLOW`); blank →
  `400 "Agent setup type cannot be blank"`. It **can be changed later via `PUT /aiworker/{id}`, but
  only while the worker is a draft** (verified: a SINGLE_AGENT draft was switched to MULTI_AGENT,
  then redeployed).
- **Update is a full PUT and needs `version`.** `PUT /aiworker/{id}` requires the current `version` in
  the body (`0` for a fresh worker, or the draft's version when editing a live worker's draft) — else
  `400 "version is required for update"`. It replaces the record, so resend the top-level fields you
  want to keep (`name`, `workerGoal`, `workerLevelPrompt`, `agentSetupType`, `voiceEnabled`, the
  voice block) or they reset.
- **Deploy targets a version.** A fresh worker's first deploy is `version=0`. When you revert a live
  worker to a draft, the draft gets a **new** version number (e.g. 1); deploy *that* version to go
  live. Workers can be LIVE at version 0.
- **`GET /aiworker/{id}` is LIVE-only.** A draft-only worker returns `400 "Live Worker not found"`.
  Read drafts from `GET /aiworker` (list), or fetch a specific version with `GET /aiworker/{id}?version=N`.

## Voice + language config

Languages and the TTS voice live under the voice settings block of the `AiWorkerRequest`:

```
workerVoiceSettingsRequest:
  voiceAgentPipelineType: "SPEECH_TO_SPEECH"   # live options (GET /aiworker/metadata voiceConfig):
                                               #   HALF_CASCADE / SPEECH_TO_SPEECH (default) / COLLOQUIAL
  workerVoiceConfiguration:
    allowedLanguages: ["en", "hi"]             # every language the worker may speak
    language: "English-Indian"
    defaultLanguage: "en"
    model:    "<tts model>"                    # REQUIRED — e.g. commotion-laya-v1-5
    provider: "<tts provider>"                 # REQUIRED — e.g. commotion-tts
    voiceId:  "<voice id>"                      # REQUIRED — a UUID
  workerTranscriptConfiguration: { provider, model, temperature, prompt }   # optional; defaults stand
  workerLLMConfigurationRequest: { provider, model, temperature, + fallback fields }  # the voice worker's LLM lives HERE
```

**For a voice worker, the LLM (brain) AND its fallback model are configured in this voice block**
(`workerLLMConfigurationRequest`) — this is the UI's *Voice Settings → LLM Settings → Provider /
Model / Fallback Provider / Fallback Model*. Do NOT use `workerAdvancedSettingsRequest` on a voice
worker (it's rejected). Inspect the exact fallback field names with `commotion_schema` `{ "schema_name":
"AiWorkerRequest" }` (`WorkerVoiceSettingsRequest`). See `references/control-and-reliability.md`
("Models + fallback").

**Verified-good en+hi block (mirror this — created + deployed live, S2S):** `provider:
"commotion-tts"`, `model: "commotion-laya-v1-5"`, `voiceId:
"d6d81480-227c-41cd-af4e-f483262cef0b"` (that UUID is the voice **Poornima** — pick deliberately from
`GET /aiworkervoice`, don't paste it blindly; see "Choosing a voice" below).
`commotion-laya-v1-5` covers `en, hi, kn, mr, ta, te, ml, bn, pa, gu`. Sending **only**
`voiceAgentPipelineType` + `workerVoiceConfiguration` on create is enough — the transcript/LLM
sub-blocks default. The full provider→model→language map lives in
`GET /aiworker/metadata` → `voiceConfig.voicePipelineTypeConfig`.

## Providers and credentials — use `commotion-*` only (verified live 2026-08-03)

**Rule: over the API, always pick a Commotion first-party provider for TTS, STT and the LLM. Never set a
non-Commotion provider, and never set a provider/model without its credential.**

`GET /aiworker/metadata` → `voiceConfig` offers external providers (TTS: `eleven-labs`, `cartesia`,
`sarvam`, `smallest-ai`; STT: `eleven-labs`, `sarvam`), and `/aimodel` offers `openai`, `anthropic`,
`cerebras`, `vayu`. **Those all require a client provider credential, and the API gives you no way to
attach one:**

| Block | Schema | Credential field? |
|---|---|---|
| TTS voice | `WorkerVoiceConfigurationRequest` | **none** |
| STT | `WorkerTranscriptConfigurationRequest` | **none** |
| Voice LLM | `WorkerLLMConfigurationRequest` | **none** |
| Worker primary LLM | `WorkerLanguageModelConfigurationRequest` | **none** |
| Worker LLM *fallback* | `WorkerFallbackModelConfigurationRequest` | `credentialId` ✅ |
| Agent LLM *fallback* | `FallbackModelConfigurationRequest` | `credentialId` ✅ |
| Simulator / eval-metric LLM | `LLMConfig` | `voiceProviderCredentialId` ✅ |

`AiModelResponse.credentialId` is documented as *"ID of the ClientProviderCredential this model is tied
to. **Null for platform models**"*, and there is **no endpoint that lists or creates those credentials**
(`/ai-worker-tool/credentials` is the SaaS-connector plane — unrelated). So a non-Commotion STT/TTS/LLM
choice can only ever be written **credential-less**.

**The backend does not stop you — that is the trap.** Verified live: a `PUT /aiworker` setting
`provider: "eleven-labs"` for both TTS (`eleven_multilingual_v2`) and STT (`scribe_v2`) returned
**`200` with no error and no warning**, and the round-tripped response contained **no credential field
at all**. In the UI that renders as *Provider: Eleven Labs · Credential: "Select credential" (blank) ·
Model: filled* — a saved-but-unrunnable config.

So:
- **Do** use `commotion-tts` (TTS), `commotion-llm` / `commotion-asr` (STT), `commotion` (LLM). These are
  platform models, need no credential, and are the only combination that works end-to-end over the API.
  Verified-good trio: TTS `commotion-tts` / `commotion-laya-v1-5`; STT `commotion-llm` / `commotion-omni`;
  LLM `commotion` / `commotion-3.6-35b` (the `isDefault: true` model in `/aimodel`).
- **Don't** write a non-Commotion provider "to be fixed later", and **never backfill the model while
  leaving the credential blank** — a half-set block is worse than an unset one, because the defaults no
  longer apply and nothing flags it.
- If the user explicitly asks for ElevenLabs/Cartesia/Sarvam/OpenAI/Anthropic for STT/TTS/LLM: **say it
  must be done in the UI** (the credential can't be bound over the API), leave the block on Commotion
  or unset, and change nothing else. Only a **fallback** LLM can take a BYOK `credentialId`, and only
  when you already have that id — find it with `GET /aimodel?credentialId=<id>`.

## Choosing a voice — `GET /aiworkervoice` (the voice catalogue)

**Voices come from `GET /aiworkervoice`, not `/aimodel`.** `/aimodel` returns *language models*; it has
no voices in it. The endpoint is `/aiworkervoice` — one word, no separator, which is why searching for
`/voice` finds nothing and concluding "voices are UI-only" is wrong.

```
GET /aiworkervoice?providerId=commotion-tts&modelId=commotion-laya-v1-5   # filter to the worker's TTS model
    # also accepts: voiceId, languageId, accentId, pageNumber, pageSize
```

Each record gives **`voiceId`** (the UUID for `workerVoiceConfiguration.voiceId`), **`voiceName`**, a
prose `description`, `languageIds`, `accentIds`, `modelIds`, and `languageIdToVoiceUrlMap` — per-language
sample audio URLs you can offer the user to listen to. Filter by `providerId`+`modelId` so every
returned voice is actually valid for the configured TTS model; it works for external providers too.

`commotion-tts` / `commotion-laya-v1-5` currently has **five** voices (verified live), all covering
`en, hi, kn, mr, ta, te, ml, bn, pa, gu`:

| `voiceName` | `voiceId` |
|---|---|
| Komal (female, upbeat) | `1b50c54f-2fd1-4ccf-9c33-ab2ca8ce94a7` |
| Raj (male, authoritative) | `04bb4f44-164f-4e39-bb8e-69d5ba134d65` |
| Poornima (female, warm) | `d6d81480-227c-41cd-af4e-f483262cef0b` |
| Tanya (female, refined) | `cb28ee98-e1b2-4f8d-8dc5-039d11486013` |
| Abhay (male, calm) | `f4af8e02-9469-4332-b9cf-d3e1590363f9` |

**Always query the catalogue rather than reusing a hardcoded id** — this table is a fallback, not the
source of truth, and `d6d81480…` (quoted elsewhere as "verified-good") is simply Poornima. When the user
says "choose a voice" or "use a different voice", list the candidates with their names and descriptions,
let them pick, then set `voiceId`; don't claim the catalogue is unavailable.

Notes:
- The `workerVoiceConfiguration` sub-object **requires** `model` / `provider` / `voiceId`. Confirm the
  valid pipeline/provider/model/language combinations in `GET /aiworker/metadata` (`voiceConfig`),
  **voices in `GET /aiworkervoice`** (see above), or omit the whole voice block on create and let
  backend defaults stand, then add languages with an update.
- ⚠ **`voiceConfig…accentIdToAccentDropdownOutputMap` is language accents, not voices** (`English-Indian`,
  `Hindi`, `Marathi`, …). It feeds `workerVoiceConfiguration.language`; it will never give you a `voiceId`.
- **TTS provider availability depends on the pipeline.** `SPEECH_TO_SPEECH` and `COLLOQUIAL` expose only
  `commotion-tts`; `HALF_CASCADE` also exposes the external providers (which you should not use — see
  above). Read `voiceConfig.voicePipelineTypeConfig[].providerIdToModelIdsMap` for the live map.
- **Request vs response field names differ.** The request uses `…Request` suffixes
  (`workerVoiceSettingsRequest`, `workerLLMConfigurationRequest`); a list/retrieve *response* uses
  `…Response`. Don't copy a response back as a request — map field-by-field against
  `commotion_schema` `{ "schema_name": "AiWorkerRequest" }`, or the mismatched keys are silently dropped.
- Multilingual workers also need a prompt line telling them to mirror the caller's language: the
  voice config lets them *speak* the language; the prompt makes them *choose* to.
- **Don't switch language on English-spoken digits (verified live — bake into the prompt).** Stay in
  the caller's spoken language and continue the WHOLE call in it. Treat a mobile number, policy
  number, OTP, or amount **read out in English digits as normal data** — do **NOT** switch the
  conversation language, and do **NOT** trigger the `Switch Language` built-in action, just because
  numbers are spoken in English. Only switch when the caller actually changes their conversational
  language. Without this rule the agent flips Hindi→English the moment the caller says their number in
  English digits (observed live). See `references/tools-and-capabilities.md` for the
  `switch_language` built-in.
