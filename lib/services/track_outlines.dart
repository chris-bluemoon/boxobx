import 'dart:convert';
import 'dart:ui';

import 'package:flutter/services.dart' show rootBundle;

/// Circuit outlines for the page-header emblems, from
/// assets/config/track_outlines.json (see tools/generate_track_outlines.py).
class TrackOutlines {
  final Map<String, List<Offset>> _byName;

  const TrackOutlines(this._byName);

  static TrackOutlines? _cache;

  static Future<TrackOutlines> load() async {
    if (_cache != null) return _cache!;
    final json = jsonDecode(await rootBundle.loadString('assets/config/track_outlines.json')) as Map<String, dynamic>;
    final outlines = (json['outlines'] as Map<String, dynamic>).map(
      (name, points) =>
          MapEntry(name, [for (final p in points as List) Offset((p[0] as num).toDouble(), (p[1] as num).toDouble())]),
    );
    return _cache = TrackOutlines(outlines);
  }

  /// The outline for a GT7 track name; a reverse layout uses its base
  /// layout's outline (same shape). Null if the track has no data.
  List<Offset>? forTrack(String? name) {
    if (name == null) return null;
    return _byName[name] ?? _byName[name.replaceFirst(RegExp(r'\s*\(Reverse\)$'), '')];
  }
}
