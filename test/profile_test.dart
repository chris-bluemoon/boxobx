// The Profile page: PSN ID, nickname (Boxington uses it now and then)
// and strategy style (aggressive: the faster tyre first wherever you
// start).
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:boxbox/models/race_briefing.dart';
import 'package:boxbox/screens/profile_screen.dart';
import 'package:boxbox/services/groq_service.dart';
import 'package:boxbox/services/league_roster.dart';
import 'package:boxbox/services/pit_stop_calculator.dart';
import 'package:boxbox/services/profile_settings.dart';

/// Always rolls [value].
class _FixedRandom implements Random {
  final double value;
  _FixedRandom(this.value);
  @override
  double nextDouble() => value;
  @override
  int nextInt(int max) => 0;
  @override
  bool nextBool() => false;
}

RaceBriefing _alsace({int? grid}) => RaceBriefing(
  trackName: 'Alsace - Village (Reverse)',
  totalLaps: 32,
  startingFuelPercent: 100,
  fuelConsumptionMultiplier: 2,
  tyreWearMultiplier: 2,
  availableTireCompounds: const ['Racing Medium', 'Racing Soft'],
  gridPosition: grid,
);

void main() {
  setUp(() => ProfileSettings.current = const ProfileSettings());
  tearDown(() => ProfileSettings.current = const ProfileSettings());

  test('saved settings load back; blank is the defaults', () async {
    SharedPreferences.setMockInitialValues({});
    expect((await ProfileSettings.load()).psnId, ProfileSettings.defaultPsnId);
    expect(ProfileSettings.current.nickname, isNull);
    expect(ProfileSettings.current.strategyStyle, StrategyStyle.passive);
    await ProfileSettings.save(const ProfileSettings(psnId: 'Someone-Else', nickname: 'Willy', strategyStyle: StrategyStyle.aggressive));
    ProfileSettings.current = const ProfileSettings();
    final loaded = await ProfileSettings.load();
    expect((loaded.psnId, loaded.nickname, loaded.strategyStyle), ('Someone-Else', 'Willy', StrategyStyle.aggressive));
    expect(playerName, 'Someone-Else', reason: 'the app\'s own car follows the PSN ID');
  });

  test('aggressive: Softs first from P9, where passive goes Mediums first', () {
    final passive = PitStopCalculator.calculate(_alsace(grid: 9), trackLengthMeters: 5345);
    final aggressive = PitStopCalculator.calculate(_alsace(grid: 9), trackLengthMeters: 5345, style: StrategyStyle.aggressive);
    expect(passive.startingTireCompound, 'Racing Medium');
    expect(aggressive.startingTireCompound, 'Racing Soft');
    expect(aggressive.pitStops, hasLength(passive.pitStops.length));
    expect(aggressive.basis.any((b) => b.startsWith('Aggressive style (Profile): the Softs first wherever you start')), isTrue);
    expect(PitStopCalculator.gridCaveat(aggressive), startsWith('Aggressive style'));
    // With no grid entered too.
    expect(PitStopCalculator.calculate(_alsace(), trackLengthMeters: 5345, style: StrategyStyle.aggressive).startingTireCompound, 'Racing Soft');
  });

  test('Boxington knows our PSN name, and uses the nickname about a third of the time', () {
    GroqService groq(double roll) => GroqService('key', random: _FixedRandom(roll))
      ..psnId = 'Willy-SwerveX'
      ..nickname = 'Willy';
    expect(groq(0.1).addressSection(), contains('Your driver is Willy-SwerveX on PSN'));
    expect(groq(0.1).addressSection(), contains('Call the driver "Willy" in this transmission'));
    expect(groq(0.9).addressSection(), contains("Don't use the driver's name"));
    // Over many calls, roughly a third by name.
    final seeded = GroqService('key', random: Random(7))..nickname = 'Willy';
    final named = List.generate(300, (_) => seeded.addressSection()).where((s) => s.contains('Call the driver')).length;
    expect(named, inInclusiveRange(70, 130));
    expect(GroqService('key').addressSection(), isEmpty, reason: 'nothing set: nothing said');
  });

  testWidgets('the Profile page saves as you type and pick', (tester) async {
    SharedPreferences.setMockInitialValues({});
    ProfileSettings? told;
    await tester.pumpWidget(MaterialApp(home: ProfileScreen(onChanged: (s) => told = s)));
    await tester.enterText(find.byKey(const Key('profile_nickname')), 'Willy');
    await tester.scrollUntilVisible(find.text('Aggressive'), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Aggressive'));
    await tester.pump();
    expect(told?.nickname, 'Willy');
    expect(told?.strategyStyle, StrategyStyle.aggressive);
    expect(find.textContaining('Generate again', skipOffstage: false), findsOneWidget);
    final saved = await ProfileSettings.load();
    expect((saved.nickname, saved.strategyStyle), ('Willy', StrategyStyle.aggressive));
  });

  test('talk level: Quiet lets only the essentials through, Chatty everything', () {
    expect(TalkLevel.quiet.allows(CallPriority.essential), isTrue);
    expect(TalkLevel.quiet.allows(CallPriority.info), isFalse);
    expect(TalkLevel.normal.allows(CallPriority.info), isTrue);
    expect(TalkLevel.normal.allows(CallPriority.chat), isFalse);
    expect(TalkLevel.chatty.allows(CallPriority.chat), isTrue);
    expect((GroqService('key')..talkLevel = TalkLevel.quiet).addressSection(), contains('quiet radio'));
    expect((GroqService('key')..talkLevel = TalkLevel.chatty).addressSection(), contains('chatty radio'));
  });

  test('the connections save and load; a bad port falls back to the default', () async {
    SharedPreferences.setMockInitialValues({});
    await ProfileSettings.save(const ProfileSettings(consoleIp: '10.0.0.5', hudPort: 40000, talkLevel: TalkLevel.quiet));
    final loaded = await ProfileSettings.load();
    expect((loaded.consoleIp, loaded.hudPort, loaded.talkLevel), ('10.0.0.5', 40000, TalkLevel.quiet));
    SharedPreferences.setMockInitialValues({'profile_hud_port': 80});
    expect((await ProfileSettings.load()).hudPort, ProfileSettings.defaultHudPort);
    expect(ProfileSettings.isValidIp('192.168.1.20'), isTrue);
    expect(ProfileSettings.isValidIp('192.168.1'), isFalse);
    expect(ProfileSettings.isValidIp('192.168.1.300'), isFalse);
  });

  testWidgets('the PS5 address: a half-typed one is flagged and not used; a whole one is', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final told = <ProfileSettings>[];
    await tester.pumpWidget(MaterialApp(
      home: ProfileScreen(onChanged: told.add, deviceAddresses: () async => ['10.0.0.9']),
    ));
    await tester.pump();
    await tester.scrollUntilVisible(find.byKey(const Key('profile_hud_port')), 300, scrollable: find.byType(Scrollable).first);
    expect(find.text('Send to this iPad at 10.0.0.9, port 33746'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('profile_console_ip')), '10.0.0');
    await tester.pump();
    expect(find.text('An address like 192.168.1.20'), findsOneWidget);
    expect(told.last.consoleIp, isNull, reason: 'not used till it is a whole address');
    await tester.enterText(find.byKey(const Key('profile_console_ip')), '10.0.0.5');
    await tester.enterText(find.byKey(const Key('profile_hud_port')), '40000');
    await tester.pump();
    expect((told.last.consoleIp, told.last.hudPort), ('10.0.0.5', 40000));
    expect(find.text('Send to this iPad at 10.0.0.9, port 40000'), findsOneWidget);
  });

  test('telemetry only: saved, and Boxington told not to call what he can\'t see', () async {
    SharedPreferences.setMockInitialValues({});
    expect((await ProfileSettings.load()).hudReader, isTrue, reason: 'the HUD reader by default');
    await ProfileSettings.save(const ProfileSettings(hudReader: false));
    expect((await ProfileSettings.load()).hudReader, isFalse);
    final section = (GroqService('key')..hudReader = false).addressSection();
    expect(section, contains('telemetry only'));
    expect(section, contains("can't see their position"));
    expect(GroqService('key').addressSection(), isNot(contains('telemetry only')));
  });

  testWidgets('picking Telemetry only hides the HUD reader settings', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final told = <ProfileSettings>[];
    await tester.pumpWidget(MaterialApp(home: ProfileScreen(onChanged: told.add, deviceAddresses: () async => ['10.0.0.9'])));
    await tester.scrollUntilVisible(find.text('Telemetry only'), 300, scrollable: find.byType(Scrollable).first);
    expect(find.byKey(const Key('profile_hud_port'), skipOffstage: false), findsOneWidget);
    await tester.tap(find.text('Telemetry only'));
    await tester.pump();
    expect(told.last.hudReader, isFalse);
    expect(find.byKey(const Key('profile_hud_port'), skipOffstage: false), findsNothing);
  });
}
