# Reproduction, the stochastic gates, and loop bounds

The controller's behaviour for `commotion-debug` Phases 3–5: how a prod call becomes a failing
simulation, what "reproduced" and "fixed" mean numerically, what to do when neither holds, and how the
loop terminates. The simulation *mechanics* (request fields, polling, status progression) are
`commotion-run-evals/references/simulation-and-results.md`; this file is the **gates**.

## 1. Why the gates are rates, not verdicts

A voice simulation runs real audio over a real transport. Timing, VAD, interruption and provider latency
all vary run to run, so a defect that is deterministic in *cause* still fires only sometimes. One run
therefore proves almost nothing in either direction:

- One passing run after a fix is the single largest source of "looked fixed in dev, still broken in
  prod".
- One passing run *before* a fix would send you off to hunt a bug you had already reproduced.

So both gates are **M-of-N**, and both are **reported as the rate**: `3/4 failed`, `4/4 passed`. Never a
bare "reproduced" or "fixed".

## 1a. ⚠ Read the verdict from the transcript, not from `scenarioEvaluationResult` (verified live)

**The evaluator frequently returns no verdict at all, on runs whose calls were perfectly good.** Verified
live 2026-07-28 across two simulations, 8 runs, on a worker with a deliberately planted defect:
**0 of 8 produced a usable PASS/FAIL.** What came back instead:

| `status` | `scenarioRunStatusLabel` | `scenarioEvaluationResult` | What actually happened |
|---|---|---|---|
| `COMPLETED` | `Evaluation Error` | **`ERROR`** | 55-second call, full conversation. The *evaluator* crashed: `Goal completion evaluation failed: 3 validation errors for EvaluationMessage … channel_types.0 Input should be 'voice' or 'chat' [input_value='customer']` |
| `FAILED` | `Simulation Error` | **`''`** (empty) | 41-second call that **reproduced the defect perfectly**, with the failing tool call and the hallucination both in the transcript |

So: `scenarioEvaluationResult` is **not** limited to `PASS`/`FAIL` — it also takes **`ERROR`** and
**empty string**, and `status: COMPLETED` does **not** mean the run was evaluated.

**The procedure, therefore:**

1. Read `GET /scenario-run?simulationId=<sim-id>` and bucket each run:
   - **verdict** — `scenarioEvaluationResult` is exactly `PASS` or `FAIL`. Only these count.
   - **no-verdict** — `ERROR`, empty, or `scenarioRunStatusLabel` in
     {`Evaluation Error`, `Simulation Error`}. **Excluded from the M-of-N denominator.**
2. For every no-verdict run, **go to Call Analyzer and judge the transcript yourself**: find the run's
   call (the scenario-run `id` is the call's `requestId`, so
   `/api/calls?requestId=<scenario-run-id>`), fetch
   `?fields=transcript,metrics`, and decide PASS/FAIL against the scenario goal from the actual turns and
   `toolCallMetrics`. A transcript-derived verdict **counts** — say that it was transcript-derived.
3. Only if you can neither get an evaluator verdict **nor** find the call is the run genuinely
   undecidable. Report `n/4 decided`.

**Never report "not reproducible" when the real answer is "the evaluator did not run."** Those are
different findings with different owners, and conflating them sends someone to fix a worker that is fine
or to ignore one that is broken. This is exactly why this skill reads Call Analyzer: on this platform the
eval surface is the less reliable of the two.

## 2. N is 4, because the platform caps it there

A single `/simulation/run` runs its scenario-runs **concurrently over websockets**, and more than **4**
at once exhausts the connections — the excess runs fail with connection errors. So:

- **N = 4**, as `scenarioIdToRunPerScenarioMap: { <repro-scenario-id>: 4 }` — one simulation, 4 runs.
- **Reproduced: fails in ≥ 2 of 4** (`repro_threshold = ⌈N/2⌉`).
- **Fixed: passes in ≥ 3 of 4** (`verify_threshold = ⌈0.8·N⌉`).

The asymmetry is deliberate. Reproducing wants sensitivity — an intermittent defect is still a defect, so
half is enough. Verifying wants confidence — 4/4 would make a single flake look like a failed fix, and
2/4 would let a coin-flip pass as fixed.

