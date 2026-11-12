// Standalone validation for ShiftCoachAdvisor and ProactiveCoachTrigger:
// the "should Gunther proactively speak up about shift habits" logic
// (3-of-last-5 bad-pattern trigger, with a per-pattern cooldown).
//
// Run with: dart run test_scripts/shift_coach_advisor_test.dart
import 'package:boxbox/models/shift_event.dart';
import 'package:boxbox/services/shift_coach_advisor.dart';
import 'package:boxbox/services/proactive_coach_trigger.dart';

void check(String label, bool condition) {
  print('${condition ? "PASS" : "FAIL"} $label');
  if (!condition) throw Exception('Failed: $label');
}

ShiftEvent shift(ShiftTiming timing) => ShiftEvent(rpmAtShift: 6000, timing: timing);

void main() {
  // --- ShiftCoachAdvisor.detectBadPattern ---
  check(
    'fewer than 3 shifts never triggers, even if all bad',
    ShiftCoachAdvisor.detectBadPattern([shift(ShiftTiming.late), shift(ShiftTiming.late)]) == null,
  );

  check(
    '3 of 5 "early" triggers early pattern',
    ShiftCoachAdvisor.detectBadPattern([
          shift(ShiftTiming.early),
          shift(ShiftTiming.good),
          shift(ShiftTiming.early),
          shift(ShiftTiming.good),
          shift(ShiftTiming.early),
        ]) ==
        ShiftTiming.early,
  );

  check(
    '3 of 5 "late" triggers late pattern',
    ShiftCoachAdvisor.detectBadPattern([
          shift(ShiftTiming.late),
          shift(ShiftTiming.late),
          shift(ShiftTiming.good),
          shift(ShiftTiming.late),
          shift(ShiftTiming.good),
        ]) ==
        ShiftTiming.late,
  );

  check(
    'mostly "good" shifts (no clear bad pattern) does not trigger',
    ShiftCoachAdvisor.detectBadPattern([
          shift(ShiftTiming.good),
          shift(ShiftTiming.good),
          shift(ShiftTiming.good),
          shift(ShiftTiming.early),
          shift(ShiftTiming.late),
        ]) ==
        null,
  );

  check(
    '2 early + 2 late (no single pattern reaching 3) does not trigger',
    ShiftCoachAdvisor.detectBadPattern([
          shift(ShiftTiming.early),
          shift(ShiftTiming.early),
          shift(ShiftTiming.late),
          shift(ShiftTiming.late),
          shift(ShiftTiming.good),
        ]) ==
        null,
  );

  // --- ProactiveCoachTrigger cooldown behaviour ---
  var fakeNow = DateTime(2026, 1, 1, 12, 0, 0);
  final trigger = ProactiveCoachTrigger(
    cooldown: const Duration(seconds: 60),
    now: () => fakeNow,
  );

  final earlyPattern = [
    shift(ShiftTiming.early),
    shift(ShiftTiming.early),
    shift(ShiftTiming.early),
    shift(ShiftTiming.good),
    shift(ShiftTiming.good),
  ];

  check('first detection of a bad pattern fires immediately', trigger.check(earlyPattern) == ShiftTiming.early);
  check(
    'same pattern checked again immediately is suppressed by cooldown',
    trigger.check(earlyPattern) == null,
  );

  fakeNow = fakeNow.add(const Duration(seconds: 30));
  check(
    'still within cooldown window (30s < 60s) stays suppressed',
    trigger.check(earlyPattern) == null,
  );

  fakeNow = fakeNow.add(const Duration(seconds: 31)); // total 61s elapsed
  check(
    'fires again once the cooldown window has elapsed',
    trigger.check(earlyPattern) == ShiftTiming.early,
  );

  // --- A different pattern is not blocked by the other pattern's cooldown ---
  final latePattern = [
    shift(ShiftTiming.late),
    shift(ShiftTiming.late),
    shift(ShiftTiming.late),
    shift(ShiftTiming.good),
    shift(ShiftTiming.good),
  ];
  check(
    'switching to a different bad pattern fires immediately, ignoring the other pattern\'s cooldown',
    trigger.check(latePattern) == ShiftTiming.late,
  );

  // --- reset() clears cooldown state ---
  trigger.reset();
  check('reset allows the same pattern to fire again immediately', trigger.check(latePattern) == ShiftTiming.late);

  print('\nAll ShiftCoachAdvisor/ProactiveCoachTrigger checks passed.');
}
