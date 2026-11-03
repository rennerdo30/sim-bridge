import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bridge/gateway_readiness.dart';

void main() {
  Map<String, dynamic> healthy() => {
    'receiveSmsGranted': true,
    'sendSmsGranted': true,
    'readPhoneStateGranted': true,
    'notificationsEnabled': true,
    'batteryExempt': true,
    'backgroundRestricted': false,
    'backgroundRestrictionCheckSupported': true,
    'manufacturerAutostartRequired': false,
    'deviceBuildFingerprint': 'build-A',
    'running': true,
    'ready': true,
    'relayOnline': true,
    'state': 'running',
    'lastSyncAgeMs': 100,
    'pending': 0,
  };
  GatewayReadiness project(
    Map<String, dynamic> status, {
    int? age = 0,
    String? confirmation,
  }) => GatewayReadiness(
    status: status,
    nativeCheckAgeMs: age,
    confirmedFingerprint: confirmation,
    confirmedAt: confirmation == null ? null : DateTime(2026),
  );
  test('relay connectivity cannot hide missing RECEIVE_SMS', () {
    final checks = project({...healthy(), 'receiveSmsGranted': false});
    expect(checks.attention, GatewayAttention.receiveSms);
    expect(checks.blocked, true);
  });
  test('rejected credentials and missing pairing outrank OEM uncertainty', () {
    for (final entry in {
      'unauthorized': GatewayAttention.unauthorized,
      'unpaired': GatewayAttention.unpaired,
    }.entries) {
      final checks = project({
        ...healthy(),
        'state': entry.key,
        'manufacturerAutostartRequired': true,
        'manufacturerAutostartState': 'unknown',
      });
      expect(checks.attention, entry.value);
      expect(checks.blocked, true);
      expect(checks.runtimeConnected, false);
    }
  });
  test('notification visibility warning does not claim SMS is blocked', () {
    final checks = project({...healthy(), 'notificationsEnabled': false});
    expect(checks.attention, GatewayAttention.notifications);
    expect(checks.blocked, false);
    expect(checks.receiveSms, true);
  });
  test(
    'OEM setting stays app-unknown and user confirmation is fingerprint-bound',
    () {
      final status = {
        ...healthy(),
        'manufacturerAutostartRequired': true,
        'manufacturerAutostartState': 'unknown',
      };
      expect(project(status).attention, GatewayAttention.autostart);
      final confirmed = project(status, confirmation: 'build-A');
      expect(confirmed.autostartConfirmedByUser, true);
      expect(confirmed.status['manufacturerAutostartState'], 'unknown');
      expect(confirmed.attention, null);
      expect(
        project(status, confirmation: 'older-OS-build').attention,
        GatewayAttention.autostart,
      );
    },
  );
  test('native read failure or stale snapshot clears healthy checks', () {
    expect(project({}, age: null).attention, GatewayAttention.notChecked);
    expect(
      project(healthy(), age: 30000).attention,
      GatewayAttention.notChecked,
    );
    expect(project(healthy(), age: -1).runtimeConnected, false);
  });
  test(
    'monotonic heartbeat ages advance with snapshot age; wall time is display-only',
    () {
      final status = {...healthy(), 'lastSync': '2099-01-01T00:00:00Z'};
      for (final age in [null, -1, 30000]) {
        expect(
          project({...status, 'lastSyncAgeMs': age}).runtimeConnected,
          false,
        );
      }
      expect(
        project({
          ...status,
          'lastSyncAgeMs': 29000,
        }, age: 2000).runtimeConnected,
        false,
      );
      expect(
        project({...status, 'lastSyncAgeMs': 29000}, age: 500).runtimeConnected,
        true,
      );
    },
  );
  test('battery exemption does not erase OS background restriction', () {
    final checks = project({
      ...healthy(),
      'batteryExempt': true,
      'backgroundRestricted': true,
    });
    expect(checks.attention, GatewayAttention.backgroundRestricted);
    expect(checks.blocked, false);
  });
  test(
    'unsupported background restriction check is neutral; supported unknown is not a pass',
    () {
      expect(
        project({
          ...healthy(),
          'backgroundRestrictionCheckSupported': false,
          'backgroundRestricted': null,
        }).attention,
        null,
      );
      expect(
        project({...healthy(), 'backgroundRestricted': null}).attention,
        GatewayAttention.notChecked,
      );
    },
  );
}
