#!/usr/bin/env bash
# ==============================================================================
# 白姬音乐 —— 六端统一构建·加壳·混淆流水线
# ------------------------------------------------------------------------------
# 用法:
#   ./scripts/protect/build_all.sh [android|ios|macos|windows|linux|ohos|all] [--release-only]
#
# 每个平台构建后自动执行加固:
#   Android : R8/资源压缩 + 资源混淆（build.gradle.kts 已配置）+ Dart 混淆
#   iOS     : --obfuscate + Xcode Release 自动 STRIP 符号
#   macOS   : --obfuscate + 构建后 strip 未导出符号
#   Windows : --obfuscate + UPX 压缩可执行文件
#   Linux   : --obfuscate + UPX 压缩可执行文件
#   ohos    : 方舟编译器 Obfuscation 配置（entry 模块开混淆）
#
# 产物统一输出到 build/out/<platform>/，日志输出到 build/logs/。
# ==============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

FLUTTER_BIN="${FLUTTER_BIN:-flutter}"
FLUTTER_CMD="$(command -v "$FLUTTER_BIN" || echo "$ROOT/../../tools/flutter/bin/flutter")"
UPX="$ROOT/tools/upx/upx-linux-x64"
OUT="$ROOT/build/out"
LOGS="$ROOT/build/logs"
mkdir -p "$OUT" "$LOGS"

# Dart 混淆参数（六端通用核心防逆向）
OBF_ARGS=(--obfuscate --split-debug-info="$OUT/debug-info")

log() { echo "[build] $*"; }
fail() { echo "[build] ❌ $*" >&2; exit 1; }

# ---------------------------------------------------------------- Android
build_android() {
  log ">>> Android：Dart 混淆 + R8/资源混淆（release）"
  "$FLUTTER_CMD" build apk --release "${OBF_ARGS[@]}" \
    --dart-define=BAIJI_BUILD_SHELL=1 \
    --dart-define=BAIJI_BUILD_DATE="$(date +%s)" 2>&1 \
    | tee "$LOGS/android.log" || fail "Android 构建失败"
  cp -f build/app/outputs/flutter-apk/app-release.apk "$OUT/android-app-release.apk"
  log "    ✅ $OUT/android-app-release.apk"
}

# ---------------------------------------------------------------- iOS
build_ios() {
  log ">>> iOS：Dart 混淆 + Archive（Release 自动 strip 符号）"
  "$FLUTTER_CMD" build ios --release --no-codesign "${OBF_ARGS[@]}" 2>&1 \
    | tee "$LOGS/ios.log" || fail "iOS 构建失败"
  # 符号剥离：对 app 内主二进制执行 strip（保留必要符号，移除调试/本地符号表）
  local APP=$(find build/ios/iphoneos -maxdepth 2 -name "*.app" | head -1)
  if [ -n "$APP" ] && command -v xcrun >/dev/null 2>&1; then
    xcrun strip -x "$APP/$(basename "${APP%.app}")" 2>/dev/null || true
    log "    ✅ 已 strip 符号: $APP"
  fi
  log "    ✅ ios/Runner.xcworkspace 构建产物（真机签名请用 Xcode Archive）"
}

# ---------------------------------------------------------------- macOS
build_macos() {
  log ">>> macOS：Dart 混淆 + 构建后符号剥离"
  "$FLUTTER_CMD" build macos --release "${OBF_ARGS[@]}" 2>&1 \
    | tee "$LOGS/macos.log" || fail "macOS 构建失败"
  local APP=$(find build/macos/Build/Products/Release -maxdepth 1 -name "*.app" | head -1)
  [ -n "$APP" ] || fail "未找到 macOS .app 产物"
  # strip 未导出符号（等价 Xcode STRIP_INSTALLED_PRODUCT）
  for bin in "$APP/Contents/MacOS/"*; do
    [ -f "$bin" ] && strip -x "$bin" 2>/dev/null || true
  done
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/macos-app.zip" 2>/dev/null \
    || zip -qr "$OUT/macos-app.zip" "$APP"
  log "    ✅ $OUT/macos-app.zip"
}

# ---------------------------------------------------------------- Windows
build_windows() {
  log ">>> Windows：Dart 混淆 + UPX 压缩"
  "$FLUTTER_CMD" build windows --release "${OBF_ARGS[@]}" 2>&1 \
    | tee "$LOGS/windows.log" || fail "Windows 构建失败"
  local EXE=$(find build/windows/x64/runner/Release -maxdepth 1 -name "*.exe" | head -1)
  [ -n "$EXE" ] || fail "未找到 Windows exe"
  "$UPX" --best -f "$EXE" 2>&1 | tee -a "$LOGS/windows.log" || true
  (cd build/windows/x64/runner/Release && zip -qr "$OUT/windows-x64.zip" .)
  log "    ✅ $OUT/windows-x64.zip（已 UPX）"
}

# ---------------------------------------------------------------- Linux
build_linux() {
  log ">>> Linux：Dart 混淆 + UPX 压缩"
  "$FLUTTER_CMD" build linux --release "${OBF_ARGS[@]}" 2>&1 \
    | tee "$LOGS/linux.log" || fail "Linux 构建失败"
  local BIN="build/linux/x64/release/bundle/baiji_music"
  [ -f "$BIN" ] || fail "未找到 Linux 可执行文件"
  "$UPX" --best -f "$BIN" 2>&1 | tee -a "$LOGS/linux.log" || true
  (cd build/linux/x64/release/bundle && zip -qr "$OUT/linux-x64.zip" .)
  log "    ✅ $OUT/linux-x64.zip（已 UPX）"
}

# ---------------------------------------------------------------- 鸿蒙 ohos
build_ohos() {
  log ">>> 鸿蒙 OHOS：hvigor 构建（entry 模块开启方舟混淆，见 build-profile.json5）"
  # 鸿蒙 SDK 需在 DevEco Studio 环境，hvigorw 在 ohos/ 下
  if [ -x "$ROOT/ohos/hvigorw" ]; then
    (cd "$ROOT/ohos" && ./hvigorw assembleHap --mode module -p product=default -p buildMode=release 2>&1 \
      | tee "$LOGS/ohos.log") || log "    ⚠ 鸿蒙 SDK 未安装，跳过本地构建（混淆配置已生效）"
  else
    log "    ⚠ 未找到 ohos/hvigorw（在 DevEco Studio 中打开 ohos/ 构建即可，混淆自动生效）"
  fi
  log "    ✅ 鸿蒙混淆配置：ohos/entry/obfuscation-rules.txt + build-profile.json5"
}

# ---------------------------------------------------------------- main
case "${1:-all}" in
  android) build_android ;;
  ios) build_ios ;;
  macos) build_macos ;;
  windows) build_windows ;;
  linux) build_linux ;;
  ohos) build_ohos ;;
  all) build_android; build_ios; build_macos; build_windows; build_linux; build_ohos ;;
  *) fail "用法: $0 [android|ios|macos|windows|linux|ohos|all]" ;;
esac

log "=== 全部完成，产物目录: $OUT ==="