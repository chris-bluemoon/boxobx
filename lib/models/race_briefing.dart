/// Tire compound names as used in GT7's own garage/race-settings UI --
/// kept as free-form strings rather than an enum since APRL's weekly
/// briefing can restrict compounds to whatever subset is allowed that
/// week (e.g. only Racing Hard/Medium, no Soft), and new compounds
/// (e.g. special event tires) shouldn't require an app update to use.
class RaceBriefing {
  /// Track name -- matched against assets/config/tracks_db.json where
  /// possible so the strategist has the real track length available,
  /// but kept as free text since APRL may run a track/layout not in
  /// that list (DLC tracks, reverse layouts, etc.).
  final String trackName;

  /// Car class/BoP group this race is restricted to. APRL races are
  /// always Gr.3, so this isn't exposed as a user-editable field on
  /// the briefing screen -- kept as a field (rather than removed
  /// outright) so the strategist prompt still has it as explicit
  /// context, and in case a future non-Gr.3 series needs it later.
  final String carClass;

  final int totalLaps;

  /// Optional additional time limit (minutes) on top of/instead of
  /// totalLaps -- some APRL formats are "45 minute race" rather than a
  /// pure lap count, so the strategist should know the race could end
  /// on time rather than lap completion.
  final int? raceLengthMinutes;

  /// GT7's own qualifying-format taxonomy. APRL races are always
  /// one-shot qualifying, so this isn't exposed as a user-editable
  /// field on the briefing screen -- kept as a field (rather than
  /// removed outright) so the strategist prompt still has it as
  /// explicit context, and in case a future series needs it later.
  final String qualifyingFormat;

  /// "Rolling Start" or "Standing Start". APRL races always use a
  /// Rolling Start, so this isn't exposed as a user-editable field on
  /// the briefing screen -- kept as a field (rather than removed
  /// outright) so the strategist prompt still has it as explicit
  /// context, and in case a future series needs it later.
  final String startType;

  /// Whether BoP and tuning are prohibited this week. APRL races always
  /// run with BoP ON (i.e. tuning/BoP is never prohibited), so this
  /// isn't exposed as a user-editable field on the briefing screen --
  /// kept as a field (rather than removed outright) so the strategist
  /// prompt still has it as explicit context, and in case a future
  /// series needs it later.
  final bool bopTuningProhibited;

  /// GT7's tyre wear rate multiplier for this race (e.g. 1x-10x) --
  /// scales how fast a compound's grip degrades, independent of fuel.
  final double tyreWearMultiplier;

  /// GT7's fuel consumption multiplier for this race (e.g. 1.0x, 2x,
  /// 3x) -- APRL briefings often mandate a non-default multiplier to
  /// force strategy, and it directly scales how fast startingFuelPercent
  /// will be burned.
  final double fuelConsumptionMultiplier;

  /// Refueling speed in litres/sec, as set by the race host -- governs
  /// how much time a pit stop costs beyond the fixed pit-lane loss.
  final double refuelingSpeedLitersPerSec;

  /// GT7's on-screen "Pit Stop Time" for this track, entered by the
  /// driver: the whole stop including service. Used as-is as the cost of
  /// a stop by the strategy, the rejoin forecast and the pit calls.
  /// Null = not entered (a default is assumed).
  final double? pitStopTimeSeconds;

  /// Starting fuel load, as a percentage of the tank (GT7's own
  /// in-race fuel display convention) -- APRL briefings specify this
  /// directly (e.g. "start on 100% fuel, no fuel multiplier").
  final double startingFuelPercent;

  /// Safety-margin fuel percent the driver wants remaining in the tank
  /// AT THE FINISH of the race (not per-stint) -- mirrors a standard
  /// sim-racing pit-calculator concept (a "finish reserve"): running a
  /// stint right to the theoretical empty point is risky if real
  /// consumption is even slightly worse than measured, so this amount
  /// is subtracted off the usable fuel before computing stint length.
  /// 0 (default) disables the margin entirely.
  final double finishFuelReservePercent;

  /// Maximum laps a single tire set should be run for, independent of
  /// fuel range -- mirrors a standard sim-racing pit-calculator concept
  /// ("maximum tyre stint"): even with a full tank, grip may fall off a
  /// cliff well before the fuel runs out, so stint length is the
  /// SHORTER of the fuel-based range and this cap. 0 (default) disables
  /// the cap entirely (stint length is fuel-range-only, as before).
  final int maxTyreStintLaps;

  /// Tire compounds permitted for this race (e.g. ["Racing Hard",
  /// "Racing Medium"]), in whatever order the driver listed them.
  /// APRL races always use GT7's "Racing" tyre category (never
  /// Comfort/Sports), and Intermediate/Heavy Wet are always legal
  /// regardless of the dry-tyre selection, so there's no separate
  /// "useable tyre category" field -- this list is the complete set.
  final List<String> availableTireCompounds;

