import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:boxbox/services/app_database.dart';
import 'package:boxbox/services/aprl_leaderboard_service.dart';

/// Every test gets a fresh in-memory app database, and no test reaches
/// the APRL leaderboard over the network.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  AprlLeaderboardService.enabled = false;
  setUp(AppDatabase.useInMemoryForTests);
  await testMain();
}
