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
| PUT | `/aiworker/km-setting/setting/{settingId}` | **the web crawler** (`webCrawlerConfig`) — a different plane; see "Web crawler" |

Item shape: `commotion_schema` `{ "schema_name": "CreateAiWorkerKnowledgeItemRequest" }`.

## The golden rules (verified against the dev3 spec)

1. **Grounding is automatic — there is no RAG toggle.** Once knowledge is created **and indexed**
   for a worker's `aiWorkerId`, the worker grounds on it. Nothing on `AiWorkerRequest`/`AiAgentRequest`
   turns RAG on or off.
2. **Every source you create ends in create → index.** You create knowledge item(s)
   (`POST …/knowledge/bulk`), then index their ids (`POST …/knowledge/index`). **Two exceptions:** a
   **global KB** (already published), and the **web crawler** (it creates *and* indexes its own items —
   you only write its config; see rule 9).
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
7. **Status fields are human-readable labels, not raw enums.** `aiWorkerKnowledgeStatus` reads
   `"Draft"` → `"In Progress"` → ready; a fresh bulk item starts at `"Draft"`, and stays `"Draft"`
   until you index it.
8. **Each grounded agent must reference the KB in its own prompt.** Worker-level attach does *not*
   bind it to an agent — embed the mention token `[knowledge:<name>|id:<id>]` in the agent's
   `instructions` (see "Binding knowledge to an agent" below).
9. **⚠ NEVER hand-create a `WEBSITE_CRAWL` knowledge item — but the crawler itself is real.**
   There *is* a working web crawler; it just isn't driven from the knowledge plane. You configure it on
   the **`km-setting`** plane (`webCrawlerConfig`) and it creates its own knowledge entries. See
   "Web crawler" below — that section is the whole story.

   What fails is creating the item yourself. `POST /aiworker/knowledge/bulk` with
   `aiWorkerKnowledgeType: "WEBSITE_CRAWL"` and a URL in `sourceUrlIdentifier` is accepted with **`200`**
   (the enum is valid), lands at `Draft`, then flips to **`Failure`** on index — because
   `sourceUrlIdentifier` is always a blob key (rule 5), so the URL gets percent-encoded and appended to
   the container:
   `https://…blob.core.windows.net/mvmt-dev-digitalassets-storage-data/https%3A%2F%2Freact.dev%2Flearn`.

   Verified live 2026-08-05 on two separate workers — identical `Failure` both times, and enabling
   `webCrawlerConfig` first does **not** change it. The crawl plane and the bulk plane are unrelated:
   **never call `/knowledge/bulk` (or `/file-upload/*`, or `/knowledge/index`) for a crawl.** If a
   `WEBSITE_CRAWL` item is sitting at `Failure`, delete it (`DELETE /aiworker/knowledge` with `[id]`).
10. **`pageNumber` is 0-based on `GET /aiworker/knowledge`.** `pageNumber=1` on a worker with one page
    of items returns `[]` — which reads as "no knowledge" and is not. Start at `pageNumber=0`.

## The knowledge item (`CreateAiWorkerKnowledgeItemRequest`)

Required: **`aiWorkerId`**, **`name`**, **`fileName`**, **`sourceUrlIdentifier`**, **`sourceType`**,
**`aiWorkerKnowledgeType`**, **`category`**. Enums (run `commotion_schema` `{ "schema_name":
"CreateAiWorkerKnowledgeItemRequest" }` for the live set):

- **`sourceType`** — `HTML`, `PDF`, `DOC`, `PPT`, `VIDEO`, `IMAGE`, `CSV`, `XLSX`, `TEXT`, `MARKDOWN`.
- **`aiWorkerKnowledgeType`** — e.g. `TEXT_UPLOAD`, `DOCUMENT_UPLOAD`, `KNOWLEDGE_BASE`,
  `WEBSITE_CRAWL`, `CLOUD_IMPORT`, … Use **`TEXT_UPLOAD`** for inline text *and for fetched web pages*,
  **`DOCUMENT_UPLOAD`** for files. **Never pass `WEBSITE_CRAWL` yourself — see golden rule 9**; the
  crawler sets that type on the entries *it* creates (see "Web crawler").
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

