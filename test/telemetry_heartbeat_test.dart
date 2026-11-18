// The PS5 being unreachable must not stop telemetry: a failed heartbeat
// is retried a second later, and the worker keeps running.
import 'package:flutter_test/flutter_test.dart';

import 'package:boxbox/models/connection_status.dart';
import 'package:boxbox/services/telemetry_udp_service.dart';

void main() {
  test('a heartbeat that fails to send (here: broadcast without permission) does not kill the worker', () async {
    final service = TelemetryUdpService();
    addTearDown(service.dispose);
    final statuses = <ConnectionStatus>[];
    final sub = service.statusStream.listen(statuses.add);
    addTearDown(sub.cancel);

    await service.start('255.255.255.255'); // every send throws a SocketException
    await Future<void>.delayed(const Duration(milliseconds: 2500)); // 3 heartbeats

    // Every failure was handled inside the worker: none escaped.
    expect(service.workerErrors, 0);
    expect(statuses, isNot(contains(ConnectionStatus.live)));
  });
}
