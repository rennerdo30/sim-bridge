import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sim_bridge/api.dart';
import 'package:sim_bridge/gateway_runtime.dart';
import 'package:sim_bridge/device_authorization.dart';
import 'package:sim_bridge/session_store.dart';
import 'package:sim_bridge/protocol.dart';
import 'authorization_coordinator_test.dart' show MemoryStore, paired;
import 'support/authorization_fixture.dart';
import 'support/relay_http_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'policy commits independently of held command claim; restart recovery waits for latest durable policy',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      final original = await paired();
      final store = MemoryStore(original);
      final command = buildCommand(
        type: 'send_sms',
        bridgeId: original.bridgeId,
        senderDeviceId: 'client',
        targetDeviceId: original.deviceId,
        issuedAt: DateTime.now(),
        payload: {'address': 'synthetic', 'body': 'synthetic'},
      );
      final envelope = await original.crypto.seal(command);
      final claiming = Completer<void>(),
          releaseClaim = Completer<bool>(),
          commitStarted = Completer<void>(),
          releaseCommit = Completer<void>(),
          bootstrapped = Completer<void>();
      var queued = false, restart = false, sends = 0, bootstraps = 0;
      String? proposal, outcome;
      final clients = <RelayFixtureClient>[];
      final rest = MockClient((request) async {
        if (request.url.path == '/v1/auth/policy') {
          return http.Response(
            proposal == null
                ? '{}'
                : jsonEncode({
                    'policyJson': proposal,
                    'proposalId': 'proposal',
                    'baseRevision': 1,
                    'revision': 2,
                  }),
            200,
          );
        }
        if (request.url.path == '/v1/auth/challenge') {
          return http.Response(
            jsonEncode(await fixtureChallenge(jsonDecode(request.body))),
            200,
          );
        }
        if (request.url.path == '/v1/auth/policy/commit') {
          if (!commitStarted.isCompleted) commitStarted.complete();
          await releaseCommit.future;
          proposal = null;
          return http.Response('{}', 200);
        }
        if (request.url.path == '/v1/auth/bootstrap') {
          bootstraps++;
          final payload = jsonDecode(request.body)['payloadJson'];
          expect(jsonDecode(payload)['revision'], 2);
          expect(store.session.authorization!.policyJson, payload);
          restart = false;
          if (!bootstrapped.isCompleted) bootstrapped.complete();
          return http.Response(
            jsonEncode({
              'token': 'renewed-session',
              'bootId': 'boot-after-restart',
              'device': {'id': original.deviceId},
              'bridge': {'id': original.bridgeId},
              'certificate': original.authorization!.certificate,
            }),
            200,
          );
        }
        if (request.url.path == '/v1/commands') {
          return http.Response(
            jsonEncode({
              'commands': queued
                  ? [
                      {
                        'id': 'relay-command',
                        'requestedBy': 'client',
                        'envelope': envelope,
                      },
                    ]
                  : [],
            }),
            200,
          );
        }
        return http.Response('{}', 200);
      });
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        GatewayRuntime.lifecycle,
        (_) async => true,
      );
      messenger.setMockMethodCallHandler(GatewayRuntime.hardware, (call) async {
        switch (call.method) {
          case 'hasPhoneRole':
            return false;
          case 'getSubscriptions':
          case 'peekPending':
          case 'pendingReceipts':
            return [];
          case 'claimCommand':
            if (!claiming.isCompleted) claiming.complete();
            return releaseClaim.future;
          case 'sendSms':
            sends++;
            return true;
          case 'finishCommand':
            outcome = (call.arguments as Map)['status'];
            queued = false;
            return null;
          case 'clearQueues':
            fail('Restart recovery must preserve the native journal');
          default:
            return null;
        }
      });
      final runtime = GatewayRuntime(store: store);
      try {
        await http.runWithClient(
          () async {
            await runtime.start();
            await Future<void>.delayed(const Duration(milliseconds: 40));
            final active = clients.singleWhere((c) => c.activeConnections == 1);
            queued = true;
            active.emit(RelayEvent.commands);
            await claiming.future.timeout(const Duration(seconds: 3));
            proposal = fixturePolicy(original, 2, joinable: false);
            active.emit(RelayEvent.policy);
            await commitStarted.future.timeout(const Duration(seconds: 3));
            expect(
              jsonDecode(store.session.authorization!.policyJson!)['revision'],
              2,
            );
            restart = true;
            active.end();
            await Future<void>.delayed(const Duration(milliseconds: 1200));
            expect(
              bootstraps,
              0,
            ); // Recovery cannot race the policy transaction.
            releaseCommit.complete();
            await bootstrapped.future.timeout(const Duration(seconds: 3));
            releaseClaim.complete(true);
            await Future<void>.delayed(const Duration(milliseconds: 80));
            expect(sends, 0);
            expect(outcome, 'unknown');
            expect(store.session.deviceId, original.deviceId);
            expect(store.session.key, original.key);
            expect(
              jsonDecode(store.session.authorization!.policyJson!)['revision'],
              2,
            );
            await runtime.stop();
          },
          () => RelayFixtureClient(
            rest,
            eventStatus: restart ? 409 : 200,
            eventCode: restart ? 'pairing_recovery_pending' : null,
          )..also(clients.add),
        );
      } finally {
        if (!releaseCommit.isCompleted) releaseCommit.complete();
        if (!releaseClaim.isCompleted) releaseClaim.complete(false);
        await runtime.stop();
        messenger.setMockMethodCallHandler(GatewayRuntime.hardware, null);
        messenger.setMockMethodCallHandler(GatewayRuntime.lifecycle, null);
      }
    },
  );
  test(
    'gateway startup consumes a durable operator candidate after process death without touching journal',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      const legacy = Session(
        server: 'http://127.0.0.1:18798',
        token: 'legacy-session',
        deviceId: 'gateway',
        bridgeId: 'bridge',
        key: [7],
      );
      final store = MemoryStore(legacy);
      final identity = await store.prepareUpgradeIdentity(legacy);
      final auth = DeviceAuthorization(
        identity: identity,
        certificate: fixtureCertificate(identity),
      );
      final candidate = legacy.withCredentials(legacy.token, auth);
      final policy = fixturePolicy(candidate, 1);
      await store.stageOperatorRecovery(
        legacy,
        auth.certificate,
        policy,
        gateway: true,
      );
      var boots = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        GatewayRuntime.lifecycle,
        (_) async => true,
      );
      messenger.setMockMethodCallHandler(GatewayRuntime.hardware, (call) async {
        if (call.method == 'clearQueues') {
          fail('Operator recovery must preserve journal');
        }
        return switch (call.method) {
          'peekPending' || 'pendingReceipts' || 'getSubscriptions' => [],
          'hasPhoneRole' => false,
          _ => null,
        };
      });
      final runtime = GatewayRuntime(store: store);
      try {
        await http.runWithClient(
          () async {
            await runtime.start();
            expect(boots, 1);
            expect(store.session.deviceId, legacy.deviceId);
            expect(store.session.key, legacy.key);
            expect(store.session.authorization!.policyJson, policy);
            expect(store.session.token, 'operator-session');
            expect(
              await SessionStore.secureStorage.read(key: 'operatorRecovery'),
              isNull,
            );
            await runtime.stop();
          },
          () => RelayFixtureClient(
            MockClient((request) async {
              if (request.url.path == '/v1/auth/bootstrap') {
                boots++;
                expect(
                  await SessionStore.secureStorage.read(
                    key: 'operatorRecovery',
                  ),
                  isNotNull,
                );
                expect(jsonDecode(request.body)['payloadJson'], policy);
                return http.Response(
                  jsonEncode({
                    'token': 'operator-session',
                    'bootId': 'boot-after-restart',
                    'certificate': auth.certificate,
                    'device': {'id': legacy.deviceId},
                    'bridge': {'id': legacy.bridgeId},
                  }),
                  200,
                );
              }
              if (request.url.path == '/v1/commands') {
                return http.Response('{"commands":[]}', 200);
              }
              return http.Response('{}', 200);
            }),
          ),
        );
      } finally {
        await runtime.stop();
        messenger.setMockMethodCallHandler(GatewayRuntime.hardware, null);
        messenger.setMockMethodCallHandler(GatewayRuntime.lifecycle, null);
      }
    },
  );
}

extension Tap<T> on T {
  T also(void Function(T) operation) {
    operation(this);
    return this;
  }
}
