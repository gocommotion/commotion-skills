# Settings — pronunciation dictionaries & state variables

Two worker **Settings** subsystems that shape *how* a worker speaks and *what* it remembers:
**pronunciation dictionaries** (teach the TTS to say domain terms correctly) and **state variables**
(values the worker tracks across a call so it doesn't re-ask, and can pull from a tool once). Unlike
guardrails/fallback (which are fields on `AiWorkerRequest`), these are their **own worker-scoped
resources** — `/ai-pronunciation-dict` and `/ai-worker-variable-schema` — reached through the two
Commotion MCP tools (`commotion_request` / `commotion_schema` — see `api-and-auth.md`). Ground field
shapes in `commotion_schema`; this file is the *behavior* the schema doesn't tell you.

(Knowledge Settings — indexing / embedding / chunking, the `/aiworker/km-setting` plane — are a
different Settings surface and live in `knowledge-and-rag.md`.)

## Golden rules (verified live against dev3, 2026-07-20)

1. **Independent worker-scoped resources, full CRUD — created on a DRAFT, shown before write.** Both
   have `POST` (create), `GET` list (filter by `workerId` + `version`), `GET`/`PUT` by id, and a bulk
   `DELETE` (array body). They are **not** fields on `AiWorkerRequest` and are **not** auto-provisioned
   — you create each entry explicitly, scoped to `(aiWorkerId/workerId, version)`, same draft-only
   discipline as agents/tools. Request fields use `…Request` suffixes; a retrieve returns `…Response`.
2. **The id field name differs — read the right one.** A pronunciation entry's id comes back as
   **`pronunciationDictId`** (NOT `id`); a state variable's id comes back as **`id`**. Both endpoints
   also 200 without echoing a top-level `id`, so read the correct field from the create/list body.
3. **Uniqueness is enforced.** Pronunciation `inputText` is unique per `(worker, version)` — a
   duplicate returns `400 "Pronunciation dictionary with input text 'X' already exists."`. A state
   variable `title` is unique per `(worker, agent, version)`.
4. **A `LOADED` variable needs a loading strategy + a tool.** `POST` with `variableSource:"LOADED"`
   but no `loadingStrategy` returns `400 "Variable creation failed: Loading strategy is required when
   variable source is LOADED"`; a LOADED variable also needs a `toolReference` (which tool produces
   the value). `EXTRACTED` variables need neither.
5. **Creating a variable does NOT bind it — the agent must name it in its prompt.** Agents read a
   state variable via the mention token **`[var:<title>]`** in `instructions` (same family as
   `[tool:…]` / `[knowledge:…]`). Defining the schema entry just makes the variable *available*; the
   agent only uses it if its prompt references it. **Bind it the Phase-6 way:** compose the `[var:…]`
   token into the agent's `instructions` and **`PUT /aiagent/{id}`** (full body — `PUT` is a full
   replace); the prompt renders/edits in the UI and the agent id is preserved (verified live 2026-08-07 —
   see `agents-and-orchestration.md`). A **code-block tool** can also
   consume a state variable directly via its `stateVariables[]` (by the variable's `id`), not only the
   prompt token — see `tools-and-capabilities.md`.

## Pronunciation dictionaries — `/ai-pronunciation-dict`

Teach the TTS to pronounce brand names, acronyms, and domain terms correctly (e.g. read `NPCL` as
"N-P-C-L", not "nipple"). Each entry is one `inputText` → one pronunciation, in a chosen notation.

| Method | Path | Purpose | Schema |
|--------|------|---------|--------|
| GET | `/ai-pronunciation-dict?workerId=&version=&pageNumber=&pageSize=&sortDirection=` | list a worker/version's entries | — |
| GET | `/ai-pronunciation-dict/{pronunciationDictId}?version=` | one entry | — |
| POST | `/ai-pronunciation-dict` | create an entry | `AiPronunciationDictRequest` |
| PUT | `/ai-pronunciation-dict/{pronunciationDictId}` | update an entry (full body) | `AiPronunciationDictRequest` |
| DELETE | `/ai-pronunciation-dict` | bulk delete (array body) | `DeleteAiPronunciationDictRequest` |

**`AiPronunciationDictRequest`** — required `aiWorkerId`, `version`, `inputText`; plus `pronunciation`
and `pronunciationType`:

- **`inputText`** — the exact string as it appears in the agent's text output (e.g. `NPCL`, `IHCL`,
  `TML`). Unique per worker+version.
- **`pronunciation`** — the phonetic rendering, in the notation set by `pronunciationType`.
- **`pronunciationType`** ∈ **`ALIAS` | `IPA` | `CMU` | `SYMBOL` | `PHONEME`**. Map to the UI:
  - **`ALIAS`** — familiar-spelling / say-it-like-this (e.g. `"N-P-C-L"`, `"eye-tch-see-el"`). Best for
    acronyms and brand names — the simplest, most robust choice.
  - **`IPA`** / **`SYMBOL`** — International Phonetic Alphabet symbols. Best for non-English terms or
    unusual phonetics.
  - **`CMU`** / **`PHONEME`** — ARPAbet/CMU phoneme codes (e.g. `AH0 L OW1`) for exact machine-readable
    control.

