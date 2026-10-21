import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // 设备唯一 ID（v2.4.0）：identifierForVendor 是 Apple 官方提供的
    // 厂商内稳定标识，不涉及隐私字段；用于生成用户 GUID。
    let channel = FlutterMethodChannel(
      name: "baiji/device",
      binaryMessenger: engineBridge.applicationRegistrar.messenger())
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "deviceId":
        result(UIDevice.current.identifierForVendor?.uuidString ?? "")
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
