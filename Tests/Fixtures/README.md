# Tests/Fixtures

Audio regression fixtures for `Tests/VoiceTypingTests/E2E/`.

Each fixture is a pair:
- `<name>.wav` — 16 kHz mono, either s16 or Float32 PCM
- `<name>.expected.json` — assertion metadata

## `expected.json` schema

```json
{
  "keywords": ["fellow Americans", "country"],
  "minChars": 50,
  "maxChars": 300,
  "language": "en",
  "streamingMinPartials": 1
}
```

| Field | Meaning |
|---|---|
| `keywords` | Case-insensitive substrings that MUST appear in the transcript. Pick 2–3 that survive minor model drift — don't overfit. |
| `minChars` | Lower bound on transcript length. Guards against "I said 30 words, got 3 chars" silent failures. |
| `maxChars` | Upper bound. Guards against runaway hallucination. |
| `language` | `Language` rawValue: `en` / `zh-CN` / `zh-TW` / `ja` / `ko`. Drives the ASR hint. |
| `streamingMinPartials` | For streaming E2E only: minimum number of `AsyncThrowingStream` yields. `1` is safe for a short utterance; bump to `2+` for fixtures with VAD-splittable silences. |

## Adding a fixture

### English (pull from public corpora)
```
./Scripts/fetch_english_fixtures.sh
```
Currently pulls JFK's "ask not" inaugural clip (~11 s, public domain, from the OpenAI Whisper team's own test fixtures). Add more PD sources to the script as needed — commit the resulting WAV + expected.json.

### Chinese / Japanese / Korean (record yourself)
```
./Scripts/record_fixture.sh <name>
```
- Records from the default mic at 16 kHz mono s16 — hit Ctrl+C to finalise.
- Auto-writes a stub `expected.json`; edit the `keywords` array to match what you actually said.
- Commit both files.

## Running the regression

```
make test          # unit tests only — no fixtures needed, runs in CI
make test-e2e      # full run incl. E2E ASR against fixtures. Needs:
                   #   - mlx.metallib (make setup-metal + make metallib)
                   #   - Qwen 1.7B downloaded (launch the app once)
                   #   - Silero VAD (downloads on first streaming test, ~2 MB)
```

E2E tests iterate every fixture in this directory and assert each one against
its `expected.json`. A failure in one fixture doesn't abort the others
(`continueAfterFailure = true`).

## Attribution

See [`ATTRIBUTION.md`](ATTRIBUTION.md) for the source and license of each
third-party clip. Self-recorded clips are repo-maintainer copyright, used as
fixtures.

## Known quirks (not bugs)

- **Short isolated utterances hallucinate in streaming**: Silero VAD sometimes
  splits a 200–400 ms burst (e.g. "ask not") into its own segment. Qwen3-ASR on
  sub-500 ms audio occasionally returns a non-sequitur ("Stop."). This is the
  cost of aggressive VAD segmentation — keywords in `expected.json` should be
  robust to this (prefer terms that repeat or live in multi-word segments).