Use it when the worker says domain jargon the TTS mangles: company/brand names, product SKUs,
acronyms, non-English proper nouns. Prefer `ALIAS` unless you need phoneme-level precision. You usually
**can't enumerate these up front — a simulation run surfaces them**: when the tester-bot's transcript
mis-hears a term (the ASR wrote a different word than the worker was told to say), add an entry for that
term. That signal-driven discovery is the primary trigger — see `commotion-run-evals`
(simulation-and-results.md) and `commotion-improve-worker`.

## State variables — `/ai-worker-variable-schema`

Dynamic values the worker tracks through a single call session — so it remembers a caller's account
number, sentiment, or pre-loaded profile and doesn't ask again. Two things a variable can be:
**`EXTRACTED`** (the LLM pulls it from what the caller says) or **`LOADED`** (fetched from a tool/API,
either at call start or when a tool fires).

| Method | Path | Purpose | Schema |
|--------|------|---------|--------|
| GET | `/ai-worker-variable-schema?workerId=&version=&pageNumber=&pageSize=&sortDirection=` | list a worker/version's variables | — |
| GET | `/ai-worker-variable-schema/{variableId}` | one variable | — |
| POST | `/ai-worker-variable-schema` | create a variable | `AiWorkerVariableSchemaRequest` |
| PUT | `/ai-worker-variable-schema/{variableId}` | update a variable (full body) | `AiWorkerVariableSchemaRequest` |
| DELETE | `/ai-worker-variable-schema` | bulk delete (array body) | `DeleteAiWorkerVariableSchemaRequest` |

**`AiWorkerVariableSchemaRequest`** — required `workerId`, `version`, `title`. Key fields:

- **`title`** — the variable name used in the prompt as `[var:<title>]` (e.g. `customer_intent`,
  `account_id`). Unique per worker+agent+version.
- **`description`** — what it stores (helps the LLM extract / other authors understand it).
- **`variableCategory`** ∈ `STATE` | `LLM` (defaults **`STATE`** — the conversational state variable
  case; `LLM` variables are the code-block `{{[llmvar:..]}}` family, distinct from the prompt
  `[var:..]` token).
- **`variableType`** ∈ `TEXT` | `NUMBER` | `INTEGER` | `FLOAT` | `DATE` | `BOOLEAN` | `ENUM` | `OBJECT`.
- **`variableSource`** ∈ **`EXTRACTED`** | **`LOADED`** | `WORKFLOW`:
  - **`EXTRACTED`** — the LLM reads the value from the conversation (sentiment, a stated preference, a
    callback number). Needs nothing else. Optional `defaultValue` is a fallback if nothing is extracted.
  - **`LOADED`** — fetched from a tool. **Requires `loadingStrategy` and `toolReference`.**
  - `WORKFLOW` — populated by a workflow step (WORKFLOW workers).
- **`availability`** ∈ `AUTO` | `ALWAYS_IN_CONTEXT` | `ON_DEMAND`. **`AUTO`** (recommended) lets the
  platform decide; `ALWAYS_IN_CONTEXT` injects it into every turn (small essential data like a name);
  `ON_DEMAND` fetches it via a lightweight call when needed (large payloads like full order history).
- **`multiValue`** (array of the type), **`possibleValues`** (allowed set for selection inputs),
  **`validation`** `{ format: DATE_TIME|TIME|DATE|EMAIL|DURATION }` (on TEXT), **`defaultValue`**.
- **`variableSchemaFields`** — nested field structure, **required for `OBJECT`** variables. Each
  `VariableSchemaField`: `name`, `type` (same enum), `required`, `multiValue`, `description`,
  `possibleValues`, `defaultValues`, `sourceAddress` (dot-path into the tool JSON, e.g.
  `data.customer_id`), `children`, `validation`.
- **LOADED-only:** **`loadingStrategy`** ∈ **`PRE_LOADING`** (fetch at call start — customer profile,
  account tier) | **`DYNAMIC_LOADING`** (fetch when a specific tool fires — order history only when the
  caller asks); **`toolReference`** `{ toolType (CUSTOM_TOOL|CODE_BLOCK|CONNECTORS|MCP_SERVER|
  BUILT_IN_ACTIONS|CUSTOM_ACTIONS|A2A_AGENT), toolMongoId, toolIdentifier (CONNECTORS only) }`;
  **`toolInputParams`** `[{ parameterName, value }]` (PRE_LOADING inputs); **`editableByAgent`**
  (whether the agent may overwrite the loaded value).

**Bind it in the prompt.** After creating the variable, reference it in the consuming agent's
`instructions` as `[var:<title>]` (for OBJECT variables you can drill in, e.g.
`[var:customer_data.last_order.amount]`). Without the token the agent won't use it. See
`agents-and-orchestration.md`.

## Recipes

