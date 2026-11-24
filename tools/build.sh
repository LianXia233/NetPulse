#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/core"
APP="$ROOT/app"
NDK="${ANDROID_HOME:-$HOME/toolchain/android/sdk}/ndk/27.3.13750724"
TC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"

export RUSTFLAGS="-Clink-arg=-Wl,-z,max-page-size=16384"

cd "$CORE"
env "CC_aarch64-linux-android=$TC/aarch64-linux-android24-clang" \
  "AR_aarch64-linux-android=$TC/llvm-ar" \
  "CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER=$TC/aarch64-linux-android24-clang" \
  cargo build --release --target aarch64-linux-android
env "CC_armv7-linux-androideabi=$TC/armv7a-linux-androideabi24-clang" \
  "AR_armv7-linux-androideabi=$TC/llvm-ar" \
  "CARGO_TARGET_ARMV7_LINUX_ANDROIDEABI_LINKER=$TC/armv7a-linux-androideabi24-clang" \
  cargo build --release --target armv7-linux-androideabi
cp target/aarch64-linux-android/release/libnetpulse_core.so "$APP/android/app/src/main/jniLibs/arm64-v8a/"
cp target/armv7-linux-androideabi/release/libnetpulse_core.so "$APP/android/app/src/main/jniLibs/armeabi-v7a/"

cd "$APP"
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY flutter build apk --release --target-platform android-arm64 --target-platform android-arm
mkdir -p "$ROOT/dist"
cp build/app/outputs/flutter-apk/app-release.apk "$ROOT/dist/NetPulse-1.0.8.apk"
echo "APK: $ROOT/dist/NetPulse-1.0.8.apk"
