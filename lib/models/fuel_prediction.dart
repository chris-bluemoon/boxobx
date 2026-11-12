/// Result of the FuelPredictor's lap-based consumption analysis (see
/// fuel_predictor.dart). Replaces the raw "FUEL: 42%" dashboard card --
/// that raw percentage is already shown directly on GT7's own HUD, so
/// showing it a second time wastes dashboard space better spent on a
/// derived prediction the driver can't read off the game screen
/// directly: which lap you'll need to pit on.
class FuelPrediction {
  /// Predicted lap number you'll run out of fuel on, if you don't pit.
  /// Null if there isn't yet enough data (needs at least one fully
  /// completed lap to measure a consumption rate from).
  final int? predictedEmptyLap;

  /// Average fuel percent consumed per lap, over the recent-lap window
  /// (see FuelPredictor.lapHistoryWindow). Null with insufficient data.
  final double? percentPerLap;

  /// True once at least one full lap of consumption data has been
  /// gathered, so the UI can distinguish "still warming up" from "no
  /// fuel being consumed" (e.g. an electric car, or sitting in a menu).
  final bool hasEnoughData;

  const FuelPrediction({
    this.predictedEmptyLap,
    this.percentPerLap,
    this.hasEnoughData = false,
  });

  factory FuelPrediction.insufficientData() => const FuelPrediction();
}
