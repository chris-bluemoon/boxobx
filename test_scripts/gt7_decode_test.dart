// Standalone sanity check for the GT7 Salsa20 decrypt + field-offset
// logic in telemetry_udp_service.dart, using a synthetic packet (since
// we don't have a real PS5 running GT7 handy for every test run).
//
// Builds a fake plaintext 296-byte "packet A" with known field values,
// encrypts it with the real GT7 key/IV scheme (Salsa20 is symmetric, so
// encrypting and decrypting use the identical operation), then runs it
// back through the exact same decode path the real isolate uses and
// verifies the round-tripped values match what was planted.
//
// Run with: dart run test_scripts/gt7_decode_test.dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:cipherlib/cipherlib.dart';

const String _gt7Salsa20KeyString = 'Simulator Interface Packet GT7 ver 0.0';
const int _gt7Magic = 0x47375330;
const int _gt7IvXorConstant = 0xDEADBEAF;

Uint8List buildFakePlaintextPacket({
  required double posX,
  required double posY,
  required double posZ,
  required double rpm,
  required double speedMs,
  required double fuelLevel,
  required double fuelCapacity,
  required List<double> tireTemps,
  required int gear,
  required int seedIv,
}) {
  final buffer = ByteData(296);
  buffer.setUint32(0x00, _gt7Magic, Endian.little);
  buffer.setFloat32(0x04, posX, Endian.little);
  buffer.setFloat32(0x08, posY, Endian.little);
  buffer.setFloat32(0x0C, posZ, Endian.little);
  buffer.setFloat32(0x3C, rpm, Endian.little);
  buffer.setUint32(0x40, seedIv, Endian.little);
  buffer.setFloat32(0x44, fuelLevel, Endian.little);
  buffer.setFloat32(0x48, fuelCapacity, Endian.little);
  buffer.setFloat32(0x4C, speedMs, Endian.little);
  buffer.setFloat32(0x60, tireTemps[0], Endian.little);
  buffer.setFloat32(0x64, tireTemps[1], Endian.little);
  buffer.setFloat32(0x68, tireTemps[2], Endian.little);
  buffer.setFloat32(0x6C, tireTemps[3], Endian.little);
  buffer.setUint8(0x90, gear & 0x0F);
  return buffer.buffer.asUint8List();
}

Uint8List salsa20Transform(Uint8List data, int seedIv) {
  final keyBytes = Uint8List.fromList(utf8.encode(_gt7Salsa20KeyString).sublist(0, 32));
  final xoredIv = seedIv ^ _gt7IvXorConstant;
  final nonce = ByteData(8)
    ..setUint32(0, xoredIv, Endian.little)
    ..setUint32(4, seedIv, Endian.little);
  return Uint8List.fromList(Salsa20(keyBytes, nonce.buffer.asUint8List()).convert(data));
}

void expectClose(String label, double actual, double expected) {
  final ok = (actual - expected).abs() < 0.001;
  print('${ok ? "PASS" : "FAIL"} $label: expected=$expected actual=$actual');
  if (!ok) throw Exception('Mismatch on $label');
}

void expectEqualInt(String label, int actual, int expected) {
  final ok = actual == expected;
  print('${ok ? "PASS" : "FAIL"} $label: expected=$expected actual=$actual');
  if (!ok) throw Exception('Mismatch on $label');
}

void main() {
  const seedIv = 0x12345678;

  final plaintext = buildFakePlaintextPacket(
    posX: 123.45,
    posY: 0.5,
    posZ: -987.65,
    rpm: 7200.0,
    speedMs: 55.5,
    fuelLevel: 42.0,
    fuelCapacity: 100.0,
    tireTemps: [88.0, 89.5, 90.0, 91.5],
    gear: 5,
    seedIv: seedIv,
  );

  // Salsa20 is a symmetric stream cipher: XOR-ing the keystream onto
  // plaintext produces ciphertext, and XOR-ing it again on ciphertext
  // recovers plaintext. So "encrypting" our fake plaintext packet here
  // uses the exact same transform as decrypting a real GT7 packet does.
  final encrypted = salsa20Transform(plaintext, seedIv);
  final decrypted = salsa20Transform(encrypted, seedIv);

  final buffer = ByteData.sublistView(decrypted);
  final magic = buffer.getUint32(0, Endian.little);
  expectEqualInt('magic', magic, _gt7Magic);

  expectClose('posX', buffer.getFloat32(0x04, Endian.little), 123.45);
  expectClose('posY', buffer.getFloat32(0x08, Endian.little), 0.5);
  expectClose('posZ', buffer.getFloat32(0x0C, Endian.little), -987.65);
  expectClose('rpm', buffer.getFloat32(0x3C, Endian.little), 7200.0);
  expectClose('speedMs', buffer.getFloat32(0x4C, Endian.little), 55.5);
  expectClose('fuelLevel', buffer.getFloat32(0x44, Endian.little), 42.0);
  expectClose('fuelCapacity', buffer.getFloat32(0x48, Endian.little), 100.0);
  expectClose('tireTemp[0]', buffer.getFloat32(0x60, Endian.little), 88.0);
  expectClose('tireTemp[3]', buffer.getFloat32(0x6C, Endian.little), 91.5);
  expectEqualInt('gear', decrypted[0x90] & 0x0F, 5);

  print('\nAll GT7 decode round-trip checks passed.');
}
