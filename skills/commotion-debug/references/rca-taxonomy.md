# Failure classes + the platform-artifact signature table

How to turn Call Analyzer evidence into a named root cause. Companion to `commotion-debug/SKILL.md`
Phase 2. The *edit* for each class lives in the `commotion-create-worker` references cross-linked below;
this file is the **diagnosis**.

Two passes, in this order, and both are required:

1. **Classify** the failure (§1).
2. **Rule out a platform artifact** (§2) — because the most common false "the worker misbehaved" is a
   harness, infra or config artifact, and prompt-fixing one burns a round and changes nothing.

The rule that cuts both ways: **an infra artifact must not suppress a real prompt finding, and a real
finding must not launder an infra artifact.** A call can have both; name both.

## 1. Failure classes

| Class | What it looks like | Signal in Call Analyzer | Fix surface | Reference |
|---|---|---|---|---|
| **Prompt gap** | The worker never had the instruction it needed — a step it skipped, a case nobody wrote down | Transcript shows the miss; `context[]` shows no instruction covering it | Agent **`instructions`** (add) | agents-and-orchestration.md |
| **Prompt conflict** | Two instructions pull opposite ways; behaviour flips between calls | Two `context[]` clauses that contradict; the same input handled differently across calls in `/api/calls` | Agent `instructions` (edit / remove the loser) | agents-and-orchestration.md |
| **Ambiguity** | The instruction exists but is vague, so the model interprets it | `context[]` clause is hedged or unqualified; the worker's answer is defensible but wrong | Agent `instructions` (make it specific) | agents-and-orchestration.md |
| **Missing / misfiring tool** | The worker says it did something and nothing happened, or it loops | `toolCallMetrics[]` empty when it should not be; or an entry whose **`result` is an error string** — a dangling reference reads exactly `"Error: function '<name>' is not registered."` (verified live); or the same `function_name` repeated with identical `arguments` | Register or fix the tool; reference `[tool:<action>]` in the prompt | tools-and-capabilities.md |
| **Missing grounding** | The worker asserts a fact it could not know, or can't answer from material it should have | Assertion in the transcript with no corresponding `toolCallMetrics` entry and nothing in `context[]` supplying it | Attach + index knowledge, bind with `[knowledge:<name>\|id:<id>]`; add a grounding rule | knowledge-and-rag.md |
| **Config / state defect** | Wrong language, wrong voice, a variable never populated, an over-strict guardrail | `sessionState`, `callMetadata.state_configurations`, **`state_load_errors` non-empty**, `preload_status`; guardrail interception in the transcript | `PUT /aiworker/{id}` (full body) · `POST /ai-worker-variable-schema` · `POST /ai-pronunciation-dict` | control-and-reliability.md · settings-variables-pronunciation.md |
| **Platform artifact** | Not the worker at all — audio, infra, the model provider, or the harness | §2 below | Nothing in the worker. Report it | — |

**Tie-break** when two classes both fit: pick the one that produces the larger behaviour change if
fixed, and prefer the **more upstream** cause. A prompt fix layered over broken variable state fails
re-validation the same way the original did, so fix the state first.

**Class → change type**, as a default: *gap* → **add**; *conflict* → **edit or remove**; *ambiguity* →
**edit for specificity**; *tool / grounding* → **wire the capability**, then a one-line prompt rule to
use it. Adding prose to fix a conflict makes the conflict worse.

## 2. Platform-artifact signatures — classify as infra, never prompt-fix

Each row is a concrete reading, not a vibe. If one fires, the worker's prompt is not the cause.

The first four rows were all observed **live on 2026-07-28**, in a single 12-run test session. Check
them first — on this platform they fire more often than real worker defects do.

