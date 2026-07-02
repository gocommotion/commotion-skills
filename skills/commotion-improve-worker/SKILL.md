---
name: commotion-improve-worker
description: >-
  Iteratively improve a Commotion worker until it clears an eval-score threshold — read the failing
  scenarios from a simulation run, diagnose why each failed, edit the worker on a DRAFT version
  (prompt, tools, knowledge, guardrails), re-run the evals against that draft, and repeat until the
  pass-rate hits the target or a max-round cap, then deploy the improved version on approval. Use this
  whenever the user wants to improve / iterate / fix / tune a worker to raise its eval score, or "make
  it pass" / "get the pass-rate up" — e.g. "my renewal bot only passes 60%, improve it until it's 85".
  This is step 4 of the quality loop (create-worker → generate-scenarios → run-evals →
  **improve-worker**) and owns the loop. Calls the dev3 backend directly over HTTP (no MCP server).
allowed-tools: Bash, Read, AskUserQuestion
---

# Commotion: Improve a Worker (the quality loop)

Close the loop: take a worker that doesn't pass its scenarios well enough, **diagnose** why from the
per-scenario failure reasons, **edit** it on a draft, **re-run** the evals, and repeat until the
**pass-rate** clears the target. You supply the judgment — reading the evaluator's reasoning, deciding
whether a failure is a prompt gap, a missing tool, missing grounding, or an over-strict guardrail, and
making the fix. There is **no MCP server** and **no server-side "improve prompt" button** — the
improvement is your reasoning plus the same editing machinery `commotion-create-worker` uses.

This is **step 4 of the worker quality loop, and it owns the loop**:

```
create-worker → generate-scenarios → run-evals → [improve-worker]
                                         ↑___________ repeat until pass-rate ≥ threshold ___________|
```

**Two hard rules (locked):**
1. **Draft-only loop — never auto-deploy mid-loop.** All iteration happens on a *draft* version: edit
   the draft → run evals against the draft → repeat. The live worker keeps serving its current version
   untouched until the very end.
2. **The gate is the scenario pass-rate** (`SimulationResponse.passRate`, a **0–100 percentage**). The
   loop stops when `passRate ≥ threshold` or a max-round cap is hit. The final improved draft deploys
   **only on the user's explicit "yes"** (same gate as create-worker Phase 10).

**Prerequisite (verified live):** evals are **voice-only** and need a **deployed** worker — the loop
runs on a *draft version of an already-live voice worker* (that draft is simulatable; a never-deployed
worker returns *"Worker is not available"*). If the target is chat or never deployed, get it to a live
voice worker first (see `commotion-run-evals` prerequisites).

## When to use this

The user wants to raise a worker's eval score / make it pass / iterate on it. You need a baseline
simulation to diagnose from — if there isn't one, run `commotion-run-evals` first (this skill will
prompt you to). Scenarios must exist (`commotion-generate-scenarios`). The actual editing of the worker
(prompt, tools, knowledge, guardrails, deploy) reuses `commotion-create-worker`'s phases and references
— this skill is the **controller** around them. **For the whole build → test → improve pipeline in one
request, use the `commotion-quality-loop` orchestrator** (it invokes this skill as its improve step).

## How this skill talks to the platform (read first)

**Same transport** as the other skills — same helper scripts, same Kong api-key, same session file, one
unified backend. Resolve the scripts dir once:

```bash
SCRIPTS="${CLAUDE_PLUGIN_ROOT:-/absolute/path/to/commotion-skills}/scripts"
```

> Do not use `${CLAUDE_PLUGIN_ROOT:?…}` — empty from a clone, would hard-fail.

### Step 0 — Make sure the API key is available (do this first)

`commotion_api.sh` reads the Kong api-key from `${TMPDIR:-/tmp}/commotion-mcp/session.env`.

1. **Already set this session?** Reuse it; run the smoke test.
2. **Otherwise** ask for the Kong api-key with `AskUserQuestion` (+ route selector only if not
   `demo_workspace`), session-only and unsaved, then write it (**never print the key**):
   ```bash
   mkdir -p "${TMPDIR:-/tmp}/commotion-mcp"
   ( umask 077; printf 'KONG_API_KEY=%s\n' '<the key the user provided>' \
       > "${TMPDIR:-/tmp}/commotion-mcp/session.env" )
   ```
3. **Smoke-test:** `bash "$SCRIPTS/commotion_api.sh" GET "/scenario/dropdown-config"` → 2xx. A 401/403 =
   wrong key. Don't start Phase 0 until this passes.

