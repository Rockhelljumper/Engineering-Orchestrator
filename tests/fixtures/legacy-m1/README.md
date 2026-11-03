# Legacy M1 state roots

State roots written by the controller **before** verdicts moved out of runner results
(origin/main at `79fef7a`, fake store, `eo run --runner fake`). Their `attempt.end` records
carry the runner's own `verification`/`review` verdicts. `tests/unit/legacy-journal.test.ts`
copies them, adopts each into the test's rollback anchor, and checks that the current code
still opens, resumes and replays them.

| Directory | How it was left |
|---|---|
| `crash-after-fail-end` | Killed (`EO_CRASH_AT`) right after A#1's `attempt.end`, whose result carries verification fail, signature `legacy:A1` |
| `crash-after-pass-end` | The same, with verification pass and review approve |
| `complete` | A finished run: A failed verification once, B had changes requested once |

Provenance: produced once by `generate.ts` in this directory, run with the code at `79fef7a`
(`node tests/fixtures/legacy-m1/generate.ts <checkout of 79fef7a> <out dir>`), and copied
here as they were left (only `locks/` was emptied).

The files must stay byte-exact: journal records are HMAC-chained and evidence manifests are
signed over file hashes. `.gitattributes` turns off line-ending conversion for that reason.
Do not edit or regenerate them in place; the generator's output differs on every run
(keys, timestamps, temporary paths). A new fixture goes in a new directory.