  /// A single compound the race forces the driver to use at some point
  /// ("N/A" if none), matching GT7's "Mandatory Tyre Compound" setting.
  final String mandatoryTyreCompound;

  /// How many mandatory pit stops the regulations require (0 if none).
  final int mandatoryPitStopCount;

  /// Whether this race involves wet/changeable conditions at all --
  /// deliberately simplified to a toggle for now rather than a full
  /// lap-by-lap weather sequence (e.g. APRL's "R06/R05/C03/S14/..."
  /// codes), since that level of detail isn't yet consumed by the
  /// strategist model.
  final bool wetOrChangeableWeather;

  /// Any other free-text notes from the briefing the strategist should
  /// consider (grid penalties, race-specific quirks, etc.) --
  /// deliberately unstructured since a weekly briefing can mention
  /// almost anything not covered by the structured fields above.
  final String additionalNotes;

  const RaceBriefing({
    required this.trackName,
    this.carClass = 'Gr.3',
    required this.totalLaps,
    this.raceLengthMinutes,
    this.qualifyingFormat = 'One-shot qualifying',
    this.startType = 'Rolling Start',
    this.bopTuningProhibited = false,
    this.tyreWearMultiplier = 1.0,
    this.fuelConsumptionMultiplier = 1.0,
    this.refuelingSpeedLitersPerSec = 8.0,
    this.pitStopTimeSeconds,
    required this.startingFuelPercent,
    this.finishFuelReservePercent = 0.0,
    this.maxTyreStintLaps = 0,
    required this.availableTireCompounds,
    this.mandatoryTyreCompound = 'N/A',
    this.mandatoryPitStopCount = 0,
    this.wetOrChangeableWeather = false,
    this.additionalNotes = '',
  });

  factory RaceBriefing.fromMap(Map<String, dynamic> map) => RaceBriefing(
        trackName: map['trackName'] as String,
        carClass: map['carClass'] as String? ?? 'Gr.3',
        totalLaps: map['totalLaps'] as int,
        raceLengthMinutes: map['raceLengthMinutes'] as int?,
        qualifyingFormat: map['qualifyingFormat'] as String? ?? 'One-shot qualifying',
        startType: map['startType'] as String? ?? 'Rolling Start',
        bopTuningProhibited: map['bopTuningProhibited'] as bool? ?? false,
        tyreWearMultiplier: (map['tyreWearMultiplier'] as num?)?.toDouble() ?? 1.0,
        fuelConsumptionMultiplier: (map['fuelConsumptionMultiplier'] as num?)?.toDouble() ?? 1.0,
        refuelingSpeedLitersPerSec: (map['refuelingSpeedLitersPerSec'] as num?)?.toDouble() ?? 8.0,
        pitStopTimeSeconds: (map['pitStopTimeSeconds'] as num?)?.toDouble(),
        startingFuelPercent: (map['startingFuelPercent'] as num).toDouble(),
        finishFuelReservePercent: (map['finishFuelReservePercent'] as num?)?.toDouble() ?? 0.0,
        maxTyreStintLaps: map['maxTyreStintLaps'] as int? ?? 0,
        availableTireCompounds: (map['availableTireCompounds'] as List).cast<String>(),
        mandatoryTyreCompound: map['mandatoryTyreCompound'] as String? ?? 'N/A',
        mandatoryPitStopCount: map['mandatoryPitStopCount'] as int? ?? 0,
        wetOrChangeableWeather: map['wetOrChangeableWeather'] as bool? ?? false,
        additionalNotes: map['additionalNotes'] as String? ?? '',
      );

  Map<String, dynamic> toMap() => {
        'trackName': trackName,
        'carClass': carClass,
        'totalLaps': totalLaps,
        'raceLengthMinutes': raceLengthMinutes,
        'qualifyingFormat': qualifyingFormat,
        'startType': startType,
        'bopTuningProhibited': bopTuningProhibited,
        'tyreWearMultiplier': tyreWearMultiplier,
        'fuelConsumptionMultiplier': fuelConsumptionMultiplier,
        'refuelingSpeedLitersPerSec': refuelingSpeedLitersPerSec,
        'pitStopTimeSeconds': pitStopTimeSeconds,
        'startingFuelPercent': startingFuelPercent,
        'finishFuelReservePercent': finishFuelReservePercent,
        'maxTyreStintLaps': maxTyreStintLaps,
        'availableTireCompounds': availableTireCompounds,
        'mandatoryTyreCompound': mandatoryTyreCompound,
        'mandatoryPitStopCount': mandatoryPitStopCount,
        'wetOrChangeableWeather': wetOrChangeableWeather,
        'additionalNotes': additionalNotes,
      };
}

