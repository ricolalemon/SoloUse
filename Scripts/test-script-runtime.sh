#!/bin/bash
set -euo pipefail
solouse_root="$(cd "$(dirname "$0")/.." && pwd)"
solouse_scratch="$(mktemp -d "${TMPDIR:-/tmp}/solouse-js-tests.XXXXXX")"
trap 'rm -rf "$solouse_scratch"' EXIT
for source in quickjs dtoa libregexp libunicode; do
  clang -O1 -std=c11 -D_GNU_SOURCE -I "$solouse_root/Native/QuickJS" \
    -c "$solouse_root/Native/QuickJS/$source.c" -o "$solouse_scratch/$source.o"
done
clang -O1 -std=c11 -D_GNU_SOURCE -I "$solouse_root/Native/QuickJS" \
  -c "$solouse_root/Native/ScriptEngine/SoloScript.c" -o "$solouse_scratch/SoloScript.o"
clang -O1 "$solouse_root/Scripts/script_thread_tests.c" "$solouse_scratch"/*.o \
  -o "$solouse_scratch/thread-tests"
"$solouse_scratch/thread-tests"
swiftc -parse-as-library -import-objc-header "$solouse_root/Native/ScriptEngine/SoloScript.h" \
  "$solouse_root"/App/AgentCore/*.swift "$solouse_root/App/SubscriptionProtocol.swift" \
  "$solouse_root/App/ScriptExecutor.swift" "$solouse_root/Scripts/script_runtime_tests.swift" \
  "$solouse_scratch"/*.o -o "$solouse_scratch/script-tests"
"$solouse_scratch/script-tests"
