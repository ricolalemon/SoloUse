# Changelog

## 0.21.2 — public source developer preview

- Add bilingual README and installation instructions, architecture/data-handling documentation and a release audit.
- Build from locked Rust dependencies using repository-owned scripts; optional Lab remains a separate scheme.
- Make signing bundle prefixes configurable, including background-task registration and the diagnostic tree companion.
- Add a first-party MIT license, preserved upstream notices and a locked-dependency license inventory.
- Exclude research screenshots, private traces, historical raw receipts, generated Xcode projects and binaries from the candidate.

## 0.21.1 — last physical-device validation, 2026-10-11

- Persist media-session ownership and recover only verified SoloUse-owned residual streams after process termination.
- Validate recovery during an in-flight JavaScript call; do not replay the interrupted script automatically.

## 0.21.0

- Separate full saved history from bounded model input; archive images by content hash.
- Add automatic context compaction and rolling pre/post-tool recovery checkpoints.

Earlier prototype development included subscription sign-in, general phone tools, persistent JavaScript, Unicode paste handling, notification replies, chat history and bilingual Markdown rendering. See [validation scope](Docs/VALIDATION.md).
