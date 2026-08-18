import Flutter
import UIKit
import AudioToolbox
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var ringtoneTimer: Timer?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SamvaadRingtonePlugin") {
      let channel = FlutterMethodChannel(
        name: "com.example.samvaad/ringtone",
        binaryMessenger: registrar.messenger()
      )

      channel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
        guard let self = self else { return }
        switch call.method {
        case "playRingtone":
          self.startRinging()
          result(nil)
        case "stopRingtone":
          self.stopRinging()
          result(nil)
        case "clearNotification", "bringAppToForeground", "cleanupForeground", "createRingtoneChannel":
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }

  private func startRinging() {
    stopRinging()
    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.duckOthers])
    try? AVAudioSession.sharedInstance().setActive(true)

    // Play system incoming call ringtone (1005) & vibration
    AudioServicesPlayAlertSound(1005)
    AudioServicesPlayAlertSound(kSystemSoundID_Vibrate)

    ringtoneTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { _ in
      AudioServicesPlayAlertSound(1005)
      AudioServicesPlayAlertSound(kSystemSoundID_Vibrate)
    }
  }

  private func stopRinging() {
    ringtoneTimer?.invalidate()
    ringtoneTimer = nil
  }
}
