#!/usr/bin/env bash
# 交叉编译 AC-4 / AV3A 原生解码器 so（baka Rust crate）。
#
# 产物（Android）：
#   android/app/src/main/jniLibs/<abi>/libac4_baka.so
#   android/app/src/main/jniLibs/<abi>/libav3a_baka.so
#
# 上游源码 vendor 在 tools/native_decoders/vendor/，C ABI wrapper 在
# tools/native_decoders/{ac4_baka,av3a_baka}/。仅依赖系统 libc/libm/libdl。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/tools/native_decoders"
NDK="${ANDROID_NDK_HOME:-/opt/android-sdk/ndk/28.2.13676358}"
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
JNI="$ROOT/android/app/src/main/jniLibs"
API=24

if [ ! -d "$TOOLCHAIN" ]; then
  echo "NDK toolchain not found: $TOOLCHAIN" >&2
  exit 1
fi

# 上游 crate 声明 rust-version 1.100，本地 stable 实测可编译，统一覆盖。
export RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-stable}"

build_target() {
  local target="$1" cc="$2" linker="$3" abi="$4"
  echo "==> building $target ($abi)"
  CC="$cc" \
  CARGO_TARGET_${target//-/_}_LINKER="$linker" \
    cargo build --release --manifest-path "$WORK/Cargo.toml" --target "$target"
  for so in libac4_baka.so libav3a_baka.so; do
    install -m 0644 "$WORK/target/$target/release/$so" "$JNI/$abi/$so"
  done
}

mkdir -p "$JNI/arm64-v8a" "$JNI/armeabi-v7a"

build_target aarch64-linux-android \
  "$TOOLCHAIN/bin/aarch64-linux-android${API}-clang" \
  "$TOOLCHAIN/bin/aarch64-linux-android${API}-clang" arm64-v8a

build_target armv7-linux-androideabi \
  "$TOOLCHAIN/bin/armv7a-linux-androideabi${API}-clang" \
  "$TOOLCHAIN/bin/armv7a-linux-androideabi${API}-clang" armeabi-v7a

echo "done. installed:"
ls -lh "$JNI/arm64-v8a"/libac4_baka.so "$JNI/arm64-v8a"/libav3a_baka.so \
      "$JNI/armeabi-v7a"/libac4_baka.so "$JNI/armeabi-v7a"/libav3a_baka.so
