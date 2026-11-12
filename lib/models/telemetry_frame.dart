/// Immutable snapshot of raw UDP telemetry data decoded at 60Hz
/// from the console's network telemetry stream (Component A).
class TelemetryFrame {
  final double rpm;
  final double speedKmh;
  final int gear;

  final double posX;
  final double posY;
  final double posZ;

  final double lapDistance;
  final double trackLength;

  final double fuelPercent;
  final List<double> tireTemps; // [FL, FR, RL, RR]

  /// Current lap number (1-indexed) and total laps for the session, as
  /// reported directly by GT7's packet (offset 0x74, two int16 values).
  /// totalLaps is -1 for sessions with no fixed lap count (e.g. some
  /// Time Trial/practice sessions).
  final int currentLap;
  final int totalLaps;

  /// Last completed lap time, in milliseconds, as reported directly by
  /// GT7's packet (offset 0x7C, int32) -- -1 if no lap has completed
  /// yet this session. Used by TireWearTracker as a proxy for tire
  /// degradation (GT7's telemetry packet has no tire-wear-percentage
  /// field at all; lap-time degradation across consecutive laps on the
  /// same tire is the closest available real signal).
  final int lastLapTimeMs;

  /// Best lap time this session, in milliseconds (offset 0x78, int32)
  /// -- -1 if no lap has completed yet. Kept alongside lastLapTimeMs
  /// since comparing against the session best (rather than only the
  /// immediately preceding lap) gives a cleaner degradation baseline.
  final int bestLapTimeMs;

  const TelemetryFrame({
    required this.rpm,
    required this.speedKmh,
    required this.gear,
    required this.posX,
    required this.posY,
    required this.posZ,
    required this.lapDistance,
    required this.trackLength,
    required this.fuelPercent,
    required this.tireTemps,
    this.currentLap = 0,
    this.totalLaps = -1,
    this.lastLapTimeMs = -1,
    this.bestLapTimeMs = -1,
  });

  factory TelemetryFrame.empty() => const TelemetryFrame(
        rpm: 0,
        speedKmh: 0,
        gear: 0,
        posX: 0,
        posY: 0,
        posZ: 0,
        lapDistance: 0,
        trackLength: 0,
        fuelPercent: 0,
        tireTemps: [0, 0, 0, 0],
        currentLap: 0,
        totalLaps: -1,
        lastLapTimeMs: -1,
        bestLapTimeMs: -1,
      );

  Map<String, dynamic> toMap() => {
        'rpm': rpm,
        'speedKmh': speedKmh,
        'gear': gear,
        'posX': posX,
        'posY': posY,
        'posZ': posZ,
        'lapDistance': lapDistance,
        'trackLength': trackLength,
        'fuelPercent': fuelPercent,
        'tireTemps': tireTemps,
        'currentLap': currentLap,
        'totalLaps': totalLaps,
        'lastLapTimeMs': lastLapTimeMs,
        'bestLapTimeMs': bestLapTimeMs,
      };

  factory TelemetryFrame.fromMap(Map<String, dynamic> map) => TelemetryFrame(
        rpm: (map['rpm'] as num).toDouble(),
        speedKmh: (map['speedKmh'] as num).toDouble(),
        gear: (map['gear'] as num).toInt(),
        posX: (map['posX'] as num).toDouble(),
        posY: (map['posY'] as num).toDouble(),
        posZ: (map['posZ'] as num).toDouble(),
        lapDistance: (map['lapDistance'] as num).toDouble(),
        trackLength: (map['trackLength'] as num).toDouble(),
        fuelPercent: (map['fuelPercent'] as num).toDouble(),
        tireTemps: (map['tireTemps'] as List).map((e) => (e as num).toDouble()).toList(),
        currentLap: (map['currentLap'] as num?)?.toInt() ?? 0,
        totalLaps: (map['totalLaps'] as num?)?.toInt() ?? -1,
        lastLapTimeMs: (map['lastLapTimeMs'] as num?)?.toInt() ?? -1,
        bestLapTimeMs: (map['bestLapTimeMs'] as num?)?.toInt() ?? -1,
      );
}
