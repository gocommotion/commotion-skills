# Commotion Skills

Claude Skills for operating Commotion voice/chat agents. The skills carry the endpoints and judgment
(the "brain") and reach the Commotion **dev3 backend** through a **thin Commotion MCP server** that
holds auth and proxies each call — `commotion_request` + `commotion_schema` (plus the read-only
`commotion_analyzer` for the debugging plane), **OAuth**,
and **no API key in the transcript**. Each skill fetches request schemas live from the OpenAPI spec
and orchestrates the full worker lifecycle. All platform write-back is human-approved.

## Overview

A skill is a phased runbook: it grounds itself in the live config schema, interviews for the goal,
drafts the worker, provisions and enables its agent(s), optionally attaches knowledge and tools, and
deploys on approval. The transport lives behind the thin Commotion MCP server's two tools, so the
credential stays server-side (OAuth) and never lands in a command transcript, and every call is made
the same way.

```
Ground in schema → interview → draft → approve → create (draft) → enable agent(s)
   → [knowledge] → [tools] → readiness gate → deploy → confirm live
```

### The quality loop

Building a worker isn't the end — a worker that *behaves well* is. Four skills compose into a closed
quality loop that builds, tests, and iteratively improves a worker until it clears an eval-score
threshold. The scenario/simulation/eval endpoints are part of the **same** dev3 backend, so the loop
skills reuse the same transport (the Commotion MCP) as create-worker.

```
create-worker → generate-scenarios → run-evals → improve-worker
                                        └──── repeat (draft-only) until pass-rate ≥ threshold ────┘
                                                            → deploy on approval
```

The improvement loop runs on a **draft** version (the live worker is untouched); the gate is the
scenario **pass-rate** (`SimulationResponse.passRate`, 0–100); only the final improved version is
deployed, on the user's explicit yes.

The loop reads **two surfaces, not one**. The eval surface says *that* a scenario failed; **Call
Analyzer** — the observability plane, reached through the read-only `commotion_analyzer` tool — says what
the worker actually did: the transcript, whether each tool fired and what it returned, real per-turn
latency, whether the simulated caller even spoke. A simulation is just a real call with a robot caller, so
run-evals and improve-worker pull the call behind every failing scenario-run rather than diagnosing from
the evaluator's opinion alone. That matters because several failure classes are only *provable* there —
and because the evaluator itself sometimes returns no verdict at all.

Run it **end-to-end with one request** via the **`commotion-quality-loop`** coordinator — it sequences
the four specialists and owns the "iterate until the pass-rate clears a threshold" control flow — or
invoke any specialist on its own for a single step. *(Automated evals are **voice-only** and need a
worker deployed at least once — the coordinator ensures that before evaluating.)*

### Debugging production issues

The quality loop is a build-time pipeline over a **test set**. Once a worker is live, defects arrive from
**real traffic** instead — so `commotion-debug` is a separate entry point, deliberately outside the loop.
It starts from a real `callId` (or chat `sessionId`) and works entirely from **Call Analyzer**. (Every
skill can read that plane; the difference is that for `commotion-debug` it is the *only* source of truth,
so its absence is a stop condition rather than a missing enrichment.)

```
RCA a real call → reproduce it as a FAILING simulation → fix on a draft → verify → regression
    (Call Analyzer)        must fail ≥2 of 4                                 must pass ≥3 of 4
```

The discipline is **reproduce before you fix**: a fix chosen from a transcript alone is a guess, so the
loop will not edit anything until a simulation fails the same way the prod call did. Both gates are
rates, not verdicts — a voice run false-passes often enough that a bare "fixed" is misinformation. When
the problem turns out to be breadth rather than one defect, it hands off to `commotion-improve-worker`.
*(Reproduction is voice-only; a chat session gets full RCA but verifies with a text spot-check, and the
skill says so rather than implying otherwise.)*

## Layout

