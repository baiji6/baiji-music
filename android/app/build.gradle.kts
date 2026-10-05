plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.baiji.baiji_music"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

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
            isMinifyEnabled = true
            isShrinkResources = true
            // 资源名混淆（AGP 8.x 用 androidResources 配置）
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    // 资源名混淆：将 res 资源名缩短为 a/b/c，配合 R8 压缩非法未用资源
    androidResources {
        isShrink = true
        // 保留启动图标与清单引用资源
        keepNames += listOf("R.string.app_name", "R.string.ic_launcher")
        // 无文本压缩；保留所有资源文件的扩展名
        noCompress += listOf("resources.arsc")
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