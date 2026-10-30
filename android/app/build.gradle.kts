import java.io.FileInputStream
import java.security.KeyStore
import java.security.MessageDigest
import java.security.cert.Certificate

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

/**
 * 计算本次构建**实际使用**的签名证书 SHA-256 指纹（#78 签名校验）。
 *
 * - 配置了 ANDROID_KEYSTORE_PATH（CI 正式签名）→ 读正式 keystore；
 * - 否则回退 debug keystore（本地出包）——指纹跟随实际签名，始终自洽。
 *
 * 指纹注入 BuildConfig.SIGN_CERT_SHA256，运行时由 MainActivity 读取
 * 当前 APK 的签名证书与之比对：重打包 / 换签的 APK 指纹必然对不上。
 * 纯 JVM API（KeyStore + MessageDigest），不依赖 keytool 输出解析。
 */
fun signingCertSha256(): String {
    val ksPath = System.getenv("ANDROID_KEYSTORE_PATH")
    val ksFile: File
    val ksPass: String
    val ksAlias: String
    if (!ksPath.isNullOrBlank()) {
        ksFile = File(ksPath)
        ksPass = System.getenv("ANDROID_KEYSTORE_PASSWORD") ?: ""
        ksAlias = System.getenv("ANDROID_KEY_ALIAS") ?: ""
    } else {
        ksFile = File(System.getProperty("user.home"), ".android/debug.keystore")
        ksPass = "android"
        ksAlias = "androiddebugkey"
    }
    if (!ksFile.exists()) return ""
    // .jks 与 .pkcs12 两种容器都试；别名给不准就取第一个证书
    for (type in listOf("JKS", "PKCS12")) {
        try {
            val ks = KeyStore.getInstance(type)
            FileInputStream(ksFile).use { ks.load(it, ksPass.toCharArray()) }
            val alias = if (ksAlias.isNotEmpty() && ks.containsAlias(ksAlias))
                ksAlias
            else
                ks.aliases().nextElement()
            val cert: Certificate = ks.getCertificate(alias) ?: continue
            return MessageDigest.getInstance("SHA-256")
                .digest(cert.encoded)
                .joinToString("") { "%02x".format(it) }
        } catch (e: Exception) {
            // 换下一种容器类型再试
        }
    }
    return ""
}

android {
    namespace = "com.baiji.baiji_music"
    // compileSdk 必须与所用插件的 AAR metadata 相容：
    // permission_handler_android 14.x 声明了 minCompileSdk=37，宿主低于 37 时
    // `checkReleaseAarMetadata` 会判定构建失败。但本机 AGP 9.1.0 官方只支持到
    // API 36（更高平台包也已改名 android-37.x），所以这里维持 36，
    // 转而在 pubspec 里把 permission_handler 钉在 12.x（对应 android 13.x，
    // compileSdk 35）来对齐。
    compileSdk = 36

    ndkVersion = flutter.ndkVersion

    // v2.4.2-pre8：臻品 DTS:X 原生解码（dts_glue）。
    // CMake 只编译我们自己的薄封装（单 C 文件，秒级）；官方
    // DTSPlaybackSDK.so 以预编译形式放 jniLibs（arm64-v8a / armeabi-v7a，
    // MD5 与官方 so_info.json 锚定）。不设 abiFilters——x86 上 dts_glue
    // 照常编译，运行时探测不到官方库则自动走音质降级。
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

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

        // #78 签名校验：把实际签名证书的 SHA-256 锚进原生代码。
        // 为空（keystore 不可读）时运行时跳过校验而不是误杀。
        buildConfigField("String", "SIGN_CERT_SHA256", "\"${signingCertSha256()}\"")
    }

    buildFeatures {
        // AGP 9 默认关闭 BuildConfig 生成，签名指纹锚定需要它
        buildConfig = true
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
