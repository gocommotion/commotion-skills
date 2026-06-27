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

## Layout

```
.claude-plugin/plugin.json            # plugin manifest (name: commotion)
.env.example                          # KONG_API_KEY (+ non-secret defaults); copy to .env
scripts/
  commotion_api.sh                    # one authenticated HTTP call to dev3 via Kong
  fetch_schema.sh                     # a bundled request schema (fetched once/session, cached)
  bundle_schema.py                    # stdlib port of the OpenAPI $defs bundler
skills/
  commotion-create-worker/
    SKILL.md                          # build & deploy a worker from a described goal (phased)
    references/
      api-and-auth.md                 # endpoint map, headers, schema names — the transport contract
      aiworker-lifecycle.md           # draft↔live, versions, voice/language config
      agents-and-orchestration.md     # single/multi-agent, FAQ, structured-output agents
      knowledge-and-rag.md            # attach + index source material; grounding tokens
      tools-and-capabilities.md       # built-in/custom/MCP-server/connector tools, A2A, HITL
      control-and-reliability.md      # guardrails, fallback models, structured output
```

## Skills

| Skill | What it does |
|---|---|
| `commotion-create-worker` | From a described goal, grounds in the live schema, interviews, drafts the worker (name, prompt, voice + languages, guardrails, fallbacks, structured output), provisions + enables its agent(s), optionally attaches knowledge and tools, and deploys on approval. |

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
