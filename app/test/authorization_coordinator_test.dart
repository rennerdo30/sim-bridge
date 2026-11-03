import 'dart:async';
import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sim_bridge/api.dart';
import 'package:sim_bridge/authorization_coordinator.dart';
import 'package:sim_bridge/device_authorization.dart';
import 'package:sim_bridge/session_store.dart';
import 'support/authorization_fixture.dart';

class MemoryStore extends SessionStore {
  MemoryStore(this.session) : super(allowGatewayPolicyStorage: true);
  Session session;
  bool failWrite = false;
  final writes = <Session>[];
  @override
  Future<StoredSession?> load() async =>
      StoredSession(session, gateway: session.authorization?.authority == true);
  @override
  Future<void> persistAuthorization(Session value) async {
    if (failWrite) throw const StoredPairingUnavailable();
    writes.add(value);
    session = value;
  }
}

Future<Session> paired({bool authority = true}) async {
  final identity = await DeviceSigningIdentity.generate();
  final initial = Session(
    server: 'http://127.0.0.1:18798',
    token: 'old-session',
    deviceId: authority ? 'gateway' : 'client',
    bridgeId: 'bridge',
    key: List.filled(32, 7),
    authorization: DeviceAuthorization(
      identity: identity,
      certificate: fixtureCertificate(
        identity,
        deviceId: authority ? 'gateway' : 'client',
        authority: authority,
      ),
      bootId: 'old-boot',
    ),
  );
  return authority
      ? initial.withCredentials(
          initial.token,
          initial.authorization!.withPolicy(fixturePolicy(initial, 1)),
        )
      : initial;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });
  test(
    'independent Ed25519 identity signs bound challenge and rejects signing oracle changes',
    () async {
      final session = await paired(authority: false);
      final auth = session.authorization!;
      expect(auth.identity.seed, isNot(base64UrlEncode(session.key)));
      expect(auth.identity.publicKey.contains('='), false);
      final challenge = await fixtureChallenge({
        'certificate': auth.certificate,
        'operation': 'resume',
        'payloadJson': '',
      });
      final signed = await auth.challengeSignature(challenge, 'resume', '');
      expect(signed.contains('='), false);
      expect(
        await Ed25519().verify(
          utf8.encode(challenge['signingPayload']),
          signature: Signature(
            decodeAuthorizationBytes(signed),
            publicKey: SimplePublicKey(
              decodeAuthorizationBytes(auth.identity.publicKey),
              type: KeyPairType.ed25519,
            ),
          ),
        ),
        true,
      );
      expect(
        () => auth.challengeSignature(challenge, 'bootstrap', ''),
        throwsFormatException,
      );
      expect(
        () => auth.challengeSignature(challenge, 'resume', 'other'),
        throwsFormatException,
      );
    },
  );
  test(
    'durable new policy precedes ACK and survives a lost ACK for idempotent retry',
    () async {
      final original = await paired();
      final store = MemoryStore(original);
      final next = fixturePolicy(original, 2, joinable: false);
      var commits = 0;
      final client = MockClient((request) async {
        if (request.url.path == '/v1/auth/policy') {
          return http.Response(
            jsonEncode({
              'policyJson': next,
              'proposalId': 'proposal',
              'baseRevision': 1,
              'revision': 2,
            }),
            200,
          );
        }
        if (request.url.path == '/v1/auth/challenge') {
          expect(store.session.authorization!.policyJson, next);
          return http.Response(
            jsonEncode(await fixtureChallenge(jsonDecode(request.body))),
            200,
          );
        }
        if (request.url.path == '/v1/auth/policy/commit') {
          expect(store.session.authorization!.policyJson, next);
          return http.Response(
            commits++ == 0 ? '{}' : '{}',
            commits == 1 ? 503 : 200,
          );
        }
        fail('Unexpected path ${request.url.path}');
      });
      await http.runWithClient(() async {
        final coordinator = AuthorizationCoordinator(
          store,
          gatewayWriter: true,
        );
        await expectLater(
          coordinator.commitPolicy(original),
          throwsA(isA<RelayRequestException>()),
        );
        expect(store.session.authorization!.policyJson, next);
        await coordinator.commitPolicy(store.session);
        expect(commits, 2);
        expect(store.session.deviceId, original.deviceId);
      }, () => client);
    },
  );
  test(
    'storage failure cannot acknowledge or sign a policy proposal',
    () async {
      final original = await paired();
      final store = MemoryStore(original)..failWrite = true;
      var proofRequests = 0;
      await http.runWithClient(
        () async {
          await expectLater(
            AuthorizationCoordinator(
              store,
              gatewayWriter: true,
            ).commitPolicy(original),
            throwsA(isA<StoredPairingUnavailable>()),
          );
          expect(proofRequests, 0);
          expect(
            store.session.authorization!.policyJson,
            original.authorization!.policyJson,
          );
        },
        () => MockClient((request) async {
          if (request.url.path != '/v1/auth/policy') proofRequests++;
          return http.Response(
            jsonEncode({
              'policyJson': fixturePolicy(original, 2),
              'proposalId': 'proposal',
              'baseRevision': 1,
              'revision': 2,
            }),
            200,
          );
        }),
      );
    },
  );
  test(
    'restart resumes same member identity and keys; member never bootstraps',
    () async {
      final original = await paired(authority: false);
      final store = MemoryStore(original);
      final paths = <String>[];
      await http.runWithClient(
        () async {
          final result = await AuthorizationCoordinator(
            store,
          ).recover(original);
          expect(result.deviceId, original.deviceId);
          expect(result.bridgeId, original.bridgeId);
          expect(result.key, original.key);
          expect(result.token, 'new-session');
          expect(result.authorization!.bootId, 'boot-after-restart');
          expect(paths, ['/v1/auth/challenge', '/v1/auth/resume']);
        },
        () => MockClient((request) async {
          paths.add(request.url.path);
          if (request.url.path.endsWith('/challenge')) {
            return http.Response(
              jsonEncode(await fixtureChallenge(jsonDecode(request.body))),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'token': 'new-session',
              'device': {'id': original.deviceId},
              'bridge': {'id': original.bridgeId},
              'certificate': original.authorization!.certificate,
              'bootId': 'boot-after-restart',
            }),
            200,
          );
        }),
      );
    },
  );
  test(
    'visible authority adopts newer worker record without any proof or write',
    () async {
      final original = await paired();
      final next = original.withCredentials(
        'worker-renewed',
        original.authorization!.withPolicy(fixturePolicy(original, 2)),
      );
      final store = MemoryStore(next);
      await http.runWithClient(
        () async {
          final result = await AuthorizationCoordinator(
            store,
          ).recover(original);
          expect(result.token, 'worker-renewed');
          expect(
            result.authorization!.policyJson,
            next.authorization!.policyJson,
          );
          expect(store.writes, isEmpty);
        },
        () => MockClient((_) async {
          fail('Visible UI must not renew authority or write its ledger');
        }),
      );
    },
  );
  test(
    'old relay keeps gateway pairing while prepared signing identity survives restart',
    () async {
      final legacy = Session(
        server: 'http://127.0.0.1:18798',
        token: 'legacy-session',
        deviceId: 'gateway',
        bridgeId: 'bridge',
        key: List.filled(32, 7),
      );
      final store = SessionStore(allowGatewayPolicyStorage: true);
      await store.save(legacy, gateway: true);
      String? protectedIdentity;
      var healthRequests = 0;
      await http.runWithClient(
        () async {
          final result = await AuthorizationCoordinator(
            store,
            gatewayWriter: true,
          ).upgradeIfSupported(legacy);
          expect(identical(result, legacy), isTrue);
          final restartedStore = SessionStore(allowGatewayPolicyStorage: true);
          final identity = await restartedStore.prepareUpgradeIdentity(
            legacy,
            createIfMissing: false,
          );
          final prepared = jsonDecode(protectedIdentity!) as Map;
          expect(identity.seed, prepared['seed']);
          expect(identity.publicKey, prepared['publicKey']);
          await AuthorizationCoordinator(
            restartedStore,
            gatewayWriter: true,
          ).upgradeIfSupported(legacy);
          expect(
            await SessionStore.secureStorage.read(
              key: 'pendingUpgradeIdentity',
            ),
            protectedIdentity,
          );
          final saved = (await restartedStore.load())!;
          expect(saved.gateway, isTrue);
          expect(saved.session.deviceId, legacy.deviceId);
          expect(saved.session.bridgeId, legacy.bridgeId);
          expect(saved.session.token, legacy.token);
          expect(saved.session.key, legacy.key);
          expect(saved.session.authorization, isNull);
          expect(healthRequests, 2);
        },
        () => MockClient((request) async {
          expect(request.url.path, '/health');
          final persisted = await SessionStore.secureStorage.read(
            key: 'pendingUpgradeIdentity',
          );
          expect(persisted, isNotNull);
          protectedIdentity ??= persisted;
          expect(persisted, protectedIdentity);
          healthRequests++;
          return http.Response('{"ok":true}', 200);
        }),
      );
    },
  );
  test(
    'lost upgrade response retains pending signing key; retry never changes identity',
    () async {
      const legacy = Session(
        server: 'http://127.0.0.1:18798',
        token: 'legacy-session',
        deviceId: 'client',
        bridgeId: 'bridge',
        key: [7],
      );
      final store = MemoryStore(legacy);
      final keys = <String>[];
      var attempts = 0;
      await http.runWithClient(
        () async {
          final coordinator = AuthorizationCoordinator(store);
          await expectLater(
            coordinator.upgradeIfSupported(legacy),
            throwsA(isA<TimeoutException>()),
          );
          final result = await coordinator.upgradeIfSupported(legacy);
          expect(keys.length, 2);
          expect(keys.first, keys.last);
          expect(result.deviceId, legacy.deviceId);
          expect(result.key, legacy.key);
        },
        () => MockClient((request) async {
          if (request.url.path == '/health') {
            return http.Response('{"authorizationVersion":2}', 200);
          }
          if (request.url.path.endsWith('/challenge')) {
            return http.Response(
              jsonEncode(await fixtureChallenge(jsonDecode(request.body))),
              200,
            );
          }
          final payload = jsonDecode(jsonDecode(request.body)['payloadJson']);
          keys.add(payload['devicePublicKey']);
          if (attempts++ == 0) throw TimeoutException('Lost response');
          return http.Response(
            jsonEncode({
              'certificate': fixtureCertificate(
                DeviceSigningIdentity('', keys.last),
                deviceId: 'client',
                authority: false,
              ),
              'bootId': 'old-boot',
            }),
            200,
          );
        }),
      );
    },
  );
  test(
    'legacy RAM mapping lost fails closed and preserves old credentials and pending key',
    () async {
      const legacy = Session(
        server: 'http://127.0.0.1:18798',
        token: 'legacy-session',
        deviceId: 'client',
        bridgeId: 'bridge',
        key: [7],
      );
      final store = MemoryStore(legacy);
      await http.runWithClient(
        () async {
          await expectLater(
            AuthorizationCoordinator(store).upgradeIfSupported(legacy),
            throwsA(
              isA<RelayRequestException>().having(
                (e) => e.code,
                'code',
                'legacy_upgrade_required',
              ),
            ),
          );
          expect(store.writes, isEmpty);
          expect(store.session.token, legacy.token);
          expect(
            await SessionStore.secureStorage.read(
              key: 'pendingUpgradeIdentity',
            ),
            isNotNull,
          );
        },
        () => MockClient((request) async {
          if (request.url.path == '/health') {
            return http.Response('{"authorizationVersion":2}', 200);
          }
          if (request.url.path.endsWith('/challenge')) {
            return http.Response(
              jsonEncode(await fixtureChallenge(jsonDecode(request.body))),
              200,
            );
          }
          return http.Response(
            '{"code":"legacy_upgrade_required","error":"Operator recovery required"}',
            401,
          );
        }),
      );
    },
  );
  test(
    'durable erased authority is terminal after publishing its tombstone',
    () async {
      final original = await paired();
      final erased =
          jsonDecode(original.authorization!.policyJson!)
              as Map<String, dynamic>;
      erased['erased'] = true;
      erased['joinable'] = false;
      erased['members'] = [];
      final session = original.withCredentials(
        original.token,
        original.authorization!.withPolicy(jsonEncode(erased)),
      );
      final store = MemoryStore(session);
      await http.runWithClient(
        () async {
          await expectLater(
            AuthorizationCoordinator(
              store,
              gatewayWriter: true,
            ).recover(session),
            throwsA(
              isA<RelayRequestException>().having(
                (e) => e.code,
                'code',
                'device_revoked',
              ),
            ),
          );
          expect(store.writes, isEmpty);
          expect(
            store.session.authorization!.policyJson,
            session.authorization!.policyJson,
          );
        },
        () => MockClient((request) async {
          if (request.url.path.endsWith('/challenge')) {
            return http.Response(
              jsonEncode(await fixtureChallenge(jsonDecode(request.body))),
              200,
            );
          }
          return http.Response('{"erased":true}', 200);
        }),
      );
    },
  );
  test(
    'staged operator certificate with missing private identity never generates another key',
    () async {
      const legacy = Session(
        server: 'http://127.0.0.1:18798',
        token: 'legacy-session',
        deviceId: 'client',
        bridgeId: 'bridge',
        key: [7],
      );
      final store = MemoryStore(legacy);
      final identity = await store.prepareUpgradeIdentity(legacy);
      await store.stageOperatorRecovery(
        legacy,
        fixtureCertificate(identity, deviceId: 'client', authority: false),
        null,
        gateway: false,
      );
      await SessionStore.secureStorage.delete(key: 'pendingUpgradeIdentity');
      await expectLater(
        store.stagedOperatorRecovery(legacy, gateway: false),
        throwsA(isA<StoredPairingUnavailable>()),
      );
      expect(
        await SessionStore.secureStorage.read(key: 'pendingUpgradeIdentity'),
        isNull,
      );
      expect(
        await SessionStore.secureStorage.read(key: 'operatorRecovery'),
        isNotNull,
      );
    },
  );
  test(
    'Android storage errors cannot invoke destructive secure-storage reset',
    () {
      expect(
        SessionStore.secureStorage.aOptions.toMap()['resetOnError'],
        'false',
      );
    },
  );
  test(
    'complete protected record repairs interrupted first-save metadata without pairing again',
    () async {
      final original = await paired();
      final failing = SessionStore(
        allowGatewayPolicyStorage: true,
        authorizationBarrier: () async =>
            throw const StoredPairingUnavailable(),
      );
      await expectLater(
        failing.save(original, gateway: true),
        throwsA(isA<StoredPairingUnavailable>()),
      );
      final restored = await SessionStore(
        allowGatewayPolicyStorage: true,
      ).load();
      expect(restored!.session.deviceId, original.deviceId);
      expect(restored.session.bridgeId, original.bridgeId);
      expect(restored.session.key, original.key);
      expect(
        restored.session.authorization!.identity.seed,
        original.authorization!.identity.seed,
      );
      expect(
        (await SharedPreferences.getInstance()).getBool('sessionReady'),
        true,
      );
    },
  );
  test(
    'disk flush must complete before signing or acknowledging new policy; clear also flushes',
    () async {
      final original = await paired();
      final held = Completer<void>();
      var holding = false, flushes = 0, proofCalls = 0;
      final store = SessionStore(
        allowGatewayPolicyStorage: true,
        authorizationBarrier: () async {
          flushes++;
          if (holding) await held.future;
        },
      );
      await store.save(original, gateway: true);
      holding = true;
      await http.runWithClient(
        () async {
          final work = AuthorizationCoordinator(
            store,
            gatewayWriter: true,
          ).commitPolicy(original);
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(proofCalls, 0);
          held.complete();
          await work;
          expect(proofCalls, 1);
        },
        () => MockClient((request) async {
          if (request.url.path == '/v1/auth/policy') {
            return http.Response(
              jsonEncode({
                'policyJson': fixturePolicy(original, 2),
                'proposalId': 'proposal',
                'baseRevision': 1,
                'revision': 2,
              }),
              200,
            );
          }
          if (request.url.path.endsWith('/challenge')) {
            return http.Response(
              jsonEncode(await fixtureChallenge(jsonDecode(request.body))),
              200,
            );
          }
          proofCalls++;
          return http.Response('{}', 200);
        }),
      );
      holding = false;
      final before = flushes;
      await store.clear();
      expect(flushes, before + 1);
      expect(
        await SessionStore.secureStorage.read(key: 'deviceAuthorization'),
        isNull,
      );
    },
  );
  test(
    'operator restore rejects rollback of a locally known policy before sending a proof',
    () async {
      final original = await paired();
      final newer = original.withCredentials(
        original.token,
        original.authorization!.withPolicy(fixturePolicy(original, 5)),
      );
      final store = MemoryStore(newer);
      await expectLater(
        store.stageOperatorRecovery(
          newer,
          original.authorization!.certificate,
          fixturePolicy(original, 3),
          gateway: true,
        ),
        throwsFormatException,
      );
      expect(
        await SessionStore.secureStorage.read(key: 'operatorRecovery'),
        isNull,
      );
      expect(
        store.session.authorization!.policyJson,
        newer.authorization!.policyJson,
      );
    },
  );
  test(
    'visible erased authority is terminal even when the worker keeps the old token',
    () async {
      final original = await paired();
      final policy = jsonDecode(original.authorization!.policyJson!) as Map;
      policy['erased'] = true;
      policy['members'] = [];
      policy['joinable'] = false;
      final erased = original.withCredentials(
        original.token,
        original.authorization!.withPolicy(jsonEncode(policy)),
      );
      await expectLater(
        AuthorizationCoordinator(MemoryStore(erased)).recover(original),
        throwsA(
          isA<RelayRequestException>().having(
            (e) => e.code,
            'code',
            'device_revoked',
          ),
        ),
      );
    },
  );
}
