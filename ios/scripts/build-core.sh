#!/bin/bash
# Builds the Rust app core (rust/core) for the Apple targets and writes:
#   ios/RustCore/LumisoundCore.xcframework   static libs + C header/module map
#   ios/RustCore/LumisoundCore.swift         UniFFI-generated Swift API
# Needs macOS with Xcode. PLATFORMS="ios tvos watchos" (default) or a subset.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUST="$ROOT/rust"
OUT="$ROOT/ios/RustCore"
PLATFORMS="${PLATFORMS:-ios tvos watchos}"
export IPHONEOS_DEPLOYMENT_TARGET=26.0
export TVOS_DEPLOYMENT_TARGET=26.0
export WATCHOS_DEPLOYMENT_TARGET=9.0

cd "$RUST"
staticlib() { # toolchain target
  echo "==> $2"
  if [ "$1" = "nightly" ]; then
    cargo +nightly rustc -Z build-std=std,panic_abort --release -p lumisound-core --lib --crate-type staticlib --target "$2"
  else
    cargo rustc --release -p lumisound-core --lib --crate-type staticlib --target "$2"
  fi
}
# Simulator slices for one platform go in one fat lib (xcframework allows one
# library per platform variant).
lipo_sim() { # out targets...
  local out="$1"; shift
  mkdir -p "$(dirname "$out")"
  lipo -create $(for t in "$@"; do echo "$RUST/target/$t/release/liblumisound_core.a"; done) -output "$out"
}

LIBS=()
if [[ " $PLATFORMS " == *" ios "* ]]; then
  rustup target add aarch64-apple-ios aarch64-apple-ios-sim
  staticlib stable aarch64-apple-ios
  staticlib stable aarch64-apple-ios-sim
  LIBS+=("$RUST/target/aarch64-apple-ios/release/liblumisound_core.a" "$RUST/target/aarch64-apple-ios-sim/release/liblumisound_core.a")
fi
if [[ " $PLATFORMS " == *" tvos "* || " $PLATFORMS " == *" watchos "* ]]; then
  # tvOS / watchOS are tier-3 Rust targets: std is built from source on nightly.
  rustup toolchain install nightly --profile minimal --component rust-src
fi
if [[ " $PLATFORMS " == *" tvos "* ]]; then
  staticlib nightly aarch64-apple-tvos
  staticlib nightly aarch64-apple-tvos-sim
  LIBS+=("$RUST/target/aarch64-apple-tvos/release/liblumisound_core.a" "$RUST/target/aarch64-apple-tvos-sim/release/liblumisound_core.a")
fi
if [[ " $PLATFORMS " == *" watchos "* ]]; then
  # Real watches are arm64_32 (Series 4-8, SE) or arm64 (Series 9+/Ultra 2).
  staticlib nightly arm64_32-apple-watchos
  staticlib nightly aarch64-apple-watchos
  staticlib nightly aarch64-apple-watchos-sim
  lipo_sim "$RUST/target/watchos-device/liblumisound_core.a" arm64_32-apple-watchos aarch64-apple-watchos
  LIBS+=("$RUST/target/watchos-device/liblumisound_core.a" "$RUST/target/aarch64-apple-watchos-sim/release/liblumisound_core.a")
fi

echo "==> Swift bindings"
cargo build --release -p lumisound-core --lib
GEN="$RUST/target/uniffi-gen"
rm -rf "$GEN" && mkdir -p "$GEN/include"
cargo run --release -p lumisound-core --features bindgen --bin uniffi-bindgen -- \
  generate --library "$RUST/target/release/liblumisound_core.dylib" --language swift \
  --config "$RUST/core/uniffi.toml" --out-dir "$GEN"
cp "$GEN/LumisoundCoreFFI.h" "$GEN/include/"
cp "$GEN/LumisoundCoreFFI.modulemap" "$GEN/include/module.modulemap"

echo "==> XCFramework"
rm -rf "$OUT" && mkdir -p "$OUT"
ARGS=()
for l in "${LIBS[@]}"; do ARGS+=(-library "$l" -headers "$GEN/include"); done
xcodebuild -create-xcframework "${ARGS[@]}" -output "$OUT/LumisoundCore.xcframework"
cp "$GEN/LumisoundCore.swift" "$OUT/"
du -sh "$OUT"/*
