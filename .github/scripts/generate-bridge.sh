#!/usr/bin/env bash
set -euo pipefail

frb_codegen_version="${FRB_CODEGEN_VERSION:-2.12.0}"
rust_features="${FRB_RUST_FEATURES:-}"

installed_version=""
if command -v flutter_rust_bridge_codegen >/dev/null 2>&1; then
  installed_version="$(flutter_rust_bridge_codegen --version | awk '{print $NF}')"
fi

if [[ "${installed_version}" != "${frb_codegen_version}" ]]; then
  cargo install flutter_rust_bridge_codegen --version "${frb_codegen_version}"
fi

args=(
  --rust-input crate::flutter_ffi
  --rust-root .
  --rust-output ./src/bridge_generated.rs
  --dart-root ./flutter
  --dart-output ./flutter/lib/generated_bridge
  --c-output ./flutter/ios/Runner/bridge_generated.h
  --duplicated-c-output ./flutter/macos/Runner/bridge_generated.h
  --no-add-mod-to-lib
  --type-64bit-int
  --no-deps-check
  --no-auto-upgrade-dependency
)

if [[ -n "${rust_features}" ]]; then
  args+=(--rust-features "${rust_features}")
fi

flutter_rust_bridge_codegen generate "${args[@]}"
python3 .github/scripts/generate-bridge-facade.py
dart format \
  ./flutter/lib/generated_bridge.dart \
  ./flutter/lib/generated_bridge
python3 .github/scripts/normalize-generated-bridge.py
