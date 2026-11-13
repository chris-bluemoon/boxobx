/// Apex Point Racing League, GT3 Clubman Division -- the same fixed
/// roster of PSN gamertags used by the laptop OCR relay to CORRECT
/// driver-name misreads (see laptop_ocr/driver_roster.py's
/// LEAGUE_ROSTER). Duplicated here (rather than shared via some
/// cross-language config file) since the Dart app and the Python relay
/// are two completely separate processes connected only by a UDP JSON
/// feed -- there's no existing mechanism to share a single source of
/// truth between them, and a league roster changes rarely enough
/// (new driver joins/leaves at most once every few weeks) that keeping
/// these two lists in sync by hand is an acceptable trade-off versus
/// building shared-config infrastructure for it.
///
/// IMPORTANT: if the roster changes, update BOTH this list and
/// laptop_ocr/driver_roster.py's LEAGUE_ROSTER to match, or OCR
/// correction and in-app driver selection (standings entry, rival
/// picking) will silently drift out of sync with each other.
const List<String> leagueRoster = [
  'Salty-067',
  'Chuck_E82',
  'Willy-SwerveX',
  'sideshow-308',
  'warrenb313-wazza',
  'ryan_tr17',
  'BlackSugar73',
  'SushiSuzie',
  'Daywalkar86',
  'Doogle_Dave',
  'L0k1_317',
  'Morgsxr6',
  'The_Elder',
  'Halfback66',
  'TCR_Camcorp',
  'joeysnarf',
  'LocoRx2',
  'bennykezza',
];
