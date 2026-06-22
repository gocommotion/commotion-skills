# dev3 aiworker lifecycle — draft/live, versions, and the sharp edges

Operational behavior of the `/aiworker` backend (reached via the `commotion` MCP tools). Read this
when a create / update / deploy call behaves unexpectedly. Field *shapes* come from
`aiworker_request_schema`; this file is the *behavior* the schema doesn't tell you. Agent specifics
live in `agents-and-orchestration.md`.

## State machine

```
aiworkers_create(config)              -> DRAFT, version 0     (auto-provisions a default agent, DISABLED)
aiagents_update / aiagents_create     -> edit agents          (only while the worker is a DRAFT)
aiworkers_update(id, config, ver)     -> edit the draft       (full PUT; needs `version`)
aiworkers_deploy(id, version=0)       -> LIVE, version 0
```

Editing something that is already **LIVE**:

```
aiworkers_deploy(id, version=0, draft=True)   OR   POST /aiworker/{id}/draft
        -> creates a NEW editable DRAFT version (e.g. v1) alongside the still-serving LIVE v0
edit the draft (worker config and/or its agents) at that new version
aiworkers_deploy(id, version=1)               -> the draft becomes LIVE; the old version is superseded
```

`GET /aiworker/{id}/versions` shows the history, one entry per version with its `status`
(`LIVE` / `DRAFT`). Only **one draft can exist at a time** per worker.

## The edges

- **A new worker is DRAFT v0 and comes with a default agent, disabled.** It is not usable until that
  agent is enabled (`aiAgentEnabled: true`). See `agents-and-orchestration.md`.
- **`agentSetupType` is required on create** (`SINGLE_AGENT` / `MULTI_AGENT` / `WORKFLOW`); blank →
  `400 "Agent setup type cannot be blank"`. It **can be changed later via `aiworkers_update`, but
  only while the worker is a draft** (verified: a SINGLE_AGENT draft was switched to MULTI_AGENT,
  then redeployed).
- **Update is a full PUT and needs `version`.** `aiworkers_update` requires the current `version` in
  the body (`0` for a fresh worker, or the draft's version when editing a live worker's draft) — else
  `400 "version is required for update"`. It replaces the record, so resend the top-level fields you
  want to keep (`name`, `workerGoal`, `workerLevelPrompt`, `agentSetupType`, `voiceEnabled`, the
  voice block) or they reset.
- **Deploy targets a version.** A fresh worker's first deploy is `version=0`. When you revert a live
  worker to a draft, the draft gets a **new** version number (e.g. 1); deploy *that* version to go
  live. Workers can be LIVE at version 0.
- **`aiworkers_retrieve` (GET /aiworker/{id}) is LIVE-only.** A draft-only worker returns
  `400 "Live Worker not found"`. Read drafts from `aiworkers_list`, or fetch a specific version with
  `GET /aiworker/{id}?version=N`.

## Voice + language config

Languages and the TTS voice live under the voice settings block of the `AiWorkerRequest`:

```
workerVoiceSettingsRequest:
  voiceAgentPipelineType: "SPEECH_TO_SPEECH"   # or HALF_CASCADE / FULL_CASCADE / COLLOQUIAL / TRANSCRIPTION_BASED
  workerVoiceConfiguration:
    allowedLanguages: ["en", "hi"]             # every language the worker may speak
    language: "English-Indian"
    defaultLanguage: "en"
    model:    "<tts model>"                    # REQUIRED — e.g. commotion-laya-v1-5
    provider: "<tts provider>"                 # REQUIRED — e.g. commotion-tts
    voiceId:  "<voice id>"                      # REQUIRED
  workerTranscriptConfiguration: { provider, model, temperature, prompt }
  workerLLMConfigurationRequest: { provider, model, temperature }
```

Notes:
- The `workerVoiceConfiguration` sub-object **requires** `model` / `provider` / `voiceId`. Get valid
  values from `aimodels_list`, or omit the whole voice block on create and let backend defaults stand
  (SPEECH_TO_SPEECH, English-Indian `en`, `commotion-laya-v1-5`, `commotion-medium`), then add
  languages with an update.
- **Request vs response field names differ.** The request uses `…Request` suffixes
  (`workerVoiceSettingsRequest`, `workerLLMConfigurationRequest`); a `list`/`retrieve` *response* uses
  `…Response`. Don't copy a response back as a request — map field-by-field against
  `aiworker_request_schema`, or the mismatched keys are silently dropped.
- Multilingual workers also need a prompt line telling them to mirror the caller's language: the
  voice config lets them *speak* the language; the prompt makes them *choose* to.
