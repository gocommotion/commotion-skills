# Knowledge & RAG grounding

How to attach source material to a worker so it **grounds** its answers in it (RAG), over the dev3
`/aiworker/knowledge` and `/aiworker/file-upload` planes, reached through the two Commotion MCP tools
(`commotion_request` / `commotion_schema` — see `api-and-auth.md`). This is the companion to
`agents-and-orchestration.md` (the FAQ agent that answers strictly from this material lives there).
**One exception:** the presigned-URL byte upload (rule 4 below) is a **direct PUT to Azure Blob
Storage via `curl`** — it bypasses the backend entirely, so it is **not** an MCP call.

## Endpoints

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/aiworker/knowledge?aiWorkerId=&pageNumber=&pageSize=&knowledgeType=&knowledgeStatus=&sortDirection=` | list a worker's items; poll `aiWorkerKnowledgeStatus` |
| GET | `/aiworker/knowledge/{id}` | one item's full record |
| POST | `/aiworker/knowledge/bulk` | create item(s) — array body |
| POST | `/aiworker/knowledge/by-global/{globalId}?aiWorkerId=` | attach a published global KB |
| GET | `/aiworker/knowledge/global?pageNumber=&pageSize=&sortDirection=` | global-KB catalogue |
| POST | `/aiworker/knowledge/index` | index items (array of ids; sync → bool) |
| PUT | `/aiworker/knowledge/{id}` | rename an item (`{"name": ...}`) |
| DELETE | `/aiworker/knowledge` | delete items (array of ids in body) |
| POST | `/aiworker/file-upload/text` · `/aiworker/file-upload/url` · DELETE `/aiworker/file-upload/delete` | the file plane |

Item shape: `commotion_schema` `{ "schema_name": "CreateAiWorkerKnowledgeItemRequest" }`.

## The golden rules (verified against the dev3 spec)

1. **Grounding is automatic — there is no RAG toggle.** Once knowledge is created **and indexed**
   for a worker's `aiWorkerId`, the worker grounds on it. Nothing on `AiWorkerRequest`/`AiAgentRequest`
   turns RAG on or off.
2. **Every source ends in create → index.** You create knowledge item(s) (`POST …/knowledge/bulk`),
   then index their ids (`POST …/knowledge/index`). The one exception is a **global KB**, already published.
3. **Indexing is synchronous but not instant.** `POST …/knowledge/index` returns a boolean immediately,
   but the material becomes searchable a little later — **poll `GET /aiworker/knowledge?aiWorkerId=…`
   and wait until each item's `aiWorkerKnowledgeStatus` is ready** before relying on it / deploying.
4. **Files upload via a presigned URL.** `POST …/file-upload/url` / `…/file-upload/text` return a
   `preSignedUrl` (where the bytes go) and a `fileUrlIdentifier` (how knowledge references them). The
   byte PUT goes **straight to cloud storage — not through the backend / MCP** — so you do it yourself
   with a **direct `curl` PUT** (this one call is bash, not a `commotion_request`). The store is
   **Azure Blob Storage**, so the PUT **must** include the header `x-ms-blob-type: BlockBlob` —
   without it Azure returns `400`. Success is **`201`** with an empty body (verified live).
5. **`sourceUrlIdentifier` is ALWAYS a blob-storage key — never a URL.** Pass the upload's returned
   `fileUrlIdentifier` as the knowledge item's `sourceUrlIdentifier`. The backend builds the item's
   `sourceUrl` by concatenating the storage container with this value verbatim, so a URL put here
   becomes a nonexistent blob path and indexing fails. See rule 9.
6. **The file must be readable on the machine Claude runs on.** The PUT reads bytes from a local
   path. If the user gives a URL, download it to a local file first, then upload — there is no
   server-side "ingest from URL" in this flow.
9. **⚠ NEVER use `aiWorkerKnowledgeType: "WEBSITE_CRAWL"` over the API — there is no crawler behind it.**
   `WEBSITE_CRAWL` exists only as an enum value on the knowledge-type list. Searching the whole dev3
   spec (220 paths) there is **no crawl endpoint and no crawl-config field anywhere** — no seed URL,
   depth, or page-limit property in any schema. The crawler is a **UI-only** service; the API exposes
   only the final knowledge record, which must already point at fetched content in blob storage.

   Verified live 2026-08-03 (controlled A/B on one worker, same source page `https://react.dev/learn`):

   | Attempt | `aiWorkerKnowledgeType` | `sourceUrlIdentifier` | Resulting status |
   |---|---|---|---|
   | crawl | `WEBSITE_CRAWL` | `https://react.dev/learn` | **`Failure`** |
   | correct | `TEXT_UPLOAD` | `demo/…/1785740968209-yuiL_reactlearn.txt` | **`Completed`** |

   The crawl attempt is accepted with **`200`** (the enum is valid) and lands at `Draft`, then flips to
   `Failure` on index. Its `sourceUrl` shows the mechanism exactly — the raw URL got percent-encoded and
   appended to the container:
   `https://…blob.core.windows.net/mvmt-dev-digitalassets-storage-data/https%3A%2F%2Freact.dev%2Flearn`.

   **So to get a web page into a KB: fetch it yourself, convert it to text, and upload it** via
   `/file-upload/text` (or `/file-upload/url` for a real file) with
   `aiWorkerKnowledgeType: "TEXT_UPLOAD"` / `"DOCUMENT_UPLOAD"` — the "Fetched web page" recipe below.
   Tell the user plainly that the platform's own crawler is UI-only and you ingested a snapshot
   instead; don't silently present it as a crawl. If a `WEBSITE_CRAWL` item is already sitting at
   `Failure`, delete it (`DELETE /aiworker/knowledge` with `[id]`) rather than leaving it in the KB.