**When 4 runs isn't enough to decide** — the repro sits exactly at 2/4 and the transcripts disagree about
*why* — run a **second batch of 4** sequentially (poll the first to completion, confirm
`GET /scenario-run/active?aiWorkerId=<worker-id>` is clear, then start the next) and judge over 8:
reproduced at ≥ 4/8, fixed at ≥ 7/8. Say you did this and report the combined rate. Do not raise the
per-simulation count above 4.

## 3. Building the repro scenario

### Preferred: generate it from the real conversation

`commotion_request` `{ "method": "POST", "path": "/scenario/generate-from-conversation", "body": {
conversationId, aiWorkerId, version, aiAgentChannelType } }`.

The `conversationId` is a **BE-side id and not the Call Analyzer `callId`**. Bridge them:

1. `GET /conversation/worker-conversations?workerId=<worker-id>` — the worker's conversations.
2. Match the record whose `voiceInteractionId` equals the Call Analyzer `<call-id>` (both are
   `call_…`-shaped) and take its conversation id.

> ⚠ **This bridge is the one link in the chain not yet confirmed live.** If the field names differ or the
> match doesn't resolve, don't improvise a path — go to the fallback. When you do confirm it, record
> what worked here.

### Fallback: author the scenario from the transcript

Invoke `commotion-generate-scenarios` and build one scenario whose caller instructions replay the prod
call. Same rules as above apply; the only thing you lose is automation.

### Rules that make a repro faithful

- **Copy the caller's turns verbatim.** Garbled words, truncations and STT artifacts are exactly what the
  model received in production — they are frequently *the trigger*. Tidying them up is the single most
  common way to build a scenario that cannot reproduce anything.
