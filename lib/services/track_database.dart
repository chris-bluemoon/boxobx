import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;

import '../models/track_info.dart';

/// Loads the FULL GT7 track list (name + length) from
/// assets/config/all_tracks.json, which deliberately includes every
/// track/layout GT7 has -- including reverse layouts and short layouts
/// with no surveyed/captured racing-line path (e.g. "Alsace - Village
/// (Reverse)", "Nürburgring Sprint") -- unlike the separate
/// assets/config/tracks_db.json used by SectorCalculator for live
/// sector-split timing, which can only safely include tracks with a
/// real captured path (fabricating one would risk false sector
/// splits). See tools/generate_all_tracks.py for how this asset is
/// generated/regenerated.
class TrackDatabase {
  static List<TrackInfo>? _cache;

  static Future<List<TrackInfo>> load() async {
    if (_cache != null) return _cache!;
    final raw = await rootBundle.loadString('assets/config/all_tracks.json');
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final tracks = (json['tracks'] as List)
        .map((e) => TrackInfo.fromMap(e as Map<String, dynamic>))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    _cache = tracks;
    return tracks;
  }
}
