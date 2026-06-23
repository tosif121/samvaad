import Flutter
import UIKit
import PushKit
import flutter_callkit_incoming

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, PKPushRegistryDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let pushRegistry = PKPushRegistry(queue: .main)
    pushRegistry.delegate = self
    pushRegistry.desiredPushTypes = [.voIP]
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
    print("[PushKit] Did update push credentials")
  }

  func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
    print("[PushKit] Did invalidate push token")
  }

  func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
    print("[PushKit] Did receive incoming push")
    let dict = payload.dictionaryPayload
    let number = dict["number"] as? String ?? "Unknown"
    let data = flutter_callkit_incoming.Data()
    data.id = UUID().uuidString
    data.nameCaller = number
    data.handle = number
    data.type = 0
    data.appName = "Samvaad"
    data.extra = ["number": number]
    data.ios = flutter_callkit_incoming.IOSData()
    data.ios!.handleType = "number"
    data.ios!.supportsVideo = false
    data.ios!.includesCallsInRecents = false
    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.showCallkitIncoming(data, fromPushKit: true)
    completion()
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
