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

  /// GT7's status bitfield (offset 0x8E, int16) -- see the [TelemetryFlags]
  /// constants. Defaults to [TelemetryFlags.carOnTrack] so a frame built
  /// without flags (tests, older call sites) is treated as live driving.
  final int flags;

  /// Throttle and brake pedal input, 0-100 (offsets 0x91/0x92, one
  /// unsigned byte each, 0-255 on the wire).
  final double throttlePercent;
  final double brakePercent;

  /// GT7's internal car ID (offset 0x124, int32), e.g. 3218 for the BMW
  /// M6 GT3 Endurance Model '16 -- see PowerBandConfig.forCar. 0 when
  /// unknown.
  final int carCode;

  /// The car's own rev-indicator range as GT7 reports it (offsets
  /// 0x88/0x8A, int16): where the shift lights start, and where they
  /// flash. Used as a fallback power band for cars without hand-tuned
  /// shift points. 0 when unknown.
  final int minAlertRpm;
  final int maxAlertRpm;

  /// GT7's packet counter (offset 0x70, int32): one per 1/60 s of game
  /// time, so differences between packets are a precise clock even if
  /// some packets are lost on Wi-Fi (see SectorCalculator). 0 if unknown.
  final int packetId;

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
    this.flags = TelemetryFlags.carOnTrack,
    this.throttlePercent = 0,
    this.brakePercent = 0,
    this.carCode = 0,
    this.minAlertRpm = 0,
    this.maxAlertRpm = 0,
    this.packetId = 0,
  });

  bool get isCarOnTrack => flags & TelemetryFlags.carOnTrack != 0;
  bool get isPaused => flags & TelemetryFlags.paused != 0;
  bool get isLoading => flags & TelemetryFlags.loadingOrProcessing != 0;

  /// True only while actually driving: on track, not paused, not
  /// loading. GT7 keeps streaming the last values (frozen) in menus,
  /// pause screens and loading, so anything that accumulates per-lap
  /// data should only consume frames where this is true.
  bool get isDriving => isCarOnTrack && !isPaused && !isLoading;

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
    flags: 0,
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
    'flags': flags,
    'throttlePercent': throttlePercent,
    'brakePercent': brakePercent,
    'carCode': carCode,
    'minAlertRpm': minAlertRpm,
    'maxAlertRpm': maxAlertRpm,
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
    flags: (map['flags'] as num?)?.toInt() ?? TelemetryFlags.carOnTrack,
    throttlePercent: (map['throttlePercent'] as num?)?.toDouble() ?? 0,
    brakePercent: (map['brakePercent'] as num?)?.toDouble() ?? 0,
    carCode: (map['carCode'] as num?)?.toInt() ?? 0,
    minAlertRpm: (map['minAlertRpm'] as num?)?.toInt() ?? 0,
    maxAlertRpm: (map['maxAlertRpm'] as num?)?.toInt() ?? 0,
  );
}

/// Bits of GT7's status field (packet offset 0x8E), as documented by
/// the community decoders (PDTools' SimulatorFlags, gt7dashboard).
abstract final class TelemetryFlags {
  static const int carOnTrack = 1 << 0;
  static const int paused = 1 << 1;
  static const int loadingOrProcessing = 1 << 2;
  static const int inGear = 1 << 3;
  static const int hasTurbo = 1 << 4;
  static const int revLimiterAlert = 1 << 5;
  static const int handBrake = 1 << 6;
  static const int lights = 1 << 7;
  static const int highBeam = 1 << 8;
  static const int lowBeam = 1 << 9;
  static const int asm = 1 << 10;
  static const int tcs = 1 << 11;
}
