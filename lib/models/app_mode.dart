/// Which of the app's three screens/jobs is active: decides which
/// unprompted calls Boxington makes, which widgets show, and where laps are
/// recorded.
///
/// * [race]: race calls and widgets; laps logged as stints too, so race
///   data feeds the strategy calculator.
/// * [practice] ("Stint Testing"): the test plan -- full-tank stints per
///   compound, logged as stints.
/// * [timeTrial] ("Time Trialing"): pure qualifying pace -- lap times
///   only, kept separate from the stint data (a low-fuel qualifying lap
///   would skew fuel and wear figures), as the pace baseline.
enum AppMode {
  race,
  practice,
  timeTrial;

  /// Unprompted calls and race widgets that only make sense in a race.
  bool get pitCalls => this == race;
  bool get rivalCallouts => this == race;
  bool get opponentPitCallouts => this == race;
  bool get trafficChip => this == race;

  /// Boxington's "biggest loss" call after each lap (see CornerReport).
  bool get cornerCalls => this == timeTrial;

  /// The test plan and Boxington's "test complete" call.
  bool get testPlan => this == practice;

  /// Where completed laps go: stints (practice log) or time-trial laps.
  bool get logsStintLaps => this != timeTrial;
  bool get logsTimeTrialLaps => this == timeTrial;

  String get label => switch (this) {
    race => 'RACE MODE',
    practice => 'STINT TESTING',
    timeTrial => 'TIME TRIALING',
  };

  static AppMode fromName(String? name) => switch (name) {
    'race' => race,
    'timeTrial' => timeTrial,
    _ => practice,
  };
}
