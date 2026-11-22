import 'package:shared_preferences/shared_preferences.dart';

/// How the race plan picks its tyre order.
enum StrategyStyle {
  /// The faster tyre first wherever you start: attack from the off.
  aggressive,

  /// By the grid: the faster tyre first from the front row, the slower
  /// one first from P4 down (see PitStopCalculator.startsNearFront).
  passive;

  String get label => switch (this) {
    aggressive => 'Aggressive',
    passive => 'Passive',
  };

  String get description => switch (this) {
    aggressive => 'The faster tyre first wherever you start -- attack from the off.',
    passive => 'By the grid: the faster tyre first from P1-P3, the slower one first from P4 down.',
  };

  static StrategyStyle fromName(String? name) =>
      StrategyStyle.values.where((s) => s.name == name).firstOrNull ?? StrategyStyle.passive;
}

/// How much Boxington says unprompted: each call is [CallPriority]
/// tagged, and the level picks which get through.
enum TalkLevel {
  /// The essentials only: pit, fuel, stint test, crash and rejoin calls.
  quiet,

  /// As well, the useful information: rivals, opponents' stops, tyres
  /// going off, spins, corner coaching.
  normal,

  /// All of that, and a short word on every lap.
  chatty;

  String get label => switch (this) {
    quiet => 'Quiet',
    normal => 'Normal',
    chatty => 'Chatty',
  };

  String get description => switch (this) {
    quiet => 'Only what you need: pit, fuel, stint test, crash and rejoin calls.',
    normal => 'Those, plus rivals, opponents\' stops, tyres going off, spins and corner coaching.',
    chatty => 'All of that, and a short word on every lap.',
  };

  bool allows(CallPriority priority) => priority.index <= index;

  static TalkLevel fromName(String? name) => TalkLevel.values.where((s) => s.name == name).firstOrNull ?? TalkLevel.normal;
}

/// What an unprompted call is: see [TalkLevel.allows].
enum CallPriority { essential, info, chat }

/// The driver's own settings, from the Profile page: their PSN ID (how
/// the app and Boxington know which car on the leaderboard is theirs),
/// the nickname Boxington calls them by now and then, and their
/// strategy style. Loaded once at start-up into [current].
class ProfileSettings {
  static const String defaultPsnId = 'Willy-SwerveX';

  final String psnId;

  /// What Boxington calls the driver, now and then (null: never by name).
  final String? nickname;

  final StrategyStyle strategyStyle;

  final TalkLevel talkLevel;

  /// The PS5's address for GT7 telemetry (null: the .env CONSOLE_IP).
  final String? consoleIp;

  /// The port the laptop's HUD reader sends to.
  final int hudPort;

  /// Whether there's a HUD reader at all: an HDMI splitter and a laptop
  /// reading GT7's screen (position, gaps, tyre wear, the tyre fitted,
  /// water). False: telemetry only -- those features are off, and the
  /// tyre is picked by hand.
  final bool hudReader;

  static const int defaultHudPort = 33746;

  const ProfileSettings({
    this.psnId = defaultPsnId,
    this.nickname,
    this.strategyStyle = StrategyStyle.passive,
    this.talkLevel = TalkLevel.normal,
    this.consoleIp,
    this.hudPort = defaultHudPort,
    this.hudReader = true,
  });

  /// The settings in use (see [load]); defaults until loaded.
  static ProfileSettings current = const ProfileSettings();

  static const _psnKey = 'profile_psn_id', _nicknameKey = 'profile_nickname', _styleKey = 'profile_strategy_style';
  static const _talkKey = 'profile_talk_level', _consoleKey = 'profile_console_ip', _hudPortKey = 'profile_hud_port';
  static const _hudReaderKey = 'profile_hud_reader';

  /// Reads the saved settings into [current].
  static Future<ProfileSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final psn = prefs.getString(_psnKey)?.trim();
    final nickname = prefs.getString(_nicknameKey)?.trim();
    final console = prefs.getString(_consoleKey)?.trim();
    final port = prefs.getInt(_hudPortKey);
    return current = ProfileSettings(
      psnId: psn == null || psn.isEmpty ? defaultPsnId : psn,
      nickname: nickname == null || nickname.isEmpty ? null : nickname,
      strategyStyle: StrategyStyle.fromName(prefs.getString(_styleKey)),
      talkLevel: TalkLevel.fromName(prefs.getString(_talkKey)),
      consoleIp: console == null || console.isEmpty ? null : console,
      hudPort: port != null && isValidPort(port) ? port : defaultHudPort,
      hudReader: prefs.getBool(_hudReaderKey) ?? true,
    );
  }

  /// Saves [settings] and makes them [current].
  static Future<void> save(ProfileSettings settings) async {
    current = settings;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_psnKey, settings.psnId);
    if (settings.nickname == null) {
      await prefs.remove(_nicknameKey);
    } else {
      await prefs.setString(_nicknameKey, settings.nickname!);
    }
    await prefs.setString(_styleKey, settings.strategyStyle.name);
    await prefs.setString(_talkKey, settings.talkLevel.name);
    if (settings.consoleIp == null) {
      await prefs.remove(_consoleKey);
    } else {
      await prefs.setString(_consoleKey, settings.consoleIp!);
    }
    await prefs.setInt(_hudPortKey, settings.hudPort);
    await prefs.setBool(_hudReaderKey, settings.hudReader);
  }

  /// An IPv4 address, e.g. 192.168.1.20.
  static bool isValidIp(String text) {
    final parts = text.trim().split('.');
    return parts.length == 4 && parts.every((p) => int.tryParse(p) != null && int.parse(p) >= 0 && int.parse(p) <= 255 && p.isNotEmpty);
  }

  static bool isValidPort(int port) => port >= 1024 && port <= 65535;
}