- **Pin the version.** Run against `<call-version>` (the `_N` suffix off the call's `workerId`), not
  whatever is live now. A defect fixed by a later deploy will not reproduce on the current version, and
  you would conclude "not reproducible" about a real bug.
- **Reproduce the goal, not just the words.** The scenario's goal must be the thing the worker failed to
  do, so the evaluator's PASS/FAIL keys off the actual defect.
- **Keep the scenario set identical between Phase 3 and Phase 5.** Same scenario id, no edits. A changed
  scenario makes the two rates incomparable and the whole gate meaningless.
- **Match the channel.** `aiAgentChannelType` must be the channel the call used. A voice defect
  reproduced over text is not reproduced.

## 4. When it will not reproduce — the diagnosis ladder

Work these in order before concluding anything. Most "won't reproduce" is one of the first three.

0. **⚠ Did the evaluator produce a verdict at all?** See §1a — the most likely answer is no. Check
   `scenarioEvaluationResult` for `ERROR`/empty before anything else, and judge from the Call Analyzer
   transcript instead. Verified live: **0 of 8 runs** returned a usable verdict.
1. **Did the simulated caller ever speak?** Fetch the run's call and read
   `audioMetrics.userTurnCount` / `userAudioSeconds`. **`userTurnCount: 0` with
   `userAudioSeconds: 0.0` and `stopReason: user_idle_timeout` means the tester bot was mute** — the
   scenario never ran, so there was nothing to reproduce. Verified live: 3 of 4 runs in one simulation
   were mute callers, with the worker correctly greeting, waiting, and hanging up. See §4a for the
   cause. This is a **harness artifact, never a worker failure.**
2. **⚠ `passRate 0.0` + `avgLatencyInMillis null` does NOT prove the runs didn't happen.** Verified
   live: a simulation reported exactly that while all four of its calls existed in Call Analyzer with
   42–57-second durations and full transcripts — the number was 0.0 only because *nothing could be
   evaluated*. Discriminate on the **per-run `duration`** and on whether the calls exist in Call
   Analyzer: genuine websocket exhaustion leaves near-zero durations and no calls; an evaluator failure
   leaves real durations and real calls. *(`/simulation/run` is also occasionally flaky with a generic
   500 `Simulation trigger failed. Please try again.` — but see §4a before retrying blindly.)*
3. **Wrong version.** Did you run against `<call-version>` or against live?
3. **The trigger isn't in the scenario.** Compare the repro transcript to the prod transcript turn by
   turn: is the caller actually saying the thing that broke it, in the same form? Did a paraphrase creep
   in? Does the scenario reach that point in the conversation at all (check `maxTurns`, `maxDuration`)?
4. **Evaluation hadn't finished.** `passRate` isn't final until every run leaves its `EVALUATION_*`
   state. Confirm `completedScenarios == totalScenarios` and check each record's `status` in
   `GET /scenario-run?simulationId=<sim-id>` before reading the rate.
5. **Wrong scenario shape.** Is the evaluator's goal the defect, or something adjacent that passes even
   when the defect occurs?
6. **It really is environment-dependent.** Re-read the platform-artifact table in `rca-taxonomy.md` — an
   infra artifact (lossy audio, a downstream tool outage, a model fallback) usually *cannot* be
   reproduced by a simulation, and that is itself the finding.

**Then stop.** Show the user the repro transcript beside the prod transcript and ask whether it matches.
An error is not a reproduction; a plausible-looking transcript is not a reproduction. Do not proceed to a
fix you cannot verify.

## 4a. ⚠ Two traps that make the verify run impossible to trigger (both hit live)

### Trap 1 — delete + re-POST the agent **breaks every scenario pinned to it**

`commotion-improve-worker` says to edit a prompt by **deleting the agent and re-POSTing** it (a bare
`PUT /aiagent/{id}` updates the runtime but leaves the UI editor blank). That is correct at *build*
time, and it is a **trap in this loop**, because the re-POST assigns a **new `aiAgentId`**, while your
repro scenario still stores the old one. The next `POST /simulation/run` then fails with:

```
500  {"message":"Simulation trigger failed. Please try again."}
```

— which reads like the known transient flake and is not. Retrying it forever will not help.

**So after any delete + re-POST of an agent, re-point the scenario before verifying:**

1. `GET /aiagent?workerId=<worker-id>&version=<draft-version>` → the **new** agent id.
2. `GET /scenario/<repro-scenario-id>` → check its `aiAgentId`.
3. If they differ, `PUT /scenario/<repro-scenario-id>` with the new `aiAgentId` (resend the fields you
   want to keep — it is a full replace).
4. Only then `POST /simulation/run`.

⚠ `PUT /scenario` **silently ignores a changed `version`** — verified live: sent `version: 1`, response
still reported `version: 0`, yet the simulation ran fine at v1. So the scenario's stored `version` is
not what binds it to a worker version; **`aiAgentId` is.**

> **The tension this creates, stated honestly.** §3 says keep the repro scenario byte-identical between
> Phase 3 and Phase 5 so the two rates are comparable. This trap forces you to mutate one field of it.
> Re-pointing `aiAgentId` is the *minimum* change that keeps the run triggerable, and it does not touch
> the caller script or the goal — so the rates stay comparable. Change nothing else, and say in the
> report that you re-pointed it.
>
> The alternative — `PUT /aiagent/{id}` to preserve the id — keeps the scenario untouched but leaves the
> prompt invisible in the UI editor, which the user will later see as an empty prompt. Prefer
> delete + re-POST + re-point.

### Trap 2 — a mute tester bot (`personality.voiceEnabled: false`)

Verified live: a 4-run simulation produced four 54–56s calls in which the caller **never spoke**
(`userTurnCount: 0`, `userAudioSeconds: 0.0`, `stopReason: user_idle_timeout`), because the chosen
personality had `voiceEnabled: false`. The worker behaved correctly throughout — greeting, re-prompting,
then hanging up — so the runs look like clean failures and are worth nothing.

**Pre-flight before any repro or verify simulation:**

```
GET /personality           → confirm the chosen record has voiceEnabled: true
```

If none do, that is a blocker to report, not something to work around: **a voice gate cannot be read
from a mute caller.** Note that a personality's name may describe a TTS voice (`Eleven_Flash_English`,
`Cartesia_Flash_English`) rather than a caller behaviour (`Angry`, `Frusted`, `2x Speaking`) — read
`prompt`, `mood`, `interruptionLevel` and `voiceEnabled`, not the name.

## 5. The overfitting check (run it before Phase 5)

Phase 4 wrote its edit having just read a failing transcript, and that exposure leaks: the most common
bad fix is the failing utterance pasted into the prompt as a trigger, turning a general instruction into
a string match against one call. Such a fix passes the repro and does nothing in production.

**Five signatures:**

| Signature | Example |
|---|---|
| Verbatim transcript quote | `If the caller says "i wanna cancel my polcy" then …` |
| Test-specific identifier | A scenario id, the test caller's name, the repro's phone number |
| Hardcoded test data | The exact policy number, amount or date from the prod call |
| Hyper-narrow case clause | A rule that fires only on the one input combination that failed |
| Transcript-cloned example | A few-shot example lifted whole from the failing call |

**The mechanical test.** Replace every proper noun, number and date in the edit with a placeholder, then
search the failing transcript for any **≥ 4-word contiguous substring** of what remains. A hit is a flag.

