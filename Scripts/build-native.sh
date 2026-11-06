#!/bin/bash
set -euo pipefail
solouse_root="$(cd "$(dirname "$0")/.." && pwd)"
solouse_target="${SOLOUSE_NATIVE_TARGET_DIR:-${CARGO_TARGET_DIR:-$solouse_root/Native/target}}"
command -v cargo >/dev/null || { echo "Install Rust/rustup and put cargo on PATH." >&2; exit 1; }
command -v xcrun >/dev/null || { echo "Full Xcode is required." >&2; exit 1; }
CARGO_TARGET_DIR="$solouse_target" cargo build --manifest-path "$solouse_root/Native/Cargo.toml" --locked --release --target aarch64-apple-ios
mkdir -p "$solouse_root/Build"
cp "$solouse_target/aarch64-apple-ios/release/libsolouse_core.a" "$solouse_root/Build/libsolouse_core.a"
echo "Built the iPhone native library."
