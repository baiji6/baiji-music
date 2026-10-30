cmake_minimum_required(VERSION 3.22.1)
project(baiji_music_native LANGUAGES C)

add_library(dts_glue SHARED dts_glue.c)

target_link_libraries(dts_glue
    log       # __android_log_print
    dl        # dlopen / dlsym
)

# 官方 DTSPlaybackSDK.so 由 jniLibs 直接打包（预编译，不参与编译）。
# 运行时 dlopen("libDTSPlaybackSDK.so") 会加载同一 nativeLibraryDir 的副本。