```
.claude-plugin/plugin.json            # plugin manifest (name: commotion) — registers the Commotion MCP server
skills/
  commotion-quality-loop/
    SKILL.md                          # orchestrator: runs the full loop end-to-end (invokes the 4 specialists)
  commotion-create-worker/
    SKILL.md                          # build & deploy a worker from a described goal (phased)
    references/
      api-and-auth.md                 # endpoint map, the two MCP tools, schema names — the transport contract
      aiworker-lifecycle.md           # draft↔live, versions, voice/language config
      agents-and-orchestration.md     # single/multi-agent, FAQ, structured-output agents
      knowledge-and-rag.md            # attach + index source material; grounding tokens
      tools-and-capabilities.md       # built-in/custom/code-block/MCP-server/connector tools, A2A, HITL
      control-and-reliability.md      # guardrails, fallback models, structured output
      settings-variables-pronunciation.md  # Settings: pronunciation dictionaries + state variables
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
  commotion-debug/                    # outside the quality loop — starts from production traffic
    SKILL.md                          # RCA a real call → reproduce → fix on a draft → verify → regression
    references/
      call-analyzer-api.md            # Call Analyzer endpoint map, fields= sections, payload sizes, gotchas
      rca-taxonomy.md                 # failure classes + the platform-artifact signature table
      repro-and-gates.md              # repro construction, stochastic gates, overfitting check, loop bounds
```

## Skills

| Skill | What it does |
|---|---|
| `commotion-quality-loop` | **Entry point / orchestrator.** Runs the whole pipeline end-to-end from one request — build (if needed) → generate scenarios → run evals → improve — iterating until the scenario pass-rate clears a threshold, then deploys on approval. Invokes the four specialists below via the Skill tool and owns the threshold/max-rounds loop. |
| `commotion-create-worker` | From a described goal, grounds in the live schema, interviews, drafts the worker (name, prompt, voice + languages, guardrails, fallbacks, structured output), provisions + enables its agent(s), optionally attaches knowledge and tools, and deploys on approval. |
| `commotion-generate-scenarios` | Builds a worker's **test set** — designs simulated-caller personalities and scenarios (AI-generated, manual, or from a real call), each with a goal the worker must achieve. Step 2 of the quality loop. |
| `commotion-run-evals` | Optionally defines eval metrics, then runs the scenarios as a **simulation** against a worker/version and reports the **pass-rate** plus a per-scenario pass/fail breakdown with failure reasons. Step 3. |
| `commotion-improve-worker` | Owns the **loop**: reads the failing scenarios, diagnoses each, edits the worker on a **draft**, re-runs the evals, and repeats until the pass-rate clears a threshold (or a round cap) — then deploys the improved version on approval. Step 4. |
| `commotion-debug` | **Outside the loop.** Debugs a **live** call or chat session: pulls the transcript, turn timeline, latency, tool calls and resolved LLM context from **Call Analyzer**, establishes the root cause, **reproduces the defect as a failing simulation before editing anything**, fixes on a draft, and re-runs until the repro passes with no regression. Escalates to `commotion-improve-worker` when the problem is breadth rather than one defect. |

## Setup

**No API key.** The plugin registers the **Commotion MCP** server; auth is **OAuth**, handled by your
MCP client. The first time a skill uses the Commotion MCP, Claude opens a Commotion login in your
browser, then stores the token and attaches it to every call automatically — the raw token never
enters the conversation.

If the tools aren't connected yet, authorize the server:

```
/mcp            # select "commotion" → Authenticate (a browser login opens once)
```

That's it — no `.env`, no key to paste. The credential lives server-side on the MCP server (see the
`commotion-mcp` repo for how OAuth + the two tools are implemented).

## Install (Claude Code)

This repo ships as a Claude Code **plugin** bundling the skills and registering the Commotion MCP
server (`plugin.json` → `mcpServers`). For local development, point Claude Code at this directory:

```bash
claude --plugin-dir /path/to/commotion-skills
```

Once published to the team plugin marketplace:

```
/plugin marketplace add gocommotion/commotion-skills
/plugin install commotion@commotion-skills
```

The skill then appears as `/commotion:commotion-create-worker` and auto-triggers when you ask Claude
to build a worker/voice agent. On first use, authorize the Commotion MCP (`/mcp` → **commotion** →
Authenticate) — a one-time browser login; no key to set.

## Relationship to `commotion-mcp`

The `commotion-mcp` repo is the **thin MCP server** these skills depend on: it holds the OAuth
credential and exposes the tools (`commotion_request` + `commotion_schema`, plus the GET-only
`commotion_analyzer` where the Call Analyzer plane is configured) that every skill
calls. `plugin.json` registers it (a hosted HTTP server, OAuth); the skills carry the endpoint map
and judgment. Deploy and operate it from that repo.

## License

UNLICENSED (internal).
