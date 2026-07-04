# Commotion Skills

Claude Skills for operating Commotion voice/chat agents. The skills call the Commotion **dev3
backend directly over HTTP** (through the Kong gateway) — there is **no MCP server**. Each skill
carries the endpoints it needs, fetches request schemas live from the OpenAPI spec, and orchestrates
the full worker lifecycle. All platform write-back is human-approved.

## Overview

A skill is a phased runbook: it grounds itself in the live config schema, interviews for the goal,
drafts the worker, provisions and enables its agent(s), optionally attaches knowledge and tools, and
deploys on approval. The HTTP mechanics live in thin helper scripts (`scripts/`) so the Kong api-key
never lands in a command transcript and every call is made the same way.

```
Ground in schema → interview → draft → approve → create (draft) → enable agent(s)
   → [knowledge] → [tools] → readiness gate → deploy → confirm live
```

### The quality loop

Building a worker isn't the end — a worker that *behaves well* is. Four skills compose into a closed
quality loop that builds, tests, and iteratively improves a worker until it clears an eval-score
threshold. The scenario/simulation/eval endpoints are part of the **same** dev3 backend, so the loop
skills reuse the same transport (`scripts/`) and Kong api-key as create-worker.

```
create-worker → generate-scenarios → run-evals → improve-worker
                                        └──── repeat (draft-only) until pass-rate ≥ threshold ────┘
                                                            → deploy on approval
```

The improvement loop runs on a **draft** version (the live worker is untouched); the gate is the
scenario **pass-rate** (`SimulationResponse.passRate`, 0–100); only the final improved version is
deployed, on the user's explicit yes.

Run it **end-to-end with one request** via the **`commotion-quality-loop`** coordinator — it sequences
the four specialists and owns the "iterate until the pass-rate clears a threshold" control flow — or
invoke any specialist on its own for a single step. *(Automated evals are **voice-only** and need a
worker deployed at least once — the coordinator ensures that before evaluating.)*

## Layout

```
.claude-plugin/plugin.json            # plugin manifest (name: commotion)
.env.example                          # KONG_API_KEY (+ non-secret defaults); copy to .env
scripts/
  commotion_api.sh                    # one authenticated HTTP call to dev3 via Kong
  fetch_schema.sh                     # a bundled request schema (fetched once/session, cached)
  bundle_schema.py                    # stdlib port of the OpenAPI $defs bundler
skills/
  commotion-quality-loop/
    SKILL.md                          # orchestrator: runs the full loop end-to-end (invokes the 4 specialists)
  commotion-create-worker/
    SKILL.md                          # build & deploy a worker from a described goal (phased)
    references/
      api-and-auth.md                 # endpoint map, headers, schema names — the transport contract
      aiworker-lifecycle.md           # draft↔live, versions, voice/language config
      agents-and-orchestration.md     # single/multi-agent, FAQ, structured-output agents
      knowledge-and-rag.md            # attach + index source material; grounding tokens
      tools-and-capabilities.md       # built-in/custom/MCP-server/connector tools, A2A, HITL
      control-and-reliability.md      # guardrails, fallback models, structured output
  commotion-generate-scenarios/
    SKILL.md                          # build a test set: personalities + scenarios for a worker/version
    references/
      eval-domain-api.md              # canonical endpoint map for scenario/sim/eval/personality (shared)
      scenarios-and-personalities.md  # scenario/persona field shapes, async generation, version-pinning
  commotion-run-evals/
    SKILL.md                          # run scenarios as a simulation; report pass-rate + per-scenario failures
    references/
      eval-metrics.md                 # eval-metric design, output types, thresholds, standard catalog, alerts
      simulation-and-results.md       # run lifecycle + poll, reading passRate/quality, scenario-run statuses
  commotion-improve-worker/
    SKILL.md                          # the loop: diagnose → edit draft → re-run → repeat → deploy on approval
    references/
      improvement-loop.md             # loop control, regression guard, version-pinning, failure→fix taxonomy
```

## Skills

| Skill | What it does |
|---|---|
| `commotion-quality-loop` | **Entry point / orchestrator.** Runs the whole pipeline end-to-end from one request — build (if needed) → generate scenarios → run evals → improve — iterating until the scenario pass-rate clears a threshold, then deploys on approval. Invokes the four specialists below via the Skill tool and owns the threshold/max-rounds loop. |
| `commotion-create-worker` | From a described goal, grounds in the live schema, interviews, drafts the worker (name, prompt, voice + languages, guardrails, fallbacks, structured output), provisions + enables its agent(s), optionally attaches knowledge and tools, and deploys on approval. |
| `commotion-generate-scenarios` | Builds a worker's **test set** — designs simulated-caller personalities and scenarios (AI-generated, manual, or from a real call), each with a goal the worker must achieve. Step 2 of the quality loop. |
| `commotion-run-evals` | Optionally defines eval metrics, then runs the scenarios as a **simulation** against a worker/version and reports the **pass-rate** plus a per-scenario pass/fail breakdown with failure reasons. Step 3. |
| `commotion-improve-worker` | Owns the **loop**: reads the failing scenarios, diagnoses each, edits the worker on a **draft**, re-runs the evals, and repeats until the pass-rate clears a threshold (or a round cap) — then deploys the improved version on approval. Step 4. |

## Setup

Secrets are environment-only. Provide your own Kong api-key — **never commit it.**

> **Security note:** in the skills-only model the Kong api-key lives on the machine running Claude
> (it used to be held server-side by the MCP adapter). Treat it like any other local secret: keep it
> in a gitignored `.env`, and use a key scoped to your workspace.

```bash
cp .env.example .env
# edit .env and set KONG_API_KEY (get it from BE)
```

`.env` carries `KONG_API_KEY` (secret) plus non-secret defaults
(`KONG_BACKEND_URL`, `KONG_API_KEY_HEADER`, `KONG_ROUTE_SELECTOR`). The skill loads it automatically;
to use the scripts by hand: `set -a; . ./.env; set +a`.

Smoke-test the transport:

```bash
bash scripts/commotion_api.sh GET /aimodel        # should list models
bash scripts/fetch_schema.sh AiWorkerRequest      # should print the worker schema
```

## Install (Claude Code)

This repo ships as a Claude Code **plugin** bundling the skills and helper scripts. For local
development, point Claude Code at this directory:

```bash
claude --plugin-dir /path/to/commotion-skills
```

Once published to the team plugin marketplace:

```
/plugin marketplace add gocommotion/commotion-skills
/plugin install commotion@commotion-skills
```

The skill then appears as `/commotion:commotion-create-worker` and auto-triggers when you ask Claude
to build a worker/voice agent. Set `KONG_API_KEY` in your environment (or the plugin's `.env`) first.

## Relationship to `commotion-mcp`

The `commotion-mcp` repo (the hosted MCP adapter) still exists but is **no longer referenced** by
these skills — the skills talk to dev3 directly. The backend endpoints, auth headers, and schema
bundling here were ported from that adapter (see `references/api-and-auth.md`).

## License

UNLICENSED (internal).
