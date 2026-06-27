# Changelog

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
