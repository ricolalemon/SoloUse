# Data handling

## What leaves the phone

The selected remote model receives the user task, applicable conversation history, tool schemas, tool arguments/results and screenshots included in active input. Screenshots can contain personal data from other apps. The execution runtime being local does **not** make model inference offline or keep all task content on-device. Provider retention and account policies apply.

Authentication and model requests go to OpenAI endpoints in `SubscriptionClient.swift`. The current client has no SoloUse-hosted relay and no added analytics SDK. Phone control uses the device's own developer services through a local tunnel. Apps the agent operates may make their own network requests.

## Local storage

- Access/refresh tokens: app-scoped iOS Keychain, accessible after first unlock on this device; not a source-code configuration file.
- Pairing material: `Library/Application Support/SoloUsePrivate/pairing.plist`. Treat it as a credential.
- Chats, exact tool receipts, model context and archived images: `SoloUsePrivate/task-records/`, with per-chat history and rolling recovery manifests.
- Diagnostic traces and optional screenshots: `SoloUsePrivate/debug-traces/`; basic diagnostic events and explicitly enabled development probes can also write app Documents files.

Private storage is protected by iOS file protection and excluded from normal backup where implemented. This is not an independent application-level encrypted vault. Debug traces redact recognized credentials, but redaction cannot guarantee that screenshots or arbitrary app text contain no secrets. Screenshot diagnostics are enabled by default in this prototype; changing that option affects debug trace images, not the full conversation image archive needed for history.

Deleting a chat removes its archived screenshots and recovery files. Independent diagnostic traces are managed separately in the app. Signing out removes subscription tokens; it does not erase all chats or pairing data. Review both histories and diagnostics when removing sensitive material. iOS Keychain items can survive deleting an app; sign out explicitly first when practical.

## Sharing reports

Never publish an app data-container export, pairing file, auth cache, signing profile, or raw conversation checkpoint. Share a minimal reproduction using synthetic data, not a complete diagnostic bundle. Inspect every image before sharing. The public source candidate contains no historical device screenshot or runtime export; test code generates synthetic fixtures.

`python3 Scripts/summarize_trace.py path/to/events.jsonl` emits aggregate numerical metadata only. It omits messages, arguments, identifiers and image contents; it does not make the original log safe to publish.
