# dev3 aiworker lifecycle — draft/live, versions, and the sharp edges

Operational behavior of the `/aiworker` backend (called directly over HTTP — see
`api-and-auth.md`). Read this when a create / update / deploy call behaves unexpectedly. Field
*shapes* come from `fetch_schema.sh AiWorkerRequest`; this file is the *behavior* the schema doesn't
tell you. Agent specifics live in `agents-and-orchestration.md`.

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
| GET | `/aiworker/metadata` · `/aimodel` | valid values / supported models |

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
  workerLLMConfigurationRequest: { provider, model, temperature }            # optional; defaults stand
```

**Verified-good en+hi block (mirror this — created + deployed live, S2S):** `provider:
"commotion-tts"`, `model: "commotion-laya-v1-5"`, `voiceId:
"d6d81480-227c-41cd-af4e-f483262cef0b"`. `commotion-laya-v1-5` covers `en, hi, kn, mr, ta, te, ml,
bn, pa, gu`. Sending **only** `voiceAgentPipelineType` + `workerVoiceConfiguration` on create is
enough — the transcript/LLM sub-blocks default. The full provider→model→language map lives in
`GET /aiworker/metadata` → `voiceConfig.voicePipelineTypeConfig`.

Notes:
- The `workerVoiceConfiguration` sub-object **requires** `model` / `provider` / `voiceId`. Confirm the
  valid pipeline/provider/model/language combinations in `GET /aiworker/metadata` (`voiceConfig`),
  voices in `GET /aimodel`, or omit the whole voice block on create and let backend defaults stand,
  then add languages with an update.
- **Request vs response field names differ.** The request uses `…Request` suffixes
  (`workerVoiceSettingsRequest`, `workerLLMConfigurationRequest`); a list/retrieve *response* uses
  `…Response`. Don't copy a response back as a request — map field-by-field against
  `fetch_schema.sh AiWorkerRequest`, or the mismatched keys are silently dropped.
- Multilingual workers also need a prompt line telling them to mirror the caller's language: the
  voice config lets them *speak* the language; the prompt makes them *choose* to.
