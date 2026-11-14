import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:boxbox/services/groq_service.dart';

String _event(String token) =>
    'data: ${jsonEncode({
          'choices': [
            {
              'delta': {'content': token}
            }
          ]
        })}\n\n';

Stream<List<int>> _chunked(String body, List<int> splitAt) async* {
  final bytes = utf8.encode(body);
  var start = 0;
  for (final end in [...splitAt, bytes.length]) {
    yield bytes.sublist(start, end);
    start = end;
  }
}

void main() {
  test('yields every token when events arrive whole', () async {
    final body = '${_event('Box ')}${_event('this ')}${_event('lap')}data: [DONE]\n\n';
    final tokens = await GroqService.parseSseTokens(_chunked(body, [])).toList();
    expect(tokens.join(), 'Box this lap');
  });

  test('does not drop a token whose data line is split across network chunks', () async {
    final body = '${_event('Box ')}${_event('this ')}${_event('lap')}data: [DONE]\n\n';
    // Split in the middle of the second event's JSON payload.
    final splitPoint = _event('Box ').length + 20;
    final tokens = await GroqService.parseSseTokens(_chunked(body, [splitPoint])).toList();
    expect(tokens.join(), 'Box this lap');
  });

  test('does not corrupt a multi-byte character split across chunks', () async {
    final body = '${_event('Kovač')}data: [DONE]\n\n';
    final bytes = utf8.encode(body);
    // Split between the two bytes of "č".
    final splitPoint = bytes.indexOf(0xC4) + 1;
    final tokens = await GroqService.parseSseTokens(_chunked(body, [splitPoint])).toList();
    expect(tokens.join(), 'Kovač');
  });

  test('stops at [DONE]', () async {
    final body = '${_event('one')}data: [DONE]\n\n${_event('two')}';
    final tokens = await GroqService.parseSseTokens(_chunked(body, [])).toList();
    expect(tokens, ['one']);
  });
}
