# Commotion Skills

Claude Skills (and the `commotion` MCP server config) for operating Commotion voice agents
through Claude.

## Overview

This project provides a set of [Claude Skills](https://docs.claude.com/en/docs/claude-code/skills)
plus the MCP server connection for building, testing, and improving voice agents — driven through
Claude as a single iterative loop:

```
Generate scenarios → Simulate → Evaluate → Diagnose → Create/Update agent → repeat
```

The **skills orchestrate the loop** (judgment + sequencing); the **`commotion` MCP server** (a
separate first-party repo) exposes the underlying platform capabilities as thin tools. The skills
in this repo call those tools — they don't reimplement the platform. All agent write-back is
human-approved.

## Layout

```
.claude-plugin/plugin.json            # plugin manifest (name: commotion)
.mcp.json                             # the `commotion` MCP server connection (token via env var)
skills/
  commotion-create-worker/
    SKILL.md                          # build & deploy a worker from a described goal
    references/aiworker-lifecycle.md  # the dev3 aiworker lifecycle gotchas
```

## Skills

| Skill | What it does |
|---|---|
| `commotion-create-worker` | From a described goal, grounds in the live config schema, interviews for the goal, drafts the worker (name, system prompt, voice + languages, guardrails), creates it as a draft, and deploys on approval. |

_More to come (coordinator/onboarding, update-worker, diagnose) as the loop fills in._

## Install (Claude Code)

This repo ships as a Claude Code **plugin** that bundles both the skills and the `commotion`
server connection, so one install wires up everything.

First, set the MCP bearer token the server expects (do **not** commit it):

```bash
export COMMOTION_MCP_TOKEN=<the MCP_BEARER_TOKEN the deployed server checks>
```

Then load the plugin. For local development, point Claude Code at this directory:

```bash
claude --plugin-dir /path/to/commotion-skills
```

Once published to the team plugin marketplace:

```
/plugin marketplace add gocommotion/commotion-skills
/plugin install commotion@commotion-skills
```

The skill then appears as `/commotion:commotion-create-worker` and auto-triggers when you ask
Claude to build a worker/voice agent.

### MCP server only (no skills)

If you just want the tools without the playbooks, add the server directly (see the
`commotion-mcp` repo README):

```bash
claude mcp add --transport http commotion \
  https://commotion-mcp-default.dev3.gocommotion.com/mcp \
  --header "Authorization: Bearer $COMMOTION_MCP_TOKEN"
```

> The `.mcp.json` here points at the dev3 host (`commotion-mcp-default.dev3.gocommotion.com`).
> Adjust the URL for other environments.

## Status

Early scaffolding — `commotion-create-worker` is the first skill. The `commotion` MCP server
lives in the separate `commotion-mcp` repo.

## License

TBD.
