---
name: commotion-quality-loop
description: >-
  Run the FULL Commotion worker quality loop end-to-end — build (if needed) → generate test scenarios →
  run evals → improve — iterating until the scenario pass-rate clears a threshold, then deploy on
  approval. This is the single entry point that orchestrates the four specialist skills in order and
  owns the "keep improving until it passes" control flow. Use this when the user wants the WHOLE
  pipeline in one go — e.g. "build a voice bot that books test drives and make it pass 90%", "test and
  improve my renewal worker until the pass-rate is 80%", "set up X and evaluate it end to end". For a
  SINGLE step, defer to the specialist instead: build only → commotion-create-worker; scenarios only →
  commotion-generate-scenarios; run evals only → commotion-run-evals; improve only →
  commotion-improve-worker. Calls the dev3 backend over HTTP (no MCP server).
allowed-tools: Bash, Read, AskUserQuestion, Skill
---

# Commotion: Quality Loop (end-to-end orchestrator)

Drive a worker from an idea to a **measurably good** deployment in one flow. This skill doesn't
re-implement anything — it **sequences the four specialist skills** and owns the top-level loop:

```
create-worker → generate-scenarios → run-evals ──► improve-worker ──► deploy (on approval)
   (if needed)                          ▲                    │
                                        └──── repeat until passRate ≥ threshold or max rounds ────┘
```

You invoke each specialist via the **Skill** tool, carry the shared state between them (worker id,
version, scenario ids, latest simulation id, pass-rate), and make the loop/threshold decisions here.
Every write stays human-approved, and **deploy is always user-gated** — same discipline as the
specialists.

## When to use this (vs a specialist)

Use the loop when the request spans the whole pipeline ("build **and** test **and** improve until it
passes"). If the user only wants one step, invoke that specialist directly and stop. Don't run the
whole loop for a single-step request.

## Hard prerequisites (verified live — the loop can't run without these)

Automated evals are **voice-only** and need a **deployed** worker. So before any evals:
- The target worker must be **voice-enabled** (a chat worker fails every simulation).
- It must have been **deployed (live) at least once** — a never-deployed worker returns *"Worker is
  not available"* and can't be simulated. (After that, a **draft version** of it *can* be simulated,
  which is what lets the improve loop run on a draft.)

If the worker doesn't meet these, the loop's job is to get it there (build a voice worker and deploy
it) before generating scenarios.

## Transport / Step 0 — same as the specialists

This skill uses the shared helpers and the session Kong api-key. Resolve the scripts dir once and
ensure the key is present (the sub-skills reuse the same session file, so you only do this once):

```bash
SCRIPTS="${CLAUDE_PLUGIN_ROOT:-/absolute/path/to/commotion-skills}/scripts"
```
- If the key is already set this session, reuse it; else ask via `AskUserQuestion` and write it to
  `${TMPDIR:-/tmp}/commotion-mcp/session.env` (umask 077; **never print it**) — see any specialist's
  Step 0 for the exact snippet. Smoke-test: `bash "$SCRIPTS/commotion_api.sh" GET /scenario/dropdown-config`.

## Phase 0 — Scope the run  ·  HUMAN INPUT (batched, minimal)

Establish, asking only for what you can't infer:
- **The goal** (what the worker should do) and whether a worker **already exists** (`aiWorkerId`) or
  must be built.
- **Threshold** — the scenario pass-rate to reach (default **80**; `passRate` is a **0–100
  percentage**).
- **Max rounds** — improvement-iteration cap (default **3**).

Confirm the plan in one line ("build a voice worker for X → generate scenarios → evaluate → improve on
a draft until pass-rate ≥ 80 (max 3 rounds) → deploy on your yes") before running.

## Phase 1 — Ensure a deployed VOICE worker (entry point)

- **No worker yet** → invoke the **`commotion-create-worker`** skill to build one. Steer it to a
  **voice** worker (evals need voice), and see it through to a **deploy** (the loop needs a live
  version). Capture the `aiWorkerId`.
- **Worker exists but is chat / never deployed** → get it to a deployed voice worker: enable voice on
  a draft and deploy (create-worker covers the edit→deploy flow). 
- **Deployed voice worker exists** → capture its `aiWorkerId` + the version you'll test (default the
  live version). Proceed.

Do not continue to Phase 2 until the prerequisite (deployed voice worker) holds.

## Phase 2 — Build the test set

Invoke the **`commotion-generate-scenarios`** skill for this worker + version. It creates the
simulated-caller **personalities** (voice-enabled) and the **scenarios** (cover happy + failure +
jailbreak/edge paths). When it returns, capture the **scenario ids** and the version they were
created at.

## Phase 3 — Baseline eval

Invoke the **`commotion-run-evals`** skill to run the scenarios as a simulation and report the
**baseline pass-rate** (optionally defining eval-metrics for richer signal). Capture the `SIM_ID`,
the `passRate`, and the per-scenario failures (the diagnosis fuel). Report the baseline vs the
threshold.

## Phase 4 — Improve loop (the core)

- If **baseline `passRate` ≥ threshold** → skip to Phase 5 (already meets the bar).
- Else → invoke the **`commotion-improve-worker`** skill, passing the worker id, the baseline
  `SIM_ID`, the **threshold**, and **max rounds**. It owns the round-by-round mechanic — diagnose the
  failing scenarios → edit the worker on a **draft** → re-run evals against that draft → repeat, with a
  regression guard — until `passRate ≥ threshold` or max rounds. **The whole loop stays on a draft; it
  never auto-deploys.** When it returns, capture the final draft version + final pass-rate + the
  per-round summary.

Surface the per-round summary table (round · edits · pass-rate Δ) to the user as it progresses.

## Phase 5 — Deploy the result  ·  ALWAYS ASK FIRST

Summarise the outcome (final version, pass-rate vs threshold, what changed across rounds). Then
`AskUserQuestion` to deploy the improved version live (Deploy now / Keep as draft). Only on a clear
yes, deploy it (the improve-worker / create-worker deploy step). If the loop hit max rounds without
clearing the bar, say so plainly and hand back the remaining failures + a recommended next step
(e.g. a tool that needs a real endpoint, or knowledge that doesn't exist yet) — don't deploy a
regression.

## Phase 6 — Confirm + report

Confirm the live worker (`GET /aiworker/{id}`) and give a final report: the worker, the final
pass-rate, the deployed version, and (if metrics were defined) how to read the Evals dashboard
(metric evaluation is async — see `commotion-run-evals`).

## Principles

- **Orchestrate, don't duplicate.** Each phase is "invoke specialist X, capture its output, decide."
  The specialists carry the field shapes and gotchas; this skill carries the *sequence* and the
  *threshold loop*.
- **Prerequisite first:** a deployed **voice** worker, or the evals can't run.
- **Threshold is a 0–100 pass-rate**; the loop is **draft-only**; **deploy is always user-gated**.
- **Carry state** between skills (worker id, version, scenario ids, SIM_ID, pass-rate, threshold, max
  rounds) so each specialist gets what it needs without re-asking.
- If any specialist reports a blocker it can't resolve (e.g. the worker can't be made voice, or a fix
  needs data that doesn't exist), stop and report — don't loop pointlessly.
