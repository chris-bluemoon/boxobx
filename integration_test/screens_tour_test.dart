// Screenshot tour of the stint and rival screens, with no console: an
// earlier stint is seeded into the real app database, and a new stint is
// driven through the dashboard by feeding telemetry frames into its
// state manager (laps with a spin and a tyre cliff).
//
// Run (simulator booted), screenshots land in build/screenshots/:
//   flutter drive --driver=test_driver/integration_test.dart \
//     --target=integration_test/screens_tour_test.dart -d <device-id>
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:boxbox/models/hud_overlay_data.dart';
import 'package:boxbox/models/championship_standing.dart';
import 'package:boxbox/models/practice_lap_record.dart';
import 'package:boxbox/models/race_strategy.dart';
import 'package:boxbox/models/race_briefing.dart';
import 'package:boxbox/models/telemetry_frame.dart';
import 'package:boxbox/screens/dashboard_screen.dart';
import 'package:boxbox/services/championship_standings_store.dart';
import 'package:boxbox/services/fuel_predictor.dart';
import 'package:boxbox/services/fused_race_state_manager.dart';
import 'package:boxbox/services/hud_ocr_service.dart';
import 'package:boxbox/services/practice_log_store.dart';
import 'package:boxbox/services/saved_briefing_store.dart';
import 'package:boxbox/services/sector_calculator.dart';
import 'package:boxbox/services/telemetry_udp_service.dart';

const _scatter = [0, 150, -120, 210, -80, 60, -190, 130, -40, 170, -150, 90, -60, 200, -110, 40];

/// Lap times: steady pace with scatter, a cliff from [cliffLap] (1-based),
/// a slow out-lap and a spin on [spinLap].
List<int> _stintTimes(int laps, {required int cliffLap, required int spinLap}) => [
  for (var i = 0; i < laps; i++)
    i == 0
        ? 93800
        : i + 1 == spinLap
        ? 97400
        : 90000 + _scatter[i % _scatter.length] + (i + 1 >= cliffLap ? 1100 + (i + 1 - cliffLap) * 250 : 0),
];

