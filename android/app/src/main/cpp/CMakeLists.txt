cmake_minimum_required(VERSION 3.22.1)
project(baiji_music_native LANGUAGES C CXX)

add_library(dts_glue SHARED dts_glue.c)

add_library(ra360_glue SHARED ra360_glue.cpp)
# 官方 decoder 是 C++ ABI（IDataSource 虚表 / std::string），glue 用 C++ 编译。
# exceptions/RTTI 关闭与 bionic 官方库一致。
target_compile_options(ra360_glue PRIVATE -fno-exceptions -fno-rtti)

target_link_libraries(dts_glue
    log       # __android_log_print
    dl        # dlopen / dlsym
)

target_link_libraries(ra360_glue
    log       # __android_log_print
    dl        # dlopen / dlsym
)

# 官方 DTSPlaybackSDK.so / qm_native_decoder_360ra.so 等由 jniLibs 直接打包
# （预编译，不参与编译）。运行时 dlopen 会加载同一 nativeLibraryDir 的副本。