**Fetched web page (a one-off snapshot — NOT the crawler; verified live):**

Use this when you want **one specific page, indexed right now**. The crawler is the right tool for a
site (or for content that should stay fresh), but over the API it only runs on its schedule — so if the
user needs the content usable this minute, snapshot it here and say plainly that you ingested a
point-in-time copy rather than a crawl. For a whole site, prefer "Web crawler" below.

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
Reached `Completed` on the same page whose hand-made `WEBSITE_CRAWL` attempt reached `Failure`. For a PDF
or other binary at a URL, download it and use the **Uploaded document** recipe (`/file-upload/url` + the
Azure `curl` PUT) instead.

## Web crawler (`webCrawlerConfig`) — verified live 2026-08-05

The crawler is real and it works. It lives on the **`km-setting`** plane, not the knowledge plane, which
is why it's easy to miss. **Configuring it is the entire job**: the crawler fetches the pages, converts
them to markdown, uploads them to blob storage itself, creates the knowledge items, and indexes them.

> **You make exactly one call.** No `/file-upload/*`, no `/knowledge/bulk`, no `/knowledge/index` —
> doing any of those for a crawl is the golden-rule-9 mistake and produces a `Failure` item.

```
GET /aiworker/km-setting/<workerId>            # read settingId; confirm status is SUCCESS
PUT /aiworker/km-setting/setting/<settingId>   # { entityId, webCrawlerConfig: {...} }   <-- the only call
# then WAIT for the schedule; poll GET /aiworker/km-setting/<workerId> -> webCrawlerConfig.lastCrawlInfo
```

**`WebCrawlerConfigRequest`** (ground it with `commotion_schema { "schema_name":
"WebCrawlerConfigRequest" }`): `enabled`, `seedUrls` (array), `crawlDepth` (link levels from seed, 1–5),
`maxPages` (per crawl run, max 100), `sameDomainOnly`, `excludeUrlPatterns` (array),
`syncFrequency` (`DAILY` | `WEEKLY` | `MONTHLY`), `authType` (`NONE` | `BASIC` | `COOKIE`),
`authCredentials`, `lightweightMode`, `respectRobotsTxt`.

**Read-back only — `lastCrawlInfo`:** `lastCrawlStatus` (`PENDING` → `CRAWLING` → `INDEXING` →
`COMPLETED` | `PARTIAL` | `FAILED`), `lastCrawlStartedAt` / `lastCrawlCompletedAt` (epoch ms),
`lastCrawlErrorMessage`, and counters `pagesDiscovered` / `pagesCrawled` / `pagesIndexed` /
`pagesSkipped` / `pagesFailed` / `pagesRemoved`. It is `null` until the first crawl runs.

### What the crawler produces

A crawl creates **one knowledge item per page, entirely on its own** — verified: a completed run took
**35s** and returned `lastCrawlStatus: COMPLETED`, `pagesCrawled: 1`, `pagesIndexed: 1`. The item it made:

| Field | Value |
|---|---|
| `name` | the page's real `<title>` — e.g. `Quick Start – React` (not your seed URL) |
| `aiWorkerKnowledgeType` | `Website Crawl` |
| `sourceType` | `MARKDOWN` (pages are converted to `.md`) |
| `fileName` | slugged title — e.g. `Quick_Start___React.md` |
| `sourceUrlIdentifier` | a **system**-generated blob key: `demo/<orgId>/system/<rand>-https___react.dev_learn.md` |
| `aiWorkerKnowledgeStatus` | `Completed` — already indexed, no `/knowledge/index` call needed |

### REQUIRED — report the arrangement back to the user

The crawler is the one knowledge source where **nothing visible happens when you finish**. You write a
config, get a `200`, and the KB stays empty — so a user who isn't told will reasonably think it failed, or
will go looking for the documents you "forgot" to upload. **Never leave them in the dark: after the PUT
succeeds, say plainly what you set up, that it runs on a schedule, and that the entries appear and index
themselves.** State the actual frequency you configured, not a generic "periodically".

