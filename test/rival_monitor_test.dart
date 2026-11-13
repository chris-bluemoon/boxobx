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

  test('a rival moving UP (lower position number) fires a callout mentioning both positions', () {
    final monitor = RivalMonitor();
    monitor.check({'Chuck_E82': 4});
    final prompt = monitor.check({'Chuck_E82': 2});

    expect(prompt, isNotNull);
    expect(prompt, contains('Chuck_E82'));
    expect(prompt, contains('moved up to P2'));
    expect(prompt, contains('was P4'));
  });

  test('a rival dropping back (higher position number) fires a callout with different wording', () {
    final monitor = RivalMonitor();
    monitor.check({'Chuck_E82': 2});
    final prompt = monitor.check({'Chuck_E82': 5});

    expect(prompt, isNotNull);
    expect(prompt, contains('dropped back to P5'));
    expect(prompt, contains('was P2'));
  });

  test('tracks 2 rivals independently -- only the one that changed fires', () {
    final monitor = RivalMonitor();
    monitor.check({'Chuck_E82': 4, 'Willy-SwerveX': 7});

    final prompt = monitor.check({'Chuck_E82': 4, 'Willy-SwerveX': 6});
    expect(prompt, isNotNull);
    expect(prompt, contains('Willy-SwerveX'));
    expect(prompt, isNot(contains('Chuck_E82')));
  });

  test('a rival with no entry this frame (not on screen) is simply skipped, not treated as a change', () {
    final monitor = RivalMonitor();
    monitor.check({'Chuck_E82': 4, 'Willy-SwerveX': 7});

    // Willy-SwerveX isn't visible this frame at all -- must not be
    // treated as a position change (e.g. to 0/null).
    expect(monitor.check({'Chuck_E82': 4}), isNull);
  });

  test('reset() clears tracked state so the next reading is treated as a fresh baseline', () {
    final monitor = RivalMonitor();
    monitor.check({'Chuck_E82': 4});
    monitor.reset();

    // Without reset(), this would fire a callout (4 -> 2); after
    // reset(), it's treated as a brand new baseline instead.
    expect(monitor.check({'Chuck_E82': 2}), isNull);
  });

  test('an empty rivalPositions map (no rivals configured on the relay) never fires', () {
    final monitor = RivalMonitor();
    expect(monitor.check({}), isNull);
  });
}