- **Call** — `bash "$SCRIPTS/commotion_api.sh" <METHOD> <PATH> [BODY]`. **Schema** —
  `bash "$SCRIPTS/fetch_schema.sh" <SchemaName>`. **Never invent a field that isn't in the schema.**

References this skill leans on:
- This skill's loop control: `references/improvement-loop.md` (threshold, rounds, regression guard,
  version-pinning of the test set, the failure→fix taxonomy).
- The eval endpoint map: `commotion-generate-scenarios/references/eval-domain-api.md`.
- The actual editing machinery (reused, not duplicated):
  `commotion-create-worker/references/aiworker-lifecycle.md` (revert-to-draft, versions, voice),
  `…/agents-and-orchestration.md` (edit/POST agents, prompt rules),
  `…/control-and-reliability.md` (guardrails, fallback), `…/tools-and-capabilities.md` (wire tools),
  `…/knowledge-and-rag.md` (attach knowledge).
- Reading scores + failures: `commotion-run-evals/references/simulation-and-results.md`.

**Execution rules:** one phase at a time; **never deploy inside the loop**; show every edit before
making it; one round = diagnose → edit draft → re-run → compare.

## Phase 0 — Inputs and the stop condition  ·  HUMAN INPUT

Gather:
- **`aiWorkerId`** — the worker to improve.
- **Baseline simulation** — the `SIM_ID` of the latest run (its failing scenarios drive round 1). If
  there isn't one, run `commotion-run-evals` now to produce one, then continue.
- **Threshold** — the pass-rate to reach (`AskUserQuestion`; **default 80** — `passRate` is a **0–100
  percentage**, not a 0–1 fraction).
- **Max rounds** — iteration cap so the loop terminates (`AskUserQuestion`; **default 3**).

Confirm the loop will run **draft-only** and only deploy at the end on their approval.

## Phase 1 — Diagnose the failures (each round)

Read the current run's failing scenarios:

```bash
bash "$SCRIPTS/commotion_api.sh" GET "/scenario-run?simulationId=$SIM_ID"
# for each failing run, read failureReason + evaluationReasoning
```

Classify each failure and map it to a fix (the **failure → fix taxonomy** — full version in
`references/improvement-loop.md`):

| Failure pattern (from `evaluationReasoning`) | Fix | Where |
|---|---|---|
| Agent missed a step / wrong flow / wrong tone | Edit the agent **`instructions`** | agents-and-orchestration.md |
| Asserted a backend fact it never fetched (hallucination) | Add/strengthen the **grounding rule**; wire the API as a **tool** | agents + tools-and-capabilities.md |
| "Called an API" but nothing happened / looped | **Register the API as a tool**, reference `[tool:<action>]` | tools-and-capabilities.md |
| Couldn't answer from source material | **Attach + index knowledge**, bind it in the prompt | knowledge-and-rag.md |
| Flipped language on English-spoken digits | Add the **don't-switch-on-digits** prompt rule | aiworker-lifecycle.md |
| Over-blocked a legitimate request / under-blocked a bad one | Tune **guardrails** (thresholds, forbidden words, custom checks) | control-and-reliability.md |
| Re-asked for info already given / looped | Add the **anti-repetition / call-once** prompt rules | agents-and-orchestration.md |

Prioritize the fixes that clear the most failing scenarios. Present the diagnosis to the user.

## Phase 2 — Edit on a DRAFT (never on live)

Agents/config are editable only on a **draft**. Establish the draft version you'll edit and capture it
into `DRAFT_VERSION` (Phase 3 and Phase 5 reuse it):

- **Worker is live** → read its current version, then mint a new draft version (e.g. N+1) alongside the
  still-serving live version:
  ```bash
  LIVE_VERSION=$(bash "$SCRIPTS/commotion_api.sh" GET "/aiworker/$WORKER_ID" | jq -r '.version')
  DRAFT_VERSION=$(bash "$SCRIPTS/commotion_api.sh" POST "/aiworker/$WORKER_ID/draft?version=$LIVE_VERSION" | jq -r '.version')
  ```
- **Worker is already a draft** → there's no live version to read (`GET /aiworker/{id}` is **live-only**
  and 400s on a draft-only worker). Get the draft's version from the version history (note the
  **`.items`** wrapper) and edit in place:
  ```bash
  DRAFT_VERSION=$(bash "$SCRIPTS/commotion_api.sh" GET "/aiworker/$WORKER_ID/versions" | jq -r '.items | map(select(.status=="DRAFT"))[0].version')
  ```
  (Only one draft can exist at a time, so there's at most one DRAFT entry. Don't POST `/draft` again.
  A superseded live version shows status **PAUSED**.)

