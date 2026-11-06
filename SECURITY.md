# Security and privacy reports

Do not post secrets or personal screenshots in a public issue. Use the repository's private vulnerability reporting feature if enabled. If it is not enabled, open a public issue requesting a private contact **without** including the sensitive details. No private reporting endpoint or response-time commitment exists yet.

Only the current developer-preview source is maintained. The app can operate other apps with the user's existing account permissions. There is no per-app permission sandbox or guaranteed semantic exactly-once execution. Stop is available in the app; returning to SoloUse pauses actions, but an in-flight action may already have happened.

ChatGPT credentials are stored in the app's Keychain. Pairing records, model history, screenshots and diagnostic traces remain sensitive local data. See [data handling](Docs/PRIVACY.md) and [limitations](Docs/LIMITATIONS.md). Code licensing is separate from authorization to use third-party services.
