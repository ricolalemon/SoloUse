#!/bin/bash
set -euo pipefail
solouse_root="$(cd "$(dirname "$0")/.." && pwd)"
solouse_scratch="$(mktemp -d "${TMPDIR:-/tmp}/solouse-tests.XXXXXX")"
trap 'rm -rf "$solouse_scratch"' EXIT
cd "$solouse_root"
cargo test --manifest-path Native/Cargo.toml --locked
for suite in context_recovery conversation_continuation chat_history notification_reply subscription_protocol session_routing status run_limits clipboard_contents; do
  swiftc -parse-as-library App/AgentCore/*.swift App/SubscriptionProtocol.swift     App/TaskRecordStore.swift App/ChatHistoryStore.swift "Scripts/${suite}_tests.swift"     -o "$solouse_scratch/$suite"
  "$solouse_scratch/$suite"
done
swiftc -parse-as-library App/AgentCore/*.swift App/SubscriptionProtocol.swift   Scripts/localization_tests.swift -o "$solouse_scratch/localization"
"$solouse_scratch/localization" App/Resources/Localizations.json
python3 Scripts/check_localization.py
bash Scripts/test-script-runtime.sh
python3 Scripts/test-diagnostic-summary.py
python3 Scripts/test-release.py
python3 Scripts/check-release.py