Something like:

> Web crawling is now configured in this worker's knowledge settings — seeded from
> `https://docs.example.com`, following links 2 levels deep, up to 25 pages, same-domain only.
> It runs **daily**. You don't need to upload anything: each crawl fetches the pages, creates a knowledge
> entry per page, and indexes them automatically. The knowledge list is empty until the first run
> completes — that's expected, not a failure. I can check `lastCrawlInfo` afterwards to confirm pages
> crawled and indexed.

Adjust for the schedule in play — `WEEKLY` and `MONTHLY` mean a correspondingly longer wait before the
worker has any grounding at all, which is worth flagging explicitly if they intend to deploy sooner. And if
they need the content usable **now**, offer the "Fetched web page" snapshot instead of leaving them waiting
(the UI's Trigger button is the other option, but that's theirs to click, not yours).

### Gotchas (all verified live)

1. **There is NO manual trigger over the API.** The UI has a "Trigger Web Crawler Sync" button; the API
   has no equivalent — no crawl route exists among the spec's 220 paths, `/v3/api-docs/swagger-config`
   exposes only the `public` group, and six plausible routes (`…/setting/{id}/sync`,
   `…/km-setting/{id}/crawl`, `/aiworker/web-crawler/sync`, `…/web-crawler/trigger`, …) all return a
   generic Spring `404`. **So over the API a crawl happens only on its schedule (`DAILY` ≈ midnight).**
   Tell the user this up front: after you save the config, nothing appears until the scheduled run. If
   they need it now, either they click Trigger in the UI, or you snapshot the page with the
   "Fetched web page" recipe.

   *Verification status:* the crawl **mechanism** is confirmed end-to-end (config → fetch → markdown →
   item → indexed), but the runs observed on 2026-08-05 were **manual UI syncs**, not scheduled ones — so
   "the `DAILY` schedule fires on its own" is reported behaviour, not yet independently confirmed. Don't
   promise the user a specific firing time; tell them it lands on the next scheduled run and check
   `lastCrawlInfo` afterwards.
2. **A broken index silently swallows the crawl.** If the worker's `km-setting` `status` is `FAILED`, the
   crawl still runs and still fetches the page, but its item stays stuck at **`Draft`** and is never
   indexed — the crawler reports success while nothing reaches the KB. **Always confirm `status:
   "SUCCESS"` / `indexCreated: true` before relying on the crawler.** See the `chunkingConfig` warning
   in the `km-setting` section below for the easiest way to break exactly this.
3. **`lightweightMode: true` skips JS rendering, so SPAs yield one page.** On `https://react.dev/learn`
   (a JS-rendered SPA) a `crawlDepth: 1, maxPages: 5` run crawled **1** page — no links were
   discoverable without rendering. Leave `lightweightMode` **off** for anything JS-driven; only turn it
   on for genuinely static HTML.
4. **`pagesDiscovered` comes back `null`** even on a `COMPLETED` run while every other counter populates.
   Don't drive logic off it; use `pagesCrawled` / `pagesIndexed`.
5. **`webCrawlerConfig` merges — omitting it does not clear it.** A later PUT without the block leaves
   the stored crawler config intact. To stop crawling, send `enabled: false` explicitly.
6. **`commotion_schema` can serve a stale spec.** `KMSettingUpdateRequest` came back *without*
   `webCrawlerConfig` from cache; `{"refresh": true}` returned it. If a field you expect is missing,
   refetch before concluding it doesn't exist.

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
— and write it the **Phase-6 way** (`PUT /aiagent/{id}` with the full body; it renders in the UI editor).
The `<knowledgeId>` is the id returned by the bulk create / list; `<name>` matches the item's `name`.
The token is byte-identical to what the UI's `/Knowledge` command stores in `instructions`, and
round-trips intact via the API.

**Note (verified live):** `PUT` places the prompt *and* the token visibly — verified 2026-08-07 that a
`PUT /aiagent/{id}` renders in the UI prompt editor, into a blank editor and over an existing prompt
alike (this replaces the older 2026-07-21 finding that a PUT left the editor blank). The token renders as
**plain text** rather than a styled Knowledge chip — cosmetic only; grounding works at runtime (a
Test-Agent run answered correctly from the document).

