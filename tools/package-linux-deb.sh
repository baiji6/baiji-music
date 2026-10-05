#!/usr/bin/env bash
# ==============================================================================
# 白姬音乐 · Linux(.deb) 打包脚本
# 用法: bash tools/package-linux-deb.sh <VERSION>
# 前置: flutter build linux --release 已完成（bundle 位于 build/linux/x64/release/bundle），
#       且可执行文件已被 UPX 加壳（如配置了该步骤）。
# 产物: build/linux/baiji-music_<VERSION>_amd64.deb
# ==============================================================================
set -euo pipefail

VER="${1:?usage: package-linux-deb.sh <VERSION>}"
BUNDLE="build/linux/x64/release/bundle"
PKG="build/linux/deb/baiji-music"
OUT="build/linux/baiji-music_${VER}_amd64.deb"

[ -d "$BUNDLE" ] || { echo "::error::bundle not found: $BUNDLE"; exit 1; }
[ -f "$BUNDLE/baiji_music" ] || { echo "::error::main binary not found in bundle"; exit 1; }

rm -rf build/linux/deb
mkdir -p "$PKG/DEBIAN" \
         "$PKG/usr/share/baiji_music" \
         "$PKG/usr/share/applications" \
         "$PKG/usr/share/icons/hicolor/256x256/apps" \
         "$PKG/usr/bin"

# 安装文件（bundle 内容）
cp -r "$BUNDLE"/* "$PKG/usr/share/baiji_music/"

# 图标（复用 macOS AppIcon 256px，若存在；否则跳过）
if [ -f "macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png" ]; then
  cp "macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png" \
     "$PKG/usr/share/icons/hicolor/256x256/apps/baiji-music.png"
fi

# 桌面入口
cat > "$PKG/usr/share/applications/baiji-music.desktop" <<'DESKTOP'
[Desktop Entry]
Name=白姬音乐
Name[en]=Baiji Music
Comment=跨平台音乐播放客户端
Exec=/usr/bin/baiji-music
Icon=baiji-music
Terminal=false
Type=Application
Categories=AudioVideo;Audio;Player;
StartupWMClass=baiji_music
DESKTOP

# 启动包装器
cat > "$PKG/usr/bin/baiji-music" <<'WRAPPER'
#!/bin/sh
exec /usr/share/baiji_music/baiji_music "$@"
WRAPPER
chmod +x "$PKG/usr/bin/baiji-music" "$PKG/usr/share/baiji_music/baiji_music"

# control 文件
cat > "$PKG/DEBIAN/control" <<CONTROL
Package: baiji-music
Version: ${VER}
Section: sound
Priority: optional
Architecture: amd64
Maintainer: baiji6 <baiji6@users.noreply.github.com>
Installed-Size: $(du -sk "$PKG/usr" | awk '{print $1}')
Depends: libgtk-3-0 (>= 3.24), liblzma5, libstdc++6, libc6 (>= 2.34)
Description: 白姬音乐 - 跨平台音乐播放客户端
 Modern futuristic music player for desktop (Linux amd64 build).
CONTROL

# 打包 .deb
dpkg-deb --build --root-owner-group "$PKG" "$OUT"
ls -la "$OUT"