**Pronunciation entry (create → verify):**
```
POST /ai-pronunciation-dict  { aiWorkerId:<id>, version:0, inputText:"NPCL",
                               pronunciation:"N-P-C-L", pronunciationType:"ALIAS" }
   -> read body.pronunciationDictId   (NOT body.id)
GET  /ai-pronunciation-dict?workerId=<id>&version=0   # confirm it's listed
```

**Extracted state variable (LLM pulls it from the call):**
```
POST /ai-worker-variable-schema  { workerId:<id>, version:0, title:"customer_intent",
   description:"Primary reason for the call", variableCategory:"STATE",
   variableType:"TEXT", variableSource:"EXTRACTED", availability:"AUTO" }
   -> read body.id
# then bind it: compose "... [var:customer_intent] ..." into the agent's instructions and
#   PUT /aiagent/<agentId> (full body) — it renders in the UI and keeps the agent id (Phase-6 rule)
```

**Loaded, pre-loaded state variable (fetched from a tool at call start):**
```
POST /ai-worker-variable-schema  { workerId:<id>, version:0, title:"customer_data",
   variableType:"OBJECT", variableSource:"LOADED", availability:"ON_DEMAND",
   loadingStrategy:"PRE_LOADING",
   toolReference:{ toolType:"CUSTOM_TOOL", toolMongoId:"<tool id>" },
   toolInputParams:[{ parameterName:"phone", value:"{Audience.Phone}" }],
   variableSchemaFields:[ { name:"tier", type:"TEXT", sourceAddress:"data.tier" },
                          { name:"name", type:"TEXT", sourceAddress:"data.name" } ] }
```

## Verified live (dev3, worker `6a5dce0cff0a5eea9a86c6c9`, draft v0, 2026-07-20)

On a fresh voice `SINGLE_AGENT` draft:
- **Pronunciation:** `POST /ai-pronunciation-dict` (NPCL/ALIAS) → 200 with **`pronunciationDictId`**
  (`6a5dd3f36cc5e39dce731c44`), no top-level `id`; `GET ?workerId=&version=0` listed it;
  `PUT /{pronunciationDictId}` changed the pronunciation and bumped `modifiedDate`; a second POST with
  the same `inputText` → `400 "... input text 'NPCL' already exists."`
- **State variable:** `POST /ai-worker-variable-schema` (`customer_intent`, EXTRACTED/TEXT/AUTO) → 200
  with **`id`** (`6a5dd3f4ff0a5eea9a86c6e0`); listed via `GET ?workerId=&version=0`. A LOADED POST with
  no `loadingStrategy` → `400 "... Loading strategy is required when variable source is LOADED"`.
- Both entries carried `createdByUserId:"system"` (created via the gateway key, not a user token —
  over the MCP the signed-in user is attributed instead).
- **Verified at runtime (live call/sim, not just a config round-trip):** the TTS **applies** a
  pronunciation entry — the term is spoken the way the entry specifies — and an **`EXTRACTED`** variable
  **is populated** from what the caller says during a real call.
- Not yet verified: that a **`LOADED`** variable fetches from its tool at runtime. And:
  `DELETE /aiworker/{id}` on a **never-deployed draft** returns `400 "Worker not found!"` (draft workers
  linger; delete isn't the cleanup path for them).

## Verified live (dev3, 2026-07-21 — workers `6a5f1014…fafa` + `6a5f1100…549f`, draft v0)

- **UI visibility — PUT vs POST.** *(Superseded 2026-08-07 — see below.)* On this date a
  `PUT /aiagent/{id}` on the **auto-provisioned default** agent set the runtime `instructions` while the
  UI prompt editor stayed **blank**, and only a delete + `POST /aiagent` rendered it. The `[var:…]` /
  `[tool:…]` tokens show as **plain text** (not styled chips) either way, but they're present and work.
- **UI visibility — PUT now renders (verified live 2026-08-07, supersedes the point above).** A
  `PUT /aiagent/{id}` renders the prompt in the UI editor — both on a never-POSTed default agent (chat
  worker `PUT UI Test 20260807`) and as an overwrite of a POST-created agent's existing prompt (voice
  worker `POST UI Test Voice 20260807`), both confirmed in the UI by a human. So `PUT` is the prompt-write
  path; it keeps the `aiAgentId`, which delete + re-POST does not.
- **Settings + tools render in the UI:** `customer_intent` shows under **Settings → State Variables**
  (Source *Extracted*, Availability *Auto*); `NPCL` under **Settings → Pronunciation Dictionaries**
  (Alias → `N-P-C-L`); the `intent_upper` code block under **Tools**.
- **Code-block ↔ state variable (confirmed).** `POST /ai-worker-tool/code-block` with
  `stateVariables:[{id}]` bound the variable (echoed back with `placeholder:null` for the extracted var).
  `POST /ai-worker-tool/code-block/run` with `{{[statevar:customer_intent]}}` +
  `stateVariableValues:[{id, value:"refund request"}]` printed the value — the placeholder is injected as
  a **pre-quoted literal**, so write `x = {{[statevar:title]}}` (the sandbox produces `x = "refund
  request"`), **not** `x = "{{[statevar:title]}}"` (double-quotes → `SyntaxError`).
