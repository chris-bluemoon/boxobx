import 'package:flutter_test/flutter_test.dart';

import 'package:boxbox/models/league_calendar.dart';
import 'package:boxbox/services/track_outlines.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every calendar circuit has an outline except Nürburgring Sprint; reverse layouts use the base shape', () async {
    final outlines = await TrackOutlines.load();
    final missing = [
      for (final round in LeagueCalendar.rounds)
        if (outlines.forTrack(round.gt7Track) == null) round.gt7Track,
    ];
    expect(missing, ['Nürburgring Sprint']);
    expect(outlines.forTrack('Alsace - Village (Reverse)'), same(outlines.forTrack('Alsace - Village')));
    expect(outlines.forTrack('Alsace - Village')!.length, greaterThan(50));
    expect(outlines.forTrack(null), isNull);
  });
}
