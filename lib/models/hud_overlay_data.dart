import 'opponent_pit_stop.dart';
import 'traffic_map.dart';

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

  /// Remaining-grip percent (100 = fresh, 0 = fully worn) for each of
  /// the 4 wheels, read directly off GT7's HUD tire-wear fill-bar
  /// widget via pixel-color analysis on the laptop relay (see
  /// laptop_ocr/tire_wear_reader.py) -- null per wheel if that frame's
  /// bar couldn't be confidently read (e.g. the widget wasn't on
  /// screen). This is real measured wear, unlike
  /// PracticeLapRecord.tireWearPercent/TireWearTracker's lap-time
  /// degradation proxy, since GT7's UDP telemetry packet has no tire
  /// wear field at all.
  final double? tireWearFrontLeftPercent;
  final double? tireWearFrontRightPercent;
  final double? tireWearRearLeftPercent;
  final double? tireWearRearRightPercent;

  /// Tire compound abbreviation (e.g. "RS", "RM", "CH") read via OCR
  /// off the same HUD widget, null if not confidently read this frame.
  /// Intended to auto-fill PracticeLapRecord.tireCompound instead of
  /// requiring manual entry on the dashboard's tire picker.
  final String? tireCompound;

  /// On-screen grid position for each of the up-to-2 chosen
  /// championship rivals (see ChampionshipStandingsStore.loadRivals),
  /// keyed by their exact league roster gamertag -- read from ANY
  /// visible leaderboard row this frame, not just driverAhead/
  /// driverBehind (see laptop_ocr/ocr_relay.py's parse_leaderboard
  /// rival_names parameter). A rival not currently on screen simply
  /// has no entry in this map, rather than a stale or zero value.
  /// Empty if no rivals are configured on the laptop relay (via
  /// --rival-names) at all.
  final Map<String, int> rivalPositions;

  /// Drivers currently showing GT7's "P" (in pits) marker on the
  /// leaderboard, keyed by roster PSN ID where the relay could resolve
  /// it, with their position / tyre being fitted / fuel going in.
  /// Excludes the driver's own car.
  final Map<String, PitLaneEntry> driversInPit;

  /// Every car's position around the lap, from GT7's course map.
  final TrafficMap traffic;

  /// True while OUR row shows GT7's "P" (in pit lane) marker, with the
  /// tyre/fuel being put on our car when shown.
  final bool playerInPit;
  final PitLaneEntry? playerPitService;

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
    this.tireWearFrontLeftPercent,
    this.tireWearFrontRightPercent,
    this.tireWearRearLeftPercent,
    this.tireWearRearRightPercent,
    this.tireCompound,
    this.rivalPositions = const {},
    this.driversInPit = const {},
    this.traffic = TrafficMap.empty,
    this.playerInPit = false,
    this.playerPitService,
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
        tireWearFrontLeftPercent: (map['tireWearFrontLeftPercent'] as num?)?.toDouble(),
        tireWearFrontRightPercent: (map['tireWearFrontRightPercent'] as num?)?.toDouble(),
        tireWearRearLeftPercent: (map['tireWearRearLeftPercent'] as num?)?.toDouble(),
        tireWearRearRightPercent: (map['tireWearRearRightPercent'] as num?)?.toDouble(),
        tireCompound: map['tireCompound'] as String?,
        rivalPositions: (map['rivalPositions'] as Map<String, dynamic>?)?.map(
              (name, position) => MapEntry(name, (position as num).toInt()),
            ) ??
            const {},
        driversInPit: (map['driversInPit'] as Map<String, dynamic>?)?.map(
              (name, value) => MapEntry(name, PitLaneEntry.fromJson(value)),
            ) ??
            const {},
        traffic: TrafficMap.fromJson(map['traffic'] as Map<String, dynamic>?),
        playerInPit: map['playerInPit'] as bool? ?? false,
        playerPitService: map['playerPitService'] == null ? null : PitLaneEntry.fromJson(map['playerPitService']),
      );
}
