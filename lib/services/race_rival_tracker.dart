import '../models/hud_overlay_data.dart';
import '../models/opponent_pit_stop.dart';
import '../models/traffic_map.dart';

/// What we know about the race rival right now (see RaceRivalTracker).
class RaceRivalState {
  final String name;

  /// Last confirmed position, and whether it was read in the last few
  /// seconds (the leaderboard only shows rows near ours).
  final int? position;
  final bool positionLive;

  /// Gap on the road: positive = behind us, negative = ahead. From the
  /// leaderboard when the rival's row and ours are both visible, else
  /// from their arrow on the course map.
  final double? gapSeconds;
  final String? gapSource;

  /// True while their arrow is being followed on the course map.
  final bool onMap;

  /// Their recent lap times as timed on the map (oldest first), and ours.
  final List<double> lapSeconds;
  final List<double> ourLapSeconds;

  final bool inPit;

  /// Stopped or crawling on track right now (a spin, an off).
  final bool inTrouble;

  const RaceRivalState({
    required this.name,
    this.position,
    this.positionLive = false,
    this.gapSeconds,
    this.gapSource,
    this.onMap = false,
    this.lapSeconds = const [],
    this.ourLapSeconds = const [],
    this.inPit = false,
    this.inTrouble = false,
  });

  Map<String, dynamic> toPromptContext(List<OpponentPitStop> pitStops) => {
    'name': name,
    if (position != null) 'position': position,
    if (position != null && !positionLive) 'positionIsLastKnown': true,
    if (gapSeconds != null) 'gapSeconds': double.parse(gapSeconds!.toStringAsFixed(1)),
    if (gapSource != null) 'gapSource': gapSource,
    if (lapSeconds.isNotEmpty) 'recentLapSeconds': [for (final s in lapSeconds) double.parse(s.toStringAsFixed(1))],
    if (ourLapSeconds.isNotEmpty)
      'ourRecentLapSeconds': [for (final s in ourLapSeconds) double.parse(s.toStringAsFixed(1))],
    'inPit': inPit,
    if (inTrouble) 'stoppedOnTrack': true,
    'pitStops': [for (final s in pitStops) if (s.driver == name) s.toPromptContext()],
  };
}

/// Something about the rival worth an unprompted call.
class RivalEvent {
  final String prompt;
  const RivalEvent(this.prompt);

  @override
  String toString() => 'RivalEvent($prompt)';
}

/// Follows one chosen race rival (Race Mode) using the leaderboard and
/// the course map together, and decides when Boxington should mention
/// them: position changes and spins/stops as they happen, plus a pace
/// and gap update every [updateEveryLaps] of our laps. Their pit stops
/// are called by the general opponent-pit call, which names them as
/// the rival.
///
/// * **Leaderboard** (only rows near ours, plus the top few): position,
///   the gap to us when every row between us is readable, pit marker.
/// * **Course map** (every car, but anonymous arrows): the rival's arrow
///   is picked out using the leaderboard gap -- the car that many
///   seconds away -- and then followed from frame to frame. That gives
///   their lap times, their gap when they're off the leaderboard, and
///   whether they've stopped or slowed right down on track.
///
/// Following an arrow can go wrong in a bunch of cars; it's re-locked
/// whenever the leaderboard gap is known, and dropped after
/// [lostAfterS] without a sighting.
class RaceRivalTracker {
  static const int updateEveryLaps = 3;
  static const int positionStabilityReadings = 2;
  static const double positionLiveS = 5;
  static const double boardGapFreshS = 2;

  // Map matching.
  static const double anchorToleranceS = 1.5;
  static const double anchorAmbiguityS = 0.8;
  static const double lostAfterS = 3;
  static const double maxRelockJump = 30; // lap-progress units

  // Trouble: crawling at under [troubleRateFraction] of normal pace for
  // [troubleForS], away from the pits.
  static const double troubleRateFraction = 0.25;
  static const double troubleForS = 2;
  static const double recoveredRateFraction = 0.6;
  static const double pitZoneProgress = 60;

  String? _rival;
  String? get rival => _rival;

  /// Chooses the rival (null = none). Starts tracking afresh.
  void setRival(String? name) {
    if (name == _rival) return;
    _rival = name;
    reset();
  }

  // Leaderboard.
  int? _position;
  int? _candidatePosition;
  int _candidateCount = 0;
  DateTime? _positionSeenAt;
  double? _boardGap;
  DateTime? _boardGapAt;
  bool _inPit = false;

