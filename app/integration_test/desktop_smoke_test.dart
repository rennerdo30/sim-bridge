import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:http/http.dart' as http;
import 'package:sim_bridge/api.dart';
import 'package:sim_bridge/device_authorization.dart';
import 'package:sim_bridge/platform_support.dart';
import 'package:sim_bridge/protocol.dart';
import 'package:sim_bridge/security.dart';
import 'package:sim_bridge/session_store.dart';

// Run explicitly on macOS against the disposable desktop smoke relay. The
// fixture owns a synthetic zero-key bridge and never connects to a physical SIM.
const _fixtureRelay = String.fromEnvironment(
  'SIM_BRIDGE_SMOKE_RELAY',
  defaultValue: 'http://127.0.0.1:18798',
);
const _smokeService = 'dev.renner.simbridge.desktop.smoke.credentials';
const _testMessage = 'Desktop outgoing smoke';
const _testNumber = '+15550102002';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'macOS native Keychain stores, reloads, and deletes isolated credentials',
    (tester) async {
      expect(
        Platform.isMacOS,
        isTrue,
        reason: 'Run this integration test with -d macos.',
      );
      await tester.pumpWidget(const MaterialApp(home: Scaffold()));

      final productionOptions =
          SessionStore.secureStorage.mOptions as MacOsOptions;
      final smokeOptions = MacOsOptions(
        accountName: _smokeService,
        usesDataProtectionKeychain:
            productionOptions.usesDataProtectionKeychain,
        accessibility: productionOptions.accessibility,
        synchronizable: productionOptions.synchronizable,
      );
      final expectedOptions = Map<String, String>.from(
        productionOptions.toMap(),
      )..['accountName'] = _smokeService;
      expect(
        smokeOptions.toMap(),
        expectedOptions,
        reason:
            'Use the production Keychain policy with a separate test service.',
      );
      final writer = FlutterSecureStorage(mOptions: smokeOptions);
      final rootKey = await BridgeCrypto.newKey();
      final encodedRootKey = base64UrlEncode(rootKey);
      final token = base64UrlEncode(await BridgeCrypto.newKey());
      final signing = await DeviceSigningIdentity.generate();
      final protectedIdentity = jsonEncode({
        'seed': signing.seed,
        'publicKey': signing.publicKey,
      });
      try {
        await writer.write(key: 'deviceToken', value: token);
        await writer.write(key: 'bridgeKey', value: encodedRootKey);
        await writer.write(
          key: 'smokeSigningIdentity',
          value: protectedIdentity,
        );
        // A new Dart storage object must load the actual native Keychain entries.
        final reader = FlutterSecureStorage(mOptions: smokeOptions);
        expect(
          await reader.read(key: 'deviceToken') == token,
          isTrue,
          reason: 'The native Keychain did not reload the credential.',
        );
        expect(
          await reader.read(key: 'bridgeKey') == encodedRootKey,
          isTrue,
          reason: 'The native Keychain did not reload the root key.',
        );
        expect(
          await reader.read(key: 'smokeSigningIdentity'),
          protectedIdentity,
        );
        final stored =
            jsonDecode((await reader.read(key: 'smokeSigningIdentity'))!)
                as Map;
        final restoredSigning = DeviceSigningIdentity(
          stored['seed'] as String,
          stored['publicKey'] as String,
        );
        expect(
          await restoredSigning.sign('native key continuity'),
          await signing.sign('native key continuity'),
        );
        await reader.delete(key: 'smokeSigningIdentity');
        expect(await reader.containsKey(key: 'deviceToken'), isTrue);
        await reader.delete(key: 'deviceToken');
        await reader.delete(key: 'bridgeKey');
        expect(await writer.read(key: 'deviceToken') == null, isTrue);
        expect(await writer.read(key: 'bridgeKey') == null, isTrue);
      } finally {
        // Never read/delete the application's normal credential service or prefs.
        await writer.delete(key: 'smokeSigningIdentity');
        await writer.delete(key: 'deviceToken');
        await writer.delete(key: 'bridgeKey');
      }
    },
  );

  testWidgets(
    'desktop native client keeps pairing across cold restart and rejects revoked identity after restart',
    (tester) async {
      expect(
        Platform.isMacOS,
        isTrue,
        reason: 'Run this integration test with -d macos.',
      );
      final uri = Uri.parse(_fixtureRelay);
      expect(
        uri.scheme == 'http' &&
            uri.host == '127.0.0.1' &&
            uri.port >= 1024 &&
            uri.port != 8787,
        isTrue,
        reason:
            'Only a disposable loopback relay may be used; live port 8787 is forbidden.',
      );
      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      final key = List<int>.filled(bridgeKeyBytes, 0);
      final identity = await BridgeIdentity.derive(key);
      final api = BridgeApi(_fixtureRelay);
      final enrolled = <Session>[];
      final connections = <RelayEvents>[];
      final subscriptions = <StreamSubscription<RelayEvent>>[];
      Future<Session> enroll(String name, bool syntheticGateway) async {
        final signing = await DeviceSigningIdentity.generate();
        final response = await api.join(
          identity,
          name,
          syntheticGateway,
          signingIdentity: signing,
        );
        final certificate = response['certificate'] as String;
        final authorization = DeviceAuthorization(
          identity: signing,
          certificate: certificate,
        );
        final device = Map<String, dynamic>.from(response['device'] as Map);
        final result = Session(
          server: _fixtureRelay,
          token: response['token'] as String,
          deviceId: device['id'] as String,
          bridgeId: identity.bridgeId,
          key: key,
          authorization: authorization,
        );
        authorization.validateFor(result.bridgeId, result.deviceId);
        enrolled.add(result);
        expect(
          device['capabilities']['smsGateway'] == syntheticGateway,
          isTrue,
        );
        return result;
      }

      Future<void> connectEvents(
        Session device,
        void Function(RelayEvent) receive,
        void Function(Object) failed,
      ) async {
        final ready = Completer<void>();
        final connection = api.events(device);
        connections.add(connection);
        subscriptions.add(
          connection.stream.listen(
            (event) {
              if (event == RelayEvent.ready && !ready.isCompleted) {
                ready.complete();
              }
              receive(event);
            },
            onError: (Object error) {
              if (!ready.isCompleted) ready.completeError(error);
              failed(error);
            },
          ),
        );
        await ready.future.timeout(const Duration(seconds: 10));
      }

      Future<Map<String, dynamic>> restartFixture({
        String action = '/restart',
      }) async {
        final response = await http
            .post(
              Uri(
                scheme: 'http',
                host: '127.0.0.1',
                port: uri.port + 1,
                path: action,
              ),
              headers: {'x-smoke-fixture': 'restart-owned-child'},
            )
            .timeout(const Duration(seconds: 20));
        expect(
          response.statusCode,
          200,
          reason: 'Only the fixture-owned relay may restart.',
        );
        return jsonDecode(response.body) as Map<String, dynamic>;
      }

      try {
        final host = BridgePlatform.current;
        var client = await enroll(
          'Desktop native integration client',
          host.restoreGateway(true),
        );
        final clientEvents = <RelayEvent>[];
        var incomingHint = Completer<void>();
        final clientRevoked = Completer<void>();
        await connectEvents(
          client,
          (event) {
            clientEvents.add(event);
            if (event == RelayEvent.messages && !incomingHint.isCompleted) {
              incomingHint.complete();
            }
          },
          (failure) {
            if (failure is RelayRequestException &&
                failure.status == 401 &&
                !clientRevoked.isCompleted) {
              clientRevoked.complete();
            }
          },
        );
        final roster = await api.roster(client);
        final ownDevice = roster.devices
            .cast<Map<String, dynamic>>()
            .singleWhere((device) => device['id'] == client.deviceId);
        expect(ownDevice['capabilities']['smsGateway'] == false, isTrue);
        expect(ownDevice['capabilities']['calls'] == false, isTrue);
        final fixtureGateways = roster.devices
            .cast<Map<String, dynamic>>()
            .where((device) => device['capabilities']['smsGateway'] == true)
            .map((device) => device['id'])
            .toSet();
        expect(fixtureGateways.isNotEmpty, isTrue);
        await restartFixture(action: '/seed');
        final page = await api.messagesSince(client, 0);
        final decrypted = <Map<String, dynamic>>[];
        for (final record in page.records) {
          decrypted.add(
            await client.crypto.open(
              Map<String, dynamic>.from(record['envelope'] as Map),
            ),
          );
        }
        bool belongsToFixtureGateway(Map<String, dynamic> event) =>
            event['v'] == commandProtocolVersion &&
            event['bridgeId'] == client.bridgeId &&
            fixtureGateways.contains(event['senderDeviceId']) &&
            event['gatewayDeviceId'] == event['senderDeviceId'];
        expect(
          decrypted.any(
            (event) =>
                event['kind'] == 'gateway_state' &&
                belongsToFixtureGateway(event) &&
                (event['simProfiles'] as List).isNotEmpty,
          ),
          isTrue,
          reason:
              'The fixture must publish a protocol-bound encrypted SIM state.',
        );
        expect(
          decrypted.any(
            (event) =>
                event['kind'] == 'sms' &&
                event['direction'] == 'incoming' &&
                belongsToFixtureGateway(event) &&
                event['body'] ==
                    'Desktop smoke message. Verification code:246810',
          ),
          isTrue,
          reason: 'The disposable fixture must seed a fresh encrypted SMS.',
        );

        // The fixture retains the gateway ledger outside its relay child. A
        // cold child has no sessions, queues, or membership database to reuse.
        final originalId = client.deviceId;
        final originalCertificate = client.authorization!.certificate;
        final originalRoot = base64UrlEncode(client.key);
        final beforeBoot = (await api.authorizationHealth())['bootId'];
        final restarted = await restartFixture();
        expect(restarted['bridgeId'], client.bridgeId);
        expect(restarted['bootId'] == beforeBoot, isFalse);
        final resumed = await api.authorizationProof(
          client.authorization!,
          'resume',
          '',
        );
        expect((resumed['device'] as Map)['id'], originalId);
        expect((resumed['bridge'] as Map)['id'], client.bridgeId);
        enrolled.remove(client);
        client = client.withCredentials(
          resumed['token'] as String,
          client.authorization!,
        );
        enrolled.add(client);
        expect(client.authorization!.certificate, originalCertificate);
        expect(base64UrlEncode(client.key), originalRoot);
        incomingHint = Completer<void>();
        await connectEvents(
          client,
          (event) {
            clientEvents.add(event);
            if (event == RelayEvent.messages && !incomingHint.isCompleted) {
              incomingHint.complete();
            }
          },
          (failure) {
            if (failure is RelayRequestException &&
                failure.status == 401 &&
                !clientRevoked.isCompleted) {
              clientRevoked.complete();
            }
          },
        );
        final afterRestart = await api.messagesSince(client, 0);
        expect(afterRestart.records.isNotEmpty, isTrue);
        expect(
          (await client.crypto.open(
            Map<String, dynamic>.from(
              afterRestart.records.first['envelope'] as Map,
            ),
          ))['bridgeId'],
          client.bridgeId,
        );

        // This relay-only target has no native worker or SIM. Its token lets the
        // test read the actual stored command, prove its bindings, and acknowledge
        // it without triggering an SMS on the owner's existing fixture gateway.
        final syntheticGateway = await enroll(
          'Integration synthetic gateway (no hardware)',
          true,
        );
        final gatewayCommandHint = Completer<void>();
        await connectEvents(syntheticGateway, (event) {
          if (event == RelayEvent.commands && !gatewayCommandHint.isCompleted) {
            gatewayCommandHint.complete();
          }
        }, (_) {});
        final issuedAt = DateTime.now().toUtc();
        final command = buildCommand(
          type: 'send_sms',
          bridgeId: client.bridgeId,
          senderDeviceId: client.deviceId,
          targetDeviceId: syntheticGateway.deviceId,
          issuedAt: issuedAt,
          payload: {
            'address': _testNumber,
            'body': _testMessage,
            'subscriptionId': 1,
          },
        );
        await api.command(
          client,
          syntheticGateway.deviceId,
          await client.crypto.seal(command),
        );
        await gatewayCommandHint.future.timeout(const Duration(seconds: 10));
        final queued = await api.commands(syntheticGateway);
        expect(queued.length == 1, isTrue);
        final record = Map<String, dynamic>.from(queued.single as Map);
        final received = await syntheticGateway.crypto.open(
          Map<String, dynamic>.from(record['envelope'] as Map),
        );
        expect(
          received['v'] == commandProtocolVersion &&
              received['type'] == 'send_sms' &&
              received['bridgeId'] == client.bridgeId &&
              received['senderDeviceId'] == client.deviceId &&
              received['targetDeviceId'] == syntheticGateway.deviceId &&
              received['commandId'] == command['commandId'] &&
              received['issuedAt'] == issuedAt.toIso8601String() &&
              received['address'] == _testNumber &&
              received['body'] == _testMessage,
          isTrue,
          reason:
              'The stored encrypted command did not retain its payload and protocol bindings.',
        );
        expect(
          record['requestedBy'] == client.deviceId &&
              record['targetDeviceId'] == syntheticGateway.deviceId,
          isTrue,
        );
        await api.complete(syntheticGateway, record['id'] as String, true);
        expect((await api.commands(syntheticGateway)).isEmpty, isTrue);

        incomingHint = Completer<void>();
        final inbound = bindEvent(
          {
            'kind': 'sms',
            'direction': 'incoming',
            'address': _testNumber,
            'body': 'Event-driven native fixture',
            'occurredAt': DateTime.now().toUtc().toIso8601String(),
          },
          bridgeId: client.bridgeId,
          senderDeviceId: syntheticGateway.deviceId,
        );
        await api.upload(
          syntheticGateway,
          await syntheticGateway.crypto.seal(inbound),
        );
        await incomingHint.future.timeout(const Duration(seconds: 10));
        final updated = await api.messagesSince(client, afterRestart.latestSeq);
        final receivedEvents = <Map<String, dynamic>>[];
        for (final row in updated.records) {
          receivedEvents.add(
            await client.crypto.open(
              Map<String, dynamic>.from(row['envelope'] as Map),
            ),
          );
        }
        expect(
          receivedEvents.any(
            (event) => event['body'] == 'Event-driven native fixture',
          ),
          isTrue,
        );
        expect(
          clientEvents.contains(RelayEvent.commands),
          isFalse,
          reason: 'Command signals must only reach their addressed gateway.',
        );
        await api.leave(client);
        enrolled.remove(client);
        await clientRevoked.future.timeout(const Duration(seconds: 10));
        await restartFixture();
        await expectLater(
          api.authorizationProof(client.authorization!, 'resume', ''),
          throwsA(
            isA<RelayRequestException>().having(
              (error) => error.code,
              'durable revoked identity',
              'device_revoked',
            ),
          ),
        );
        await expectLater(
          BridgeApi.forSession(client).roster(client),
          throwsA(
            isA<RelayRequestException>().having(
              (error) => error.status,
              'revoked token status',
              401,
            ),
          ),
        );
      } finally {
        for (final subscription in subscriptions) {
          await subscription.cancel();
        }
        for (final connection in connections) {
          await connection.close();
        }
        // Clean up both test enrollments even if any assertion above fails.
        Object? cleanupFailure;
        for (var device in enrolled.reversed) {
          try {
            final result = await api.authorizationProof(
              device.authorization!,
              'resume',
              '',
            );
            device = device.withCredentials(
              result['token'] as String,
              device.authorization!,
            );
            await api.leave(device);
          } catch (error) {
            cleanupFailure ??= error;
          }
        }
        if (cleanupFailure != null) throw cleanupFailure;
      }
    },
  );
}
