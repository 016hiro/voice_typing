# 0004. Per-app hotwords replace ContextProfile snippet

- Date: 2026-05-20
- Status: Superseded by 0005-per-app-independent-hotwords

## Context

v0.8.0 #B5 needs per-app hotword selection: when dictating into iMessage
the user wants no coding hotwords; when dictating into Cursor they want
`Qwen` / `Claude Code` / `MLX` enforced. Today `state.dictionary.entries`
is global — every dict entry is in scope for every app, which is why
short ASR mishearings like `Cloud Code` get rescued in chat too, where
the user doesn't want it.

`ContextProfile` already exists since v0.6.x for a different problem:
**per-app LLM system-prompt snippets**. Each profile carries a `bundleID`
and a `systemPromptSnippet: String` that gets appended to the refine
system prompt when the frontmost app matches at `stopRecording` time. The
infrastructure is good — profile resolution, JSON store with debounced
writes (`profiles.json`, DiskLayout v1), corruption recovery, Settings
table + editor sheet — but the **payload** has zero realized value:

- Sole dogfood user (project author) has never filled in a snippet
  across 6 months of daily use.
- Refine quality has not been a complaint in any close-iteration devlog
  v0.6.x → v0.7.3.
- `RefineRecord.profileSnippet` debug-capture field exists in all 14
  refine call sites; reviewing dogfood telemetry shows it always nil.

So the situation is: solid infrastructure carrying a payload that earns
nothing, and a new use case (per-app hotwords) looking for a home. The
choice is either to *layer* hotword filtering onto ContextProfile next
to the snippet, or *replace* the snippet outright.

Layering preserves a feature with zero proven demand and forces the
profile editor to grow two unrelated controls. Replacing collapses the
page to one purpose and is consistent with the dogfood evidence that
snippet doesn't pull weight. v0.8.0 is the right moment to make the
break, before the per-app feature accretes UI and tests around a
two-field design.

## Decision

Replace `ContextProfile.systemPromptSnippet: String` with
`ContextProfile.dictionaryFilter: [UUID]?`. Three states:

