# Install from source

[简体中文](INSTALL.zh-CN.md) · [README](../README.md)

This is a developer workflow, not a one-tap IPA installer. Use your own signing assets. No pre-signed app, developer certificate, device identifier or provisioning profile is supplied.

## 1. Prepare the Mac

- Install full Xcode 27 with its iOS 27 SDK and finish its first-launch setup. Command Line Tools alone are insufficient. `xcode-select -p` should point inside the intended Xcode; change it in Xcode → Settings → Locations if needed.
- Install XcodeGen (`brew install xcodegen`) and Rust through [rustup](https://rustup.rs/). Python 3 and Git are used by the development scripts.
- Run `rustup target add aarch64-apple-ios`.
- Run `xcodebuild -version`, `cargo --version` and `xcodegen --version` to confirm the tools are on PATH.

## 2. Configure your application identity

From the extracted/cloned source root:

```sh
cp Config.local.xcconfig.example Config.local.xcconfig
```

Edit `SOLOUSE_BUNDLE_PREFIX` to a reverse-DNS prefix you own, for example `dev.yourname.solouse`. The app uses `<prefix>.probe`, optional Lab `<prefix>.lab` and diagnostic test target `<prefix>.tree`. Set `DEVELOPMENT_TEAM` to your own team ID, or select it in Xcode. Keep persistent signing choices in the ignored local file because the Xcode project is generated.

`Config.defaults.xcconfig` supplies unsigned defaults and optionally includes that local file. No author's team ID is embedded. The app's background identifier and diagnostic companion references follow this prefix.

Paid development signing was used in the historical tests. Personal Team/free-account installation has not been validated for this complete workflow; do not infer support from an unsigned build. Re-sign before your own provisioning profile expires.

## 3. Build

```sh
bash Scripts/build.sh
open SoloUse.xcodeproj
```

The script runs a locked Rust release build for `aarch64-apple-ios`, copies the static library to ignored `Build/`, generates the project, and builds an unsigned Release app. Generated products stay in ignored `.build/` by default. Override with `SOLOUSE_BUILD_DIR` and `SOLOUSE_NATIVE_TARGET_DIR` when desired. `SOLOUSE_CONFIGURATION=Debug` enables explicit development diagnostics; Release is the default.

If Xcode says `library not found for -lsolouse_core`, rerun `bash Scripts/build-native.sh`. Do not download an unknown prebuilt library or commit a local `.a` file to fix it.

## 4. Prepare and install on the iPhone

1. Connect the phone to the Mac with a data cable, unlock it and accept Trust if prompted.
2. Enable Developer Mode in Settings → Privacy & Security; complete the requested reboot/confirmation. If the switch is missing, first connect the phone to Xcode's Devices and Simulators view.
3. Wait for Xcode's device preparation to finish. This prepares the developer services/DDI used by the prototype. Resolve any SDK/device-version mismatch before proceeding.
4. In Xcode select the **SoloUse** scheme, your device and your signing team; leave automatic signing enabled. Build and run. If iOS asks you to trust the developer, follow Settings → General → VPN & Device Management.
5. Install [LocalDevVPN](https://apps.apple.com/app/localdevvpn/id6755608044) separately on the phone and connect it. The normal task path uses its local developer-service route; arbitrary remote endpoints and the direct-loopback diagnostic are not substitutes.

## 5. Pair and sign in

1. Open SoloUse → Device. Start local pairing.
2. Follow the app's displayed instructions and the iOS developer-pairing UI; select the SoloUse host and enter the displayed PIN when asked. System wording may vary. Keep LocalDevVPN connected and the phone unlocked until pairing completes.
3. Use the readiness check to verify the connection and screen/control path. End an existing phone/VoIP call yourself before testing if iOS reports a call conflict.
4. Open Account and start sign-in. Complete the displayed device-code flow on OpenAI's own authorization page, then return. If device-code authentication is unavailable for the account, see the [official authentication documentation](https://developers.openai.com/codex/auth) and your workspace settings. SoloUse does not add a password form or an API-key fallback.
5. Select a model from the returned account catalog. Historical model names in tests are not a list of guaranteed current models.

## 6. First task and recovery

Use a reversible, non-submitting task: “Open Settings and describe the visible page. Do not change settings.” Watch the phone. Returning to SoloUse pauses action dispatch; Stop ends the task. Check [privacy](PRIVACY.md) before using personal apps.

Once setup succeeds, disconnect USB and repeat a harmless task while keeping LocalDevVPN and internet access. This tests your particular device's runtime independence; it is not assumed solely because installation succeeded.

If the process ends, reopen SoloUse and choose **Continue from checkpoint** when offered, or send a follow-up in the same chat. The model must take a fresh observation. Completed effects are not undone; a script's instruction pointer and globals are not restored. Phone reboot recovery is a different case: re-check developer services/DDI and provisioning, using Xcode if necessary.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| App will not install/start | Your bundle prefix, signing team/profile, device inclusion, Developer Mode and developer trust |
| VPN says connected but readiness fails | DDI/device preparation, local pairing, phone lock and active calls are separate checks |
| Display session occupied | Close another screen-sharing session. Only a persisted, matching SoloUse-owned media session can be reclaimed automatically; unmarked legacy sessions remain blocked |
| Sign-in or model request rejected | Account/workspace/device-code access and the experimental backend; signing in successfully does not guarantee every model/tier |
| Agent pauses after returning to SoloUse | Expected takeover behavior; inspect and explicitly continue |
| Paste dialog or wrong input | Allow the actual iOS prompt when appropriate; verify the field and input method. Clipboard backup can require foreground access |
| Background task ends | Reopen the saved chat and inspect the last receipts; do not assume an uncertain action did not happen |

## Optional developer fixtures

Build/run the **SoloUseLab** scheme for synthetic input checks. The **SoloUseTree** scheme is an experimental XCTest diagnostic and is not required for the default agent. Its setup and signed-framework packaging are not part of the normal installation guide; `Scripts/prepare_tree_runner.py` is a developer utility operating only on local Xcode-built products. Never distribute copied Apple frameworks as part of a source release.
