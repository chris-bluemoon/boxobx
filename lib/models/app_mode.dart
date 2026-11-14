/// Practice vs race: decides which UNPROMPTED calls Gunther makes and
/// which race-only widgets show. Laps, fuel, tyre wear and pit loss are
/// recorded in both modes, so race data feeds the strategy calculator
/// too, and push-to-talk works the same in both.
enum AppMode {
  practice,
  race;

  /// Unprompted calls and race widgets that only make sense in a race.
  bool get pitCalls => this == race;
  bool get rivalCallouts => this == race;
  bool get opponentPitCallouts => this == race;
  bool get trafficChip => this == race;

  /// The practice test plan's chip and Gunther's test calls (target
  /// reached / wrong tyre or fuel for the planned test).
  bool get testPlan => this == practice;

  String get label => this == race ? 'RACE MODE' : 'PRACTICE MODE';

  static AppMode fromName(String? name) => name == 'race' ? race : practice;
}
