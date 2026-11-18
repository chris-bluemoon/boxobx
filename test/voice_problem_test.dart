// Boxington says why he can't speak (a blocked network, a bad key...)
// instead of failing silently -- checked at start-up.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:boxbox/services/groq_service.dart';
import 'package:boxbox/services/voice_engine.dart';

/// What the dashboard banner would say after a start-up check.
Future<String?> _check(http.Client client) async {
  try {
    await GroqService('key', client: client).checkAccess();
    return null;
  } catch (error) {
    return VoiceEngine.describeProblem(error);
  }
}

void main() {
  test('Groq refusing the network (e.g. a VPN) is named as that', () async {
    final denied = MockClient(
      (_) async => http.Response('{"error":{"message":"Access denied. Please check your network settings."}}', 403),
    );
    final problem = await _check(denied);
    expect(problem, contains('access denied'));
    expect(problem, contains('VPN'));
  });

  test('a bad key is named; a working check has no problem', () async {
    expect(await _check(MockClient((_) async => http.Response('{"error":"Invalid API Key"}', 401))), 'Groq API key rejected');
    expect(await _check(MockClient((_) async => http.Response('{"data":[]}', 200))), isNull);
  });

  test('no internet is said plainly', () {
    expect(VoiceEngine.describeProblem(const SocketException('Failed host lookup')), 'No internet connection');
  });

  test('the voice service not connecting is named', () {
    expect(
      VoiceEngine.describeProblem(Exception('TTS (elevenlabs) connection failed: WebSocketException: not upgraded')),
      startsWith('Voice service (ElevenLabs) not connecting'),
    );
  });
}