  // Map.
  double? _progress;
  DateTime? _progressAt;
  DateTime? _lastSeenOnMap;
  double? _rate; // lap-progress units per second
  DateTime? _lastCrossAt;
  final List<double> _lapSeconds = [];
  bool _hasBeenAtPace = false;
  DateTime? _slowSince;
  DateTime? _fastSince;
  bool _inTrouble = false;

  // Our laps and the periodic update.
  int _ourLap = 0;
  int _lastUpdateLap = 0;
  final List<double> _ourLapSeconds = [];
  double? _gapAtLastUpdate;

  RaceRivalState? _state;
  RaceRivalState? get state => _state;

  /// Feeds one relay reading (with our lap from telemetry). Returns the
  /// calls to make now, if any.
  List<RivalEvent> update(
    HudOverlayData hud, {
    required int ourLap,
    required int ourLastLapMs,
    double? pitLapProgress,
    required DateTime now,
  }) {
    final name = _rival;
    if (name == null) return const [];
    final events = <RivalEvent>[];

    _readLeaderboard(hud, name, now, events);
    _followOnMap(hud.traffic, now, pitLapProgress, events);
    _trackOurLaps(ourLap, ourLastLapMs, events);

    _state = RaceRivalState(
      name: name,
      position: _position,
      positionLive: _positionSeenAt != null && _secs(now, _positionSeenAt!) <= positionLiveS,
      gapSeconds: _gap(hud.traffic, now),
      gapSource: _gapSource(hud.traffic, now),
      onMap: _progress != null,
      lapSeconds: List.unmodifiable(_lapSeconds),
      ourLapSeconds: List.unmodifiable(_ourLapSeconds),
      inPit: _inPit,
      inTrouble: _inTrouble,
    );
    return events;
  }

  // --- leaderboard ---------------------------------------------------------

  void _readLeaderboard(HudOverlayData hud, String name, DateTime now, List<RivalEvent> events) {
    final rows = hud.standings;
    final rivalIndex = rows.indexWhere((r) => r.name == name && !r.isPlayer);
    if (rivalIndex < 0) {
      _inPit = false;
      return;
    }
    final row = rows[rivalIndex];
    _inPit = row.inPit;

    final playerIndex = rows.indexWhere((r) => r.isPlayer);
    final ourPosition = playerIndex >= 0 ? rows[playerIndex].position ?? hud.gridPosition : hud.gridPosition;

    var gap = _gapBetween(rows, rivalIndex, playerIndex);
    final aheadGap = hud.gapAheadSeconds;
    if (gap == null && hud.driverAhead == name && aheadGap != null) gap = -aheadGap;
    if (gap == null && hud.driverBehind == name) gap = hud.gapBehindSeconds;
    if (gap != null) {
      _boardGap = gap;
      _boardGapAt = now;
    }

    final position = row.position;
    if (position == null) return;
    _positionSeenAt = now;
    if (_position == null) {
      _position = position;
      return;
    }
    if (position == _position) {
      _candidatePosition = null;
      _candidateCount = 0;
      return;
    }
    _candidateCount = position == _candidatePosition ? _candidateCount + 1 : 1;
    _candidatePosition = position;
    if (_candidateCount < positionStabilityReadings) return;

    final before = _position!;
    _position = position;
    _candidatePosition = null;
    _candidateCount = 0;
    final moved = position < before ? 'moved up to' : 'dropped back to';
    final relation = ourPosition <= 0
        ? ''
        : position < ourPosition
            ? ', ahead of us (we are P$ourPosition)'
            : ', behind us (we are P$ourPosition)';
    final passing = ourPosition > 0 && (before < ourPosition) != (position < ourPosition)
        ? (position < ourPosition ? ' They have just got past us.' : ' We are now ahead of them.')
        : '';
    events.add(RivalEvent(
      'RACE RIVAL: $name has just $moved P$position (was P$before)$relation.$passing '
      'Call it out briefly, with what it means for us.',
    ));
  }

  /// Signed gap (+ = rival behind) summed over the intervals between the
  /// two rows -- only when every row in between is there and readable.
  static double? _gapBetween(List<StandingsRow> rows, int rivalIndex, int playerIndex) {
    if (playerIndex < 0) return null;
    final top = rivalIndex < playerIndex ? rivalIndex : playerIndex;
    final bottom = rivalIndex < playerIndex ? playerIndex : rivalIndex;
    final topPosition = rows[top].position;
    final bottomPosition = rows[bottom].position;
    if (topPosition != null && bottomPosition != null && bottomPosition - topPosition != bottom - top) {
      return null; // positions missing from the list between us
    }
    var sum = 0.0;
    for (var i = top + 1; i <= bottom; i++) {
      final gap = rows[i].gapToAhead;
      if (gap == null) return null;
      sum += gap;
    }
    return rivalIndex < playerIndex ? -sum : sum;
  }