TelemetryFrame _frame(
  int lap,
  double fuel,
  int lastLapTimeMs, {
  double throttle = 0,
  double brake = 0,
  List<double> wheels = const [],
}) => TelemetryFrame(
  rpm: 6000,
  speedKmh: 180,
  gear: 4,
  posX: 0,
  posY: 0,
  posZ: 0,
  lapDistance: 0,
  trackLength: 0,
  fuelPercent: fuel,
  tireTemps: const [80, 80, 80, 80],
  currentLap: lap,
  lastLapTimeMs: lastLapTimeMs,
  throttlePercent: throttle,
  brakePercent: brake,
  wheelSpeedsKmh: wheels,
);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('screens tour', (tester) async {
    dotenv.testLoad(fileInput: ''); // no API keys: Boxington stays silent
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    await prefs.setString('app_mode', 'practice');
    await SavedBriefingStore.save(
      name: 'Round 5 - Nürburgring Sprint',
      briefing: RaceBriefing(
        trackName: 'Nürburgring Sprint',
        totalLaps: 26,
        startingFuelPercent: 100,
        availableTireCompounds: const ['Racing Medium', 'Racing Soft'],
        wetOrChangeableWeather: true,
        weatherSlots: 'R06/R05/C03/S14/S04/R03/R04/R05',
      ),
      strategy: const RaceStrategy(
        startingTireCompound: 'Intermediate',
        pitStops: [
          PlannedPitStop(lap: 6, tireCompound: 'Racing Medium', reasoning: 'track dry by the C03 slot'),
          PlannedPitStop(lap: 17, tireCompound: 'Intermediate', reasoning: 'rain back for R03'),
        ],
        summary: 'Start on Inters in the R06 rain, slicks once it dries, Inters again when the rain returns late on.',
        assumedPercentPerLap: 3.1,
        totalEstimatedTimeLossSeconds: 58,
        pitStopTimeIsMeasured: true,
      ),
    );
    await ChampionshipStandingsStore.save([
      for (final (driver, points) in [
        ('Salty-067', [25, 18, 25, 18, 25]),
        ('Chuck_E82', [18, 25, 12, 15, 18]),
        ('Willy-SwerveX', [15, 15, 18, 25, 15]),
        ('sideshow-308', [12, 12, 15, 12, 12]),
        ('ryan_tr17', [10, 10, 10, 10, 10]),
      ])
        ChampionshipStanding(driverName: driver, roundPoints: [...points, null, null, null, null]),
    ]);

    // An earlier stint on Mediums: 16 laps, cliff from lap 12, spin on lap 7.
    final earlier = _stintTimes(16, cliffLap: 12, spinLap: 7);
    await PracticeLogStore.save([
      for (final (i, t) in earlier.indexed)
        PracticeLapRecord(
          lapNumber: i + 1,
          lapTimeMs: t,
          tireCompound: 'Racing Medium',
          fuelPercentAtLapStart: 100 - i * 2.8,
          fuelPercentAtLapEnd: 97.2 - i * 2.8,
          tireWearPercent: 100 - (i + 1) * 3.5,
          recordedAt: DateTime(2026, 11, 14, 19, i * 2),
          stintNumber: 1,
          wheelspinPercent: 1.5 + (i % 3) * 0.4, // a dry run
          lockupPercent: 0.8,
        ),
      // Wet laps, with the water gauge: Inters and Wets in R06 (about
      // 73% water), then Inters and Mediums as the track dried.
      for (final (stint, tyre, weather, base, perWater, waterFrom, waterTo) in [
        (2, 'Intermediate', 'R06', 95000, 125, 74.0, 72.0),
        (3, 'Heavy Wet', 'R06', 102900, 0, 75.0, 73.0),
        (4, 'Intermediate', null, 95000, 125, 40.0, 8.0),
        (5, 'Racing Medium', null, 90500, 380, 35.0, 5.0),
      ])
        for (var i = 0; i < 5; i++)
          PracticeLapRecord(
            lapNumber: 17 + (stint - 2) * 5 + i,
            lapTimeMs: base + (perWater * (waterFrom + (waterTo - waterFrom) * i / 4)).round() + const [0, 180, -150, 90, -60][i],
            tireCompound: tyre,
            fuelPercentAtLapStart: 50 - i * 2.8,
            fuelPercentAtLapEnd: 47.2 - i * 2.8,
            recordedAt: DateTime(2026, 11, 14, 20, stint * 10 + i),
            stintNumber: stint,
            weather: weather,
            waterPercent: waterFrom + (waterTo - waterFrom) * i / 4,
          ),
    ]);

    // An earlier round's practice, kept in the database as history.
    await PracticeLogStore.save([
      for (var i = 0; i < 12; i++)
        PracticeLapRecord(
          lapNumber: i + 1,
          lapTimeMs: 78400 + (i % 4) * 160,
          tireCompound: i < 6 ? 'Racing Medium' : 'Racing Soft',
          fuelPercentAtLapStart: 100 - i * 3.0,
          fuelPercentAtLapEnd: 97 - i * 3.0,
          recordedAt: DateTime(2026, 11, 7, 19, i * 2),
          stintNumber: i < 6 ? 1 : 2,
        ),
      // ...and its race: 10 laps, one stop, finished P3.
      for (var i = 0; i < 10; i++)
        PracticeLapRecord(
          lapNumber: 13 + i,
          lapTimeMs: (i == 5 ? 104200 : 78900 + (i % 3) * 120),
          tireCompound: i < 5 ? 'Racing Medium' : 'Racing Soft',
          fuelPercentAtLapStart: 100 - i * 3.0,
          fuelPercentAtLapEnd: 97 - i * 3.0,
          recordedAt: DateTime(2026, 11, 12, 20, i * 2),
          stintNumber: i < 5 ? 3 : 4,
          isRaceLap: true,
          raceNumber: 1,
          isPitLap: i == 5,
          position: i < 5 ? 4 : 3,
        ),
    ], round: 'Round 4 - Alsace Village (Reverse)');

    final manager = FusedRaceStateManager(
      telemetryService: TelemetryUdpService(),
      hudService: HudOcrService(),
      sectorCalculator: SectorCalculator(),
      fuelPredictor: FuelPredictor(),
    );
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true).copyWith(scaffoldBackgroundColor: Colors.black),
        home: DashboardScreen(connectOnStart: false, raceStateManager: manager),
      ),
    );
    await tester.pumpAndSettle();
    await manager.loadPersistedData();
    await tester.pumpAndSettle();
    await tester.tap(find.text('CHANGE ROUND'));
    await tester.pumpAndSettle();
    await binding.takeScreenshot('01b_round_picker');
    await tester.tap(find.text('Round 5')); // the current round: no change
    await tester.pumpAndSettle();

    // Driven while the home page is up, where unprompted calls are held
    // (with no API keys, a call would fail the test).
    // This session's stint on Softs: 14 laps, cliff from lap 9, spin on lap 5.
    final live = _stintTimes(14, cliffLap: 9, spinLap: 5);
    var fuel = 100.0;
    manager.practiceLapLogger.currentTireCompound = 'Racing Soft';
    manager.handleTelemetryFrame(_frame(1, fuel, -1));
    for (final (i, t) in live.indexed) {
      fuel -= 3.1;
      manager.practiceLapLogger.currentTireWearPercent = 100 - (i + 1) * 5.0;
      // The lap's driving, on a track getting wetter: more of the
      // full-throttle time spinning the rears, more lock-ups.
      for (var f = 0; f < 100; f++) {
        manager.handleTelemetryFrame(_frame(i + 1, fuel, -1, throttle: 100, wheels: f < 3 + i * 2 ? [180, 180, 205, 205] : [180, 180, 180, 180]));
      }
      for (var f = 0; f < 50; f++) {
        manager.handleTelemetryFrame(_frame(i + 1, fuel, -1, brake: 80, wheels: f < 1 + i ? [120, 180, 180, 180] : [180, 180, 180, 180]));
      }
      manager.handleTelemetryFrame(_frame(i + 2, fuel, t));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
    // The relay reading the water gauge.
    manager.handleHudData(
      const HudOverlayData(
        waterPercent: 47,
        tireWearFrontLeftPercent: 64,
        tireWearFrontRightPercent: 58,
        tireWearRearLeftPercent: 41,
        tireWearRearRightPercent: 18,
      ),
    );
    await binding.takeScreenshot('01_home');
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('PRACTICE')));
    await tester.pumpAndSettle();
    await binding.takeScreenshot('02_stint_dashboard_dropped_off');
    // The wet brief's stint tests: Wets vs Inters at its rain levels.
    await tester.tap(find.text('CHOOSE STINT TEST').first);
    await tester.pumpAndSettle();
    await binding.takeScreenshot('02b_wet_stint_tests');
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    await tester.tap(find.text('HIDE'));
    await tester.pumpAndSettle();
    await binding.takeScreenshot('02c_free_practice');
    await tester.tap(find.text('SHOW STINT TESTS'));
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('TOTAL)').first);
    await tester.pumpAndSettle();
    await binding.takeScreenshot('03_practice_log');
    final wetCard = find.text('WET TESTING');
    await tester.scrollUntilVisible(wetCard, 300, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await binding.takeScreenshot('03b_wet_testing');
    final stintCard = find.textContaining('Stint 6').first;
    await tester.scrollUntilVisible(stintCard, 300, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await binding.takeScreenshot('04_practice_log_stint_card');
    final earlierCard = find.textContaining('Stint 3 ');
    await tester.dragUntilVisible(earlierCard, find.byType(ListView), const Offset(0, -300), maxIteration: 100);
    await tester.pumpAndSettle();
    await binding.takeScreenshot('05_practice_log_earlier_stint');
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('RACE MODE')));
    await tester.pumpAndSettle();
    await binding.takeScreenshot('06_race_dashboard');
    await tester.tap(find.text('PICK RIVAL'));
    await tester.pumpAndSettle();
    await binding.takeScreenshot('07_rival_picker');
    await tester.tap(find.text('Chuck_E82'));
    await tester.pumpAndSettle();
    await binding.takeScreenshot('08_rival_chosen');

    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('APRL')));
    await tester.pumpAndSettle();
    await binding.takeScreenshot('08b_aprl_standings');
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('HOME')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('PRACTICE LOG'));
    await tester.pumpAndSettle();
    await binding.takeScreenshot('08c_practice_log_rounds');
    await tester.tap(find.text('Round 4 - Alsace Village (Reverse)'));
    await tester.pumpAndSettle();
    await binding.takeScreenshot('08d_earlier_round_log');
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('RACE REPORTS'));
    await tester.pumpAndSettle();
    await binding.takeScreenshot('08e_race_report_rounds');
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('RACE BRIEF').last);
    await tester.pumpAndSettle();
    final timeline = find.textContaining('Assumes the slots');
    await tester.scrollUntilVisible(timeline, 300, scrollable: find.byType(Scrollable).first);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -250));
    await tester.pumpAndSettle();
    await binding.takeScreenshot('09_weather_slots');
  });
}
