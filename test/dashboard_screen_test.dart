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
import 'package:boxbox/widgets/status_badge.dart';
import 'package:boxbox/widgets/track_header.dart';
import 'package:boxbox/widgets/voice_status_badge.dart';

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

  /// The bottom bar's tab labelled [label].
  Finder tab(String label) => find.descendant(of: find.byType(NavigationBar), matching: find.text(label));

  /// Opens the app and picks [mode]'s tab.
  Future<void> pumpDashboard(WidgetTester tester, {required String mode}) async {
    await pumpApp(tester);
    const labels = {'race': 'RACE MODE', 'practice': 'PRACTICE', 'timeTrial': 'TIME TRIAL'};
    await tester.tap(tab(labels[mode]!));
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('the app opens on Home, with the bottom bar', (tester) async {
    await pumpApp(tester, lastMode: 'race');
    for (final label in ['HOME', 'RACE MODE', 'PRACTICE', 'TIME TRIAL', 'APRL']) {
      expect(tab(label), findsOneWidget, reason: label);
    }
    expect(find.text('BEST LAPS BY TYRE'), findsOneWidget);
    expect(find.textContaining('No laps yet'), findsOneWidget);
    expect(find.text('RACE BRIEF'), findsNWidgets(2), reason: 'the card and the button');
    expect(find.textContaining('No strategy yet'), findsOneWidget);
    expect(find.text('PRACTICE LOG'), findsOneWidget);
    expect(find.textContaining('RACE REPORTS'), findsOneWidget);
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

    for (final mode in ['RACE MODE', 'PRACTICE', 'TIME TRIAL']) {
      await tester.tap(tab(mode));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('SAINTE-CROIX C'), findsOneWidget, reason: mode);
      await tester.tap(tab('HOME'));
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

  testWidgets('the APRL tab shows the standings, and Home goes back', (tester) async {
    await pumpDashboard(tester, mode: 'race');
    expect(find.text('PIT LAP'), findsOneWidget);
    await tester.tap(tab('APRL'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('STANDINGS'), findsOneWidget);
    expect(find.widgetWithText(TrackHeader, 'APRL'), findsOneWidget, reason: 'the same heading as the other tabs');
    expect(find.text('REFRESH'), findsOneWidget);
    expect(find.text('ENTER RESULTS'), findsNothing);
    expect(find.byType(StatusBadge), findsNothing, reason: 'no connection dots on the league page');
    expect(find.text('PIT LAP'), findsNothing);
    await tester.tap(tab('HOME'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('BEST LAPS BY TYRE'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('practice mode shows the test screen, without race cards or push-to-talk', (tester) async {
    await pumpDashboard(tester, mode: 'practice');
    expect(find.text('NO STINT TESTS'), findsOneWidget); // no round saved in this test
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
    expect(find.text('PIT LAP'), findsOneWidget);
    expect(find.text('POSITION'), findsOneWidget);
    expect(find.text('AHEAD'), findsOneWidget);
    expect(find.text('NO STINT TESTS'), findsNothing);
    expect(find.text('TYRES LEFT'), findsNothing);
    expect(find.text('NEW STINT'), findsNothing);
    expect(find.byType(DropdownButton<String>), findsNothing, reason: 'no tyre picker in a race');
    expect(find.textContaining('LAPS LOGGED'), findsNothing);
    expect(find.text('ENGAGE TELEMETRY'), findsNothing, reason: 'connects on launch');
    expect(tester.takeException(), isNull);
  });

  testWidgets('time trial shows the lap-time screen only', (tester) async {
    await pumpDashboard(tester, mode: 'timeTrial');
    expect(find.text('BEST LAP'), findsOneWidget);
    expect(find.text('LIVE DELTA'), findsOneWidget);
    expect(find.text('IDEAL LAP'), findsOneWidget);
    expect(find.text('NO STINT TESTS'), findsNothing);
    expect(find.text('PIT LAP'), findsNothing);
    expect(find.text('NEW STINT'), findsNothing);
    expect(find.byType(DropdownButton<String>), findsNothing, reason: 'tyre comes from the HUD, no picker');
    expect(find.text('TIRE:'), findsNothing, reason: 'each lap in the list shows its tyre');
    expect(tester.takeException(), isNull);
  });

  testWidgets('every mode keeps the bottom bar, and no refresh button', (tester) async {
    for (final mode in ['race', 'practice', 'timeTrial']) {
      await pumpDashboard(tester, mode: mode);
      expect(find.byType(NavigationBar), findsOneWidget, reason: mode);
      expect(find.byIcon(Icons.refresh), findsNothing, reason: mode);
      await tester.tap(tab('HOME'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('BEST LAPS BY TYRE'), findsOneWidget, reason: 'back on the home page from $mode');
    }
  });

  testWidgets('connection status is two dots in each mode\'s heading, and none on Home', (tester) async {
    Finder dot(String label) => find.byWidgetPredicate((w) => w is StatusBadge && w.dotOnly && w.label == label);
    await pumpApp(tester);
    expect(find.byType(StatusBadge), findsNothing, reason: 'home');
    for (final label in ['RACE MODE', 'PRACTICE', 'TIME TRIAL']) {
      await tester.tap(tab(label));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(StatusBadge), findsNWidgets(2), reason: label);
      expect(find.byType(VoiceStatusBadge), label == 'RACE MODE' ? findsOneWidget : findsNothing, reason: label);
      for (final d in ['TELEMETRY', 'HUD OCR']) {
        expect(find.descendant(of: find.byType(TrackHeader), matching: dot(d)), findsOneWidget, reason: '$label: $d');
      }
      expect(find.textContaining('TELEMETRY ·'), findsNothing, reason: '$label: no text pill');
    }
  });
}