  // --- course map ----------------------------------------------------------

  void _followOnMap(TrafficMap map, DateTime now, double? pitLapProgress, List<RivalEvent> events) {
    final lap = map.lapSeconds;
    if (!map.trackReady || lap == null || lap <= 0 || map.cars.isEmpty) {
      _maybeLose(now);
      return;
    }
    final normalRate = 1000 / lap;

    // Lock on (or re-lock) from the leaderboard gap.
    final boardGap = _freshBoardGap(now);
    if (boardGap != null) {
      final scored = [
        for (final car in map.cars)
          if (map.relativeSeconds(car) != null) (car, (map.relativeSeconds(car)! - boardGap).abs()),
      ]..sort((a, b) => a.$2.compareTo(b.$2));
      if (scored.isNotEmpty &&
          scored.first.$2 <= anchorToleranceS &&
          (scored.length < 2 || scored[1].$2 - scored.first.$2 >= anchorAmbiguityS)) {
        final anchored = scored.first.$1.lapProgress;
        final current = _progress;
        if (current == null || _circular(anchored - current).abs() > maxRelockJump) {
          // A new lock (or a correction): lap timing restarts.
          _progress = anchored;
          _progressAt = now;
          _lastSeenOnMap = now;
          _lastCrossAt = null;
          _rate = null;
          return;
        }
      }
    }

    final progress = _progress;
    final at = _progressAt;
    if (progress == null || at == null) return;
    final dt = _secs(now, at);
    if (dt <= 0) return;

    final rate = _rate ?? normalRate;
    final expected = rate * dt;
    final slack = 15 + normalRate * 1.5;
    TrafficCar? best;
    var bestMiss = double.infinity;
    double bestMove = 0;
    for (final car in map.cars) {
      final move = _circular(car.lapProgress - progress);
      if (move < -8 || move > expected + slack) continue;
      final miss = (move - expected).abs();
      if (miss < bestMiss) {
        best = car;
        bestMiss = miss;
        bestMove = move;
      }
    }
    if (best == null) {
      _maybeLose(now);
      return;
    }

    final observed = bestMove.clamp(0, double.infinity) / dt;
    _rate = _rate == null ? observed : _rate! * 0.65 + observed * 0.35;
    if (progress + bestMove >= 1000) _completeLap(now, lap);
    _progress = best.lapProgress;
    _progressAt = now;
    _lastSeenOnMap = now;

    _checkTrouble(map, best, normalRate, now, pitLapProgress, events);
  }

  void _completeLap(DateTime now, double ourMapLap) {
    final last = _lastCrossAt;
    _lastCrossAt = now;
    if (last == null) return;
    final seconds = _secs(now, last);
    // Anything far off our own lap time is a tracking slip, not a lap.
    if (seconds < ourMapLap * 0.75 || seconds > ourMapLap * 1.5) return;
    _lapSeconds.add(seconds);
    if (_lapSeconds.length > 5) _lapSeconds.removeAt(0);
  }

  void _checkTrouble(
    TrafficMap map,
    TrafficCar car,
    double normalRate,
    DateTime now,
    double? pitLapProgress,
    List<RivalEvent> events,
  ) {
    final rate = _rate ?? normalRate;
    if (rate >= recoveredRateFraction * normalRate) {
      _hasBeenAtPace = true;
      _slowSince = null;
      final fastSince = _fastSince ??= now;
      if (_inTrouble && _secs(now, fastSince) >= 5) _inTrouble = false;
      return;
    }
    _fastSince = null;
    if (rate >= troubleRateFraction * normalRate || !_hasBeenAtPace || _inTrouble || _inPit) return;
    final since = _slowSince ??= now;
    if (_secs(now, since) < troubleForS) return;

    _inTrouble = true;
    final name = _rival!;
    final nearPits = pitLapProgress != null && _circular(car.lapProgress - pitLapProgress).abs() <= pitZoneProgress;
    final relative = map.relativeSeconds(car);
    final where = relative == null
        ? ''
        : relative >= 0
            ? ' about ${relative.toStringAsFixed(0)} seconds behind us on the road'
            : ' about ${(-relative).toStringAsFixed(0)} seconds up the road';
    events.add(RivalEvent(nearPits
        ? 'RACE RIVAL: $name has slowed right down by the pit entry$where -- looks like they are pitting. '
            'Call it out briefly; we will see what tyres they come out on.'
        : 'RACE RIVAL: $name has stopped or slowed right down on track$where -- looks like a spin or an off. '
            'Call it out straight away, with what it means for us.'));
  }

