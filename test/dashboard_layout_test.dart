// Every mode screen, with a round saved (track header showing) and
// time-trial laps recorded, must lay out without overflow on an iPad in
// both orientations.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:boxbox/models/race_briefing.dart';
import 'package:boxbox/models/time_trial_lap.dart';
import 'package:boxbox/screens/dashboard_screen.dart';
import 'package:boxbox/services/saved_briefing_store.dart';
import 'package:boxbox/services/time_trial_store.dart';

void main() {
  for (final (orientation, size) in [('portrait', const Size(1640, 2360)), ('landscape', const Size(2360, 1640))]) {
    for (final mode in ['RACE MODE', 'STINT TESTING', 'TIME TRIALING']) {
      testWidgets('$mode fits an iPad in $orientation', (tester) async {
        dotenv.testLoad(fileInput: '');
        final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        for (final c in ['boxbox/audio_session', 'com.ryanheise.just_audio.methods', 'com.llfbandit.record/messages']) {
          messenger.setMockMethodCallHandler(MethodChannel(c), (_) async => null);
        }
        SharedPreferences.setMockInitialValues({});
        await tester.runAsync(() async {
          await SavedBriefingStore.save(
            name: 'Round 4 - Alsace Village (Reverse)',
            briefing: RaceBriefing(
              trackName: 'Alsace - Village (Reverse)',
              totalLaps: 26,
              startingFuelPercent: 100,
              availableTireCompounds: const ['Racing Medium', 'Racing Soft'],
            ),
          );
          await TimeTrialStore.save([
            for (var i = 0; i < 8; i++)
              TimeTrialLap(
                lapTimeMs: 89950 + i * 137,
                tireCompound: 'Racing Soft',
                recordedAt: DateTime(2026, 1, 1, 10, i),
              ),
          ]);
        });
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 2.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(const MaterialApp(home: DashboardScreen(connectOnStart: false)));
        for (var i = 0; i < 5; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(tester.takeException(), isNull, reason: 'home page');
        await tester.tap(find.text(mode));
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull, reason: mode);
      });
    }
  }
}
