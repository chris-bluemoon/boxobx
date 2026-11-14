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
    // Native audio session channel (Gunther's ducking) and the audio
    // plugins: answered with nothing.
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final channel in ['boxbox/audio_session', 'com.ryanheise.just_audio.methods', 'com.llfbandit.record/messages']) {
      messenger.setMockMethodCallHandler(MethodChannel(channel), (_) async => null);
    }
  });

  Future<void> pumpDashboard(WidgetTester tester, {required String mode, Size size = const Size(1640, 2360)}) async {
    SharedPreferences.setMockInitialValues({'app_mode': mode});
    tester.view.physicalSize = size; // default: iPad portrait
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: DashboardScreen(connectOnStart: false)));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('practice mode shows the test screen, without race cards or push-to-talk', (tester) async {
    await pumpDashboard(tester, mode: 'practice');
    expect(find.text('PRACTICE MODE'), findsOneWidget);
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
    expect(find.byType(DropdownButton<String>), findsOneWidget, reason: 'race keeps the tyre picker');
    expect(find.text('ENGAGE TELEMETRY'), findsNothing, reason: 'connects on launch');
    expect(tester.takeException(), isNull);
  });
}
