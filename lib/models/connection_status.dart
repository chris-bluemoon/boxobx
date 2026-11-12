/// Shared connection lifecycle used by every ingestion/voice component so
/// the dashboard can render a consistent "is this component actually
/// talking to something right now" indicator.
enum ConnectionStatus {
  /// Socket/service not started yet, or explicitly stopped by the user.
  disconnected,

  /// Socket bound / handshake sent, but no data has been received yet.
  connecting,

  /// Data has been received within the freshness window — fully live.
  live,

  /// Was live previously, but no new data has arrived within the
  /// freshness window (e.g. console turned off, Wi-Fi hiccup, laptop OCR
  /// relay stopped).
  stale,
}

extension ConnectionStatusLabel on ConnectionStatus {
  String get label {
    switch (this) {
      case ConnectionStatus.disconnected:
        return 'OFFLINE';
      case ConnectionStatus.connecting:
        return 'CONNECTING…';
      case ConnectionStatus.live:
        return 'LIVE';
      case ConnectionStatus.stale:
        return 'STALE';
    }
  }
}
