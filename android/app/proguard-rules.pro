# 白姬音乐 Android R8/ProGuard 规则
# ---------------------------------------------------------------------------
# 目标：开启全量混淆的同时，保证 Flutter 引擎、插件反射与日志链路不崩溃。
# 原则：keep 最小面——只保留必须通过 Java 反射/命名访问的类，其余全部混淆。

# ---- Flutter 引擎 ----
-keep class io.flutter.** { *; }
-keep class io.flutter.plugin.editing.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.embedding.** { *; }

# ---- Flutter 可变分包（Optional Deferred Components）引用了 play-core，但本工程未引入该依赖 ----
# 这些类属于可选功能（Play Store 动态交付），缺失时 R8 不应报错
-dontwarn com.google.android.play.core.splitinstall.**
-dontwarn com.google.android.play.core.splitcompat.**
-dontwarn com.google.android.play.core.tasks.**

# ---- Flutter 插件（just_audio / path_provider / shared_preferences 等）----
-keep class com.ryanheise.audioservice.** { *; }
-keep class com.ryanheise.audioplayer.** { *; }

# ---- Kotlin 元数据 / 协程 ----
-keepclassmembers class * {
    @kotlin.Metadata *;
}
-dontwarn kotlinx.coroutines.**
-dontwarn org.jetbrains.annotations.**

# ---- Gson / JSON 反序列化目标（Credential 等 POJO 保留字段名）----
-keep class com.baiji.baiji_music.models.** { *; }
-keepclassmembers class * {
    @com.google.gson.annotations.SerializedName <fields>;
}

# ---- 确保 entry point 不被混淆 ----
-keepclasseswithmembers class * {
    public static void main(java.lang.String[]);
}
-keepclassmembers class * {
    native <methods>;
}

# ---- 资源混淆保护：Material 组件 / 系统主题资源名 keep 由 androidResources.keepNames 处理 ----
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile