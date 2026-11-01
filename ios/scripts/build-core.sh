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
# Only the target's own deployment variable may be set: clang (coreaudio-sys
# bindgen) rejects an environment carrying several.
IOS_MIN=26.0
TVOS_MIN=26.0
WATCHOS_MIN=9.0

cd "$RUST"
staticlib() { # toolchain target
  echo "==> $2"
  local envvar
  case "$2" in
    *-ios|*-ios-sim) envvar="IPHONEOS_DEPLOYMENT_TARGET=$IOS_MIN" ;;
    *-tvos|*-tvos-sim) envvar="TVOS_DEPLOYMENT_TARGET=$TVOS_MIN" ;;
    *-watchos|*-watchos-sim) envvar="WATCHOS_DEPLOYMENT_TARGET=$WATCHOS_MIN" ;;
  esac
  if [ "$1" = "nightly" ]; then
    env $envvar cargo +nightly rustc -Z build-std=std,panic_abort --release -p lumisound-core --lib --crate-type staticlib --target "$2"
  else
    env $envvar cargo rustc --release -p lumisound-core --lib --crate-type staticlib --target "$2"
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
  rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
  staticlib stable aarch64-apple-ios
  staticlib stable aarch64-apple-ios-sim
  # Intel simulator slice too: "generic/platform=iOS Simulator" builds both archs.
  staticlib stable x86_64-apple-ios
  lipo_sim "$RUST/target/ios-sim-universal/liblumisound_core.a" aarch64-apple-ios-sim x86_64-apple-ios
  LIBS+=("$RUST/target/aarch64-apple-ios/release/liblumisound_core.a" "$RUST/target/ios-sim-universal/liblumisound_core.a")
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
  staticlib nightly x86_64-apple-watchos-sim
  lipo_sim "$RUST/target/watchos-device/liblumisound_core.a" arm64_32-apple-watchos aarch64-apple-watchos
  lipo_sim "$RUST/target/watchos-sim-universal/liblumisound_core.a" aarch64-apple-watchos-sim x86_64-apple-watchos-sim
  LIBS+=("$RUST/target/watchos-device/liblumisound_core.a" "$RUST/target/watchos-sim-universal/liblumisound_core.a")
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