  void _maybeLose(DateTime now) {
    final seen = _lastSeenOnMap;
    if (_progress != null && seen != null && _secs(now, seen) > lostAfterS) {
      _progress = null;
      _progressAt = null;
      _rate = null;
      _lastCrossAt = null;
      _slowSince = null;
    }
  }

  double? _freshBoardGap(DateTime now) {
    final at = _boardGapAt;
    return at != null && _secs(now, at) <= boardGapFreshS ? _boardGap : null;
  }

  double? _gap(TrafficMap map, DateTime now) {
    final board = _freshBoardGap(now);
    if (board != null) return board;
    final progress = _progress;
    if (progress == null) return null;
    final car = map.cars.where((c) => c.lapProgress == progress).firstOrNull;
    return car == null ? null : map.relativeSeconds(car);
  }

  String? _gapSource(TrafficMap map, DateTime now) {
    if (_freshBoardGap(now) != null) return 'leaderboard';
    return _gap(map, now) == null ? null : 'courseMap';
  }

  // --- our laps and the periodic update -----------------------------------

  void _trackOurLaps(int ourLap, int ourLastLapMs, List<RivalEvent> events) {
    if (ourLap == _ourLap) return;
    final firstReading = _ourLap == 0;
    _ourLap = ourLap;
    if (firstReading) {
      _lastUpdateLap = ourLap;
      return;
    }
    if (ourLastLapMs > 0) {
      _ourLapSeconds.add(ourLastLapMs / 1000);
      if (_ourLapSeconds.length > 5) _ourLapSeconds.removeAt(0);
    }
    if (ourLap - _lastUpdateLap < updateEveryLaps) return;
    _lastUpdateLap = ourLap;

    final state = _state;
    if (state == null) return;
    final facts = <String>[
      if (state.position != null) '${state.positionLive ? '' : 'last seen in '}P${state.position}',
      if (state.gapSeconds != null)
        state.gapSeconds! >= 0
            ? '${state.gapSeconds!.toStringAsFixed(1)} s behind us'
            : '${(-state.gapSeconds!).toStringAsFixed(1)} s ahead of us',
      if (state.gapSeconds != null && _gapAtLastUpdate != null) _trend(_gapAtLastUpdate!, state.gapSeconds!),
      if (_lapSeconds.isNotEmpty) 'their recent laps ${_lapSeconds.map((s) => s.toStringAsFixed(1)).join(', ')} s',
      if (_ourLapSeconds.isNotEmpty) 'ours ${_ourLapSeconds.map((s) => s.toStringAsFixed(1)).join(', ')} s',
    ];
    _gapAtLastUpdate = state.gapSeconds;
    if (state.gapSeconds == null && _lapSeconds.isEmpty) return; // nothing worth saying
    events.add(RivalEvent(
      'RACE RIVAL UPDATE on ${state.name}: ${facts.join('; ')}. '
      'In one short transmission give the driver the rival picture -- where they are, '
      'whether we are gaining or losing, and who is quicker. Do not read out every number.',
    ));
  }

  static String _trend(double before, double now) {
    // Positive gap = they're behind: growing means we're pulling away.
    final change = now.abs() - before.abs();
    if (change.abs() < 0.3) return 'gap about the same as $updateEveryLaps laps ago';
    final ahead = now < 0;
    final growing = change > 0;
    final weAreGaining = ahead ? !growing : growing;
    return '${weAreGaining ? 'we have gained' : 'we have lost'} ${change.abs().toStringAsFixed(1)} s on them in $updateEveryLaps laps';
  }

  /// Session end. The chosen rival is kept.
  void reset() {
    _position = null;
    _candidatePosition = null;
    _candidateCount = 0;
    _positionSeenAt = null;
    _boardGap = null;
    _boardGapAt = null;
    _inPit = false;
    _progress = null;
    _progressAt = null;
    _lastSeenOnMap = null;
    _rate = null;
    _lastCrossAt = null;
    _lapSeconds.clear();
    _hasBeenAtPace = false;
    _slowSince = null;
    _fastSince = null;
    _inTrouble = false;
    _ourLap = 0;
    _lastUpdateLap = 0;
    _ourLapSeconds.clear();
    _gapAtLastUpdate = null;
    _state = null;
  }

  /// Lap-progress difference wrapped to (-500, 500].
  static double _circular(double d) {
    var r = d % 1000;
    if (r > 500) r -= 1000;
    return r;
  }

  static double _secs(DateTime a, DateTime b) => a.difference(b).inMicroseconds / 1e6;
}
