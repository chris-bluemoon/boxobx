// Smoke test for the two dashboard layouts (iPad -- the only target for
// now): each mode renders its own
// screen without overflow, and the race-only / practice-only pieces
// appear only where they belong.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:boxbox/screens/dashboard_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    dotenv.testLoad(fileInput: 'GROQ_API_KEY=test\nTTS_API_KEY=test\n');
    // Native audio session channel (Boxington's ducking) and the audio
    // plugins: answered with nothing.
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final channel in ['boxbox/audio_session', 'com.ryanheise.just_audio.methods', 'com.llfbandit.record/messages']) {
      messenger.setMockMethodCallHandler(MethodChannel(channel), (_) async => null);
    }
  });

  Future<void> pumpApp(WidgetTester tester, {String? lastMode}) async {
    SharedPreferences.setMockInitialValues({if (lastMode != null) 'app_mode': lastMode});
    tester.view.physicalSize = const Size(1640, 2360); // iPad portrait
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: DashboardScreen(connectOnStart: false)));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
  }

  /// Opens the app and picks [label] on the launch page.
  Future<void> pumpDashboard(WidgetTester tester, {required String mode}) async {
    await pumpApp(tester);
    const labels = {'race': 'RACE MODE', 'practice': 'PRACTICE', 'timeTrial': 'TIME TRIALING'};
    await tester.tap(find.text(labels[mode]!));
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('the app opens on the three modes', (tester) async {
    await pumpApp(tester, lastMode: 'race');
    expect(find.text('RACE MODE'), findsOneWidget);
    expect(find.text('PRACTICE'), findsOneWidget);
    expect(find.text('TIME TRIALING'), findsOneWidget);
    expect(find.text('LAST USED'), findsOneWidget);
    expect(find.textContaining('RACE REPORTS'), findsOneWidget);
    expect(find.text('RACE STRATEGY'), findsOneWidget);
    expect(find.text('STANDINGS'), findsOneWidget);
    expect(find.text('PIT LAP'), findsNothing, reason: 'no dashboard until a mode is chosen');
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping the home header picks the round, and every mode follows it', (tester) async {
    await pumpApp(tester);
    expect(find.text('TAP TO PICK A ROUND'), findsOneWidget);
    await tester.tap(find.text('CHANGE ROUND'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('Round 6'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('SAINTE-CROIX C'), findsOneWidget);
    expect((await SharedPreferences.getInstance()).getString('saved_briefing_name'), 'Round 6 - Sainte-Croix C');

    for (final mode in ['RACE MODE', 'PRACTICE', 'TIME TRIALING']) {
      await tester.tap(find.text(mode));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('SAINTE-CROIX C'), findsOneWidget, reason: mode);
      await tester.tap(find.text(mode)); // back home
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('the rival picker lists the other drivers, not us', (tester) async {
    await pumpDashboard(tester, mode: 'race');
    await tester.tap(find.text('PICK RIVAL'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Chuck_E82'), findsOneWidget);
    expect(find.text('Willy-SwerveX'), findsNothing);
  });

  testWidgets('tapping the mode chip goes back to the three modes', (tester) async {
    await pumpDashboard(tester, mode: 'race');
    expect(find.text('PIT LAP'), findsOneWidget);
    await tester.tap(find.text('RACE MODE'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('TIME TRIALING'), findsOneWidget);
    expect(find.text('PIT LAP'), findsNothing);
  });

  testWidgets('practice mode shows the test screen, without race cards or push-to-talk', (tester) async {
    await pumpDashboard(tester, mode: 'practice');
    expect(find.text('PRACTICE'), findsOneWidget);
    expect(find.text('NO TEST PLAN'), findsOneWidget); // no round saved in this test
    expect(find.text('TYRES LEFT'), findsOneWidget);
    expect(find.text('FUEL / LAP'), findsOneWidget);
    expect(find.text('DROP-OFF'), findsOneWidget);
    expect(find.text('NEW STINT'), findsOneWidget);
    expect(find.byType(DropdownButton<String>), findsNothing, reason: 'no tyre picker in practice');
    expect(find.text('ENGAGE TELEMETRY'), findsNothing, reason: 'connects on launch');
    expect(find.text('Racing Medium'), findsOneWidget, reason: 'the logged tyre is shown read-only');
    expect(find.text('PIT LAP'), findsNothing);
    expect(find.text('POSITION'), findsNothing);
    expect(find.text('AHEAD'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('race mode shows the race cards and push-to-talk, without the test screen', (tester) async {
    await pumpDashboard(tester, mode: 'race');
    expect(find.text('RACE MODE'), findsOneWidget);
    expect(find.text('PIT LAP'), findsOneWidget);
    expect(find.text('POSITION'), findsOneWidget);
    expect(find.text('AHEAD'), findsOneWidget);
    expect(find.text('NO TEST PLAN'), findsNothing);
    expect(find.text('TYRES LEFT'), findsNothing);
    expect(find.text('NEW STINT'), findsNothing);
    expect(find.byType(DropdownButton<String>), findsNothing, reason: 'no tyre picker in a race');
    expect(find.textContaining('LAPS LOGGED'), findsNothing);
    expect(find.text('ENGAGE TELEMETRY'), findsNothing, reason: 'connects on launch');
    expect(tester.takeException(), isNull);
  });

  testWidgets('time trialing shows the lap-time screen only', (tester) async {
    await pumpDashboard(tester, mode: 'timeTrial');
    expect(find.text('TIME TRIALING'), findsOneWidget);
    expect(find.text('BEST LAP'), findsOneWidget);
    expect(find.text('LIVE DELTA'), findsOneWidget);
    expect(find.text('IDEAL LAP'), findsOneWidget);
    expect(find.text('NO TEST PLAN'), findsNothing);
    expect(find.text('PIT LAP'), findsNothing);
    expect(find.text('NEW STINT'), findsNothing);
    expect(find.byType(DropdownButton<String>), findsNothing, reason: 'tyre comes from the HUD, no picker');
    expect(find.text('TIRE:'), findsNothing, reason: 'each lap in the list shows its tyre');
    expect(tester.takeException(), isNull);
  });

  testWidgets('every mode has a HOME button to the home page, and no strategy/standings/refresh buttons', (tester) async {
    for (final mode in ['race', 'practice', 'timeTrial']) {
      await pumpDashboard(tester, mode: mode);
      expect(find.byIcon(Icons.refresh), findsNothing, reason: mode);
      expect(find.byIcon(Icons.flag), findsNothing, reason: mode);
      expect(find.byIcon(Icons.emoji_events), findsNothing, reason: mode);
      await tester.tap(find.text('HOME'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('RACE STRATEGY'), findsOneWidget, reason: 'back on the home page from $mode');
    }
  });

  testWidgets('the connection badges sit bottom left on the home page and every mode', (tester) async {
    Future<void> expectBottomLeft(String where) async {
      final badge = tester.getRect(find.textContaining('TELEMETRY ·'));
      final screen = tester.getRect(find.byType(Scaffold).last);
      expect(badge.left, lessThan(screen.width * 0.2), reason: '$where: left');
      expect(badge.bottom, greaterThan(screen.height * 0.85), reason: '$where: bottom');
      expect(find.textContaining('HUD OCR ·'), findsOneWidget, reason: where);
    }

    await pumpApp(tester);
    await expectBottomLeft('home');
    for (final label in ['RACE MODE', 'PRACTICE', 'TIME TRIALING']) {
      await tester.tap(find.text(label));
      await tester.pump(const Duration(milliseconds: 100));
      await expectBottomLeft(label);
      await tester.tap(find.text('HOME'));
      await tester.pump(const Duration(milliseconds: 100));
    }
  });
}
