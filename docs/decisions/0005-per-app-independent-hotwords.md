# 0005. Per-app independent hotwords (global shared + app-private)

- Date: 2026-05-22
- Status: Accepted (Supersedes 0004-app-hotwords-replace-profile-snippet)

## Context

ADR-0004 shipped (but did not yet `gh release`) a per-app hotword model
where `ContextProfile.dictionaryFilter: [UUID]?` lets each app pick a
**subset of the global dictionary**. During the first dogfood session of
that build the project author hit the model's ceiling: per-app hotwords
can only *subtract* from the global list, never *add* app-specific terms.

The breakdown is structural. To make a hotword that fires only in WeChat
(a friend's name `张三`), the whitelist model forces:

1. Add `张三` to the **global** dictionary (it's now a global entry).
2. In every **other** app's profile, ensure the whitelist excludes it.
3. In WeChat's profile, include it.

The term conceptually belongs to WeChat but is forced to live globally,
and its *absence* must be managed everywhere else. As app-specific terms
grow, the global dictionary becomes the union of every app's vocabulary
and every profile becomes a hand-maintained whitelist — unmanageable.

ADR-0004 explicitly rejected the "independent per-app dictionary" option
(its alternative (b)) on the assumption that there was "no demand for
app-specific spellings" and that a single global SSOT was preferable.
The first day of real use invalidated that assumption: the user does
want genuinely app-private hotwords. ADR-0004's whitelist is the wrong
primitive.

Timing is favorable: v0.8.0 has not been `gh release`d, so no released
build carries the whitelist schema. This is a pre-release revision, not
a migration of shipped behavior.

## Decision

Replace `ContextProfile.dictionaryFilter: [UUID]?` with two fields:

```swift
struct ContextProfile {
    let id: UUID
    var name: String
    var bundleID: String
    var entries: [DictionaryEntry]   // app-private hotwords
    var includeGlobal: Bool          // also apply the global dictionary?
    var enabled: Bool
    var createdAt: Date
}
```

Model: **global shared baseline + per-app private additions**, with a
per-app opt-out of the global baseline.

- **Global dictionary** (`CustomDictionary` / `dictionary.json`,
  unchanged): terms wanted everywhere — the user's name, universal
  technical vocabulary.
- **Per-app private entries** (`ContextProfile.entries`, inline in
  `profiles.json`): hotwords specific to one app.
- **`includeGlobal`** (default `true`): whether the global dictionary
  also applies in this app. Set `false` for an app where global terms
  would be noise (e.g. coding hotwords leaking into chat dictation).

Effective hotword set when app X is frontmost at dictation:

```
effective = (profile.includeGlobal ? global : []) + profile.entries
```

Apps with no profile resolve to `global` only (matches today's
behavior — `includeGlobal` defaults true, `entries` empty).

The effective set feeds all three consumers uniformly — ASR bias
context, refine glossary, and the #S1 skip-gate hotword guard — at the
same single resolution points the v0.8.0 pipeline already established
(Fn↓ for live, Fn↑ for batch).

`DiskLayout(version: 1)` is unchanged. Legacy `profiles.json` from the
pre-release v0.8.0 whitelist build (carrying `dictionaryFilter`) decodes
cleanly: Codable ignores the unknown field, new fields default
(`entries: []` via `decodeIfPresent`, `includeGlobal: true`). The
whitelist's "only these globals" intent is **not** reconstructed — the
handful of dogfood test profiles get reset to "use all global + no
private", which the user re-configures. No migration code; the older
`systemPromptSnippet` field continues to be ignored (ADR-0004 rationale
unchanged on that point).

Settings UI: the "App hotwords" profile editor sheet replaces the
global-entry checkbox list with (1) an "Also use global hotwords" toggle
and (2) a compact inline table of the app's private hotwords with
add/edit/delete, reusing the same entry editor shape as the global
Dictionary tab. The profile table's "Hotwords" column shows a summary
like `global + 3` / `3 only` / `global`.

## Consequences

**Positive**

- App-private hotwords become first-class. A term that belongs to one
  app lives in that app's profile; it does not pollute the global list
  and requires no whitelist bookkeeping elsewhere.
- The two genuinely-distinct needs each get the right home: "term I want
  everywhere" → global (no duplication); "term for this app only" →
  per-app. The `includeGlobal` toggle covers the coarse "this app should
  not see global terms" case in one click.
- Unconfigured apps and fresh profiles behave exactly as before the
  feature existed (global only), so the change is invisible until a user
  deliberately adds a per-app profile.
- Builds on the v0.8.0 pipeline plumbing: the single Fn↓/Fn↑ resolution
  points and the `effectiveEntries(global:)` helper replace
  `filteredEntries(from:)` one-for-one. The 14 GlossaryBuilder call
  sites are unaffected — they still receive a pre-resolved entry list.

**Negative**

- More UI than the whitelist checkbox list. The profile editor now
  embeds a mini dictionary editor (term + hints + note rows, add/edit/
  delete) plus a nested entry-editor sheet. Heavier to build and to
  keep within the CLAUDE.md Settings sizing rules. Mitigated by reusing
  the global Dictionary tab's entry-editor shape rather than inventing a
  second one.
- Two places now hold `DictionaryEntry` lists (global store + each
  profile). They share the struct but not the management surface: the
  global store has the 500-cap, LRU `lastMatchedAt` eviction, and
  import/export; per-app entries are plain inline arrays with none of
  that. A future need for per-app import/export or capping is
  unaddressed. Accepted: per-app lists are small by nature.
- `lastMatchedAt` LRU bumping (`noteDictionaryMatches`) only updates the
  global store. A match on a per-app private entry won't bump anything —
  the id isn't in the global store and the lookup silently no-ops. This
  means per-app entries don't participate in usage-based ordering. Fine
  for small lists; would matter only if per-app lists grew large enough
  to need eviction.
- This is the **second** reversal of the per-app model in two days
  (snippet → whitelist → independent). The churn is real and the
  pre-release timing is the only reason it's cheap. If the independent
  model also proves wrong, the credibility cost of a third pivot is
  higher. The bet here is grounded in concrete dogfood failure, not
  speculation, which is why it's worth making now rather than shipping
  the known-limited whitelist.
- Reintroduces the duplication ADR-0004 worried about for terms a user
  wants in *several but not all* apps: such a term either lives global
  (and the excluding apps turn off global entirely, losing the other
  globals too) or is copied into each wanting app's private list. The
  `includeGlobal` toggle is app-granular, not term-granular, so the
  "mostly global minus a few" case is awkward. Deferred: option (c)
  (per-term suppression) remains a forward path if this bites, but it
  adds a per-app blacklist UI nobody has asked for yet.

## Alternatives Considered

- **Keep ADR-0004's whitelist (`dictionaryFilter`)** — the shipped
  pre-release model. Rejected: cannot express app-private hotwords at
  all, which is the exact capability the first dogfood session demanded.
- **Fully independent, no global concept** (ADR-0004 alternative (b) in
  its purest form) — each app owns its whole list; a "Default" profile
  covers unlisted apps. Rejected: terms the user wants everywhere (their
  name, `Claude`) must be duplicated into every profile and edited in N
  places. The global baseline earns its keep for exactly these terms.
- **Global + per-app add + per-app per-term suppression** (option (c)) —
  most flexible: a profile can both add private entries and uncheck
  specific global entries. Rejected for now as premature: at dogfood
  dictionary scale (<20 terms) the app-granular `includeGlobal` toggle
  covers the suppression need, and per-term blacklist UI is real
  complexity for a case no one has hit. Reachable later additively
  (add a `suppressedGlobalIDs: [UUID]` field) without breaking this
  schema.
- **Migrate whitelist `dictionaryFilter: [ids]` into per-app `entries`
  by snapshotting the referenced global entries** — would preserve the
  pre-release test profiles' intent. Rejected: snapshotting copies
  global entries (with their UUIDs) into profiles, creating confusing
  duplicates that then drift from the global originals. The dogfood
  profile count is tiny; a clean reset is simpler than a lossy,
  duplicate-creating migration.
