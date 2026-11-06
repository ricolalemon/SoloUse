# Validation

## Earlier physical-device evidence

The last recorded device run was 2026-10-11 on iPhone 17 Pro Max / iOS 27.0.1, using prototype 0.21.1 (build 57).

- Local phone capture/input and earlier Lab input tests ran without a USB runtime dependency.
- A fresh daily-challenge test included two real process SIGKILLs. The first exposed a residual media-stream bug. After the ownership-marker fix, a second interruption during a script restored the same conversation and continued after a fresh observation, without replaying the already completed prefix.
- The game ended in a loss with 90 tiles remaining. There were 83 completed model requests, including one compaction. The final archive retained 193 items, 81 receipts and 80 images. These are historical aggregate measurements, not a winning demo or proof of semantic memory equivalence.
- The test used USB for development, evidence collection and one legacy-session cleanup before the fix. It was not a new fully unplugged endurance test.

Raw device records, user screenshots, account bindings and machine paths are deliberately excluded. No public video is provided by this source candidate.

## Candidate verification

Run `bash Scripts/test.sh` for native Rust tests, agent/history/recovery/protocol tests, the C/QuickJS suite, localization and release-file checks. No account, network inference or phone operation is performed by these tests; the first Cargo run may download locked build dependencies.

`bash Scripts/build.sh` builds the native iPhone library and an unsigned Release app from the candidate source. It does not install or replace an app on a phone. `Docs/release-validation.json` records the actual preparation checks; unperformed checks remain explicit.

The configurable bundle prefix changes background-task and diagnostic app identities. A fresh physical install using a contributor's own signing team remains a release follow-up, even when an unsigned build succeeds.