| value | meaning |
|---|---|
| `nil` | use all global dictionary entries (default; matches today's behavior + decodes naturally from legacy JSON) |
| `[]` | use no hotwords for this app (intentional "clean dictation" mode) |
| `[id1, id2, …]` | whitelist subset — only these entries are in scope |

Filter applies to all downstream consumers of `state.dictionary.entries`
via a single helper `profile.filteredEntries(from: all)` resolved once
at recording start, then threaded through `GlossaryBuilder` calls and
into `RefineSkipHeuristic.evaluate` (consistent semantics: an entry the
user excluded for this app must not block skip either).

Drop the entire `profileSnippet: String?` parameter chain from
`LLMRefining` protocol, `CloudLLMRefiner`, `LocalMLXRefiner`, and
`RefineRecord`. Strike `LLMRefining.applyContext` snippet-merge logic.

`DiskLayout(version: 1)` is unchanged. Legacy `profiles.json` files
load fine: Swift Codable silently ignores extra fields (`systemPromptSnippet`)
on decode, and the new optional `dictionaryFilter` defaults to nil via
`decodeIfPresent`. The first save after upgrade strips the dead field.
No explicit migration code; no version bump.

Settings tab renamed `Profiles` → `App hotwords`. Profile editor sheet
replaces the snippet `TextEditor` with a radio (`Use all` / `Custom subset`)
+ scrollable checkbox list of global entries. Profile table column
`Snippet` becomes `Hotwords` displaying `all (12)` / `5 of 12` / `none`.

## Consequences

**Positive**

- One purpose per Settings page. New users read "App hotwords" and
  immediately understand the affordance; no need to explain what a
  "profile snippet" is supposed to do.
- Profile editor sheet shrinks: a TextEditor (120–220 pt flex height)
  is replaced by a radio + checkbox list that fits the same envelope
  with room to spare. Sheet buffer per `CLAUDE.md` hard rule is safer
  than before, not tighter.
- The dead `profileSnippet: String?` parameter disappears from 12+
  method signatures across 2 refiner implementations + protocol +
  3 AppDelegate paths + telemetry. Future refiner work doesn't need
  to keep threading a nil through.
- Hotword scope becomes inspectable per refine: `RefineRecord` already
  has `glossary` field — combined with the gate telemetry from #S1,
  post-hoc analysis can answer "which app dictations would have hit
  which entries". Snippet-based prompting had no such signal.
- Forward-compatible to a blacklist mode (`dictionaryMode: enum {
  all / whitelist / blacklist }` + `[UUID]`): the migration is
  `nil → .all`, `[uuid…] → .whitelist`. Same field on disk, additive
  enum. Reachable without breaking JSON.
- Eliminates a class of refine quality regression: with snippet gone,
  refine prompt is pinned. No drift from per-app overrides users
  forgot they enabled.

**Negative**

- Irreversible feature deletion. If a future use case for per-app
  prompt snippets does emerge (e.g., a user wants Markdown output in
  one app, plain text in another), it's a re-implementation, not a
  toggle restore. We are betting that 6 months of zero usage is
  signal, not absence. If we lose that bet the schema work is wasted.
- Anyone *did* populate snippets has data silently dropped on first
  save. Mitigated only by the dogfood-only blast radius (one user,
  who already confirmed zero usage). For a multi-user product this
  would require a one-time export prompt.
- Whitelist-only model. The user with 12 entries who wants iMessage
  to disable just `Claude Code` and `Qwen` has to check the other 10.
  Forward path to blacklist exists but isn't shipped. In practice
  dogfood dict size is <20 entries and "select the few you want" is
  not yet ergonomically painful — the cost shows up only if dict
  growth outpaces blacklist demand.
- `ContextProfile` is now a single-purpose container around
  `dictionaryFilter: [UUID]?` — the struct, store, debounced writer,
  corruption recovery, import/export are all infrastructure for one
  field. Heavier than necessary. Justified by reusing what already
  shipped (zero new I/O code), but a from-scratch design would have
  inlined the filter into the dict entries themselves (`scopedTo:
  [bundleID]?`) and skipped the profile concept entirely. We're not
  doing that refactor now; the existing structure is paid-for.
- Two coupled invariants the codebase now has to maintain together:
  the filter is applied at every `GlossaryBuilder` call site AND at
  `RefineSkipHeuristic.evaluate`. If a future refine path lands and
  forgets one site, hotwords leak across apps silently — no test
  catches this short of an integration test that asserts a
  per-app-filtered dict reaches the LLM. Mitigation: route both
  through a single `effectiveDictEntries(for profile:)` helper on
  `AppState` and grep for `state.dictionary.entries` to catch
  bypassers. The helper exists; the discipline is human.
- Settings UI buffer is fine in fresh-install, but a user with 500
  entries (soft cap) sees a 500-row scrollable checkbox list inside
  a 520pt-wide modal sheet. Usable, not pretty. Adding search/filter
  to the list is post-v0.8.0 work; we ship without it.

## Alternatives Considered

- **(b) Independent `PerAppDictionaryStore`, each profile owns its
  own entries** — supports "totally different vocab per app" but
  violates SSOT for hotwords. Adding `Qwen` requires editing N app
  profiles. Profile editor needs a full embedded dict table (520pt
  sheet too narrow). 14 pipeline call sites all need new merge
  semantics (global + per-app concat? override?). Rejected: solves
  a problem nobody has (no demand for app-specific spellings of the
  same term) at high schema + UI cost.
- **(c) `dictionaryMode: enum { all / whitelist / blacklist }`
  + `[UUID]` from day one** — supports blacklist now. Rejected as
  speculative: dict size is <20, blacklist ergonomic win doesn't
  exist yet, and the migration path from (a) → (c) is trivial
  (`nil → .all`, `[uuid…] → .whitelist`). Ship the smaller schema;
  upgrade if dogfood ever shows real blacklist demand.
- **Layered: keep snippet, add `dictionaryFilter` alongside it** —
  the conservative move. Rejected because (i) snippet has zero
  realized value across 6 months of daily use, (ii) profile editor
  sheet would carry two unrelated controls — a TextEditor and a
  checkbox list — diluting the page identity that v0.8.0 is
  supposed to clarify, and (iii) tests, telemetry, refiner
  protocols would have to keep threading a known-dead parameter.
- **Per-entry `scopedTo: [bundleID]?` on `DictionaryEntry`, no
  profile concept** — cleanest from-scratch design: the filter lives
  with the data it filters. Rejected as scope creep for v0.8.0:
  requires deleting `ContextProfile` and its store entirely,
  rewriting Settings UI from scratch, and writing a real migration
  from `profiles.json` to per-entry scopes. The existing profile
  infrastructure is paid-for and the per-entry model is reachable
  later as a v0.9+ refactor if the profile concept ever feels stale.
- **Hide snippet UI without dropping the schema field** — keeps
  technical debt as a hedge against the "we lose the bet" scenario.
  Rejected: half-shipped features rot. If snippet ever comes back
  the dogfood evidence will be fresher than today's, not older;
  re-deriving the schema then will be informed by that evidence,
  not by a stale stub.
