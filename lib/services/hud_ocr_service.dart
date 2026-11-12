import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/hud_overlay_data.dart';
import '../models/connection_status.dart';

/// Component B: HUD Screen Parser network ingestion.
///
/// OCR does not run on-device (a mobile/tablet CPU decoding 1080p video
/// while running Vision-framework OCR concurrently risks thermal
/// throttling and dropped frames over a long session). Instead, a laptop
/// captures the HDMI feed via the USB capture card, crops the ROI,
/// performs OCR locally at ~5Hz, and streams parsed leaderboard JSON to
/// this device (iPhone or iPad — same app, same UDP listener) over Wi-Fi.
/// This service just binds a UDP listener socket and decodes those JSON
/// datagrams.
class HudOcrService {
  static const int listenPort = 33746;

  /// OCR relay samples at ~5Hz (every 200ms); allow a couple of missed
  /// samples before flagging the laptop relay as stale.
  static const Duration freshnessWindow = Duration(seconds: 2);

  RawDatagramSocket? _socket;
  Timer? _watchdog;
  final _controller = StreamController<HudOverlayData>.broadcast();
  final _statusController = StreamController<ConnectionStatus>.broadcast();
  ConnectionStatus _status = ConnectionStatus.disconnected;

  Stream<HudOverlayData> get stream => _controller.stream;
  Stream<ConnectionStatus> get statusStream => _statusController.stream;
  ConnectionStatus get status => _status;

  void _setStatus(ConnectionStatus status) {
    if (_status == status) return;
    _status = status;
    _statusController.add(status);
  }

  Future<void> start() async {
    if (_socket != null) return;
    _setStatus(ConnectionStatus.connecting);

    _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, listenPort);
    _socket!.listen((RawSocketEvent event) {
      if (event != RawSocketEvent.read) return;
      final datagram = _socket!.receive();
      if (datagram == null) return;

      try {
        final json = jsonDecode(utf8.decode(datagram.data)) as Map<String, dynamic>;
        _controller.add(HudOverlayData.fromMap(json));
        _setStatus(ConnectionStatus.live);
        _resetWatchdog();
      } on FormatException {
        // Ignore malformed/partial packets.
      }
    });

    _watchdog = Timer(freshnessWindow, () => _setStatus(ConnectionStatus.stale));
  }

  void _resetWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer(freshnessWindow, () => _setStatus(ConnectionStatus.stale));
  }

  Future<void> stop() async {
    _socket?.close();
    _socket = null;
    _watchdog?.cancel();
    _watchdog = null;
    _setStatus(ConnectionStatus.disconnected);
  }

  void dispose() {
    stop();
    _controller.close();
    _statusController.close();
  }
}