10. **`pageNumber` is 0-based on `GET /aiworker/knowledge`.** `pageNumber=1` on a worker with one page
    of items returns `[]` — which reads as "no knowledge" and is not. Start at `pageNumber=0`.
7. **Status fields are human-readable labels, not raw enums.** `aiWorkerKnowledgeStatus` reads
   `"Draft"` → `"In Progress"` → ready; a fresh bulk item starts at `"Draft"`, and stays `"Draft"`
   until you index it.
8. **Each grounded agent must reference the KB in its own prompt.** Worker-level attach does *not*
   bind it to an agent — embed the mention token `[knowledge:<name>|id:<id>]` in the agent's
   `instructions` (see "Binding knowledge to an agent" below).

## The knowledge item (`CreateAiWorkerKnowledgeItemRequest`)

Required: **`aiWorkerId`**, **`name`**, **`fileName`**, **`sourceUrlIdentifier`**, **`sourceType`**,
**`aiWorkerKnowledgeType`**, **`category`**. Enums (run `commotion_schema` `{ "schema_name":
"CreateAiWorkerKnowledgeItemRequest" }` for the live set):

- **`sourceType`** — `HTML`, `PDF`, `DOC`, `PPT`, `VIDEO`, `IMAGE`, `CSV`, `XLSX`, `TEXT`, `MARKDOWN`.
- **`aiWorkerKnowledgeType`** — e.g. `TEXT_UPLOAD`, `DOCUMENT_UPLOAD`, `KNOWLEDGE_BASE`,
  `WEBSITE_CRAWL`, `CLOUD_IMPORT`, … Use **`TEXT_UPLOAD`** for inline text *and for fetched web pages*,
  **`DOCUMENT_UPLOAD`** for files. **`WEBSITE_CRAWL` is unusable over the API — see golden rule 9**;
  it is accepted then fails to index.
- **`category`** — `FAQ`, `TROUBLESHOOTING`, `MANUAL`, `VIDEO`.

`fileType` on the file-upload bodies is `IMAGE` / `VIDEO` / `AUDIO` / `OTHER` (use `OTHER` for text/docs).

## Recipes

**Inline / pasted text:**
```
POST /aiworker/file-upload/text  { content:"<the text>", fileName:"policy.txt", fileType:"OTHER" }
   -> capture fileUrlIdentifier
POST /aiworker/knowledge/bulk  [{ aiWorkerId:<id>, name:"Refund policy", fileName:"policy.txt",
        sourceType:"TEXT", aiWorkerKnowledgeType:"TEXT_UPLOAD", category:"FAQ",
        sourceUrlIdentifier:<fileUrlIdentifier> }]
   -> capture the created item id
POST /aiworker/knowledge/index  [ "<item id>" ]
# poll GET /aiworker/knowledge?aiWorkerId=<id> until aiWorkerKnowledgeStatus is ready
```

**Uploaded document (PDF/docx/txt):**
```
POST /aiworker/file-upload/url  { fileName:"handbook.pdf", fileType:"OTHER" }
   -> capture preSignedUrl + fileUrlIdentifier
# PUT the bytes yourself — a DIRECT bash/curl upload to Azure Blob Storage, NOT an MCP call:
curl -X PUT --upload-file ./handbook.pdf -H 'x-ms-blob-type: BlockBlob' "<preSignedUrl>"   # expect 201
POST /aiworker/knowledge/bulk  [{ aiWorkerId:<id>, name:"Handbook", fileName:"handbook.pdf",
        sourceType:"PDF", aiWorkerKnowledgeType:"DOCUMENT_UPLOAD", category:"MANUAL",
        sourceUrlIdentifier:<fileUrlIdentifier> }]
POST /aiworker/knowledge/index  [ "<item id>" ]
# poll until ready
```

