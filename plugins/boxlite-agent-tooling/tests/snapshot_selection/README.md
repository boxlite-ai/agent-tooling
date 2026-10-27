## TL;DR

Snapshot selection keeps the same claims, tool prefix, and bytes with fewer manifest encodings. Synthetic differential tests check the old scan; an opt-in benchmark measures complete reader calls.

## Run

From the repository root:

```sh
make test:plugin TEST_FILTER=snapshot-selection
bash plugins/boxlite-agent-tooling/tests/snapshot-selection.test.sh --benchmark 3
```

One Bash entrypoint runs checks and benchmarks, using the existing `jq` dependency
for JSON fixtures/assertions and two Perl fixtures for the reference selector and
encoder probe. Generated Claude/Codex-shaped records contain no local transcripts;
passing them does not verify live host integration.

## Selection contract

Preview limits retain their existing order: result/call characters of 768/768,
512/768, then 512/256. Only then may tools be omitted, newest first. The search
keeps a fitting prefix and an overflowing upper bound; each midpoint narrows that
interval. The last fitting candidate supplies the output, including the final LF.
If claims alone exceed the cap, the existing truncated manifest or failure remains.

For fixed previews, adding a tool adds a record. Existing records are unchanged;
sorting cannot alter their encoded lengths. Only omission counters can shrink:
one digit for omitted count, at most the payload size's decimal width for omitted
bytes. The new record already includes that width in `payload_bytes`, plus its
keys, hash, and content. Other counters cannot shrink; `true` becoming `false`
adds a byte. Thus sizes strictly increase. Recheck this proof when the schema or
preview rules change. See the [design](https://github.com/boxlite-ai/agent-tooling/issues/264).

## Evidence boundaries

- `linear-selector.pl` freezes the original selection block at commit
  `cba08ca75cc3a4dc991f238d3a036f0df2b8ae7a`. Tests splice it into a temporary copy
  of the current reader, sharing parsing, encoding, integrity, and publication code.
- `SnapshotProbe.pm` observes real JSON::PP manifest encodings through a test-only
  environment. It changes neither inputs nor returned bytes. The 515-tool regression
  requires at most `4 + ceil(log2(515))` encodings.
- Boundary tests enumerate actual candidates, check increasing sizes, and compare
  exact bytes and return status. They include Unicode, escapes, decimal transitions,
  preview stages, zero/full retention, interleaved claims, and invalid input.
- Benchmark runs exclude tracing and compare identical bytes on every repetition.
  Bash `time` measures complete reader calls. Reports include wall-time median/range,
  input size, retained count, and toolchain; fixture generation is outside the timer.
  Machine load affects timings; the original issue's private transcript is not a fixture.

## Measured example

2026-10-27, macOS arm64, Bash 3.2.57, Perl 5.34.1 / JSON::PP 4.06; three repetitions,
256 KiB cap, wall-time medians. Every output matched the linear scan byte-for-byte.

| Tools seen → retained | Linear scan | Binary search |
| --- | --- | --- |
| 352 → 236 | 1.697 s | 0.242 s |
| 400 → 236 | 2.498 s | 0.250 s |
| 472 → 236 | 4.098 s | 0.292 s |
| 515 → 236 | 5.071 s | 0.296 s |

The 515-tool search ranged from 0.289–0.303 s. At a non-dropping 4 MiB cap,
the same case retained all tools: 0.147 s median for both selectors.
These are synthetic reader measurements, not timings from live Claude/Codex sessions
or the original issue's transcript. Linux and Windows timings remain unverified.
