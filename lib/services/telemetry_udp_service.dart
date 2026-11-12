import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:cipherlib/cipherlib.dart';

import '../models/telemetry_frame.dart';
import '../models/connection_status.dart';

/// Component A: Telemetry Network Worker.
///
/// Spawns a background isolate that binds a raw UDP socket on GT7's real
/// telemetry receive port (33740), sends the real single-byte heartbeat
/// ('A' = base packet format), and decrypts + parses incoming Salsa20
/// encrypted binary telemetry frames at up to 60Hz, forwarding decoded
/// [TelemetryFrame] maps back to the main isolate via a
/// [ReceivePort]/[SendPort] bridge.
///
/// Protocol reverse-engineered by the GT7/GTPlanet community (PDTools,
/// gt7dashboard, and related open-source projects). GT7 only starts
/// streaming telemetry to a given IP after it receives a heartbeat on
/// port 33739, and expects a fresh heartbeat roughly every 100 packets
/// (~1.6s at 60Hz) or the stream will stop.
class TelemetryUdpService {
  /// GT7 sends the live 60Hz telemetry stream to whatever IP most
  /// recently sent it a heartbeat, on this fixed receive port.
  static const int listenPort = 33740;

  /// GT7 listens for heartbeats on this port (note: different from
  /// [listenPort] — send and receive are NOT symmetric).
  static const int heartbeatPort = 33739;

  /// Single-byte heartbeat selecting packet format "A" (the original/base
  /// 296-byte telemetry packet). Other known values are 'B' and '~' for
  /// newer packet variants, not used by this app.
  static final Uint8List handshake = Uint8List.fromList(utf8.encode('A'));

  /// If no frame arrives within this window after going live, the
  /// connection is considered stale (console off / Wi-Fi dropped).
  static const Duration freshnessWindow = Duration(seconds: 2);

  Isolate? _isolate;
  ReceivePort? _receivePort;
  Timer? _watchdog;
  final _controller = StreamController<TelemetryFrame>.broadcast();
  final _statusController = StreamController<ConnectionStatus>.broadcast();
  ConnectionStatus _status = ConnectionStatus.disconnected;

  Stream<TelemetryFrame> get stream => _controller.stream;
  Stream<ConnectionStatus> get statusStream => _statusController.stream;
  ConnectionStatus get status => _status;

  void _setStatus(ConnectionStatus status) {
    if (_status == status) return;
    _status = status;
    _statusController.add(status);
  }

  Future<void> start(String consoleIp) async {
    if (_isolate != null) return;
    _receivePort = ReceivePort();
    _setStatus(ConnectionStatus.connecting);

    _isolate = await Isolate.spawn(
      _telemetryIsolateEntry,
      _TelemetryIsolateArgs(_receivePort!.sendPort, consoleIp),
    );

    _receivePort!.listen((message) {
      if (message is Map<String, dynamic>) {
        _controller.add(TelemetryFrame.fromMap(message));
        _setStatus(ConnectionStatus.live);
        _resetWatchdog();
      }
    });

    _watchdog = Timer(freshnessWindow, () => _setStatus(ConnectionStatus.stale));
  }

  void _resetWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer(freshnessWindow, () => _setStatus(ConnectionStatus.stale));
  }

  Future<void> stop() async {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _receivePort?.close();
    _receivePort = null;
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

class _TelemetryIsolateArgs {
  final SendPort sendPort;
  final String consoleIp;
  _TelemetryIsolateArgs(this.sendPort, this.consoleIp);
}

/// GT7's fixed Salsa20 key, discovered by the GT7/GTPlanet reverse
/// engineering community (PDTools, gt7dashboard, and related projects).
/// Only the first 32 bytes of this ASCII string are used as the key.
const String _gt7Salsa20KeyString = 'Simulator Interface Packet GT7 ver 0.0';

/// Expected decrypted magic number at offset 0x00 ("G7S0" little-endian),
/// used to validate that decryption succeeded / the packet is intact.
const int _gt7Magic = 0x47375330;

/// XOR constant used to derive the second half of the Salsa20 nonce from
/// the packet's embedded 4-byte seed IV (not 0xDEADBEEF — the real magic
/// constant used by GT7 is 0xDEADBEAF).
const int _gt7IvXorConstant = 0xDEADBEAF;

/// Runs entirely on the background isolate — never touches the UI thread.
Future<void> _telemetryIsolateEntry(_TelemetryIsolateArgs args) async {
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, TelemetryUdpService.listenPort);
  final consoleAddress = InternetAddress(args.consoleIp);

  void sendHeartbeat() {
    socket.send(TelemetryUdpService.handshake, consoleAddress, TelemetryUdpService.heartbeatPort);
  }

  sendHeartbeat();

  // GT7 stops streaming if it doesn't receive a fresh heartbeat roughly
  // every ~1.6s (100 packets at 60Hz); resending on a timer is simpler
  // and more robust than counting packets.
  final heartbeatTimer = Timer.periodic(const Duration(seconds: 1), (_) => sendHeartbeat());

  socket.listen((RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final datagram = socket.receive();
    if (datagram == null) return;

    final frame = _decodeFrame(datagram.data);
    if (frame != null) {
      args.sendPort.send(frame.toMap());
    }
  }, onDone: () => heartbeatTimer.cancel());
}