**Fetched web page (the substitute for the UI-only crawler — verified live):**
```
# 1. fetch + strip to text YOURSELF (bash/curl, not an MCP call). Keep the source URL in the text
#    so the grounding stays attributable:
curl -sL "https://react.dev/learn" -o page.html      # then strip tags -> page.txt
# 2. upload the TEXT (content goes in the body; no separate byte PUT for /file-upload/text):
POST /aiworker/file-upload/text  { content:"<the extracted text>", fileName:"react-learn.txt",
        fileType:"OTHER" }                            -> capture fileUrlIdentifier
# 3. create as TEXT_UPLOAD - NOT WEBSITE_CRAWL:
POST /aiworker/knowledge/bulk  [{ aiWorkerId:<id>, name:"React Learn (react.dev)",
        fileName:"react-learn.txt", sourceType:"TEXT", aiWorkerKnowledgeType:"TEXT_UPLOAD",
        category:"MANUAL", sourceUrlIdentifier:<fileUrlIdentifier> }]
POST /aiworker/knowledge/index  [ "<item id>" ]
# poll GET /aiworker/knowledge?aiWorkerId=<id>&pageNumber=0 until "Completed"
```
Reached `Completed` on the same page whose `WEBSITE_CRAWL` attempt reached `Failure`. For a PDF or other
binary at a URL, download it and use the **Uploaded document** recipe (`/file-upload/url` + the Azure
`curl` PUT) instead.

**Existing global KB (already published — no index):**
```
GET  /aiworker/knowledge/global                                   # browse the catalogue
POST /aiworker/knowledge/by-global/<globalId>?aiWorkerId=<id>     # attach by global id + worker id
```

## Binding knowledge to an agent (the `/Knowledge` mention) — REQUIRED

Creating + indexing knowledge attaches it to the **worker**, but an **agent only uses it if the
agent's own prompt references it**. In the UI this is the `/Knowledge` block; over the API it is a
mention **token embedded in the agent's `instructions` string** — there is **no separate
agent↔knowledge field or endpoint** (verified against the schema and live). The token format is:

```
[knowledge:<knowledge name>|id:<knowledgeId>]
```

So a grounded agent's `instructions` should be your prose **plus** the token, e.g.:

```
Search the attached knowledge base and answer only from it; if a topic isn't there, say you
don't know - never guess, no outside knowledge.

[knowledge:General Knowledge Book|id:6a3a20eeb70d8b3ef551f387]
```

Compose it into the agent's `instructions` — `{..., instructions: "<prose>\n\n[knowledge:<name>|id:<id>]"}`
— and set it the **Phase-6 way** (POST-create / re-POST so it renders in the UI; a bare `PUT` writes the
runtime only — see the note just below on runtime-vs-editor).
The `<knowledgeId>` is the id returned by the bulk create / list; `<name>` matches the item's `name`.
The token is byte-identical to what the UI's `/Knowledge` command stores in `instructions`, and
round-trips intact via the API.

**Note (verified live):** bind the token by composing it into the **POST-created** agent's
`instructions` (the required POST-create rule — see `agents-and-orchestration.md`). It renders in the
editor as **plain text** rather than a styled Knowledge chip — cosmetic only; grounding works at runtime
(a Test-Agent run answered correctly from the document). But a `PUT` on the auto-provisioned default
agent sets the runtime `instructions` while the editor stays **blank** (verified 2026-07-21) — so don't
rely on `PUT` to place the prompt; POST-create (or re-POST) the prompt-bearing agent so it's visible in the UI.

## Knowledge settings — indexing / embedding / chunking (`km-setting`, verified live)

A worker's RAG **indexing/embedding/chunking** config is a separate, **auto-provisioned** setting (one
per worker) — you don't create it, you edit it in place. The defaults are sensible; only touch this
when the use case needs a specific chunking/embedding strategy.

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/aiworker/km-setting/metadata` | valid indexing/embedding/chunking options |
| GET | `/aiworker/km-setting/{entityId}` | the worker's setting (`entityId` = the worker id) |
| PUT | `/aiworker/km-setting/setting/{settingId}` | update it (`KMSettingUpdateRequest`) |

**Verified live (dev3, 2026-07-20):** `GET /aiworker/km-setting/<workerId>` returns the setting object
whose top-level keys include **`settingId`**, `entityId` (= the worker id), `indexName`, `status`,
`indexId`, and the `indexingConfig` / `embeddingConfig` / `chunkingConfig` blocks. So the flow is:
`GET /aiworker/km-setting/<workerId>` → read `settingId` → `PUT /aiworker/km-setting/setting/<settingId>`
with `KMSettingUpdateRequest` (`entityId`, `entityType`, `collectionName`, `indexingConfig`,
`embeddingConfig`, `chunkingConfig` (per file-type: `pdf`/`markdown`/`csv`/`xlsx`/`docx`/`image`),
`piiMaskingConfig`). Ground the exact shapes with `commotion_schema { "schema_name":
"KMSettingUpdateRequest" }` and the metadata endpoint before writing.

## Where this sits in the create-worker flow

Attach knowledge **after the agent(s) are provisioned and before deploy** (SKILL.md Phase 7). For an
**FAQ agent**, the knowledge base is what it answers from — attach + index it here, and the FAQ
agent's strict-grounding instructions (see `agents-and-orchestration.md`) keep it from inventing
when an answer isn't in the docs. Show the user what you're attaching before each write.
