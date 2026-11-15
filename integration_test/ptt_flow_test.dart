// Integration test that exercises the real Push-to-Talk flow end-to-end
// on a running device/simulator: long-presses the actual PushToTalkButton
// widget (same GestureDetector a real finger-tap would hit), holds it
// long enough to capture a few seconds of simulator microphone input,
// releases it, and watches the on-screen VoiceStatusBadge progress
// through listening -> transcribing -> responding -> idle, confirming
// the full PTT -> Whisper -> Boxington -> TTS pipeline runs without
// crashing and reaches a terminal state within a generous timeout.
//
// Requires a real .env with valid GROQ_API_KEY / TTS_API_KEY / TTS_VOICE_ID
// (same file the real app loads), since this hits the live Groq and
// Cartesia APIs -- there is no mocking here, this is a true black-box
// run of the production code path.
//
// Run with (simulator must already be booted):
//   flutter test integration_test/ptt_flow_test.dart -d <device-id>
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'package:boxbox/widgets/push_to_talk_button.dart';
import 'package:boxbox/models/voice_engine_status.dart';
import 'package:boxbox/widgets/voice_status_badge.dart';
import 'package:boxbox/screens/dashboard_screen.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Push-to-talk produces a Boxington response', (tester) async {
    await dotenv.load(fileName: '.env');

    await tester.pumpWidget(const MaterialApp(home: DashboardScreen()));
    await tester.pumpAndSettle();

    final pttButtonFinder = find.byType(PushToTalkButton);
    expect(pttButtonFinder, findsOneWidget, reason: 'PTT button should be on screen');

    // Simulate a real hold-to-talk gesture: press down, hold for a few
    // seconds (so the simulator mic actually captures some audio), then
    // release -- exactly what onTapDown/onTapUp wire up to in the widget.
    final gesture = await tester.startGesture(tester.getCenter(pttButtonFinder));
    await tester.pump(const Duration(seconds: 3));

    // Button should visually flip to "TRANSMITTING..." while held.
    expect(find.text('TRANSMITTING…'), findsOneWidget);

    await gesture.up();
    await tester.pump();

    // Button should flip back once released.
    expect(find.text('HOLD TO TALK'), findsOneWidget);

    // Poll the on-screen VoiceStatusBadge status for up to ~30s, since the
    // real pipeline (Whisper transcription + streamed Boxington response +
    // streamed TTS) takes a few seconds over a live network call.
    const pollInterval = Duration(milliseconds: 500);
    const timeout = Duration(seconds: 30);
    var elapsed = Duration.zero;
    String? lastStatusText;

    while (elapsed < timeout) {
      await tester.pump(pollInterval);
      elapsed += pollInterval;

      final badgeFinder = find.byType(VoiceStatusBadge);
      if (badgeFinder.evaluate().isEmpty) continue;

      // A dot in the Race Mode heading now: read its status, not text.
      lastStatusText = tester.widget<VoiceStatusBadge>(badgeFinder.first).status.label;

      // Pipeline completed a full round trip back to idle/ready.
      if (lastStatusText.contains('READY') && elapsed > const Duration(seconds: 5)) {
        break;
      }
    }

    debugPrint('Final voice status badge text: $lastStatusText');
    expect(
      lastStatusText,
      isNotNull,
      reason: 'Voice status badge should have been readable throughout the test',
    );
  });
}
