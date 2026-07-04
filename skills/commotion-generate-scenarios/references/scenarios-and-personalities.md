# Scenarios & personalities — field shapes and the sharp edges

Operational behavior of the `/scenario` and `/personality` resources (called directly over HTTP — see
`eval-domain-api.md`). Field *shapes* come from `fetch_schema.sh`; this file is the *behavior* the
schema doesn't tell you. Running them as a simulation and reading scores is
`commotion-run-evals/references/simulation-and-results.md`.

## A scenario, conceptually

A **scenario** is one simulated conversation with a **goal** the worker must achieve to pass. A
**personality** is who's on the other end — the simulated caller's persona, mood, voice, and
behaviour. One personality is reused across many scenarios; one scenario references one personality.
The simulation (run-evals) drives the personality through the scenario against the worker and an
evaluator judges whether the `scenarioGoal` was met.

## `ScenarioRequest` (POST/PUT `/scenario`)

| Field | Notes |
|---|---|
| `name` | short, human label |
| `aiWorkerId`, `version` | the worker + **version under test** (see version rule below) |
| `aiAgentId`, `isTestSpecificAgent` | set both to test **one specific agent** of a multi-agent worker |
| `intent` | a tag (typeahead values from `GET /scenario/intent-values`) — for filtering |
| `complexity` | a `code` from `dropdown-config.complexity` (e.g. simple vs multi-turn/edge-case) |
| `pathType` | a `code` from `dropdown-config.pathType` (e.g. happy path vs failure/jailbreak) |
| `personalityId` | the simulated caller (Phase 2) |
| `situation` | background/context of the caller (what's going on) |
| `userScript` | step-by-step of what the simulated caller will say / share during the call |
| `scenarioGoal` | **the pass criterion** — what the worker must achieve. Make it concrete + checkable |
| `extraContext` | extra constraints / special conditions |
| `aiAgentChannelType` | voice or chat (must match the worker's channel) |
| `sourceType` | how the scenario was created (set by the platform for generated/from-call) |

`ScenarioResponse` echoes these plus `id`, `*Label` display strings (`complexityLabel`, `pathTypeLabel`,
`sourceTypeLabel`, `channelTypeLabel`), `scenarioGenerationId` (if AI-generated), and `version`.

## Valid values come from `GET /scenario/dropdown-config`

Returns `complexity`, `pathType`, `scenarioGenerationType`, `channelType` — each an array of
`{code, label, label2, description, isDefault}` — **plus** `maxScenarioGenerationLimit` and
`maxScenarioRunLimit`. **Use the `code` (not the label) in request bodies**, and respect the two
limits. Verified live values: `complexity` = **SIMPLE / MODERATE / COMPLEX**; `pathType` = **HAPPY /
JAILBREAK**; `channelType` = **VOICE / CHAT**; `scenarioGenerationType` came back **empty** (omit it);
`maxScenarioGenerationLimit` = `maxScenarioRunLimit` = **20**. `GET /scenario/intent-values` returns
existing `intents` for the `intent` tag.

## AI generation is async — generate then poll

`POST /scenario/generate` (`GenerateScenarioRequest`):

| Field | Notes |
|---|---|
| `aiWorkerId`, `version` | worker + version to generate for |
| `aiAgentId`, `isTestSpecificAgent` | scope generation to one agent |
| `instructions` | free-text steering the generator toward the use cases you want covered |
| `numScenarios` | how many to generate — keep ≤ `maxScenarioGenerationLimit` |
| `generationType` | a `code` from `dropdown-config.scenarioGenerationType` |
| `personalityIds` | personas to assign to the generated scenarios |
| `contextVariables` | object of domain values to inject (e.g. `{policy_number, caller_name}`) so generated scenarios use realistic data instead of placeholders |
| `aiAgentChannelType` | voice/chat |
| `llm` | the **simulator LLM** (`LLMConfig`: `provider`, `model`, optional `voiceProviderCredentialId`) — codes from `GET /aimodel` |

The call returns **only** `{scenarioGenerationId}` (it's async). **Poll** until the scenarios exist:

```bash
GEN=$(bash "$SCRIPTS/commotion_api.sh" POST /scenario/generate @gen.json | jq -r '.scenarioGenerationId')
# poll — the generated scenarios appear filtered by the generation id:
bash "$SCRIPTS/commotion_api.sh" GET "/scenario?scenarioGenerationId=$GEN&aiWorkerId=$WORKER_ID"
# repeat until the array is populated (and count ≈ numScenarios). Then review them.
```

**Verified caveat:** there is **no generation-progress endpoint** — you only poll `/scenario`. And
generation needs a **deployed (live)** worker: against a never-deployed worker it returns a generation
id but yields **zero** scenarios (silently). If polling stays empty, the worker likely isn't live —
deploy it, or use manual `POST /scenario` (below), which is channel-agnostic and always works.

> Tip (mirrors the platform UI): pair a specific `instructions` (a concrete situation) with
> `contextVariables` (the data that situation needs) to get tightly targeted, realistic scenarios
> rather than generic placeholders.

## From a real call

`POST /scenario/generate-from-conversation` (`conversationId, aiWorkerId, version, aiAgentChannelType`)
turns a recorded interaction into a scenario — ideal for capturing a **production failure as a
regression test**. It returns a `ScenarioResponse` with the user-script pre-filled from the transcript;
review and complete the remaining fields (`complexity`, `pathType`, and especially `scenarioGoal` — you
define what "correct" should have been).

## Bulk import (large hand-authored sets)

`GET /scenario/import/csv` (or `/excel`) returns a presigned URL + template; fill the file, upload it,
then `POST /scenario/bulk` (`BulkScenarioCreateRequest`: `fileProcessId, processStatus, aiWorkerId,
version`). Reserve this for large sets — for a handful of edge cases, plain `POST /scenario` is simpler.

## `PersonalityRequest` (POST/PUT `/personality`)

| Field | Notes |
|---|---|
| `name`, `gender`, `mood` | persona identity + emotional state (drives behaviour) |
| `prompt` | natural-language behaviour spec — AI-draft it via `POST /personality/prompt/generate` `{description}` → `{generatedPrompt}`, then edit |
| `voiceEnabled` | `true` to give the simulated caller a real TTS voice (needed for voice simulations) |
| `voiceProvider`, `voiceModel`, `voiceId`, `voiceProviderCredentialId`, `languages` | the caller's voice (codes from `GET /aimodel`; mirror the worker's voice domain) |
| `interruptionLevel`, `speakingSpeed` | conversational realism (interrupts, pace) |
| `backgroundNoise` / `backgroundNoiseFileIdentifier` / `backgroundNoiseFileName` / `backgroundNoiseIntensity` | ambient noise to stress audio handling |
| `packetLoss` | simulate a poor connection (0–100) |

Build a small **library of reusable personas** (cooperative, frustrated, impatient-interrupter,
code-switching, noisy-line, adversarial/jailbreak) and reference them across scenarios — running the
same scenario with different personas is how you stress edge cases.

## The version rule (carry into the loop)

- Create scenarios/personas at the **version under test** (`version` in the body). In
  `commotion-improve-worker` that's the **draft** version being improved.
- **List endpoints don't filter by `version`** — only `aiWorkerId`. Read each `ScenarioResponse.version`
  to know which version a scenario targets, and filter client-side if you keep scenarios for several
  versions.
- **Verified:** create scenarios at the version you'll run — a simulation takes `scenarioId`s + a
  worker `version`, and a **draft version of an already-live worker can be simulated** (so the
  draft-only improve loop works). When you mint a new draft version to improve on, create/point the
  test-set scenarios at that draft version and run against it.
