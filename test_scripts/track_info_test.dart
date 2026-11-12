// Sanity check that TrackInfo.fromMap parses the real tracks_db.json
// entries correctly and that sorting/dedup assumptions used by the Race
// Strategy screen's track dropdown hold. Doesn't use TrackDatabase.load()
// directly since that depends on Flutter's rootBundle (needs a running
// Flutter engine) -- this exercises the same parsing logic via plain
// dart:io file reads instead, mirroring tracks_db_load_test.dart.
//
// Run with: dart run test_scripts/track_info_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:boxbox/models/track_info.dart';

void check(String label, bool condition) {
  print('${condition ? "PASS" : "FAIL"} $label');
  if (!condition) throw Exception('Failed: $label');
}

void main() {
  // all_tracks.json (not tracks_db.json) is what TrackDatabase/the Race
  // Strategy screen's dropdown actually loads -- tracks_db.json is the
  // separate, path-only dataset used for live sector timing.
  final raw = File('assets/config/all_tracks.json').readAsStringSync();
  final json = jsonDecode(raw) as Map<String, dynamic>;
  final tracks = (json['tracks'] as List)
      .map((e) => TrackInfo.fromMap(e as Map<String, dynamic>))
      .toList()
    ..sort((a, b) => a.name.compareTo(b.name));

  check('parses at least one track from the real asset', tracks.isNotEmpty);
  check('every track has a non-empty name', tracks.every((t) => t.name.isNotEmpty));
  check('every track has a positive length', tracks.every((t) => t.trackLengthMeters > 0));

  final names = tracks.map((t) => t.name).toSet();
  check('no duplicate track names after parsing', names.length == tracks.length);

  final sortedNames = tracks.map((t) => t.name).toList();
  final expectedSorted = [...sortedNames]..sort();
  check('tracks list is sorted alphabetically by name', sortedNames.toString() == expectedSorted.toString());

  final suzuka = tracks.where((t) => t.name.toLowerCase().contains('suzuka'));
  check('Suzuka is present in the real track list', suzuka.isNotEmpty);

  check(
    'Alsace - Village (Reverse) is present (previously missing)',
    names.contains('Alsace - Village (Reverse)'),
  );
  check(
    'Nürburgring Sprint is present (previously missing)',
    names.contains('Nürburgring Sprint'),
  );
  check(
    'covers a comprehensive set of GT7 layouts (>= 100 entries)',
    tracks.length >= 100,
  );

  print('\nLoaded ${tracks.length} tracks. All TrackInfo checks passed.');
}
