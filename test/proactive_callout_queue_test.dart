import 'package:flutter_test/flutter_test.dart';

import 'package:boxbox/services/proactive_callout_queue.dart';

void main() {
  late DateTime now;
  ProactiveCalloutQueue queue({int maxLength = 3}) => ProactiveCalloutQueue(
        maxAge: const Duration(seconds: 15),
        maxLength: maxLength,
        now: () => now,
      );

  setUp(() => now = DateTime(2026, 11, 14, 12));

  test('returns callouts oldest first', () {
    final q = queue()
      ..add('a')
      ..add('b');
    expect(q.takeNext(), 'a');
    expect(q.takeNext(), 'b');
    expect(q.takeNext(), isNull);
  });

  test('discards callouts older than maxAge instead of speaking them late', () {
    final q = queue()..add('stale');
    now = now.add(const Duration(seconds: 10));
    q.add('fresh');
    now = now.add(const Duration(seconds: 6)); // stale is now 16s old, fresh 6s
    expect(q.takeNext(), 'fresh');
    expect(q.length, 0);
  });

  test('drops the oldest once maxLength is exceeded', () {
    final q = queue(maxLength: 2)
      ..add('a')
      ..add('b')
      ..add('c');
    expect(q.takeNext(), 'b');
    expect(q.takeNext(), 'c');
  });

  test('clear() empties the queue', () {
    final q = queue()..add('a');
    q.clear();
    expect(q.takeNext(), isNull);
  });
}
