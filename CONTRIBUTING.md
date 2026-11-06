# Contributing

This is an experimental developer preview. Please start with a small issue or patch describing the observed behavior, expected behavior and reproduction steps.

Use synthetic accounts/data. Do not attach raw device logs, pairing records, credentials, clipboard contents, screenshots of personal apps, or chat archives. A minimal error code, version, iOS version and redacted sequence is usually enough. See [privacy](Docs/PRIVACY.md).

Build and run `bash Scripts/test.sh` before submitting runtime changes. Keep the agent general: add reusable observation/control mechanisms instead of app-specific click sequences. Preserve completed action receipts; uncertain effects must not be automatically replayed. Do not equate a delivered touch with a verified UI outcome.

Run `python3 Scripts/check-release.py` before preparing a public archive. If dependencies change, regenerate the license inventory with `python3 Scripts/collect-licenses.py` and review its warnings. Keep upstream copyright and modified-file notices.

Contributions to first-party MIT files are provided under MIT; files retaining another license keep that license. No credentials or paid model access are required by the offline test suite.
