#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/core"
APP="$ROOT/app"
VERSION="$(sed -n 's/^version:[[:space:]]*//p' "$APP/pubspec.yaml" | head -1 | tr -d '\r' | cut -d+ -f1)"
if [ -z "$VERSION" ]; then
  echo "无法从 app/pubspec.yaml 读取版本号" >&2
  exit 1
fi
SDK="${ANDROID_HOME:-$HOME/toolchain/android/sdk}"
NDK="${ANDROID_NDK_HOME:-$SDK/ndk/28.2.13676358}"
case "$(uname -s)" in
  Linux*)  HOST_TAG=linux-x86_64 ;;
  Darwin*) HOST_TAG=darwin-x86_64 ;;
  *) echo "仅支持 Linux / macOS / WSL 构建" >&2; exit 1 ;;
esac
TC="$NDK/toolchains/llvm/prebuilt/$HOST_TAG/bin"

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
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
  flutter build apk --release --target-platform android-arm64 --target-platform android-arm
mkdir -p "$ROOT/dist"
cp build/app/outputs/flutter-apk/app-release.apk "$ROOT/dist/NetPulse-$VERSION.apk"
echo "APK: $ROOT/dist/NetPulse-$VERSION.apk"
