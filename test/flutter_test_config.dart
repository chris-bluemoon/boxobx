import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:boxbox/services/app_database.dart';

/// Every test gets a fresh in-memory app database.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  setUp(AppDatabase.useInMemoryForTests);
  await testMain();
}
