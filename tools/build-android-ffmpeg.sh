#!/usr/bin/env bash
# 白姬音乐 — Android 内置 ffmpeg 转码引擎构建脚本（可复现）
#
# 背景：App 播放链路用的 media_kit / libmpv 内嵌 ffmpeg 是白名单纯解码构建
# （--disable-muxers --disable-encoders --disable-programs），能解几乎所有音质
# 但没有编码器 / 封装器 / 命令行，产不出文件。音频转码因此随 APK 附带一份
# 「裁剪版静态 ffmpeg CLI」，只启用转码需要的组件，体积约 5MB / ABI。
#
# 上游与许可（均为 LGPL-2.1+ / BSD，未启用任何 GPL 组件）：
#   FFmpeg 7.1.3 (LGPL-2.1+)  https://ffmpeg.org/releases/ffmpeg-7.1.3.tar.xz
#   lame 3.100   (LGPL-2.1)   https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz
#   libogg 1.3.5 (BSD)        https://downloads.xiph.org/releases/ogg/libogg-1.3.5.tar.gz
#   libvorbis 1.3.7 (BSD)     https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.gz
# 随 APK 分发静态链接的 LGPL 库需保留本脚本与上游源码获取方式（见 release
# libs-ffmpeg-v1 的说明），便于使用者自行重构建/替换。
#
# 用法：
#   ANDROID_NDK_HOME=/path/to/ndk/28.2.13676358 ./tools/build-android-ffmpeg.sh
#   ABIS="arm64-v8a" ./tools/build-android-ffmpeg.sh
#   LINK_MODE=exe ./tools/build-android-ffmpeg.sh   # 产出 qemu 可跑的静态 ET_EXEC 验证版
#
# 产物：
#   $ROOT/out/<abi>/libffmpeg_exec.so       static-PIE（随 APK 打包）
#   $ROOT/jars/ffmpeg-<abi>.jar             jar 内路径 lib/<abi>/libffmpeg_exec.so
#   $ROOT/jars/*.md5                        写进 third_party/.../build.gradle 的校验和
#
# 打包约定：app 模块必须开启 packaging.jniLibs.useLegacyPackaging = true
# （等价于 android:extractNativeLibs="true"），安装时系统把 lib*.so 解压到
# nativeLibraryDir 并授予执行权限；Android 10+ 的 W^X 只允许执行该只读目录
# 里的二进制，因此不能改用 assets + 运行时复制。
set -euo pipefail

ROOT=${FFMPEG_BUILD_ROOT:-/tmp/baiji-ffmpeg-build}
SRC=$ROOT/src
NDK=${ANDROID_NDK_HOME:-/opt/android-sdk/ndk/28.2.13676358}
API=${ANDROID_API:-24}
ABIS=${ABIS:-"arm64-v8a armeabi-v7a x86_64"}
LINK_MODE=${LINK_MODE:-pie}   # pie（随包）/ exe（qemu 端到端验证）
TOOLCHAIN=$NDK/toolchains/llvm/prebuilt/linux-x86_64

mkdir -p "$SRC" "$ROOT/jars"

# ---------------------------------------------------------------- 源码 ------
fetch() {
  local url=$1 tarball=$2 dir=$3
  if [ -d "$SRC/$dir" ]; then return; fi
  echo "=== 下载 $tarball ==="
  curl -sSL --fail --retry 3 -o "$SRC/$tarball" "$url"
  tar xf "$SRC/$tarball" -C "$SRC"
}
fetch https://ffmpeg.org/releases/ffmpeg-7.1.3.tar.xz ffmpeg-7.1.3.tar.xz ffmpeg-7.1.3
fetch https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz lame-3.100.tar.gz lame-3.100
fetch https://downloads.xiph.org/releases/ogg/libogg-1.3.5.tar.gz libogg-1.3.5.tar.gz libogg-1.3.5
fetch https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.gz libvorbis-1.3.7.tar.gz libvorbis-1.3.7

# ---------------------------------------------------------------- 组件白名单 --
DEMUXERS=wav,flac,mp3,aac,ogg,mov,asf,ac3,eac3,dts,aiff,ape,wv,dsf,caf,au,matroska,m4a,mp4,adts
DECODERS=pcm_s16le,pcm_s24le,pcm_s32le,pcm_s64le,pcm_f32le,pcm_f64le,pcm_u8,pcm_alaw,pcm_mulaw,flac,mp3,mp3float,mp3adu,aac,aac_fixed,alac,vorbis,wmav1,wmav2,wmalossless,wmapro,ac3,eac3,opus,dca,truehd,mlp,ape,wavpack,dsd_lsbf,dsd_msbf,adpcm_ima_wav
ENCODERS=pcm_s16le,pcm_s24le,pcm_s32le,flac,aac,wmav2,libmp3lame,libvorbis,ac3,eac3
MUXERS=wav,flac,ipod,mp4,asf,adts,ac3,eac3,mp3,ogg
FILTERS=anull,anullsrc,aresample,aformat,abuffer,abuffersink,asetnsamples,atrim,asetpts,asettb,volume,acopy
PARSERS=aac,aac_latm,ac3,flac,mp3,vorbis,opus,dca,dts,mpegaudio
BSFS=aac_adtstoasc,extract_extradata,null
PROTOCOLS=file,pipe

DEPS_CFLAGS="-fPIC -O3 -DNDEBUG"
FF_CFLAGS="$DEPS_CFLAGS -DANDROID -D__ANDROID_API__=$API"
PAGE_ALIGN="-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384"
case "$LINK_MODE" in
  pie) FF_LDFLAGS="-static-pie $PAGE_ALIGN" ;;
  exe) FF_LDFLAGS="-static $PAGE_ALIGN" ;;
  *) echo "LINK_MODE 只能是 pie 或 exe"; exit 2 ;;
