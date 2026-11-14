import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:boxbox/models/app_mode.dart';
import 'package:boxbox/models/fused_race_state.dart';
import 'package:boxbox/services/app_mode_store.dart';

void main() {
  test('practice mode makes no unprompted race calls and hides the traffic chip', () {
    const mode = AppMode.practice;
    expect([mode.pitCalls, mode.rivalCallouts, mode.opponentPitCallouts, mode.trafficChip], everyElement(isFalse));
  });

  test('race mode turns all race calls and the traffic chip on', () {
    const mode = AppMode.race;
    expect([mode.pitCalls, mode.rivalCallouts, mode.opponentPitCallouts, mode.trafficChip], everyElement(isTrue));
  });

  test('the mode is remembered between launches, defaulting to practice', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await AppModeStore.load(), AppMode.practice);
    await AppModeStore.save(AppMode.race);
    expect(await AppModeStore.load(), AppMode.race);
  });

  test('Gunther is told which mode he is in', () {
    expect(FusedRaceState.initial().toPromptContext()['mode'], 'practice');
    expect(FusedRaceState.initial().copyWith(mode: AppMode.race).toPromptContext()['mode'], 'race');
  });
}
