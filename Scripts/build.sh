#!/bin/bash
set -euo pipefail
solouse_root="$(cd "$(dirname "$0")/.." && pwd)"
solouse_build="${SOLOUSE_BUILD_DIR:-$solouse_root/.build}"
solouse_configuration="${SOLOUSE_CONFIGURATION:-Release}"
case "$solouse_configuration" in Debug|Release) ;; *) echo "Use Debug or Release." >&2; exit 1;; esac
command -v xcodegen >/dev/null || { echo "Install XcodeGen (brew install xcodegen)." >&2; exit 1; }
bash "$solouse_root/Scripts/build-native.sh"
xcodegen generate --spec "$solouse_root/project.yml" --project "$solouse_root"
xcodebuild -project "$solouse_root/SoloUse.xcodeproj" -scheme SoloUse   -configuration "$solouse_configuration" -destination 'generic/platform=iOS'   -derivedDataPath "$solouse_build/DerivedData" CODE_SIGNING_ALLOWED=NO   COMPILER_INDEX_STORE_ENABLE=NO build
echo "Unsigned build complete. Open SoloUse.xcodeproj to sign with your own team and install."