| # | Signature (where to look) | Root cause | What to do |
|---|---|---|---|
| **A** | `scenarioEvaluationResult` is **`ERROR`** or **`''`**, and/or `scenarioRunStatusLabel` is `Evaluation Error` / `Simulation Error` — while the call itself ran 40–60s with a full transcript | **The evaluator crashed, so there is no verdict.** Seen reason: `Goal completion evaluation failed: 3 validation errors for EvaluationMessage … channel_types.0 Input should be 'voice' or 'chat' [input_value='customer']` | **Judge from the Call Analyzer transcript instead** (`repro-and-gates.md` §1a). Verified live: **0 of 8 runs** produced a usable verdict. Never report this as "the worker failed" or as "not reproducible" |
| **B** | `audioMetrics.userTurnCount: 0` **and** `userAudioSeconds: 0.0`, `stopReason: user_idle_timeout`, bot politely greeting → waiting → hanging up | **The simulated caller was mute — the scenario never ran.** Root cause found live: every available personality had **`voiceEnabled: false`**, so the tester bot produced no audio | Harness artifact. Fix the personality (`voiceEnabled: true`) and re-run. There is nothing to diagnose in the worker |
| **C** | `passRate: 0.0` with `avgLatencyInMillis: null` on a `COMPLETED` simulation | **Ambiguous — do not read it as "the runs did not happen."** Verified live: a sim reported exactly this while all four calls existed with 42–57s durations | Discriminate on per-run `duration` and on whether the calls exist in Call Analyzer. Real durations + real calls = an evaluator failure (row A), not websocket exhaustion |
| **D** | `stopReason: pipeline_error` | ⚠ **Not self-explanatory — go to the logs, it is often a config gap.** Verified live, `level=error` decomposed it into: `[ALERT] Silent LLM response` → **`[ALERT] No fallback services available`** → `ErrorFrame(error: LLM produced empty response (no content, no tool calls), fatal: True)` → `PIPELINE ERROR … terminating call`. The model returned empty (a recoverable blip) and **no fallback model was configured to catch it**, so it became fatal and killed the call | **Configure a fallback model** (`control-and-reliability.md`) — this one is the worker's, not the platform's. Only treat it as an artifact once the logs show a genuinely post-conversation error (also seen live, on 4 otherwise-clean calls) |
| **E** | Tool-call syntax spoken aloud in an `assistant` turn — e.g. `Have a wonderful day! [tool:end_call{reason:` | The model emitted its tool-call markup as speech instead of invoking it | Platform/serialization artifact. Worth reporting; it is not fixed by rewording the instruction that mentions the tool |
| 1 | `stopReason: client_disconnected` with **sub-second `duration`**, or `wasConnected: false` | The call never really established | Report as infra. There is nothing in the transcript to fix |
| 2 | `callMetadata.state_load_errors` non-empty | State variables failed to load, so the worker ran without context it was configured to have | Fix the variable/config source, not the prompt |
| 3 | `contextCorruption.detected: true` (`corruptedTurns[]` / `unmatchedTurns[]`) | The context sent to the model diverged from the transcript — the model saw something other than the conversation | Platform issue; escalate. A prompt edit cannot compensate |
| 4 | `raw-inbound/gap-analysis`: `audioLossPercent > 0`, high `avgJitterMs`, `delays[]` with `severity: medium\|high` | Inbound audio was lossy or late — "the bot didn't hear me" is literal | Network/telephony. Not a VAD or prompt tune |
| 5 | `llmFallbackEvents[]` non-empty | The primary model failed. Read `fallbackSucceeded`: `true` → a fallback answered and the behaviour you are reading may be **its**, not the configured model's. **`false` → nothing caught it** | ⚠ `fallbackSucceeded: false` is usually a **worker config gap, not a platform fault** — see row D. Otherwise re-read the behaviour against the fallback |
| 6 | A `toolCallMetrics[]` entry whose **`result`** is an error/timeout string, or `latency_seconds` far above the rest | The tool's downstream failed | Fix the tool or its upstream. The prompt asked correctly |
| 7 | `callMetadata.preload_status` shows failure | The worker started before its resources were ready | Platform/config |
| 8 | `promptTokenStats` + `turnTokenBreakdown[]` climbing toward the model's window; degradation late in a long call | Context exhaustion — quality falls off with length, not with any one instruction | Reduce `initialContextCost` (fewer/smaller tools, shorter system prompt), not more prose |
| 9 | `stt-segment-audio/summary` shows `packetMappingStatus` not `aligned`, or the transcript's mishearing matches a segment boundary | ASR received the audio wrong | Pronunciation dictionary or audio path — the model answered the words it was given |
| 10 | `dataWarnings[]` / `playbackContract.warningCodes` (e.g. `heuristic-transcript-anchor`, `vad-duration-mismatch`) | The *analysis* is approximate here — timings are estimated | Don't build a latency or barge-in conclusion on estimated offsets |

**A guardrail interception is its own trap.** A call blocked by a guardrail can surface as an ordinary
failure. Check the guardrail configuration before classifying it as a prompt gap — the fix is tuning the
guardrail (`control-and-reliability.md`), and there is a known backend defect where interception reports
as `FAILED` rather than as a block.

## 2a. A dangling `[tool:…]` reference is provable without the defect firing

The commonest planted-and-real defect in this platform is a prompt that references a tool nobody
registered. You do **not** need the behaviour to reproduce to establish it — it is a **static**
mismatch between two things Call Analyzer already gives you:

1. the `[tool:<name>]` tokens in the agent's prompt (`?fields=config` → `context[]`, or
   `GET /aiagent/<id>?version=<n>` on the BE plane), and
