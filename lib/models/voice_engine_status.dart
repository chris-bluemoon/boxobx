/// Lifecycle state of the voice pipeline (Section 4), surfaced to the UI
/// so the driver can see whether Gunther is idle, listening, thinking,
/// or actively transmitting.
enum VoiceEngineStatus {
  idle,
  listening,
  transcribing,
  responding,
  error,
}

extension VoiceEngineStatusLabel on VoiceEngineStatus {
  String get label {
    switch (this) {
      case VoiceEngineStatus.idle:
        return 'READY';
      case VoiceEngineStatus.listening:
        return 'LISTENING';
      case VoiceEngineStatus.transcribing:
        return 'PROCESSING';
      case VoiceEngineStatus.responding:
        return 'GUNTHER TALKING';
      case VoiceEngineStatus.error:
        return 'VOICE ERROR';
    }
  }
}
