// Sanity check that the generated tracks_db.json parses correctly and
// has sane values. This doesn't use SectorCalculator directly since that
// class depends on Flutter's rootBundle (needs a running Flutter engine),
// so this is a plain Dart JSON structural check instead.
//
// Run with: dart run test_scripts/tracks_db_load_test.dart
import 'dart:convert';
import 'dart:io';

void main() {
  final raw = File('assets/config/tracks_db.json').readAsStringSync();
  final json = jsonDecode(raw) as Map<String, dynamic>;
  final tracks = json['tracks'] as List;

  print('Loaded ${tracks.length} tracks.');

  var errors = 0;
  for (final trackJson in tracks) {
    final track = trackJson as Map<String, dynamic>;
    final name = track['name'];
    final length = (track['trackLengthMeters'] as num).toDouble();

    for (final sectorKey in ['sector1Boundary', 'sector2Boundary']) {
      final box = track[sectorKey] as Map<String, dynamic>;
      final minX = (box['minX'] as num).toDouble();
      final maxX = (box['maxX'] as num).toDouble();
      final minZ = (box['minZ'] as num).toDouble();
      final maxZ = (box['maxZ'] as num).toDouble();

      if (minX >= maxX || minZ >= maxZ) {
        print('FAIL $name: $sectorKey has an invalid/degenerate box');
        errors++;
      }
    }

    if (length <= 0) {
      print('FAIL $name: non-positive track length ($length)');
      errors++;
    }
  }

  if (errors == 0) {
    print('All ${tracks.length} tracks have valid, non-degenerate sector boxes and positive lengths.');
  } else {
    print('$errors issues found.');
    exit(1);
  }

  // Spot check a well-known real-world GT7 track (Silverstone isn't in
  // GT7's license roster, so don't use that as a sample -- Suzuka is).
  final sample = tracks.cast<Map<String, dynamic>>().where(
        (t) => (t['name'] as String).toLowerCase().contains('suzuka'),
      );
  if (sample.isNotEmpty) {
    print('\nSample: ${sample.first}');
  } else {
    print('\nNote: no track matching "suzuka" found in this dataset.');
  }
}
