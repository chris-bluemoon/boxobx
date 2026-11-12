// Standalone live-API validation for RaceStrategistService: sends a
// real APRL-style weekly briefing to Groq and prints the parsed
// strategy, to confirm the JSON response shape actually round-trips
// through RaceStrategy.fromMap() against a real model response (not
// just a hand-crafted fixture).
//
// Run from the project root with:
//   dart run test_scripts/race_strategist_test.dart
//
// Requires a real .env with GROQ_API_KEY already populated.
import 'dart:io';

import 'package:boxbox/models/race_briefing.dart';
import 'package:boxbox/services/race_strategist_service.dart';

Map<String, String> _loadEnv(String path) {
  final file = File(path);
  final env = <String, String>{};
  if (!file.existsSync()) return env;
  for (final line in file.readAsLinesSync()) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    final splitIndex = trimmed.indexOf('=');
    if (splitIndex == -1) continue;
    env[trimmed.substring(0, splitIndex)] = trimmed.substring(splitIndex + 1);
  }
  return env;
}

Future<void> main() async {
  final env = _loadEnv('.env');
  final groqKey = env['GROQ_API_KEY'] ?? '';
  if (groqKey.isEmpty) {
    stderr.writeln('Missing GROQ_API_KEY in .env');
    exit(1);
  }

  // A real APRL weekly briefing, structured through the full field set
  // (car class, qualifying/start format, BoP, tyre wear, fuel rate,
  // refueling speed, mandatory tyre/pit-stop count, weather toggle).
  final briefing = RaceBriefing(
    trackName: 'Suzuka Circuit',
    carClass: 'Gr.3',
    totalLaps: 32,
    raceLengthMinutes: 45,
    qualifyingFormat: 'One-shot qualifying',
    startType: 'Rolling Start',
    bopTuningProhibited: true,
    tyreWearMultiplier: 6.0,
    fuelConsumptionMultiplier: 3.0,
    refuelingSpeedLitersPerSec: 8.0,
    startingFuelPercent: 100,
    availableTireCompounds: const ['Racing Hard'],
    mandatoryTyreCompound: 'N/A',
    mandatoryPitStopCount: 1,
    wetOrChangeableWeather: true,
    additionalNotes: 'BMW M6 GT3 Endurance. Weather shifts through the race '
        '(sunny start, rain mid-race, clearing late) -- custom per-phase '
        'weather sequence not modeled in detail yet, treat as changeable.',
  );

  print('Sending briefing to Groq strategist (call 1 of 2)...\n');
  final strategist = RaceStrategistService(groqKey);
  final strategy = await strategist.generateStrategy(briefing);

  print('Starting tire: ${strategy.startingTireCompound}');
  print('Assumed %/lap: ${strategy.assumedPercentPerLap}');
  print('Summary: ${strategy.summary}\n');
  print('Pit stops:');
  for (final stop in strategy.pitStops) {
    print('  Lap ${stop.lap}: ${stop.tireCompound} -- ${stop.reasoning}');
  }

  if (strategy.pitStops.isEmpty) {
    stderr.writeln('\nWARNING: no pit stops returned despite mandatoryPitStopCount=1.');
  }

  // Determinism check: the same briefing must produce the exact same
  // pit laps/tires/fuel assumption on a second call -- only the
  // AI-phrased wording (reasoning/summary text) is allowed to differ,
  // never the numbers. This is the actual fix for the user-reported
  // "strategy is different every time" bug.
  print('\nSending the SAME briefing again (call 2 of 2) to verify determinism...\n');
  final strategy2 = await strategist.generateStrategy(briefing);

  final lapsMatch = strategy.pitStops.map((p) => p.lap).toList().toString() ==
      strategy2.pitStops.map((p) => p.lap).toList().toString();
  final tiresMatch = strategy.pitStops.map((p) => p.tireCompound).toList().toString() ==
      strategy2.pitStops.map((p) => p.tireCompound).toList().toString();
  final fuelMatches = strategy.assumedPercentPerLap == strategy2.assumedPercentPerLap;
  final startingTireMatches = strategy.startingTireCompound == strategy2.startingTireCompound;

  print('Call 2 -- Starting tire: ${strategy2.startingTireCompound}, Assumed %/lap: ${strategy2.assumedPercentPerLap}');
  print('Call 2 -- Pit laps: ${strategy2.pitStops.map((p) => p.lap).toList()}');

  print('\n${lapsMatch ? 'PASS' : 'FAIL'} pit laps identical across both calls');
  print('${tiresMatch ? 'PASS' : 'FAIL'} tire compounds identical across both calls');
  print('${fuelMatches ? 'PASS' : 'FAIL'} assumed fuel-per-lap identical across both calls');
  print('${startingTireMatches ? 'PASS' : 'FAIL'} starting tire identical across both calls');

  if (!lapsMatch || !tiresMatch || !fuelMatches || !startingTireMatches) {
    stderr.writeln('\nFAILED: strategy was not deterministic across two calls with the same briefing.');
    exit(1);
  }

  print('\nDone. Strategy is deterministic.');
}
