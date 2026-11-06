# SoloUse

**An experimental iPhone app that runs an agent loop and operates the same phone.**

[简体中文](README.zh-CN.md) · [Install](Docs/INSTALL.md) · [Architecture](Docs/ARCHITECTURE.md) · [Limitations](Docs/LIMITATIONS.md)

SoloUse combines screenshot-based phone control, a local JavaScript runtime, chat history and explicit interruption recovery. You enter a task; a remote model chooses general tools; the iPhone executes them and returns screenshots and action receipts. The execution loop is on the phone. **Model inference is remote**, and task content/screenshots are sent to the model provider.

**Status: experimental developer preview 0.21.2.** The last physical-device validation was prototype 0.21.1 on one iPhone 17 Pro Max / iOS 27.0.1. This is not an App Store release, a finished consumer app, or a claim of being the first/fastest phone agent.

## What works

- General screen capture, app discovery/opening, taps, gestures, keys and Unicode paste handling.
- Local QuickJS scripts for short action sequences and calculations; no Node.js, shell or arbitrary filesystem/network access.
- Streaming assistant messages, tool activity, pause/takeover, notification replies and chat history.
- Content-addressed screenshot archives, bounded active image input and automatic context compaction.
- Recovery points before/after tool calls. Relaunch waits for the user; uncertain calls and queued script tails are not automatically replayed.
- Chinese/English UI and Markdown answers.

The default agent uses screenshots; the XCTest tree companion is optional development diagnostics. Lab is a synthetic test app. Neither is required for normal tasks.

## Requirements

| Component | Current requirement |
| --- | --- |
| Phone | Real iPhone on iOS 27, Developer Mode enabled; portrait operation |
| Initial development setup | Mac, full Xcode 27 / iOS 27 SDK, Rust/rustup, XcodeGen and Python 3 |
| Signing | Your own development team, bundle identifiers and device provisioning |
| Runtime connection | LocalDevVPN connected; prepared developer services/DDI |
| Model | Network access and an account accepted by the current experimental ChatGPT/Codex subscription transport |

The subscription transport is adapted from public Codex source, but is **not a supported public API integration or an OpenAI-endorsed client**. The source license does not establish permission to use a backend. There is currently no API-key fallback. Availability can change. See [limitations](Docs/LIMITATIONS.md).

## Build and try

Clone the repository, then prepare the build:

```sh
git clone https://github.com/ricolalemon/SoloUse.git
cd SoloUse
cp Config.local.xcconfig.example Config.local.xcconfig
# Edit the ignored local file: choose a unique prefix and your own signing team.
rustup target add aarch64-apple-ios
bash Scripts/build.sh
open SoloUse.xcodeproj
```

Select the **SoloUse** scheme and your connected, unlocked iPhone. Configure your team and run it from Xcode. The script first produces an unsigned Release build; it does not install an app or include anyone's signing assets. [Complete setup and troubleshooting](Docs/INSTALL.md).

After device preparation, keep LocalDevVPN connected, pair from the Device tab and sign in from the Account tab. Check readiness, then start a harmless task such as **“Open Settings and tell me which page is visible; do not change any setting.”** Supervise the first run. Returning to SoloUse pauses actions; use Stop to end the task.

The documented setup uses a Mac initially. Earlier unplugged tests demonstrate runtime execution without a Mac, but complete phone-reboot recovery without one is not yet verified.

## Evidence and limits

A real process-kill recovery test continued the same conversation after a script interruption. A daily-challenge test also completed one automatic compaction and saved its history; **the game was lost**, so it is not presented as a winning demo. Detailed scope and candidate checks are in [VALIDATION.md](Docs/VALIDATION.md).

Current limits include call/VoIP conflicts, iOS background termination, portrait-only input and provider-dependent access. Compaction can affect semantic memory; an archived screenshot is not proof the model remembers it. A delivered touch is not proof of a correct UI outcome. [Full limitations](Docs/LIMITATIONS.md).

## Privacy

Credentials live in iOS Keychain; pairing records, conversations, images and traces are sensitive local data. Screenshots and applicable history go to the remote model. Diagnostic exports can expose personal app content even when token redaction succeeds. [Data handling](Docs/PRIVACY.md).

This candidate intentionally excludes historical phone captures, raw execution logs, pairing records, account bindings, provisioning profiles and compiled Apple frameworks.

## Development

```sh
bash Scripts/test.sh
python3 Scripts/check-release.py
python3 Scripts/package-source.py --output /tmp/SoloUse-source.zip
```

No model account or device operation is required by the offline tests. Dependency downloads may be needed on first build. See [contributing](CONTRIBUTING.md), [security reports](SECURITY.md) and [the changelog](CHANGELOG.md).

## License and credits

First-party code is **MIT**, except explicitly marked Apache-2.0 adaptations. Vendored and referenced third-party code keeps its original license. See [LICENSE](LICENSE), [NOTICE](NOTICE), [third-party notices](THIRD_PARTY_NOTICES.md) and the [locked Rust dependency inventory](Licenses/CARGO_DEPENDENCIES.md).

SoloUse is independent of Apple and OpenAI. LocalDevVPN is installed separately; its source or app is not bundled here.
