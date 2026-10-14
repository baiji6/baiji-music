package com.baiji.baiji_music

import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.MessageDigest

/**
 * 完整性校验入口（#78 签名校验）。
 *
 * 原理：构建期 [build.gradle.kts] 把**实际使用**的签名证书 SHA-256
 * 锚进 BuildConfig.SIGN_CERT_SHA256（随 R8 编进 dex，Dart 侧拿不到原文）；
 * 运行时在这里读当前 APK 的签名证书算指纹比对——重打包 / 换签的包
 * 指纹必然对不上。比对在原生层完成，Dart 只拿到结论，绕过 Dart 层
 * 的 hook 不影响判定。
 *
 * 指纹为空（本地 keystore 不可读的异常构建）时返回 ok=true 但 enforced=false，
 * 由 Dart 侧决定放行并打日志。
 */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "baiji/integrity")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "verifySignature" -> result.success(verifySignature())
                    else -> result.notImplemented()
                }
            }
    }

    /** 当前 APK 签名证书 SHA-256（hex 小写）；读不到返回 null。 */
    private fun currentCertSha256(): String? {
        return try {
            val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                val info = packageManager.getPackageInfo(
                    packageName, PackageManager.GET_SIGNING_CERTIFICATES)
                info.signingInfo?.apkContentsSigners
            } else {
                @Suppress("DEPRECATION")
                val info = packageManager.getPackageInfo(
                    packageName, PackageManager.GET_SIGNATURES)
                info.signatures
            }
            val first = signatures?.firstOrNull() ?: return null
            MessageDigest.getInstance("SHA-256")
                .digest(first.toByteArray())
                .joinToString("") { "%02x".format(it) }
        } catch (e: Exception) {
            null
        }
    }

    /**
     * 比对结果。
     * - ok：指纹一致（或因 expected 为空跳过——此时 enforced=false）
     * - enforced：构建期是否锚定了指纹（决定 Dart 侧是否拦截）
     */
    private fun verifySignature(): Map<String, Any> {
        val expected = try {
            BuildConfig.SIGN_CERT_SHA256 ?: ""
        } catch (e: Exception) {
            ""
        }
        val current = currentCertSha256()
        val enforced = expected.isNotEmpty()
        val ok = if (!enforced) true else (current != null && current == expected)
        return mapOf(
            "ok" to ok,
            "enforced" to enforced,
            "expected" to expected,
            "current" to (current ?: ""),
        )
    }
}
