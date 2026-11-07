#!/usr/bin/env bash
# Cross-compile the AlwaysStrong native HTTPS fetcher for x86_64 Android and
# copy the binary into native/asfetch/prebuilt/x86_64/asfetch.
#
# asfetch is arm-only in stock builds (x86/x86_64 are emulator-only, where
# curl/busybox already work — see build-asfetch.sh). This script exists for the
# x86_64 build line (.github/workflows/build-x86_64.yml): customize.sh aborts
# the install when bin/$ABI_DIR/asfetch is missing, and repair_runtime.sh's
# flock/run-bounded helpers need the binary for every settings write, so an
# x86_64 module zip ships its own asfetch instead of degrading.
#
# Run this BEFORE build.sh with ASFETCH_ABIS_EXTRA=x86_64 exported (see
# build.sh), then `find native -path '*/prebuilt/*' -type f -exec touch {} +`
# so build.sh stages the fresh binary instead of trying to rebuild all ABIs.
#
# Dependency-light on purpose (build-repair-native.sh style: plain cargo +
# the NDK clang wrappers, no cargo-ndk) so the CI job needs nothing beyond
# rustup's x86_64-linux-android target and an NDK.
#
# Requires: rustup target x86_64-linux-android, ANDROID_NDK_HOME (NDK r25+).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/native/asfetch"
OUT="$SRC/prebuilt"
MIN_API=29   # match MIN_SDK in customize.sh
TARGET="x86_64-linux-android"

[[ -n "${ANDROID_NDK_HOME:-}" ]] || {
    echo "ANDROID_NDK_HOME not set" >&2
    exit 1
}
command -v cargo >/dev/null 2>&1 || {
    echo "cargo not on PATH (source ~/.cargo/env?)" >&2
    exit 1
}
if ! rustup target list --installed 2>/dev/null | grep -qx "$TARGET"; then
    echo "rust target $TARGET missing (rustup target add $TARGET)" >&2
    exit 1
fi

case "$(uname -s)" in
    Darwin) host=darwin-x86_64 ;;
    Linux)  host=linux-x86_64 ;;
    *) echo "unsupported host OS: $(uname -s)" >&2; exit 1 ;;
esac
TOOL="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$host/bin"
[[ -x "$TOOL/${TARGET}${MIN_API}-clang" ]] || {
    echo "NDK clang not found at $TOOL/${TARGET}${MIN_API}-clang" >&2
    exit 1
}

# Same path-hygiene as build-asfetch.sh: no build-machine paths in .rodata.
CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=${CARGO_HOME}=/cargo --remap-path-prefix=${SRC}=/src --remap-path-prefix=${HOME}=/build"

env_target=${TARGET//-/_}
upper=$(printf %s "$env_target" | tr '[:lower:]' '[:upper:]')

echo "==> cross-compiling asfetch (x86_64, API $MIN_API)"
env "CARGO_TARGET_${upper}_LINKER=$TOOL/${TARGET}${MIN_API}-clang" \
    "CC_$env_target=$TOOL/${TARGET}${MIN_API}-clang" \
    "AR_$env_target=$TOOL/llvm-ar" \
    cargo build --locked --release --target "$TARGET" --manifest-path "$SRC/Cargo.toml"

src_bin="$SRC/target/$TARGET/release/asfetch"
[[ -f "$src_bin" ]] || { echo "missing $src_bin" >&2; exit 1; }
mkdir -p "$OUT/x86_64"
cp -f "$src_bin" "$OUT/x86_64/asfetch"
chmod 755 "$OUT/x86_64/asfetch"

echo "==> prebuilt binary:"
du -h "$OUT/x86_64/asfetch"
