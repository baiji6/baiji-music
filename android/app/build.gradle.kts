plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.baiji.baiji_music"
    compileSdk = 36

    ndkVersion = flutter.ndkVersion

    // 关闭 Google 依赖信息块（DEPENDENCY_INFO_BLOCK），减小 APK 体积并减少元数据泄露
    dependenciesInfo {
        includeInApk = false
        includeInBundle = false
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    signingConfigs {
        // 签名配置从环境变量注入（CI secrets 提供），keystore 文件不提交到仓库
        create("release") {
            val ksPath = System.getenv("ANDROID_KEYSTORE_PATH")
            if (!ksPath.isNullOrBlank()) {
                storeFile = file(ksPath)
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD") ?: ""
                keyAlias = System.getenv("ANDROID_KEY_ALIAS") ?: ""
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD") ?: ""
                // 用户要求完整签名链 v1 + v2 + v3
                enableV1Signing = true
                enableV2Signing = true
                enableV3Signing = true
            }
        }
    }

    defaultConfig {
        applicationId = "com.baiji.baiji_music"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // CI 注入签名密钥时用 release 签名；本地无密钥时回退 debug 签名便于出包
            signingConfig = if (System.getenv("ANDROID_KEYSTORE_PATH").isNullOrBlank())
                signingConfigs.getByName("debug")
            else
                signingConfigs.getByName("release")
            // —— R8 全量混淆 + 资源压缩（防逆向核心开关）——
            // AGP 9.3 之前：isShrinkResources 在 release 构建类型上启用资源压缩；
            // 代码压缩 isMinifyEnabled 同时驱动 R8 全量混淆与资源混淆。
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