Then apply the diagnosed fixes on that draft version.

Apply the diagnosed fixes using the **create-worker machinery** (don't reinvent it):
- **Prompt** → `PUT /aiagent/{id}` to revise `instructions` (or re-POST the agent — see the
  POST-create rule in agents-and-orchestration.md so the prompt renders/edits in the UI).
- **Tools** → create on the draft (`POST /ai-worker-tool/...`) and reference by action name in the
  prompt — see tools-and-capabilities.md.
- **Knowledge** → attach + index, bind in the prompt — see knowledge-and-rag.md.
- **Guardrails / fallback** → `PUT /aiworker/{id}` (full PUT, resend kept fields + `version`) — see
  control-and-reliability.md.
- **Language / voice config** (e.g. add a language) → `PUT /aiworker/{id}` full body with
  `workerVoiceSettingsRequest.workerVoiceConfiguration.allowedLanguages` updated (e.g. `["en","hi"]`) +
  a language-mirroring rule in the agent prompt. **Resend the fields you want to keep** (name, setup,
  guardrails) or they reset. Verified live: adding `hi` + the prompt rule made the agent switch to
  Hindi mid-call and stay in Hindi on English-spelled emails.
- **Agent type change** (e.g. CHAT_AGENT→VOICE_AGENT) → **delete the agent and re-POST** it with the
  new `agentType`. A `PUT` that changes the type is rejected: *"Cannot change agent type…"*.

**Show every edit before making it.** Make the smallest set of changes that addresses the round's
failures (so you can attribute the pass-rate change to them — see the regression guard).

## Phase 3 — Re-run the evals against the draft

Point the test set at the draft version and re-run, reusing `commotion-run-evals`:

- Ensure scenarios exist **for the draft version** (a draft-of-a-live worker is simulatable; a sim
  takes scenarioIds + the worker `version`). If the fresh draft version lacks them, recreate/point the
  test set at it via `commotion-generate-scenarios` — see `references/improvement-loop.md`.
- Check `GET /scenario-run/active?aiWorkerId=$WORKER_ID` (sequential), then `POST /simulation/run` with
  `version` = the **draft** version. Poll `GET /simulation/{id}` to COMPLETED and read the new
  `passRate`. This becomes the round's result and the next round's `SIM_ID`.

## Phase 4 — Loop control (the decision each round)

- **`passRate ≥ threshold`** → **stop: success.** Go to Phase 5.
- **Below threshold, rounds remaining, and `passRate` went up** (regression guard: an edit that *lowered*
  the rate is reverted/reconsidered, not kept) → **back to Phase 1** with the new failing scenarios.
- **Below threshold and (no rounds left or no improvement)** → **stop: report.** Summarize where it
  plateaued and the remaining failures; suggest the next manual step (e.g. a tool that needs a real
  endpoint spec, or knowledge that doesn't exist yet).

Keep a **per-round summary table**: round · what changed · `passRate` (and Δ) · scenarios fixed/broken.
Show it to the user as the loop progresses.

## Phase 5 — Deploy the improved draft  ·  ALWAYS ASK FIRST

Only after the loop stops:
- Summarize the final draft (version, the edits made across rounds, final `passRate` vs target).
- `AskUserQuestion`: deploy now or keep as draft.
- On a clear **yes**:
  ```bash
  bash "$SCRIPTS/commotion_api.sh" POST "/aiworker/$WORKER_ID/deploy?version=$DRAFT_VERSION"
  ```
- Otherwise leave it as a draft (it persists; the user can deploy later). Confirm live with
  `GET "/aiworker/$WORKER_ID"`.

## Principles

- **Draft-only, deploy-at-end.** Never deploy inside the loop; the live worker is untouched until the
  user approves the final version. This mirrors create-worker's deploy gate.
- **Gate on the pass-rate**; diagnose from `failureReason` + `evaluationReasoning`. Fewer, targeted
  edits per round so you can attribute the change.
- **Regression guard + max rounds** keep the loop honest and terminating — don't keep an edit that
  lowered the score; always have a round cap.
- **Reuse, don't reinvent** — the editing is create-worker's machinery; this skill is the controller.
- Version-pin the test set to the draft under test; show every edit; deploy only on explicit "yes".