/// Decrypts (Salsa20) and decodes a raw GT7 "packet A" (296 bytes) into a
/// [TelemetryFrame]. Byte offsets and the decryption scheme are sourced
/// from community reverse-engineering of GT7's Simulator Interface
/// protocol (see PDTools / gt7dashboard / raw-sim-telemetry projects).
///
/// NOTE: GT7's packet does not include total track length or cumulative
/// lap distance directly, so [TelemetryFrame.trackLength] and
/// [TelemetryFrame.lapDistance] are left at 0 here. This means the
/// bounding-box [SectorCalculator]'s track-database matching and
/// equal-thirds fallback (both of which require a nonzero track length)
/// will not trigger from GT7 telemetry alone — sector splitting would
/// need to be re-derived purely from the live X/Z position stream
/// instead, which is a follow-up task.
TelemetryFrame? _decodeFrame(Uint8List data) {
  const expectedPacketSize = 0x128; // 296 bytes, GT7 "packet A"
  if (data.lengthInBytes < expectedPacketSize) return null;

  final decrypted = _decryptGt7Packet(data);
  if (decrypted == null) return null;

  final buffer = ByteData.sublistView(decrypted);

  double f32(int offset) => buffer.getFloat32(offset, Endian.little);

  final posX = f32(0x04);
  final posY = f32(0x08);
  final posZ = f32(0x0C);
  final rpm = f32(0x3C);
  final speedMs = f32(0x4C);
  final fuelLevel = f32(0x44); // liters remaining
  final fuelCapacity = f32(0x48); // max capacity for current car (liters)
  final tireTemps = [f32(0x60), f32(0x64), f32(0x68), f32(0x6C)];
  // Gear byte: low nibble = current gear (0 = neutral, 15 = reverse in
  // GT7's encoding quirk handled below), high nibble = suggested gear.
  final gearByte = decrypted[0x90];
  final currentGear = gearByte & 0x0F;

  // fuelCapacity is 0 for electric cars (no meaningful "percent remaining").
  final fuelPercent = fuelCapacity > 0 ? (fuelLevel / fuelCapacity) * 100 : 0.0;

  // Lap counter: two consecutive int16 (little-endian) values at 0x74 --
  // current lap, then total laps for the session. GT7 reports -1 for
  // totalLaps in sessions with no fixed lap count (e.g. some Time
  // Trial/practice sessions).
  final currentLap = buffer.getInt16(0x74, Endian.little);
  final totalLaps = buffer.getInt16(0x76, Endian.little);

  // Best/last lap time, in milliseconds (int32 little-endian) -- GT7
  // reports -1 (0xFFFFFFFF) for either field until a lap has actually
  // been completed this session.
  final bestLapTimeMs = buffer.getInt32(0x78, Endian.little);
  final lastLapTimeMs = buffer.getInt32(0x7C, Endian.little);

  return TelemetryFrame(
    rpm: rpm,
    speedKmh: speedMs * 3.6, // convert meters/second to km/h
    gear: currentGear,
    posX: posX,
    posY: posY,
    posZ: posZ,
    // Not available in GT7's packet — see doc comment above.
    lapDistance: 0,
    trackLength: 0,
    fuelPercent: fuelPercent,
    tireTemps: tireTemps,
    currentLap: currentLap,
    totalLaps: totalLaps,
    lastLapTimeMs: lastLapTimeMs,
    bestLapTimeMs: bestLapTimeMs,
  );
}

/// Decrypts a raw GT7 UDP packet with Salsa20 and validates the magic
/// number. Returns null if decryption fails or the magic doesn't match
/// (corrupt/truncated packet, or not actually a GT7 packet).
Uint8List? _decryptGt7Packet(Uint8List data) {
  final keyBytes = Uint8List.fromList(utf8.encode(_gt7Salsa20KeyString).sublist(0, 32));

  // The packet embeds a 4-byte "seed" IV at offset 0x40. The full 8-byte
  // Salsa20 nonce is built from that seed IV and (seed IV XOR a fixed
  // magic constant), each as 4 little-endian bytes.
  final seedIv = ByteData.sublistView(data, 0x40, 0x44).getUint32(0, Endian.little);
  final xoredIv = seedIv ^ _gt7IvXorConstant;

  final nonce = ByteData(8)
    ..setUint32(0, xoredIv, Endian.little)
    ..setUint32(4, seedIv, Endian.little);

  final decrypted = Uint8List.fromList(
    Salsa20(keyBytes, nonce.buffer.asUint8List()).convert(data),
  );

  final magic = ByteData.sublistView(decrypted, 0, 4).getUint32(0, Endian.little);
  if (magic != _gt7Magic) return null;

  return decrypted;
}
