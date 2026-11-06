# Open-source preparation audit — 2026-11-06

Candidate: **0.21.2 / build 58**, derived from the locally validated 0.21.1 prototype. This is a source-only developer preview. This audit describes the prepared source. Publishing it does not extend the recorded runtime validation or create a signed app release.

## Privacy review

- Publication uses an explicit file allowlist. The private prototype and research materials remain outside this candidate.
- Excluded: historical device screenshots/video, raw diagnostic exports, old run JSON and account-bound context, signing assets, generated Xcode projects, compiled apps/libraries/frameworks, the old Mac bridge, obsolete Lab summary scripts and unused screenshot fixtures.
- Replaced the retained diagnostic summarizer with numerical aggregates only. Tests inject synthetic sensitive fields and verify they are not emitted.
- Checked common token/key formats, local home paths, Apple device identifiers and signing-team literals; separately checked known identifiers from the private prototype without logging their values. No private prototype identifier was found in the publication files.
- Three matching occurrences in pinned upstream idevice files are public protocol fixture/documentation identifiers. Exact path/rule/value-hash exceptions are recorded in `Scripts/release-scan-exceptions.json`; this is not a blanket exclusion of vendor code.
- Synthetic secret-redaction fixtures are explicitly named and allowlisted by exact value. The public OAuth client ID and `10.7.0.1` protocol endpoint are identifiers/configuration, not user credentials.
- No raster image, runtime data export or binary is included in this source candidate. Upstream authorship and copyright notices remain intact.

Pattern matching cannot prove that arbitrary text is non-sensitive. The scope above combines allowlisted packaging, code/document review and automated checks. It does not certify future edits or user-generated logs.

## License review

- Root MIT license follows the original first-party Rust package metadata. Explicitly marked Codex adaptations retain Apache-2.0 notices.
- idevice and QuickJS-NG notices/source provenance are preserved; local idevice changes are listed. WebDriverAgent and Device Hub reference notices remain included.
- All 190 packages in the lock graph were examined via Cargo metadata; 189 are third-party, including 152 in the iOS-resolved graph. Original license texts/notices are retained where shipped, with byte hashes and upstream revisions.
- The inventory records permissive options for dual/triple-licensed packages, including MIT for r-efi. Required Unicode and ring's multiple notices are retained.
- `ns-keyed-archive` and `plist-macro` ship SPDX declarations without standalone license files. The exact declarations and author attribution are retained, and canonical MIT text is supplied for the declared option. This remains an explicitly documented upstream provenance gap; no missing copyright year or separate permission is invented.
- There are no bundled signed IPAs, Apple SDK/framework binaries, LocalDevVPN implementation or OpenMinis/iCTRL code. Build tools and external services have their own terms. Source-code licensing does not establish account/backend access rights.

See [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) and [the inventory](../Licenses/CARGO_DEPENDENCIES.md). This is an engineering review of identified license declarations and notices, not a legal opinion.

## Build and reproducibility

- Repository-owned build scripts compile the locked native source and generate the Xcode project. No private signing helper or cached prebuilt library is required.
- Bundle prefix, background-task identifier and optional diagnostic app IDs follow the contributor's configuration.
- Main app Release/Debug and optional Lab unsigned builds were checked. The source ZIP was then extracted into a fresh directory and its Release build passed without the local configuration file. The fixture prefix is a reserved example, not a personal team/device identity.
- Offline tests cover native operation/receipt behavior, context/history recovery, notification replies, protocols, script execution, localization, release rejection cases and diagnostic-summary privacy.
- GitHub Actions checks source publication and packaging only. It does not claim to build the iOS app on a hosted runner with an unknown SDK.

Machine-readable results: [release-validation.json](release-validation.json). The original physical tests are summarized in [VALIDATION.md](VALIDATION.md). No new signed-device installation, account login or live phone operation was performed in this preparation pass.

Before any later binary release, repeat the audit against the actual binary/dependency set and verify installation with the intended signing configuration. Publish only a package produced by `Scripts/package-source.py`, not an export of the private prototype or device container.