2. `callMetadata.registered_tools[]` (`?fields=config`).

Any `[tool:<name>]` with no matching entry in `registered_tools` is dangling. When it does fire, the
runtime confirms it in `toolCallMetrics[]`:

```
get_policy_status({"policy_number":"AP44712290"})
  result : "Error: function 'get_policy_status' is not registered."   ← verified live
```

⚠ **`registered_tools` always contains the built-ins.** `end_call` is present on every call, so
`initialContextCost.toolCount: 1` means *"one tool, and it is the built-in"* — **not** "one custom tool
is wired." Read the names, never the count.

**The logs catch it earliest and most explicitly.** At call setup the pipeline logs its tool inventory,
before any turn happens:

```
level=debug&filter=|~:tools configured|No .* configured        (5 rows / 2.7 KB)
  pipeline_factories.setup_custom_tools:       No custom code tools configured
  pipeline_factories.setup_session_state_tools: No session-state builtin tools configured
  pipeline_factories.setup_a2a_tools:          No A2A agents configured
  pipeline_factories.setup_skills_tools:       No skills configured; skipping skills tool
```

If the prompt names a tool and those lines say nothing was configured, the defect is established ~10
seconds before the LLM attempts the call. And `level=debug&filter=|~:system instruction` returns the
composed prompt exactly as the model received it — so you can confirm the `[tool:…]` token really is in
what was sent, rather than trusting the config you *think* you wrote.

**The pairing that makes this severe.** A dangling tool alone yields a worker that says it cannot help.
A dangling tool **plus** a prompt that forbids admitting uncertainty yields a worker that **fabricates**
— verified live, the tool errored and the very next turn was:

> *"Thank you. I have checked your policy status. I can confirm that your renewal amount of four
> thousand nine hundred and ninety nine rupees has already been debited from your registered account."*

So when you find a dangling tool, always check the prompt for anti-uncertainty language ("always sound
certain", "never say you cannot", "do not ask them to call back"). That combination is two classes at
once — *missing tool* **and** *missing grounding* — and fixing only the tool leaves the fabrication
behaviour in place for the next thing the worker cannot verify.

## 3. Reading the transcript against the timeline

The transcript says *what* was said; the timeline and metrics say *whether the worker could have done
better*. Read them together:

- **Bot talked over the caller** → `turnTimeline[]` overlap plus `audioMetrics.botRatioPercent`. If the
  caller's turn had not finished, it is barge-in/VAD, not rudeness in the prompt.
- **"The bot was slow"** → `latencyMetrics.summary.avg_pipeline` and `latency.ttfb`. A slow *tool*
  (`toolCallMetrics[].latency_seconds`) and a slow *model* need opposite fixes.
- **Long silences** → `audioMetrics.silenceRatioPercent` with `silenceSeconds`. Compare against
  `/api/reports/latest` — if the fleet average is similar, it is normal for this worker.
- **"It repeated itself"** → repeated `assistant` turns with near-identical content, and check
  `contextCorruption` first (row 3) before concluding the prompt lacks an anti-repetition rule.
- **A masked transcript** (`hasMaskedTranscript: true`) means `maskedContent` is the PII-safe mirror.
  Quote from `maskedContent` in reports where you can still make the point.

## 4. One-off vs systemic

Scope changes the fix, so establish it before Phase 3:

- `/api/calls?workerId=<id>&limit=20` → how many recent calls share this `stopReason`?
- `/api/reports/latest` → the fleet baseline: `stop_reasons` distribution, error/success rate, latency,
  per-tool metrics.

A single bad call against a clean baseline is a **defect** — reproduce and fix it. A pattern matching the
fleet baseline is **systemic**: reproduce it if you can, but the fix is likelier to be config, capacity
or a platform artifact than one instruction, and a broad quality problem belongs to
`commotion-improve-worker`.

For a pattern across many calls, `POST /eval-insight-group` takes a `callIds` list and computes
failure-mode analysis over the set (`eval-domain-api.md`) — useful when you have twenty bad calls and no
single obvious cause yet.

## 5. The RCA record

Five slots, and every claim carries the evidence that proves it. **If you cannot quote it, you have not
established it** — no verbatim turn, tool `result` or metric value means no finding.

```
What the caller said        <verbatim transcript turn(s)>
What the worker did wrong   <verbatim turn + why it is wrong>
Root cause                  <one sentence>
Failure class + surface     <class from §1> → <the config surface that owns it>
Evidence                    <quoted signals, each with the endpoint it came from>
Scope                       one-off | systemic (N of 20 recent calls; fleet baseline X)
```

Name a platform artifact explicitly when one fired, even when you also found a real worker defect — the
user needs to know which part of the fix is theirs and which is the platform's.
