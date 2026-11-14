/// One lap recorded in Time Trialing mode -- qualifying pace, kept apart
/// from stint laps (see AppMode.timeTrial).
class TimeTrialLap {
  final int lapTimeMs;
  final String tireCompound;
  final DateTime recordedAt;

  /// S1/S2/S3 times (ms), adding up to [lapTimeMs]; null if not split
  /// (see SectorCalculator).
  final List<int>? sectorsMs;

  const TimeTrialLap({required this.lapTimeMs, required this.tireCompound, required this.recordedAt, this.sectorsMs});

  factory TimeTrialLap.fromMap(Map<String, dynamic> map) => TimeTrialLap(
    lapTimeMs: (map['lapTimeMs'] as num).toInt(),
    tireCompound: map['tireCompound'] as String,
    recordedAt: DateTime.parse(map['recordedAt'] as String),
    sectorsMs: (map['sectorsMs'] as List?)?.map((s) => (s as num).toInt()).toList(),
  );

  Map<String, dynamic> toMap() => {
    'lapTimeMs': lapTimeMs,
    'tireCompound': tireCompound,
    'recordedAt': recordedAt.toIso8601String(),
    if (sectorsMs != null) 'sectorsMs': sectorsMs,
  };

  /// e.g. "1:29.950".
  static String format(num ms) {
    final minutes = ms ~/ 60000;
    return '$minutes:${((ms % 60000) / 1000).toStringAsFixed(3).padLeft(6, '0')}';
  }

  /// The fastest lap, or null if there are none.
  static TimeTrialLap? best(List<TimeTrialLap> laps) =>
      laps.isEmpty ? null : laps.reduce((a, b) => b.lapTimeMs < a.lapTimeMs ? b : a);
}