esac

build_autotools() {
  local abi=$1 name=$2 dir=$3; shift 3
  local work="$ROOT/build/$abi/$name"
  echo "=== [$abi] build $name ==="
  rm -rf "$work"; mkdir -p "$work"
  ( cd "$work"
    export CC="$CC" CXX="$CXX" AR="$AR" NM="$NM" RANLIB="$RANLIB" STRIP="$STRIP"
    export CFLAGS="$DEPS_CFLAGS" CXXFLAGS="$DEPS_CFLAGS" LDFLAGS=""
    export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
    "$SRC/$dir/configure" --host="$HOST" --prefix="$PREFIX" \
      --disable-shared --enable-static "$@" )
  make -C "$work" -j"$(nproc)"
  make -C "$work" install
}

for ABI in $ABIS; do
  case "$ABI" in
    arm64-v8a)     TRIPLE=aarch64-linux-android;    ARCH=aarch64; CPU=armv8-a; HOST=aarch64-linux-android ;;
    armeabi-v7a)   TRIPLE=armv7a-linux-androideabi; ARCH=arm;      CPU=armv7-a; HOST=armv7a-linux-androideabi ;;
    x86_64)        TRIPLE=x86_64-linux-android;     ARCH=x86_64;   CPU=x86-64;  HOST=x86_64-linux-android ;;
    *) echo "不支持的 ABI: $ABI"; exit 2 ;;
  esac

  PREFIX="$ROOT/prefix/$ABI"
  OUT="$ROOT/out/$ABI"
  mkdir -p "$PREFIX/lib/pkgconfig" "$OUT" "$ROOT/build/$ABI/ffmpeg"
  CC="$TOOLCHAIN/bin/${TRIPLE}${API}-clang"
  CXX="$TOOLCHAIN/bin/${TRIPLE}${API}-clang++"
  AR="$TOOLCHAIN/bin/llvm-ar"
  NM="$TOOLCHAIN/bin/llvm-nm"
  RANLIB="$TOOLCHAIN/bin/llvm-ranlib"
  STRIP="$TOOLCHAIN/bin/llvm-strip"

  echo "=== [$ABI] toolchain: $CC ==="
  "$CC" --version | head -1

  build_autotools "$ABI" libogg libogg-1.3.5 \
    ac_cv_func_malloc_0_nonnull=yes ac_cv_func_realloc_0_nonnull=yes
  build_autotools "$ABI" libvorbis libvorbis-1.3.7
  build_autotools "$ABI" lame lame-3.100 \
    --disable-frontend --disable-decoder --disable-gtktest --disable-analyzer-hooks

  echo "=== [$ABI] configure ffmpeg ==="
  ( cd "$ROOT/build/$ABI/ffmpeg"
    export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
    "$SRC/ffmpeg-7.1.3/configure" \
      --prefix="$OUT" \
      --enable-cross-compile --target-os=android --arch="$ARCH" --cpu="$CPU" \
      --cc="$CC" --cxx="$CXX" --ar="$AR" --nm="$NM" --ranlib="$RANLIB" --strip="$STRIP" \
      --pkg-config=pkg-config --pkg-config-flags=--static \
      --extra-cflags="-I$PREFIX/include $FF_CFLAGS" \
      --extra-cxxflags="-I$PREFIX/include $FF_CFLAGS" \
      --extra-ldflags="-L$PREFIX/lib $FF_LDFLAGS" \
      --extra-libs="-lm" \
      --disable-shared --enable-static --enable-pic \
      --disable-autodetect --disable-doc --disable-debug --disable-symver \
      --disable-avdevice --disable-postproc --disable-swscale \
      --disable-ffplay --disable-ffprobe --enable-ffmpeg \
      --disable-encoders --disable-decoders --disable-muxers --disable-demuxers \
      --disable-parsers --disable-bsfs --disable-protocols --disable-filters \
      --disable-hwaccels --disable-devices --disable-indevs --disable-outdevs \
      --enable-demuxer=$DEMUXERS --enable-decoder=$DECODERS \
      --enable-encoder=$ENCODERS --enable-muxer=$MUXERS \
      --enable-filter=$FILTERS --enable-parser=$PARSERS \
      --enable-bsf=$BSFS --enable-protocol=$PROTOCOLS \
      --enable-libmp3lame --enable-libvorbis \
      --enable-swresample --enable-avfilter
  )
  make -C "$ROOT/build/$ABI/ffmpeg" -j"$(nproc)"

  cp "$ROOT/build/$ABI/ffmpeg/ffmpeg" "$OUT/libffmpeg_exec.so"
  "$STRIP" "$OUT/libffmpeg_exec.so" 2>/dev/null || true
  echo "=== [$ABI] ffmpeg ($LINK_MODE) ==="
  file "$OUT/libffmpeg_exec.so"

  # 打包成 jar（内部路径 lib/<abi>/libffmpeg_exec.so），与官方 media-kit jar 一致
  stage="$ROOT/pkg/$ABI"
  rm -rf "$stage"; mkdir -p "$stage/lib/$ABI"
  cp "$OUT/libffmpeg_exec.so" "$stage/lib/$ABI/libffmpeg_exec.so"
  ( cd "$stage" && zip -q -r "$ROOT/jars/ffmpeg-$ABI.jar" lib )
done

echo "=== 完成：$ROOT/jars ==="
( cd "$ROOT/jars" && md5sum ffmpeg-*.jar | tee checksums.md5 )
echo
echo "下一步：把 *.jar 上传到 release libs-ffmpeg-v1，并把上面的 MD5 同步到"
echo "third_party/media_kit_libs_android_audio/android/build.gradle 的 filesToDownload。"
