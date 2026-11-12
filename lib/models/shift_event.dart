/// Classification of a single detected upshift's timing against the
/// car's power band (see PowerBandConfig).
enum ShiftTiming {
  /// Shifted well before the optimal window -- short-shifting, leaving
  /// power on the table.
  early,

  /// Shifted within the optimal window -- good shift.
  good,

  /// Shifted well past the optimal window -- over-revving, already
  /// losing acceleration before the shift happened.
  late,
}

/// A single recorded upshift: the RPM the engine was at the instant
/// before the gear count increased, and how that RPM classifies against
/// the configured power band.
class ShiftEvent {
  final double rpmAtShift;
  final ShiftTiming timing;

  const ShiftEvent({required this.rpmAtShift, required this.timing});
}
