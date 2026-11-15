// Round-trips a synthetic, encrypted GT7 "packet A" through the REAL
// decoder (decodeGt7Packet). Salsa20 is symmetric, so encrypting the
// planted plaintext with the same key/nonce scheme produces exactly
// what the console would send.
import 'dart:convert';
import 'dart:typed_data';

import 'package:cipherlib/cipherlib.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:boxbox/models/telemetry_frame.dart';
import 'package:boxbox/services/telemetry_udp_service.dart';

Uint8List _encryptedPacket(void Function(ByteData plain) plant, {int seedIv = 0x12345678}) {
  final plain = ByteData(0x128);
  plain.setUint32(0x00, 0x47375330, Endian.little); // "G7S0" magic
  plant(plain);
  plain.setUint32(0x40, seedIv, Endian.little);

  final key = Uint8List.fromList(utf8.encode('Simulator Interface Packet GT7 ver 0.0').sublist(0, 32));
  final nonce = ByteData(8)
    ..setUint32(0, seedIv ^ 0xDEADBEAF, Endian.little)
    ..setUint32(4, seedIv, Endian.little);
  final cipher = Uint8List.fromList(Salsa20(key, nonce.buffer.asUint8List()).convert(plain.buffer.asUint8List()));
  // GT7 leaves the seed IV readable in the clear at 0x40.
  cipher.buffer.asByteData().setUint32(0x40, seedIv, Endian.little);
  return cipher;
}

void main() {
  test('decodes flags, pedals, car code and rev-alert range', () {
    final packet = _encryptedPacket((p) {
      p.setFloat32(0x3C, 6400, Endian.little); // rpm
      p.setFloat32(0x44, 50, Endian.little); // fuel litres
      p.setFloat32(0x48, 100, Endian.little); // capacity
      p.setInt16(0x74, 3, Endian.little); // current lap
      p.setInt16(0x88, 5900, Endian.little);
      p.setInt16(0x8A, 7100, Endian.little);
      p.setUint16(0x8E, TelemetryFlags.carOnTrack | TelemetryFlags.inGear, Endian.little);
      p.setUint8(0x90, 0x54); // suggested 5, current 4
      p.setUint8(0x91, 255);
      p.setUint8(0x92, 51);
      p.setInt32(0x124, 3218, Endian.little);
    });

    final frame = decodeGt7Packet(packet)!;
    expect(frame.rpm, 6400);
    expect(frame.fuelPercent, 50);
    expect(frame.currentLap, 3);
    expect(frame.gear, 4);
    expect(frame.minAlertRpm, 5900);
    expect(frame.maxAlertRpm, 7100);
    expect(frame.isCarOnTrack, isTrue);
    expect(frame.isPaused, isFalse);
    expect(frame.isDriving, isTrue);
    expect(frame.throttlePercent, 100);
    expect(frame.brakePercent, closeTo(20, 0.01));
    expect(frame.carCode, 3218);
  });

  test('wheel road speeds come from rotation x tyre radius', () {
    final packet = _encryptedPacket((p) {
      for (var i = 0; i < 4; i++) {
        p.setFloat32(0xA4 + i * 4, i < 2 ? -100 : -110, Endian.little); // rad/s, negative forwards
        p.setFloat32(0xB4 + i * 4, 0.35, Endian.little); // m
      }
    });
    final frame = TelemetryFrame.fromMap(decodeGt7Packet(packet)!.toMap());
    expect(frame.wheelSpeedsKmh[0], closeTo(126, 0.01)); // 100 * 0.35 * 3.6
    expect(frame.wheelSpeedsKmh[3], closeTo(138.6, 0.01));
  });

  test('the packet counter survives the trip from the UDP isolate', () {
    final packet = _encryptedPacket((p) => p.setInt32(0x70, 4242, Endian.little));
    expect(TelemetryFrame.fromMap(decodeGt7Packet(packet)!.toMap()).packetId, 4242);
  });

  test('paused and loading frames are not "driving"', () {
    final paused = decodeGt7Packet(
      _encryptedPacket((p) {
        p.setUint16(0x8E, TelemetryFlags.carOnTrack | TelemetryFlags.paused, Endian.little);
      }),
    )!;
    expect(paused.isDriving, isFalse);

    final loading = decodeGt7Packet(
      _encryptedPacket((p) {
        p.setUint16(0x8E, TelemetryFlags.loadingOrProcessing, Endian.little);
      }),
    )!;
    expect(loading.isDriving, isFalse);
    expect(loading.isCarOnTrack, isFalse);
  });

  test('rejects a packet whose magic does not decrypt correctly', () {
    final packet = _encryptedPacket((_) {});
    packet[0] ^= 0xFF;
    expect(decodeGt7Packet(packet), isNull);
  });

  test('flags survive the isolate map round-trip, and old maps default to on-track', () {
    const frame = TelemetryFrame(
      rpm: 1,
      speedKmh: 1,
      gear: 1,
      posX: 0,
      posY: 0,
      posZ: 0,
      lapDistance: 0,
      trackLength: 0,
      fuelPercent: 1,
      tireTemps: [0, 0, 0, 0],
      flags: TelemetryFlags.paused,
      carCode: 42,
      throttlePercent: 30,
    );
    final restored = TelemetryFrame.fromMap(frame.toMap());
    expect(restored.flags, TelemetryFlags.paused);
    expect(restored.carCode, 42);
    expect(restored.throttlePercent, 30);

    final legacy = frame.toMap()..remove('flags');
    expect(TelemetryFrame.fromMap(legacy).isCarOnTrack, isTrue);
    expect(TelemetryFrame.empty().isDriving, isFalse);
  });
}
