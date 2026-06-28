# Knowledge & RAG grounding

How to attach source material to a worker so it **grounds** its answers in it (RAG), over the dev3
`/aiworker/knowledge` and `/aiworker/file-upload` planes (called directly over HTTP — see
`api-and-auth.md`). This is the companion to `agents-and-orchestration.md` (the FAQ agent that
answers strictly from this material lives there).

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

Item shape: `fetch_schema.sh CreateAiWorkerKnowledgeItemRequest`.

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
   byte PUT goes **straight to cloud storage — not through Kong** — so you do it yourself. The store
   is **Azure Blob Storage**, so the PUT **must** include the header `x-ms-blob-type: BlockBlob` —
   without it Azure returns `400`. Success is **`201`** with an empty body (verified live).
5. **`sourceUrlIdentifier` links knowledge to its file.** Pass the upload's returned
   `fileUrlIdentifier` as the knowledge item's `sourceUrlIdentifier`.
6. **The file must be readable on the machine Claude runs on.** The PUT reads bytes from a local
   path. If the user gives a URL, download it to a local file first, then upload — there is no
   server-side "ingest from URL" in this flow.
7. **Status fields are human-readable labels, not raw enums.** `aiWorkerKnowledgeStatus` reads
   `"Draft"` → `"In Progress"` → ready; a fresh bulk item starts at `"Draft"`, and stays `"Draft"`
   until you index it.
8. **Each grounded agent must reference the KB in its own prompt.** Worker-level attach does *not*
   bind it to an agent — embed the mention token `[knowledge:<name>|id:<id>]` in the agent's
   `instructions` (see "Binding knowledge to an agent" below).

## The knowledge item (`CreateAiWorkerKnowledgeItemRequest`)

Required: **`aiWorkerId`**, **`name`**, **`fileName`**, **`sourceUrlIdentifier`**, **`sourceType`**,
**`aiWorkerKnowledgeType`**, **`category`**. Enums (run `fetch_schema.sh
CreateAiWorkerKnowledgeItemRequest` for the live set):

- **`sourceType`** — `HTML`, `PDF`, `DOC`, `PPT`, `VIDEO`, `IMAGE`, `CSV`, `XLSX`, `TEXT`, `MARKDOWN`.
- **`aiWorkerKnowledgeType`** — e.g. `TEXT_UPLOAD`, `DOCUMENT_UPLOAD`, `KNOWLEDGE_BASE`,
  `WEBSITE_CRAWL`, `CLOUD_IMPORT`, … (use `TEXT_UPLOAD` for inline text, `DOCUMENT_UPLOAD` for files).
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
# PUT the bytes yourself — straight to cloud storage, NOT through Kong:
curl -X PUT --upload-file ./handbook.pdf -H 'x-ms-blob-type: BlockBlob' "<preSignedUrl>"   # expect 201
POST /aiworker/knowledge/bulk  [{ aiWorkerId:<id>, name:"Handbook", fileName:"handbook.pdf",
        sourceType:"PDF", aiWorkerKnowledgeType:"DOCUMENT_UPLOAD", category:"MANUAL",
        sourceUrlIdentifier:<fileUrlIdentifier> }]
POST /aiworker/knowledge/index  [ "<item id>" ]
# poll until ready
```

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

Set it with `PUT /aiagent/{id}` and body `{..., instructions: "<prose>\n\n[knowledge:<name>|id:<id>]"}`.
The `<knowledgeId>` is the id returned by the bulk create / list; `<name>` matches the item's `name`.
The token is byte-identical to what the UI's `/Knowledge` command stores in `instructions`, and
round-trips intact via the API.

**Note (verified live):** an API-injected token renders in the editor as **plain text** rather than
a styled Knowledge chip — but that is **cosmetic only**. Grounding works at runtime: a Test-Agent
run answered correctly from the document with the token written purely via `PUT /aiagent/{id}`. So you
do **not** need the UI `/Knowledge` command — writing the token into `instructions` is sufficient.

## Where this sits in the create-worker flow

Attach knowledge **after the agent(s) are provisioned and before deploy** (SKILL.md Phase 7). For an
**FAQ agent**, the knowledge base is what it answers from — attach + index it here, and the FAQ
agent's strict-grounding instructions (see `agents-and-orchestration.md`) keep it from inventing
when an answer isn't in the docs. Show the user what you're attaching before each write.
