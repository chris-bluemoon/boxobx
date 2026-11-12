import Flutter
import AVFoundation

/// Section 5: iOS System Hardware Overrides.
///
/// Boxbox intentionally does NOT route Gunther's voice through any
/// external DAC/amp (e.g. a Fosi K7) — that chain is reserved exclusively
/// for pristine PS5 game audio to the driver's headphones. Gunther's
/// voice plays independently out of the iPad's own built-in speaker (or
/// a paired Bluetooth speaker/earbud, if the built-in speaker proves too
/// quiet over engine noise), with zero physical cable between the iPad
/// and the K7.
///
/// Configures AVAudioSession to:
///  - .voiceChat mode: optimizes mic gain/clarity for PTT recording.
///  - .defaultToSpeaker: explicitly forces playback to the iPad's
///    built-in speaker rather than any other implicit output route.
///  - .mixWithOthers: keeps background media apps (Spotify, etc.) alive.
///  - .duckOthers: automatically lowers other *iPad-internal* audio ~50%
///    while Gunther talks. NOTE: this has no effect on PS5 game audio,
///    since that never passes through the iPad's audio session at all —
///    it goes straight from the PS5 to the K7 to the headphones.
///  - .allowBluetooth / .allowBluetoothA2DP: lets output be redirected to
///    a paired Bluetooth speaker/earbud instead of the speaker, if chosen
///    in iOS's audio route picker.
final class AudioSessionChannel: NSObject {
  static let channelName = "boxbox/audio_session"

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    let instance = AudioSessionChannel()
    channel.setMethodCallHandler(instance.handle)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "configureVoiceChatSession":
      configureVoiceChatSession(result: result)
    case "setDucking":
      let args = call.arguments as? [String: Any]
      let active = args?["active"] as? Bool ?? false
      setDucking(active: active, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func configureVoiceChatSession(result: @escaping FlutterResult) {
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(
        .playAndRecord,
        mode: .voiceChat,
        options: [.mixWithOthers, .duckOthers, .defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
      )
      try session.setActive(true)
      result(nil)
    } catch {
      result(FlutterError(code: "AUDIO_SESSION_ERROR", message: error.localizedDescription, details: nil))
    }
  }

  /// Ducking is already declared via .duckOthers at the category level; iOS
  /// engages it automatically whenever this app's session is active and
  /// producing audio. This hook exists so the Dart layer can explicitly
  /// signal start/stop of Gunther's speech for any additional local mixing
  /// logic (e.g. fading in/out a sidetone) without re-configuring the
  /// category each time.
  private func setDucking(active: Bool, result: @escaping FlutterResult) {
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setActive(active, options: active ? [] : [.notifyOthersOnDeactivation])
      result(nil)
    } catch {
      result(FlutterError(code: "AUDIO_DUCK_ERROR", message: error.localizedDescription, details: nil))
    }
  }
}
