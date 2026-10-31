cmake_minimum_required(VERSION 3.22.1)
project(baiji_music_native LANGUAGES C CXX)

add_library(dts_glue SHARED dts_glue.c)

add_library(ra360_glue SHARED ra360_glue.cpp)
# 官方 decoder 是 C++ ABI（IDataSource 虚表 / std::string），glue 用 C++ 编译。
# exceptions/RTTI 关闭与 bionic 官方库一致。
target_compile_options(ra360_glue PRIVATE -fno-exceptions -fno-rtti)

# NAC（TL01）神经音频解码：自研管线 —— 容器解析 + codes 解包 + MNN 推理 +
# ISTFT。运行时 dlopen 官方 libMNN_dl.so（arm64，Apache-2.0 的 MNN 引擎），
# 因此编译期不链接任何 MNN 库、也不需要 MNN 头文件。
add_library(nac_glue SHARED nac_glue.cpp)
target_compile_options(nac_glue PRIVATE -fno-exceptions -fno-rtti)

target_link_libraries(dts_glue
    log       # __android_log_print
    dl        # dlopen / dlsym
)

target_link_libraries(ra360_glue
    log       # __android_log_print
    dl        # dlopen / dlsym
)

target_link_libraries(nac_glue
    log       # __android_log_print
    dl        # dlopen / dlsym
)

# 官方 DTSPlaybackSDK.so / qm_native_decoder_360ra.so / libMNN_dl.so 等由
# jniLibs 直接打包（预编译，不参与编译）。运行时 dlopen 会加载同一
# nativeLibraryDir 的副本。