**Verdicts.** *Revise* (generalise the clause — the default), *strip* (remove it; the fix doesn't depend
on it), *keep* (a genuine domain term that happens to appear in the transcript — a product name, a real
policy rule). **When in doubt, revise rather than strip.** And when revising would invalidate the fix,
don't pick a side silently: show the user the tension and let them decide.

**Not flagged:** domain vocabulary the business actually uses; a value read from config or a tool rather
than hardcoded; an instruction general enough that the transcript merely happens to exercise it.

## 6. Loop bounds

- **Max 3 rounds** of Phase 4 → Phase 5.
- **One surface per round.** Prompt *or* tool *or* config — so the rate change is attributable. A round
  that changed three things teaches you nothing about which one worked.
- **A worse round is reverted, not built on.** If the pass-rate dropped, undo that edit, reconsider the
  class, and don't count the round against the cap.
- **No oscillation.** If round 3 is re-proposing round 1's edit under different words, the class is
  wrong. Go back to Phase 2 rather than round the loop again.
- **No-change signature.** If the rate is *identical* run-for-run after an edit, suspect the edit didn't
  take (a bare `PUT /aiagent/{id}` that updated the runtime but not the editor; a `PUT /aiworker/{id}`
  that dropped fields; the sim pointed at the wrong version) before concluding the diagnosis was wrong.
- **Never widen the change autonomously.** At the cap, report where it plateaued, what each round
  changed and the rate after each, and recommend the next step — a broader rewrite is the user's call, or
  `commotion-improve-worker`'s job.
- **Never declare success on the repro alone.** The repro passing is necessary, not sufficient; Phase 6's
  regression sweep over the existing scenario set is what says the fix didn't cost something else.

## 7. Regression sweep

Run the worker's existing scenarios against `<draft-version>` in **sequential batches of ≤4 runs**,
polling each to completion and confirming `/scenario-run/active` is clear before the next, then aggregate.
Compare to the same set's pre-fix pass-rate — if you don't have one, that baseline is worth a run before
Phase 4 so the comparison exists at all.

`passRate` is a **0–100 percentage**. `avgQuality` is usually `null` and is not wired to eval-metrics —
ignore it as a quality signal.

**A fix that repairs one call and breaks three is not a fix.** Report the delta, and never deploy a
regression.

## 8. Verified live (worker `6a6845731936dac595f46ed5`, v0 LIVE + v1 DRAFT, 2026-07-28)

The whole loop was exercised end to end against dev3 on a worker built with a deliberately planted
defect: an agent prompt referencing `[tool:get_policy_status]` (never registered) **plus** instructions
to state a renewal amount, a debit, an expiry date and an emailed certificate as confirmed fact, and
never to admit uncertainty.

| Phase | What happened |
|---|---|
| Instance | 12 scenario-runs across 3 simulations produced 10 real voice calls in Call Analyzer |
| RCA | `toolCallMetrics[0].result == "Error: function 'get_policy_status' is not registered."`, and the very next turn fabricated *"your renewal amount of four thousand nine hundred and ninety nine rupees has already been debited"*. `contextCorruption: clean` ruled out a platform cause; `llmFallbackEvents` carried one *"LLM produced empty response"* with `fallbackSucceeded: false` — named as an artifact, not the cause |
| Classes | *missing/misfiring tool* **+** *missing grounding*, exactly the pairing in `rca-taxonomy.md` §2a |
| Repro | **1 of 1 decided run FAILED** — but only because the verdict was read from the transcript. The eval surface returned `status: FAILED` / `Simulation Error` / `scenarioEvaluationResult: ''` on a 41-second call that demonstrated the defect perfectly |
| Fix | Draft v1: removed the dangling `[tool:]` reference and the anti-uncertainty language, added an absolute grounding rule. Delete + re-POST → **new `aiAgentId`** → verify `500`ed until the scenario was re-pointed (§4a Trap 1) |
| Verify | **4 of 4 PASS, transcript-derived.** Every run: *"I cannot verify your renewal details on this call, but a colleague will confirm…"*, zero fabrications, no dangling tool call. The eval surface again returned `''` on all four |

**Evaluator verdicts obtained from the platform across the whole session: 0 of 8.** Every gate in this
skill was decided from Call Analyzer transcripts. That is not a degraded mode — on this platform it is
the normal path, which is why this skill exists.