## Knowledge settings — indexing / embedding / chunking (`km-setting`, verified live)

A worker's RAG **indexing/embedding/chunking** config is a separate, **auto-provisioned** setting (one
per worker) — you don't create it, you edit it in place. The defaults are sensible; only touch this
when the use case needs a specific chunking/embedding strategy. This is also where the **web crawler**
lives (`webCrawlerConfig` — see the section above).

> ### ⚠ A partial `chunkingConfig` permanently destroys the worker's index
>
> `chunkingConfig` has **six** file-type blocks (`pdf`, `markdown`, `csv`, `xlsx`, `docx`, `image`). Send
> the field with any of them missing and the absent ones are set to **`null`**, a new `indexName` is
> minted, index creation **fails**, and `indexId` / `collectionName` are wiped:
>
> ```
> status: "FAILED", errorMessage: "Please modify settings for index creation", indexCreated: false
> ```
>
> **It is not recoverable** — re-PUTting all six blocks still fails, and the worker's KB is dead (any
> crawl or upload afterwards sticks at `Draft`, never indexed). Verified live 2026-08-05: reproduced on
> two workers, isolated by elimination — `entityType`, `collectionName`, `indexingConfig`,
> `embeddingConfig` and repeat PUTs are each individually harmless; **only the partial `chunkingConfig`
> triggers it.**
>
> **So: PUT only the blocks you are actually changing, and omit `chunkingConfig` entirely unless you are
> sending all six.** Omitted top-level blocks are merged/preserved, so the minimal PUT is safe and is what
> you should default to:
>
> ```
> PUT /aiworker/km-setting/setting/<settingId>   { "entityId": "<workerId>", "webCrawlerConfig": {...} }
> ```
>
> Do **not** "read the GET response and send it all back" — that recipe is what breaks it, because the GET
> shape and the PUT shape are not interchangeable. Read `status` back after every PUT.

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/aiworker/km-setting/metadata` | valid indexing/embedding/chunking options |
| GET | `/aiworker/km-setting/{entityId}` | the worker's setting (`entityId` = the worker id) |
| PUT | `/aiworker/km-setting/setting/{settingId}` | update it (`KMSettingUpdateRequest`) |

**Verified live (dev3, 2026-07-20):** `GET /aiworker/km-setting/<workerId>` returns the setting object
whose top-level keys include **`settingId`**, `entityId` (= the worker id), `indexName`, `status`,
`indexId`, `indexCreated`, `collectionName`, `webCrawlerConfig`, and the `indexingConfig` /
`embeddingConfig` / `chunkingConfig` blocks. So the flow is:
`GET /aiworker/km-setting/<workerId>` → read `settingId` → `PUT /aiworker/km-setting/setting/<settingId>`
with `KMSettingUpdateRequest` — whose writable fields are `entityId`, `entityType`, `collectionName`,
`indexingConfig`, `embeddingConfig`, `chunkingConfig` (per file-type:
`pdf`/`markdown`/`csv`/`xlsx`/`docx`/`image`), `piiMaskingConfig`, and **`webCrawlerConfig`** — but
**send only the fields you're changing** (see the warning above; a partial `chunkingConfig` is fatal).
Ground the exact shapes with `commotion_schema { "schema_name": "KMSettingUpdateRequest", "refresh":
true }` and the metadata endpoint before writing. Note `GET /aiworker/km-setting/metadata` carries **no**
crawler options — the crawler's valid values come from `WebCrawlerConfigRequest` only.

## Where this sits in the create-worker flow

Attach knowledge **after the agent(s) are provisioned and before deploy** (SKILL.md Phase 7). For an
**FAQ agent**, the knowledge base is what it answers from — attach + index it here, and the FAQ
agent's strict-grounding instructions (see `agents-and-orchestration.md`) keep it from inventing
when an answer isn't in the docs. Show the user what you're attaching before each write.
