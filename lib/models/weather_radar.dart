/// GT7's Weather Radar as the relay reads it (laptop_ocr/
/// weather_radar_reader.py) -- only while the central display is on the
/// radar page at its 100 km zoom. GT7 runs the radar time-lapsed: rain
/// drifts across it within seconds, and at a weather slot change fades
/// out (or in) where it is.
class WeatherRadar {
  /// Rain over the circuit now (the radar's centre).
  final bool overTrack;
  final double coverageAtTrackPercent;

  /// Rain within ~45 km of the circuit, percent of that area.
  final double coverageNearPercent;

  /// The nearest rain, km (0 when over the track; null if none on the
  /// radar), and when it reaches the circuit if it's closing in.
  final double? nearestRainKm;
  final double? arrivalSeconds;
  final double? driftKmPerMin;

  /// Rain near the circuit "building", "fading" or "steady" (null until
  /// there's enough history).
  final String? trend;

  const WeatherRadar({
    this.overTrack = false,
    this.coverageAtTrackPercent = 0,
    this.coverageNearPercent = 0,
    this.nearestRainKm,
    this.arrivalSeconds,
    this.driftKmPerMin,
    this.trend,
  });

  bool get fading => trend == 'fading';
  bool get building => trend == 'building';

  /// No rain over the track, and none on its way in.
  bool get clearOverTrack => !overTrack && arrivalSeconds == null;

  static WeatherRadar? fromJson(Object? json) {
    if (json is! Map) return null;
    double? num_(String k) => (json[k] as num?)?.toDouble();
    return WeatherRadar(
      overTrack: json['overTrack'] as bool? ?? false,
      coverageAtTrackPercent: num_('coverageAtTrackPercent') ?? 0,
      coverageNearPercent: num_('coverageNearPercent') ?? 0,
      nearestRainKm: num_('nearestRainKm'),
      arrivalSeconds: num_('arrivalSeconds'),
      driftKmPerMin: num_('driftKmPerMin'),
      trend: json['trend'] as String?,
    );
  }

  /// "Rain over the track, fading" / "rain 47 km out, arriving in about
  /// 70 s" / "no rain on the radar".
  String describe() {
    if (overTrack) return 'rain over the track${trend == null || trend == 'steady' ? '' : ', $trend'}';
    if (nearestRainKm == null) return 'no rain on the radar';
    final arriving = arrivalSeconds == null ? 'not heading for the track' : 'arriving in about ${arrivalSeconds!.round()} s';
    return 'nearest rain ${nearestRainKm!.round()} km out, $arriving';
  }

  Map<String, dynamic> toPromptContext() => {
    'summary': describe(),
    'rainOverTrack': overTrack,
    if (nearestRainKm != null) 'nearestRainKm': nearestRainKm!.round(),
    if (arrivalSeconds != null) 'rainArrivesInSeconds': arrivalSeconds!.round(),
    if (driftKmPerMin != null) 'rainDriftKmPerMin': driftKmPerMin!.round(),
    'rainNearTrackPercent': coverageNearPercent.round(),
    if (trend != null) 'trend': trend,
  };
}
