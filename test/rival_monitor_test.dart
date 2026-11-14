import 'package:flutter_test/flutter_test.dart';

import 'package:boxbox/services/rival_monitor.dart';

void main() {
  test('first-ever reading for a rival establishes a baseline without firing a callout', () {
    final monitor = RivalMonitor();
    expect(monitor.check({'Chuck_E82': 4}), isNull);
  });

  test('the SAME position read again does not fire a callout', () {
    final monitor = RivalMonitor();
    monitor.check({'Chuck_E82': 4});
    expect(monitor.check({'Chuck_E82': 4}), isNull);
  });

  test('a rival moving UP fires once the new position is confirmed, mentioning both positions', () {
    final monitor = RivalMonitor();
    monitor.check({'Chuck_E82': 4});
    expect(monitor.check({'Chuck_E82': 2}), isNull, reason: 'one reading is not yet confirmed');
    final prompt = monitor.check({'Chuck_E82': 2});

    expect(prompt, isNotNull);
    expect(prompt, contains('Chuck_E82'));
    expect(prompt, contains('moved up to P2'));
    expect(prompt, contains('was P4'));
  });

  test('a rival dropping back fires with different wording', () {
    final monitor = RivalMonitor();
    monitor.check({'Chuck_E82': 2});
    monitor.check({'Chuck_E82': 5});
    final prompt = monitor.check({'Chuck_E82': 5});

    expect(prompt, isNotNull);
    expect(prompt, contains('dropped back to P5'));
    expect(prompt, contains('was P2'));
  });

  test('a confirmed change fires only once, not on every later reading', () {
    final monitor = RivalMonitor();
    monitor.check({'Chuck_E82': 4});
    monitor.check({'Chuck_E82': 3});
    expect(monitor.check({'Chuck_E82': 3}), isNotNull);
    expect(monitor.check({'Chuck_E82': 3}), isNull);
  });

  test('a single OCR misread (P5 -> P8 -> P5) fires nothing', () {
    final monitor = RivalMonitor();
    monitor.check({'Chuck_E82': 5});
    expect(monitor.check({'Chuck_E82': 8}), isNull);
    expect(monitor.check({'Chuck_E82': 5}), isNull);
    expect(monitor.check({'Chuck_E82': 5}), isNull);
  });

  test('two different one-off misreads in a row do not combine into a confirmation', () {
    final monitor = RivalMonitor();
    monitor.check({'Chuck_E82': 5});
    expect(monitor.check({'Chuck_E82': 8}), isNull);
    expect(monitor.check({'Chuck_E82': 9}), isNull);
  });

  test('stabilityThreshold of 1 fires on the first differing reading', () {
    final monitor = RivalMonitor(stabilityThreshold: 1);
    monitor.check({'Chuck_E82': 4});
    expect(monitor.check({'Chuck_E82': 3}), contains('moved up to P3'));
  });

  test('tracks 2 rivals independently -- only the one that changed fires', () {
    final monitor = RivalMonitor();
    monitor.check({'Chuck_E82': 4, 'Willy-SwerveX': 7});

    monitor.check({'Chuck_E82': 4, 'Willy-SwerveX': 6});
    final prompt = monitor.check({'Chuck_E82': 4, 'Willy-SwerveX': 6});
    expect(prompt, isNotNull);
    expect(prompt, contains('Willy-SwerveX'));
    expect(prompt, isNot(contains('Chuck_E82')));
  });

  test('both rivals changing in the same reading are reported together, not just the first', () {
    final monitor = RivalMonitor();
    monitor.check({'Chuck_E82': 4, 'Willy-SwerveX': 5});
    monitor.check({'Chuck_E82': 5, 'Willy-SwerveX': 4});
    final prompt = monitor.check({'Chuck_E82': 5, 'Willy-SwerveX': 4});

    expect(prompt, contains('Chuck_E82 just dropped back to P5'));
    expect(prompt, contains('Willy-SwerveX just moved up to P4'));
  });

  test('a rival with no entry this frame (not on screen) is simply skipped, not treated as a change', () {
    final monitor = RivalMonitor();
    monitor.check({'Chuck_E82': 4, 'Willy-SwerveX': 7});

    expect(monitor.check({'Chuck_E82': 4}), isNull);
    expect(monitor.check({'Chuck_E82': 4}), isNull);
  });

  test('reset() clears tracked state so the next reading is treated as a fresh baseline', () {
    final monitor = RivalMonitor();
    monitor.check({'Chuck_E82': 4});
    monitor.reset();

    expect(monitor.check({'Chuck_E82': 2}), isNull);
    expect(monitor.check({'Chuck_E82': 2}), isNull);
  });

  test('an empty rivalPositions map (no rivals configured on the relay) never fires', () {
    final monitor = RivalMonitor();
    expect(monitor.check({}), isNull);
  });
}
