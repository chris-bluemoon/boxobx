/// Whether the time gap to a rival is shrinking, growing, or holding
/// steady, as computed by the laptop OCR relay's GapTracker (a rolling
/// comparison across several consecutive samples, not just the single
/// latest reading, since OCR noise on the gap digits would otherwise
/// cause spurious flip-flopping). This is the metric actually useful for
/// race strategy calls -- the driver can already see who's ahead/behind
/// by name directly on the GT7 HUD; whether the gap is closing or
/// growing is the part that needs a second pair of (virtual) eyes.
enum GapTrend { closing, losing, steady, unknown }

GapTrend _gapTrendFromString(String? value) {
  switch (value) {
    case 'closing':
      return GapTrend.closing;
    case 'losing':
      return GapTrend.losing;
    case 'steady':
      return GapTrend.steady;
    default:
      return GapTrend.unknown;
  }
}

/// Parsed state from the HUD Screen Parser (Component B) — produced via
/// OCR (VNRecognizeTextRequest) on the ROI-cropped leaderboard strip.
class HudOverlayData {
  final int gridPosition;
  final String? driverAhead;
  final String? driverBehind;
  final double? gapAheadSeconds;
  final double? gapBehindSeconds;
  final GapTrend gapAheadTrend;
  final GapTrend gapBehindTrend;

  /// Gap to the race leader (P1), in seconds -- a distinct quantity
  /// from gapAheadSeconds (gap to the car directly ahead). Confirmed
  /// against a real race: GT7 renders this as a red number inline on
  /// the driver's own highlighted standings row, not a per-row gap.
  final double? gapToLeaderSeconds;
  final GapTrend gapToLeaderTrend;

  const HudOverlayData({
    this.gridPosition = 0,
    this.driverAhead,
    this.driverBehind,
    this.gapAheadSeconds,
    this.gapBehindSeconds,
    this.gapAheadTrend = GapTrend.unknown,
    this.gapBehindTrend = GapTrend.unknown,
    this.gapToLeaderSeconds,
    this.gapToLeaderTrend = GapTrend.unknown,
  });

  factory HudOverlayData.empty() => const HudOverlayData();

  factory HudOverlayData.fromMap(Map<String, dynamic> map) => HudOverlayData(
        gridPosition: (map['gridPosition'] as num?)?.toInt() ?? 0,
        driverAhead: map['driverAhead'] as String?,
        driverBehind: map['driverBehind'] as String?,
        gapAheadSeconds: (map['gapAheadSeconds'] as num?)?.toDouble(),
        gapBehindSeconds: (map['gapBehindSeconds'] as num?)?.toDouble(),
        gapAheadTrend: _gapTrendFromString(map['gapAheadTrend'] as String?),
        gapBehindTrend: _gapTrendFromString(map['gapBehindTrend'] as String?),
        gapToLeaderSeconds: (map['gapToLeaderSeconds'] as num?)?.toDouble(),
        gapToLeaderTrend: _gapTrendFromString(map['gapToLeaderTrend'] as String?),
      );
}
